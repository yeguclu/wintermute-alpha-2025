
# Before the Storm - Flash Loan Liquidation

## Challenge Description

UwU Lend was drained for $20M a few days ago, and the exploiter's [Llamalend position](https://etherscan.io/address/0x6F8C5692b00c2eBbd07e4FD80E332DfF3ab8E83c) became unhealthy. The goal is to liquidate it using a flash loan and end up with at least 20k CRV in the registered wallet.

## Solution Overview

This solution implements a sophisticated flash loan liquidation strategy that:

1. **Balancer Vault** for flash loans (USDC)
2. **Implements partial liquidation** since the position couldn't be liquidated at once
3. **Optimizes token swaps** across multiple DEXs for maximum efficiency

## Key Features

### Partial Liquidation Strategy
- Uses `liquidate_extended()` with a small fraction (1%) to avoid liquidation failures
- Dynamically calculates the required crvUSD amount based on the liquidation fraction

### Multi-DEX Routing
- **Curve pools**: crvUSD/USDC and triCRV (CRV/crvUSD/WETH)
- **Uniswap V3**: WETH/USDC (0.05% fee tier)
- **Split routing**: Half CRV → crvUSD → USDC, half CRV → WETH → USDC

## Strategy Details

### 1. Flash Loan Setup
- Borrows USDC from Balancer Vault
- No fees (fee == 0 check ensures this)
- Calculates optimal amount needed for liquidation

### 2. Liquidation Execution
- Swaps USDC → crvUSD via Curve crvUSD/USDC pool
- Calls `liquidate_extended()` with 1% fraction
- Converts leftover crvUSD back to USDC

### 3. CRV Profit Extraction
- Sells received CRV collateral in small chunks
- Uses both triCRV routes (CRV→crvUSD→USDC and CRV→WETH→USDC)
- Continues until sufficient USDC for repayment

### 4. Profit Distribution
- Repays flash loan to Balancer Vault
- Transfers remaining CRV to beneficiary address