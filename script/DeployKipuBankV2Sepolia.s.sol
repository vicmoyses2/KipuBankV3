// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {KipuBankV2} from "../src/KipuBankV2.sol";

contract DeployKipuBankV2 is Script {
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
        // Aqui o Foundry vai usar a chave passada em --private-key
        vm.startBroadcast();

        uint256 bankCapacityUsd = 1_000_000e18;
        uint256 maxWithdrawPerTxUsd = 10_000e18;

        KipuBankV2 kipu = new KipuBankV2(
            bankCapacityUsd,
            maxWithdrawPerTxUsd,
            SEPOLIA_ETH_USD_FEED,
            SEPOLIA_BTC_USD_FEED,
            SEPOLIA_BTC_ERC20,
            SEPOLIA_USDC_ERC20
        );

        vm.stopBroadcast();

        console2.log("KipuBankV2 deployed on Sepolia at:", address(kipu));
    }
}
