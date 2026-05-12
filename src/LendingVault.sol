// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LendingVault
 * @notice ERC-4626 vault for lenders to deposit USDC and earn yield from borrower interest
 *
 * Flow:
 * 1. Lender deposits USDC → gets share tokens
 * 2. LendingPool borrows USDC from this vault to give to borrowers
 * 3. Borrowers repay with interest → vault balance grows
 * 4. Lender withdraws → gets USDC + portion of interest
 */
contract LendingVault is ERC4626, Ownable {
    address public lendingPool;

    event LendingPoolSet(address indexed pool);
    event Borrowed(address indexed pool, uint256 amount);
    event Repaid(address indexed pool, uint256 amount);

    constructor(
        IERC20 _usdc
    ) ERC4626(_usdc) ERC20("Lending Vault Share", "lvUSDC") Ownable(msg.sender) {}

    function setLendingPool(address _pool) external onlyOwner {
        require(_pool != address(0), "Invalid pool address");
        lendingPool = _pool;
        emit LendingPoolSet(_pool);
    }

    /**
     * @notice LendingPool calls this to borrow USDC for borrowers
     */
    function borrowFromVault(uint256 amount) external returns (bool) {
        require(msg.sender == lendingPool, "Only lending pool");
        require(amount <= totalAssets(), "Insufficient liquidity");

        IERC20(asset()).transfer(lendingPool, amount);
        emit Borrowed(lendingPool, amount);
        return true;
    }

    /**
     * @notice LendingPool calls this when borrowers repay
     */
    function repayToVault(uint256 amount) external returns (bool) {
        require(msg.sender == lendingPool, "Only lending pool");

        IERC20(asset()).transferFrom(lendingPool, address(this), amount);
        emit Repaid(lendingPool, amount);
        return true;
    }

    /**
     * @notice Available liquidity for borrowing
     */
    function availableLiquidity() external view returns (uint256) {
        return totalAssets();
    }
}
