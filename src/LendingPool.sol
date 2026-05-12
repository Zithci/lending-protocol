// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "./LendingVault.sol";

/**
 * @title LendingPool
 * @notice Core lending protocol — deposit collateral, borrow, repay, liquidate
 *
 * Key parameters:
 * - LTV_RATIO = 75% — max borrow = 75% of collateral value
 * - LIQUIDATION_THRESHOLD = 80% — liquidate when debt > 80% of collateral value
 * - LIQUIDATION_BONUS = 10% — liquidator gets collateral + 10% bonus
 * - INTEREST_RATE = 5% per year (simple interest)
 */
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant LTV_RATIO = 75; // 75%
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant LIQUIDATION_BONUS = 10; // 10%
    uint256 public constant INTEREST_RATE = 5; // 5% per year
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant PRECISION = 100;

    // ============ State ============
    IERC20 public immutable weth; // Collateral token (18 decimals)
    IERC20 public immutable usdc; // Borrow token (6 decimals)
    AggregatorV3Interface public immutable oracle; // ETH/USD price feed
    LendingVault public immutable vault; // USDC vault for lenders

    struct Position {
        uint256 collateralAmount; // WETH deposited (18 decimals)
        uint256 debtAmount; // USDC borrowed (6 decimals)
        uint256 lastUpdateTime; // Timestamp for interest calculation
    }

    mapping(address => Position) public positions;

    // ============ Events ============
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    // ============ Constructor ============
    constructor(
        address _weth,
        address _usdc,
        address _oracle,
        address _vault
    ) {
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        oracle = AggregatorV3Interface(_oracle);
        vault = LendingVault(_vault);
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit WETH as collateral
     * @param amount Amount of WETH to deposit
     */
    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");

        weth.safeTransferFrom(msg.sender, address(this), amount);
        positions[msg.sender].collateralAmount += amount;

        emit CollateralDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw collateral (if position stays healthy or no debt)
     * @param amount Amount of WETH to withdraw
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(amount > 0, "Amount must be > 0");
        require(pos.collateralAmount >= amount, "Insufficient collateral");

        // Temporarily reduce collateral to check health
        pos.collateralAmount -= amount;

        // If user has debt, ensure position stays healthy
        if (pos.debtAmount > 0) {
            require(
                _healthFactor(msg.sender) >= PRECISION,
                "Would make position unhealthy"
            );
        }

        weth.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Borrow USDC against collateral
     * @param amount Amount of USDC to borrow
     */
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");

        Position storage pos = positions[msg.sender];
        require(pos.collateralAmount > 0, "No collateral deposited");

        // Accrue interest first
        _accrueInterest(msg.sender);

        // Check max borrowable (LTV check)
        uint256 collateralValueUSD = _getCollateralValueUSD(msg.sender);
        uint256 maxBorrow = (collateralValueUSD * LTV_RATIO) / PRECISION;
        uint256 currentDebt = pos.debtAmount;

        require(currentDebt + amount <= maxBorrow, "Exceeds max LTV");

        // Update debt
        pos.debtAmount += amount;
        pos.lastUpdateTime = block.timestamp;

        // Get USDC from vault and send to borrower
        vault.borrowFromVault(amount);
        usdc.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    /**
     * @notice Repay borrowed USDC
     * @param amount Amount of USDC to repay (use type(uint256).max for full repay)
     */
    function repay(uint256 amount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(pos.debtAmount > 0, "No debt to repay");

        // Accrue interest first
        _accrueInterest(msg.sender);

        // Handle full repayment
        uint256 repayAmount = amount;
        if (amount == type(uint256).max || amount > pos.debtAmount) {
            repayAmount = pos.debtAmount;
        }

        // Transfer USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), repayAmount);

        // Update debt
        pos.debtAmount -= repayAmount;

        // Send to vault
        usdc.approve(address(vault), repayAmount);
        vault.repayToVault(repayAmount);

        emit Repaid(msg.sender, repayAmount);
    }

    /**
     * @notice Liquidate an unhealthy position
     * @param user The borrower to liquidate
     */
    function liquidate(address user) external nonReentrant {
        require(user != msg.sender, "Cannot liquidate yourself");

        // Accrue interest
        _accrueInterest(user);

        // Check if position is liquidatable
        require(
            _healthFactor(user) < PRECISION,
            "Position is healthy"
        );

        Position storage pos = positions[user];
        uint256 debtToRepay = pos.debtAmount;

        // Calculate collateral to seize (debt value + bonus)
        // debtToRepay is in USDC (6 decimals)
        // collateral is in WETH (18 decimals)
        // Need to convert using oracle price

        uint256 ethPrice = _getETHPrice(); // 8 decimals
        // collateralToSeize = (debtToRepay * (100 + bonus)) / ethPrice
        // Adjust for decimals: USDC(6) -> WETH(18), price has 8 decimals
        uint256 collateralToSeize = (debtToRepay * (PRECISION + LIQUIDATION_BONUS) * 1e20) /
            (ethPrice * PRECISION);

        // Cap at user's collateral
        if (collateralToSeize > pos.collateralAmount) {
            collateralToSeize = pos.collateralAmount;
        }

        // Liquidator pays the debt
        usdc.safeTransferFrom(msg.sender, address(this), debtToRepay);

        // Send repayment to vault
        usdc.approve(address(vault), debtToRepay);
        vault.repayToVault(debtToRepay);

        // Update position
        pos.debtAmount = 0;
        pos.collateralAmount -= collateralToSeize;

        // Transfer collateral to liquidator
        weth.safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(user, msg.sender, debtToRepay, collateralToSeize);
    }

    // ============ View Functions ============

    /**
     * @notice Get health factor for a user (100 = 1.0, healthy threshold)
     */
    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Get collateral value in USD (6 decimals to match USDC)
     */
    function getCollateralValueUSD(address user) external view returns (uint256) {
        return _getCollateralValueUSD(user);
    }

    /**
     * @notice Get user's total debt including accrued interest
     */
    function getTotalDebt(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtAmount == 0) return 0;

        uint256 timeElapsed = block.timestamp - pos.lastUpdateTime;
        uint256 interest = (pos.debtAmount * INTEREST_RATE * timeElapsed) /
            (SECONDS_PER_YEAR * PRECISION);

        return pos.debtAmount + interest;
    }

    /**
     * @notice Get max borrowable amount for user
     */
    function getMaxBorrow(address user) external view returns (uint256) {
        uint256 collateralValueUSD = _getCollateralValueUSD(user);
        uint256 maxBorrow = (collateralValueUSD * LTV_RATIO) / PRECISION;
        uint256 currentDebt = positions[user].debtAmount;

        if (maxBorrow <= currentDebt) return 0;
        return maxBorrow - currentDebt;
    }

    // ============ Internal Functions ============

    function _healthFactor(address user) internal view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtAmount == 0) return type(uint256).max; // No debt = infinitely healthy

        uint256 collateralValueUSD = _getCollateralValueUSD(user);
        uint256 liquidationValue = (collateralValueUSD * LIQUIDATION_THRESHOLD) / PRECISION;

        // Health factor = liquidationValue / debt * PRECISION
        // If >= PRECISION (100), position is healthy
        return (liquidationValue * PRECISION) / pos.debtAmount;
    }

    function _getCollateralValueUSD(address user) internal view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.collateralAmount == 0) return 0;

        uint256 ethPrice = _getETHPrice(); // 8 decimals

        // collateralAmount is 18 decimals (WETH)
        // ethPrice is 8 decimals
        // We want result in 6 decimals (USDC)
        // value = collateral * price / 1e20 (18 + 8 - 6 = 20)
        return (pos.collateralAmount * ethPrice) / 1e20;
    }

    function _getETHPrice() internal view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = oracle.latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt < 1 hours, "Stale price");
        return uint256(price);
    }

    function _accrueInterest(address user) internal {
        Position storage pos = positions[user];
        if (pos.debtAmount == 0 || pos.lastUpdateTime == 0) {
            pos.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - pos.lastUpdateTime;
        if (timeElapsed == 0) return;

        // Simple interest: principal * rate * time
        uint256 interest = (pos.debtAmount * INTEREST_RATE * timeElapsed) /
            (SECONDS_PER_YEAR * PRECISION);

        pos.debtAmount += interest;
        pos.lastUpdateTime = block.timestamp;
    }
}
