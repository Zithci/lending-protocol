// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/LendingPool.sol";
import "../src/LendingVault.sol";
import "../src/mocks/MockWETH.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/mocks/MockOracle.sol";

contract LendingPoolTest is Test {
    LendingPool public pool;
    LendingVault public vault;
    MockWETH public weth;
    MockUSDC public usdc;
    MockOracle public oracle;

    address public lender = makeAddr("lender");
    address public borrower = makeAddr("borrower");
    address public liquidator = makeAddr("liquidator");

    // ETH price: $2000 (8 decimals)
    int256 public constant ETH_PRICE = 2000e8;

    function setUp() public {
        // Deploy mocks
        weth = new MockWETH();
        usdc = new MockUSDC();
        oracle = new MockOracle(ETH_PRICE, 8, "ETH/USD");

        // Deploy vault
        vault = new LendingVault(usdc);

        // Deploy pool
        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(oracle),
            address(vault)
        );

        // Connect vault to pool
        vault.setLendingPool(address(pool));

        // Fund accounts
        weth.mint(borrower, 10 ether);
        usdc.mint(lender, 100_000e6); // 100k USDC
        usdc.mint(liquidator, 100_000e6);

        // Lender deposits USDC to vault
        vm.startPrank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(50_000e6, lender); // 50k USDC
        vm.stopPrank();

        // Borrower approves WETH
        vm.prank(borrower);
        weth.approve(address(pool), type(uint256).max);

        // Liquidator approves USDC
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ============ Deposit Collateral Tests ============

    function test_depositCollateral() public {
        vm.prank(borrower);
        pool.depositCollateral(1 ether);

        (uint256 collateral, , ) = pool.positions(borrower);
        assertEq(collateral, 1 ether);
    }

    function test_depositCollateral_multiple() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.depositCollateral(0.5 ether);
        vm.stopPrank();

        (uint256 collateral, , ) = pool.positions(borrower);
        assertEq(collateral, 1.5 ether);
    }

    function test_depositCollateral_revert_zeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert("Amount must be > 0");
        pool.depositCollateral(0);
    }

    // ============ Borrow Tests ============

    function test_borrow_basic() public {
        // Deposit 1 ETH ($2000)
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);

        // Max borrow = $2000 * 75% = $1500
        usdc.approve(address(pool), type(uint256).max);
        pool.borrow(1000e6); // Borrow 1000 USDC
        vm.stopPrank();

        (, uint256 debt, ) = pool.positions(borrower);
        assertEq(debt, 1000e6);
        assertEq(usdc.balanceOf(borrower), 1000e6);
    }

    function test_borrow_maxLTV() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);

        // Max borrow = $2000 * 75% = $1500
        pool.borrow(1500e6);
        vm.stopPrank();

        (, uint256 debt, ) = pool.positions(borrower);
        assertEq(debt, 1500e6);
    }

    function test_borrow_revert_exceedsLTV() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);

        // Try to borrow more than 75% LTV
        vm.expectRevert("Exceeds max LTV");
        pool.borrow(1501e6);
        vm.stopPrank();
    }

    function test_borrow_revert_noCollateral() public {
        vm.prank(borrower);
        vm.expectRevert("No collateral deposited");
        pool.borrow(1000e6);
    }

    // ============ Repay Tests ============

    function test_repay_partial() public {
        // Setup: deposit and borrow
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);

        // Get USDC to repay
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(500e6);
        vm.stopPrank();

        (, uint256 debt, ) = pool.positions(borrower);
        assertEq(debt, 500e6);
    }

    function test_repay_full() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);

        usdc.approve(address(pool), type(uint256).max);
        pool.repay(type(uint256).max);
        vm.stopPrank();

        (, uint256 debt, ) = pool.positions(borrower);
        assertEq(debt, 0);
    }

    function test_repay_revert_noDebt() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);

        vm.expectRevert("No debt to repay");
        pool.repay(100e6);
        vm.stopPrank();
    }

    // ============ Withdraw Collateral Tests ============

    function test_withdrawCollateral_noDebt() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.withdrawCollateral(1 ether);
        vm.stopPrank();

        (uint256 collateral, , ) = pool.positions(borrower);
        assertEq(collateral, 0);
        assertEq(weth.balanceOf(borrower), 10 ether);
    }

    function test_withdrawCollateral_partial() public {
        vm.startPrank(borrower);
        pool.depositCollateral(2 ether);
        pool.borrow(1000e6); // Borrow $1000

        // Can withdraw some collateral if position stays healthy
        pool.withdrawCollateral(0.5 ether);
        vm.stopPrank();

        (uint256 collateral, , ) = pool.positions(borrower);
        assertEq(collateral, 1.5 ether);
    }

    function test_withdrawCollateral_revert_wouldBeUnhealthy() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1500e6); // Max LTV

        // Try to withdraw any collateral - should fail
        vm.expectRevert("Would make position unhealthy");
        pool.withdrawCollateral(0.1 ether);
        vm.stopPrank();
    }

    // ============ Liquidation Tests ============

    function test_liquidate_basic() public {
        // Setup: borrower at max LTV
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1500e6); // $1500 at $2000 ETH price
        vm.stopPrank();

        // Price drops to $1800 → health factor < 1
        oracle.setPrice(1800e8);

        // Liquidator liquidates
        vm.prank(liquidator);
        pool.liquidate(borrower);

        // Check borrower position is cleared
        (, uint256 debt, ) = pool.positions(borrower);
        assertEq(debt, 0);
    }

    function test_liquidate_revert_healthyPosition() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6); // Well under max LTV
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert("Position is healthy");
        pool.liquidate(borrower);
    }

    function test_liquidate_revert_selfLiquidate() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1500e6);
        vm.stopPrank();

        oracle.setPrice(1800e8);

        vm.prank(borrower);
        vm.expectRevert("Cannot liquidate yourself");
        pool.liquidate(borrower);
    }

    function test_liquidator_getsBonus() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1500e6);
        vm.stopPrank();

        oracle.setPrice(1800e8);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(borrower);

        uint256 liquidatorWethAfter = weth.balanceOf(liquidator);
        uint256 collateralReceived = liquidatorWethAfter - liquidatorWethBefore;

        // Should get debt value + 10% bonus worth of collateral
        // $1500 * 1.1 = $1650 worth of ETH at $1800/ETH
        // = 1650 / 1800 = 0.9166... ETH
        assertGt(collateralReceived, 0.9 ether);
        assertLt(collateralReceived, 1 ether);
    }

    // ============ Health Factor Tests ============

    function test_healthFactor_noDebt() public {
        vm.prank(borrower);
        pool.depositCollateral(1 ether);

        assertEq(pool.healthFactor(borrower), type(uint256).max);
    }

    function test_healthFactor_healthy() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);
        vm.stopPrank();

        // HF = ($2000 * 80%) / $1000 = 1.6 = 160 in PRECISION
        assertEq(pool.healthFactor(borrower), 160);
    }

    function test_healthFactor_afterPriceDrop() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1500e6);
        vm.stopPrank();

        // Initial HF = ($2000 * 80%) / $1500 = 1.066... ≈ 106
        assertGt(pool.healthFactor(borrower), 100);

        // Price drops to $1800
        oracle.setPrice(1800e8);

        // HF = ($1800 * 80%) / $1500 = 0.96 = 96
        assertLt(pool.healthFactor(borrower), 100);
    }

    // ============ Interest Tests ============

    function test_interest_accrues() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Total debt should be 1000 + 5% = 1050
        uint256 totalDebt = pool.getTotalDebt(borrower);
        assertEq(totalDebt, 1050e6);
    }

    function test_interest_halfYear() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);
        vm.stopPrank();

        // Warp 6 months
        vm.warp(block.timestamp + 182.5 days);

        // Total debt should be ~1025 (half of 5%)
        uint256 totalDebt = pool.getTotalDebt(borrower);
        assertApproxEqAbs(totalDebt, 1025e6, 1e6);
    }

    // ============ View Function Tests ============

    function test_getMaxBorrow() public {
        vm.prank(borrower);
        pool.depositCollateral(1 ether);

        // Max borrow = $2000 * 75% = $1500
        assertEq(pool.getMaxBorrow(borrower), 1500e6);
    }

    function test_getMaxBorrow_afterBorrow() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);
        vm.stopPrank();

        // Remaining = $1500 - $1000 = $500
        assertEq(pool.getMaxBorrow(borrower), 500e6);
    }

    function test_getCollateralValueUSD() public {
        vm.prank(borrower);
        pool.depositCollateral(1 ether);

        // 1 ETH at $2000 = $2000 (in USDC decimals = 2000e6)
        assertEq(pool.getCollateralValueUSD(borrower), 2000e6);
    }

    // ============ Vault Integration Tests ============

    function test_vault_balanceDecreases_onBorrow() public {
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);
        vm.stopPrank();

        uint256 vaultBalanceAfter = usdc.balanceOf(address(vault));
        assertEq(vaultBalanceBefore - vaultBalanceAfter, 1000e6);
    }

    function test_vault_balanceIncreases_onRepay() public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        usdc.approve(address(pool), type(uint256).max);
        pool.repay(1000e6);
        vm.stopPrank();

        uint256 vaultBalanceAfter = usdc.balanceOf(address(vault));
        assertEq(vaultBalanceAfter - vaultBalanceBefore, 1000e6);
    }

    // ============ Fuzz Tests ============

    function testFuzz_depositCollateral(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);

        vm.prank(borrower);
        pool.depositCollateral(amount);

        (uint256 collateral, , ) = pool.positions(borrower);
        assertEq(collateral, amount);
    }

    function testFuzz_borrow_withinLTV(uint256 borrowAmount) public {
        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);

        // Max = 1500e6
        borrowAmount = bound(borrowAmount, 1e6, 1500e6);

        pool.borrow(borrowAmount);
        vm.stopPrank();

        (, uint256 debt, ) = pool.positions(borrower);
        assertEq(debt, borrowAmount);
    }

    function testFuzz_healthFactor_priceChanges(uint256 newPrice) public {
        // Price between $500 and $5000
        newPrice = bound(newPrice, 500e8, 5000e8);

        vm.startPrank(borrower);
        pool.depositCollateral(1 ether);
        pool.borrow(1000e6);
        vm.stopPrank();

        oracle.setPrice(int256(newPrice));

        uint256 hf = pool.healthFactor(borrower);

        // HF = (collateralValue * 80%) / debt
        // collateralValue = newPrice * 1e18 / 1e20 = newPrice / 1e2 (in USDC decimals)
        // HF = (newPrice / 1e2 * 80 / 100) * 100 / 1000e6
        // Simplified: HF < 100 means liquidatable
        // Break-even: newPrice * 0.8 / 1e2 = 1000e6 / 100
        // newPrice = 1250e8 is the boundary

        // Just check the relationship holds
        if (hf < 100) {
            // Position is liquidatable
            assertTrue(newPrice < 1251e8, "Should be low price if liquidatable");
        } else {
            // Position is healthy
            assertTrue(newPrice >= 1250e8, "Should be high price if healthy");
        }
    }
}
