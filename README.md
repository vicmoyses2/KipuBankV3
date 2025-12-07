# 🏦 KipuBankV3 --- Multi-Currency On-Chain Bank

**KipuBankV3** is an upgraded decentralized banking smart contract
supporting **multi-asset deposits (ETH, BTC-ERC20, USDC-ERC20)** while
internally accounting all balances in **USD (18 decimals)** using
**Chainlink price feeds**.

Users can safely deposit and withdraw cryptocurrencies, and the bank
enforces strict economic and security constraints such as:

-   **Global USD capacity limit**
-   **Per-transaction withdrawal limit**
-   **USDC divisibility rules (must be divisible by 1e12)**
-   **ReentrancyGuard protection**
-   **Direct ETH transfer rejection**

Developed collaboratively by **[Victor Moyses
Nascimento](https://github.com/victormoyses)** and **[Bruno
Pancotto](https://github.com/pancotto)** as part of the **ETH‑KIPU
blockchain learning program**.

------------------------------------------------------------------------

## 📘 Overview

KipuBankV3 allows users to:

### Deposit assets:

-   **ETH** (native)
-   **BTC** (ERC20, 18 decimals)
-   **USDC** (ERC20, 6 decimals)

### Withdraw assets:

-   ETH\
-   BTC\
-   USDC

### Internal accounting:

-   All users' balances are normalized to **USD (18 decimals)**
-   Using:
    -   **ETH/USD Chainlink Aggregator**
    -   **BTC/USD Chainlink Aggregator**
-   All non‑USDC deposits are swapped to **USDC**, the canonical reserve
    asset.

------------------------------------------------------------------------

## 🏛️ Formal Banking Rules (Protocol-Level Invariants)

### 1️⃣ **Global Bank Capacity (i_bankCapacityUsd)**

-   Maximum total USD (18 decimals) that the bank can hold.\
-   Any deposit that would exceed this cap **reverts with
    `ExceedsBankCapacity()`**.\
-   Ensures the bank cannot become under-collateralized.

### 2️⃣ **Maximum Withdrawal Per Transaction (i_maxWithdrawPerTxUsd)**

-   A user cannot withdraw more than this USD amount in a single call.\
-   Exceeding this limit **reverts with `InvalidMaxWithdrawAmount()`**.\
-   Prevents large single‑shot liquidity drains.

### 3️⃣ **USDC Divisibility Rule**

All internal accounting uses USD with **18 decimals**, while USDC has
**6 decimals**.\
Therefore:

    amountUsd % 1e12 == 0

If not divisible, the withdrawal **reverts with `InvalidUsdcAmount()`**.

This enforces: - Precise conversion between USDC and USD\
- No fractional USDC issues on withdrawal

### 4️⃣ **Only Canonical USDC Reserves**

-   ETH and BTC deposits **are immediately swapped into USDC** using the
    configured router.\
-   Users' internal balances are stored in:
    -   Canonical **USDC** (6 decimals)
    -   Consolidated **USD** (18 decimals)

### 5️⃣ **Reentrancy Protection**

All deposit/withdraw flows use `nonReentrant`.\
Reentrancy attempts always **revert**.

### 6️⃣ **Direct ETH Transfers Blocked**

-   `receive()` and `fallback()` both revert with
    `InvalidDepositPath()`.\
-   Users **must** call `depositWithEth()`.

------------------------------------------------------------------------

## 🌐 Verified Contract --- Sepolia Testnet

> ⚡ **Live deployed & verified on Etherscan**

**Contract Address:**\
[`0x034B69b8d6661C4Ad970FA698e4e25296D8f5f20`](https://sepolia.etherscan.io/address/0x034b69b8d6661c4ad970fa698e4e25296d8f5f20)

Interact through Etherscan: - Read state (balances, counters) -
Deposit/withdraw - Inspect verified source code

------------------------------------------------------------------------

## 🏗️ Architecture Summary

### Storage Model

1.  **Raw token balances**
    -   ETH → wei\
    -   BTC → 18-decimals ERC20\
    -   USDC → 6-decimals
2.  **Consolidated USD balance (18 decimals)**
    -   Enforces per‑user and system‑wide limits\
    -   Updated after every deposit/withdrawal

### Price Conversion

-   Chainlink ETH/USD\

-   Chainlink BTC/USD\

-   USDC mapped via:

        amountUsd = amountUsdc * 1e12

------------------------------------------------------------------------

## 🌐 Sepolia Deployment (Foundry)

### Chainlink Feeds

  Asset     Address
  --------- ----------------------------------------------
  BTC/USD   `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43`
  ETH/USD   `0x694AA1769357215DE4FAC081bf1f309aDC325306`

### ERC20 Tokens

  Token   Address
  ------- ----------------------------------------------
  BTC     `0x35f131cF4b53038192117f640e161807dBcB0fdF`
  USDC    `0x5dEaC602762362FE5f135FA5904351916053cF70`

### Deploy

``` bash
export SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/<API_KEY>"
export PRIVATE_KEY="<your_wallet_private_key>"
export UNISWAP_V4_ROUTER="<router_address>"
export ETHERSCAN_API_KEY="<your_etherscan_key>"

forge script script/DeployKipuBankV3Sepolia.s.sol:DeployKipuBankV3 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

------------------------------------------------------------------------

## 🧪 Testing (Foundry)

``` bash
forge test -vvvv
```

Tests cover: - All deposit/withdraw flows\
- ETH/BTC/USDC conversion\
- Bank capacity rules\
- Per‑tx withdrawal rules\
- Reentrancy attack simulation\
- Invalid USDC divisibility\
- Direct ETH transfer rejection

------------------------------------------------------------------------

## 📊 Interaction (cast)

### Deposit ETH

``` bash
cast send $CONTRACT "depositWithEth()" \
  --value 1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### Deposit BTC (ERC20)

``` bash
cast send $BTC "approve(address,uint256)" $CONTRACT 1e18
cast send $CONTRACT "depositWithBtc(uint256)" 1e18
```

### Withdraw

    withdrawWithEth(uint256 amountUsd)
    withdrawWithBtc(uint256 amountUsd)
    withdrawWithUsdc(uint256 amountUsd)

------------------------------------------------------------------------

## 🛡️ Security Model

-   No owner, no admin keys\
-   Immutable protocol parameters\
-   Full reentrancy protection\
-   Strict validation on every operation

------------------------------------------------------------------------

## 🧾 License

MIT License © 2025\
Part of the **ETH-KIPU** blockchain learning program.
