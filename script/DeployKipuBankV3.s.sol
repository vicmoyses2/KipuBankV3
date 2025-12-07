// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

/**
 * @title DeployKipuBankV3
 * @notice Foundry script responsible for deploying the KipuBankV3 contract.
 * @dev
 * Relies on environment variables for configuration:
 *  - PRIVATE_KEY: Deployer's private key
 *  - ETH_USD_FEED: Address of the Chainlink ETH/USD price feed
 *  - BTC_USD_FEED: Address of the Chainlink BTC/USD price feed
 *  - BTC_TOKEN: Address of the BTC ERC20 token
 *  - USDC_TOKEN: Address of the USDC ERC20 token
 *  - UNISWAP_V4_ROUTER: Address of the Uniswap V4 router          // << NEW
 *  - BANK_CAPACITY_USD (optional, default: 1_000_000e18)
 *  - MAX_WITHDRAW_PER_TX_USD (optional, default: 10_000e18)
 */
contract DeployKipuBankV3 is Script {
    /**
     * @notice Runs the deployment script.
     * @dev The script:
     *  - Reads configuration from environment variables.
     *  - Broadcasts a transaction that deploys KipuBankV3.
     *  - Logs the deployed contract address.
     */
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address ethUsdFeed = vm.envAddress("ETH_USD_FEED");
        address btcUsdFeed = vm.envAddress("BTC_USD_FEED");
        address btcToken = vm.envAddress("BTC_TOKEN");
        address usdcToken = vm.envAddress("USDC_TOKEN");

        // -------- NEW: read Uniswap V4 router address from env --------
        address uniswapV4Router = vm.envAddress("UNISWAP_V4_ROUTER"); // << NEW
        // ----------------------------------------------------------------

        uint256 bankCapacityUsd = vm.envOr(
            "BANK_CAPACITY_USD",
            uint256(1_000_000e18)
        );
        uint256 maxWithdrawPerTxUsd = vm.envOr(
            "MAX_WITHDRAW_PER_TX_USD",
            uint256(10_000e18)
        );

        vm.startBroadcast(deployerPrivateKey);

        // ----------------- CHANGED: added uniswapV4Router -----------------
        KipuBankV3 kipuBank = new KipuBankV3(
            bankCapacityUsd,
            maxWithdrawPerTxUsd,
            ethUsdFeed,
            btcUsdFeed,
            btcToken,
            usdcToken,
            uniswapV4Router // << NEW 7th argument
        );
        // ------------------------------------------------------------------

        vm.stopBroadcast();

        console2.log("KipuBankV3 deployed at:", address(kipuBank));
    }
}
