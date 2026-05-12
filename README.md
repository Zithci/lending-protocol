# Lending Protocol

A minimal DeFi lending protocol built with Foundry. Deposit WETH as collateral, borrow USDC, earn yield as a lender.

## Architecture

```
LendingVault (ERC-4626)   ←→   LendingPool
  Lenders deposit USDC           Borrowers deposit WETH collateral
  Earn yield from interest        Borrow USDC, repay with interest
```

## Key Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| LTV Ratio | 75% | Max borrow = 75% of collateral value |
| Liquidation Threshold | 80% | Liquidate when debt > 80% of collateral value |
| Liquidation Bonus | 10% | Liquidator gets collateral + 10% bonus |
| Interest Rate | 5% / year | Simple interest on borrowed amount |

## Contracts

- **`LendingPool.sol`** — Core protocol: deposit collateral, borrow, repay, liquidate
- **`LendingVault.sol`** — ERC-4626 vault where lenders deposit USDC to earn yield
- **`interfaces/AggregatorV3Interface.sol`** — Chainlink price feed interface
- **`mocks/`** — MockWETH, MockUSDC, MockOracle for testing

## Usage

### As a Lender
```solidity
usdc.approve(address(vault), amount);
vault.deposit(amount, receiver); // Get lvUSDC shares
vault.withdraw(amount, receiver, owner); // Redeem USDC + yield
```

### As a Borrower
```solidity
weth.approve(address(pool), amount);
pool.depositCollateral(1 ether);      // Deposit WETH
pool.borrow(1000e6);                  // Borrow up to 75% LTV in USDC
pool.repay(type(uint256).max);        // Repay full debt
pool.withdrawCollateral(amount);      // Withdraw WETH
```

### Liquidation
```solidity
// If health factor < 100, position is liquidatable
pool.liquidate(borrowerAddress); // Repay debt, receive collateral + 10% bonus
```

## Health Factor

```
Health Factor = (collateralValueUSD × 80%) / totalDebt × 100
```

- **≥ 100** → Healthy
- **< 100** → Liquidatable

## Running Tests

```bash
forge install
forge test
```

30 tests covering: deposits, borrows, repayments, withdrawals, liquidations, interest accrual, fuzz testing, and edge cases.

## Tech Stack

- Solidity 0.8.24
- Foundry
- OpenZeppelin (ERC-4626, SafeERC20, ReentrancyGuard)
- Chainlink Price Feeds
