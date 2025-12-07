// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
    // Sepolia Chainlink Price Feeds
    address constant SEPOLIA_BTC_USD_FEED =
        0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant SEPOLIA_ETH_USD_FEED =
        0x694AA1769357215DE4FAC081bf1f309aDC325306;

    // Sepolia ERC20 tokens
    address constant SEPOLIA_BTC_ERC20 =
        0x35f131cF4b53038192117f640e161807dBcB0fdF;
    address constant SEPOLIA_USDC_ERC20 =
        0x5dEaC602762362FE5f135FA5904351916053cF70;

    function run() external {
        // Foundry will use the key passed via --private-key or from env
        vm.startBroadcast();

        uint256 bankCapacityUsd = 1_000_000e18;
        uint256 maxWithdrawPerTxUsd = 10_000e18;

        // -------- NEW: read Uniswap V4 router address from env --------
        // On Sepolia, you should point this to a real Uniswap V4 (or compatible)
        // router instance deployed on that network.
        address uniswapV4Router = vm.envAddress("UNISWAP_V4_ROUTER"); // << NEW
        // ----------------------------------------------------------------

        // ----------------- CHANGED: added uniswapV4Router -----------------
        KipuBankV3 kipu = new KipuBankV3(
            bankCapacityUsd,
            maxWithdrawPerTxUsd,
            SEPOLIA_ETH_USD_FEED,
            SEPOLIA_BTC_USD_FEED,
            SEPOLIA_BTC_ERC20,
            SEPOLIA_USDC_ERC20,
            uniswapV4Router // << NEW 7th argument
        );
        // ------------------------------------------------------------------

        vm.stopBroadcast();

        console2.log("KipuBankV3 deployed on Sepolia at:", address(kipu));
    }
}
