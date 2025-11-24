# 🏦 KipuBankV2 — Multi-Currency On-Chain Bank

**KipuBankV2** is an upgraded decentralized banking smart contract supporting **multi-asset deposits (ETH, BTC-ERC20, USDC-ERC20)** while internally accounting all balances in **USD (18 decimals)** using **Chainlink price feeds**.

Users can safely deposit and withdraw cryptocurrencies, and the bank enforces strong security and economic constraints such as a **global USD capacity** and a **maximum withdrawal limit per transaction**.

Developed collaboratively by **Victor Moyses Nascimento** and **Bruno Pancotto** as part of the **ETH-KIPU blockchain learning program**.

---

## 📘 Overview

KipuBankV2 allows users to:

- Deposit assets:
  - **ETH** (native)
  - **BTC** (ERC20, 18 decimals)
  - **USDC** (ERC20, 6 decimals)

- Withdraw assets back in:
  - ETH  
  - BTC  
  - USDC  

- Track balances internally in **USD (18 decimals)** using:
  - **ETH/USD Chainlink Aggregator**
  - **BTC/USD Chainlink Aggregator**

### 🔐 Key Features

- **Global bank USD capacity** (`i_bankCapacityUsd`)
- **Max withdrawal per transaction** (`i_maxWithdrawPerTxUsd`)
- **ReentrancyGuard** protection for all transfers
- **USD-normalized accounting for all users**
- **Events** for deposits and withdrawals
- **Rejection of direct ETH transfers** (via `receive` and `fallback`)
- **Immutable feed/token addresses** (no admin privileges)

---

## 🌐 Verified Contract — Sepolia Testnet

> ⚡ **Live deployed & verified on Etherscan**

**Contract Address:**  
[`0x3417d87bB325f82B88aFf6E2A40F584983A4b10F`](https://sepolia.etherscan.io/address/0x3417d87bb325f82b88aff6e2a40f584983a4b10f)

Interact through Etherscan:
- Read state (balances, counters)
- Deposit/withdraw
- Inspect verified source code

---

## 🏗️ Architecture Summary

### Internal Storage Model

Balances tracked in two layers:

1. **Raw token balances** (native units)
   - ETH → wei  
   - BTC → 18-decimals ERC20  
   - USDC → 6-decimals ERC20  

2. **Consolidated USD balance** (18 decimals)
   - Enforces user limits  
   - Enforces global bank capacity  

### Price Conversion

- ETH/USD and BTC/USD use Chainlink price feeds  
- USDC → `amountUsdc * 1e12` to convert to 18 decimals

---

## ⚙️ Deployment Instructions

### 🧩 Using Remix

1. Open https://remix.ethereum.org  
2. Paste contract into `KipuBankV2.sol`  
3. Compile with Solidity `0.8.24`  
4. Deploy with parameters:  
   - `bankCapacityUsd` (e.g., `1_000_000e18`)  
   - `maxWithdrawPerTxUsd` (e.g., `10_000e18`)  
   - Chainlink feed addresses  
   - BTC & USDC ERC20 token addresses  

---

## 🌐 Sepolia Testnet Deployment (Foundry)

### Chainlink Price Feeds

| Asset   | Address                                      |
| ------- | -------------------------------------------- |
| BTC/USD | `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` |
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

### ERC20 Tokens

| Token | Address                                      |
| ----- | -------------------------------------------- |
| BTC   | `0x35f131cF4b53038192117f640e161807dBcB0fdF` |
| USDC  | `0xf08a50178dfcde18524640ea6618a1f965821715` |

### Foundry Deployment

```bash
export SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/<API_KEY>"
export PRIVATE_KEY="<your_wallet_private_key>"
export ETHERSCAN_API_KEY="<your_etherscan_key>"

forge script script/DeployKipuBankV2Sepolia.s.sol:DeployKipuBankV2   --rpc-url $SEPOLIA_RPC_URL   --private-key $PRIVATE_KEY   --broadcast   --verify   -vvvv
```

---

## 🧪 Testing (Foundry)

Run the complete test suite:

```bash
forge test -vvvv
```

Includes tests for:
- Deposits/withdrawals (ETH, BTC, USDC)
- ReentrancyAttack prevention
- Zero-amount validation
- Non-existing user withdrawals
- Bank capacity enforcement
- Per-tx withdrawal limits
- USDC divisibility (`InvalidUsdcAmount`)
- Reverts on `receive()` and `fallback()`
- Multi-user deposit accounting

---

## 💬 Interaction Guide

### 1. Deposit ETH
```bash
cast send $CONTRACT "depositWithEth()" --value 1ether --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

### 2. Deposit BTC
```bash
cast send $BTC "approve(address,uint256)" $CONTRACT 1000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
cast send $CONTRACT "depositWithBtc(uint256)" 1000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

### 3. Deposit USDC
Approve then deposit.

### 4. Withdraw (any asset)
```solidity
withdrawWithEth(uint256 amountUsd)
withdrawWithBtc(uint256 amountUsd)
withdrawWithUsdc(uint256 amountUsd)
```

---

## 📊 Reading State

```bash
cast call $CONTRACT "getUserBalanceUsd(address)" $ME
cast call $CONTRACT "getUserTokenBalances(address)" $ME
cast call $CONTRACT "getContractBalanceUsd()"
```

---

## 🛡️ Security Considerations

- ReentrancyGuard on all flows  
- No owner / no admin roles  
- Direct ETH transfers rejected  
- Strong validation:  
  - `InvalidAmount`  
  - `ExceedsBankCapacity`  
  - `InvalidMaxWithdrawAmount`  
  - `InvalidUsdcAmount`  
  - `InsufficientBalance`  

---

## 🧾 License

MIT License © 2025  
Part of the **ETH-KIPU** blockchain learning project.
