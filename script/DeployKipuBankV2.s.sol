// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KipuBankV2} from "../src/KipuBankV2.sol";

/**
 * @title DeployKipuBankV2
 * @notice Foundry script responsible for deploying the KipuBankV2 contract.
 * @dev
 * Relies on environment variables for configuration:
 *  - PRIVATE_KEY: Deployer's private key
 *  - ETH_USD_FEED: Address of the Chainlink ETH/USD price feed
 *  - BTC_USD_FEED: Address of the Chainlink BTC/USD price feed
 *  - BTC_TOKEN: Address of the BTC ERC20 token
 *  - USDC_TOKEN: Address of the USDC ERC20 token
 *  - BANK_CAPACITY_USD (optional, default: 1_000_000e18)
 *  - MAX_WITHDRAW_PER_TX_USD (optional, default: 10_000e18)
 */
contract DeployKipuBankV2 is Script {
    /**
     * @notice Runs the deployment script.
     * @dev The script:
     *  - Reads configuration from environment variables.
     *  - Broadcasts a transaction that deploys KipuBankV2.
     *  - Logs the deployed contract address.
     */
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address ethUsdFeed = vm.envAddress("ETH_USD_FEED");
        address btcUsdFeed = vm.envAddress("BTC_USD_FEED");
        address btcToken = vm.envAddress("BTC_TOKEN");
        address usdcToken = vm.envAddress("USDC_TOKEN");

        uint256 bankCapacityUsd = vm.envOr(
            "BANK_CAPACITY_USD",
            uint256(1_000_000e18)
        );
        uint256 maxWithdrawPerTxUsd = vm.envOr(
            "MAX_WITHDRAW_PER_TX_USD",
            uint256(10_000e18)
        );

        vm.startBroadcast(deployerPrivateKey);

        KipuBankV2 kipuBank = new KipuBankV2(
            bankCapacityUsd,
            maxWithdrawPerTxUsd,
            ethUsdFeed,
            btcUsdFeed,
            btcToken,
            usdcToken
        );

        vm.stopBroadcast();

        console2.log("KipuBankV2 deployed at:", address(kipuBank));
    }
}
