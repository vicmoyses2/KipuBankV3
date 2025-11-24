// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KipuBankV2} from "../src/KipuBankV2.sol";
import {PriceConverter} from "../src/PriceConverter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockV3Aggregator
 * @notice Minimal mock implementation of Chainlink's AggregatorV3Interface
 *         for testing purposes.
 * @dev
 * - The mock allows setting an arbitrary latest answer.
 * - It returns fixed metadata for decimals, description, and version.
 */
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 private _decimals;
    string private _description;
    uint256 private _version;
    int256 private _answer;

    /**
     * @param decimals_ Number of decimals reported by the feed.
     * @param description_ Human-readable feed description.
     * @param version_ Feed version.
     * @param initialAnswer_ Initial price answer to be used by the mock.
     */
    constructor(
        uint8 decimals_,
        string memory description_,
        uint256 version_,
        int256 initialAnswer_
    ) {
        _decimals = decimals_;
        _description = description_;
        _version = version_;
        _answer = initialAnswer_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    /**
     * @notice Updates the mocked latest answer.
     * @param newAnswer The new price answer to be used by the mock.
     */
    function setLatestAnswer(int256 newAnswer) external {
        _answer = newAnswer;
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        answer = _answer;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        answer = _answer;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }
}

/**
 * @title MockBtcToken
 * @notice Simple ERC20 mock token representing BTC with 18 decimals.
 */
contract MockBtcToken is ERC20 {
    constructor() ERC20("Mock BTC", "mBTC") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/**
 * @title MockUsdcToken
 * @notice Simple ERC20 mock token representing USDC with 6 decimals.
 */
contract MockUsdcToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/**
 * @title ReentrancyAttacker
 * @notice Malicious contract used to test the ReentrancyGuard protection
 *         implemented in KipuBankV2.
 * @dev
 * - Attempts to trigger a reentrant call during ETH withdrawal.
 * - The entire transaction should revert due to ReentrancyGuard.
 */
contract ReentrancyAttacker {
    KipuBankV2 public bank;
    bool private _reenter;

    constructor(KipuBankV2 bank_) {
        bank = bank_;
    }

    /**
     * @notice Initiates the reentrancy attack.
     * @dev
     * - Deposits ETH into the bank.
     * - Calls withdrawWithEth for a small USD amount.
     * - Tries to reenter from the receive() hook.
     */
    function attack() external payable {
        _reenter = true;

        // Deposit ETH from this contract into the bank
        bank.depositWithEth{value: msg.value}();

        // Attempt to withdraw a small USD amount (1 USD, 18 decimals)
        bank.withdrawWithEth(1e18);

        _reenter = false;
    }

    /**
     * @notice Fallback receive hook used to attempt reentrant withdrawal.
     * @dev
     * - On receiving ETH from the bank, tries to call withdrawWithEth again.
     * - This second call must be blocked by ReentrancyGuard.
     */
    receive() external payable {
        if (_reenter) {
            // This call should revert due to ReentrancyGuard's nonReentrant modifier.
            bank.withdrawWithEth(1e18);
        }
    }
}

/**
 * @title KipuBankV2Test
 * @notice Test suite for the KipuBankV2 contract using mocked price feeds and tokens.
 * @dev Uses Foundry's Test base contract and cheatcodes (via vm).
 */
contract KipuBankV2Test is Test {
    using PriceConverter for uint256;

    KipuBankV2 public kipu;
    MockV3Aggregator public ethFeed;
    MockV3Aggregator public btcFeed;
    MockBtcToken public btcToken;
    MockUsdcToken public usdcToken;

    address public user = address(1);
    address public user2 = address(2);

    /// @notice ETH price used in tests ($2,000 with 8 decimals).
    int256 public constant ETH_PRICE = 2_000e8;

    /// @notice BTC price used in tests ($40,000 with 8 decimals).
    int256 public constant BTC_PRICE = 40_000e8;

    /**
     * @notice Sets up the test environment:
     *  - Deploys mock price feeds and tokens.
     *  - Deploys KipuBankV2 pointing to the mocks.
     *  - Allocates initial ETH, BTC, and USDC balances to test users.
     */
    function setUp() external {
        ethFeed = new MockV3Aggregator(8, "ETH/USD", 1, ETH_PRICE);
        btcFeed = new MockV3Aggregator(8, "BTC/USD", 1, BTC_PRICE);

        btcToken = new MockBtcToken();
        usdcToken = new MockUsdcToken();

        uint256 bankCapacityUsd = 1_000_000e18;
        uint256 maxWithdrawPerTxUsd = 10_000e18;

        kipu = new KipuBankV2(
            bankCapacityUsd,
            maxWithdrawPerTxUsd,
            address(ethFeed),
            address(btcFeed),
            address(btcToken),
            address(usdcToken)
        );

        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);

        bool ok1 = btcToken.transfer(user, 10_000e18);
        assertTrue(ok1, "Initial BTC transfer to user failed");

        bool ok2 = usdcToken.transfer(user, 10_000e6);
        assertTrue(ok2, "Initial USDC transfer to user failed");

        bool ok3 = btcToken.transfer(user2, 10_000e18);
        assertTrue(ok3, "Initial BTC transfer to user2 failed");

        bool ok4 = usdcToken.transfer(user2, 10_000e6);
        assertTrue(ok4, "Initial USDC transfer to user2 failed");
    }

    // -------------------------------------------------------------------------
    // Existing Core Tests
    // -------------------------------------------------------------------------

    function testDepositWithEthUpdatesBalances() external {
        uint256 depositEth = 1 ether;

        vm.prank(user);
        kipu.depositWithEth{value: depositEth}();

        uint256 expectedUsd = depositEth.getPriceFeedConversionRate(ethFeed);

        uint256 userUsd = kipu.userBalanceUsd(user);
        uint256 totalUsd = kipu.getContractBalanceUsd();

        assertEq(userUsd, expectedUsd, "User USD balance mismatch");
        assertEq(totalUsd, expectedUsd, "Total bank balance mismatch");

        (uint256 ethBalance, uint256 btcBalance, uint256 usdcBalance) = kipu
            .getUserTokenBalances(user);

        assertEq(ethBalance, depositEth, "ETH balance mismatch");
        assertEq(btcBalance, 0, "BTC balance should be zero");
        assertEq(usdcBalance, 0, "USDC balance should be zero");
    }

    function testWithdrawWithEthReducesBalances() external {
        uint256 depositEth = 2 ether;

        vm.prank(user);
        kipu.depositWithEth{value: depositEth}();

        uint256 initialUserEth = user.balance;

        uint256 totalUsd = kipu.userBalanceUsd(user);
        uint256 amountUsd = totalUsd / 2;

        vm.prank(user);
        kipu.withdrawWithEth(amountUsd);

        uint256 ethPrice = PriceConverter.getPriceFeed(ethFeed);
        uint256 expectedEthReceived = (amountUsd * 1e18) / ethPrice;

        assertApproxEqAbs(
            user.balance,
            initialUserEth + expectedEthReceived,
            1e10,
            "User ETH balance incorrect after withdraw"
        );

        uint256 userUsd = kipu.userBalanceUsd(user);
        uint256 newTotalUsd = kipu.getContractBalanceUsd();

        assertEq(
            userUsd,
            totalUsd - amountUsd,
            "User USD balance incorrect after withdraw"
        );
        assertEq(
            newTotalUsd,
            userUsd,
            "Total bank USD balance should match aggregated user balances"
        );
    }

    function testDepositAndWithdrawWithBtc() external {
        uint256 depositBtc = 1e18;

        vm.startPrank(user);
        btcToken.approve(address(kipu), depositBtc);
        kipu.depositWithBtc(depositBtc);

        uint256 expectedUsd = depositBtc.getPriceFeedConversionRate(btcFeed);
        assertEq(
            kipu.userBalanceUsd(user),
            expectedUsd,
            "User USD balance after BTC deposit"
        );

        // Withdraw an amount within per-tx limit (10_000 USD)
        uint256 amountUsd = expectedUsd / 4;
        assertLe(
            amountUsd,
            kipu.i_maxWithdrawPerTxUsd(),
            "Test withdraw exceeds per-tx limit"
        );

        kipu.withdrawWithBtc(amountUsd);
        vm.stopPrank();

        uint256 btcPrice = PriceConverter.getPriceFeed(btcFeed);
        uint256 expectedBtcReceived = (amountUsd * 1e18) / btcPrice;

        assertEq(
            btcToken.balanceOf(user),
            10_000e18 - depositBtc + expectedBtcReceived,
            "User BTC balance mismatch after withdraw"
        );
    }

    function testDepositAndWithdrawWithUsdc() external {
        uint256 depositUsdc = 1_000e6;

        vm.startPrank(user);
        usdcToken.approve(address(kipu), depositUsdc);
        kipu.depositWithUsdc(depositUsdc);

        uint256 expectedUsd = depositUsdc * 1e12;
        assertEq(
            kipu.userBalanceUsd(user),
            expectedUsd,
            "User USD balance after USDC deposit"
        );

        uint256 amountUsd = 500e18;
        kipu.withdrawWithUsdc(amountUsd);
        vm.stopPrank();

        uint256 expectedUsdcReceived = amountUsd / 1e12;

        assertEq(
            usdcToken.balanceOf(user),
            10_000e6 - depositUsdc + expectedUsdcReceived,
            "User USDC balance mismatch after withdraw"
        );
    }

    function testRevertWhenWithdrawExceedsMaxPerTx() external {
        uint256 depositEth = 100 ether;

        vm.prank(user);
        kipu.depositWithEth{value: depositEth}();

        uint256 tooHighUsd = kipu.i_maxWithdrawPerTxUsd() + 1;

        vm.prank(user);
        vm.expectRevert(KipuBankV2.InvalidMaxWithdrawAmount.selector);
        kipu.withdrawWithEth(tooHighUsd);
    }

    /**
     * @notice Ensures deposits that exceed the bank's configured capacity revert.
     */
    function testExceedsBankCapacityOnDeposit() external {
        uint256 smallCapacityUsd = 1_000e18;
        uint256 maxWithdrawPerTxUsd = 10_000e18;

        kipu = new KipuBankV2(
            smallCapacityUsd,
            maxWithdrawPerTxUsd,
            address(ethFeed),
            address(btcFeed),
            address(btcToken),
            address(usdcToken)
        );

        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(KipuBankV2.ExceedsBankCapacity.selector);
        kipu.depositWithEth{value: 1 ether}();
    }

    /**
     * @notice Ensures withdrawals in USDC revert when the USD amount
     *         cannot be represented with 6-decimal precision.
     */
    function testInvalidUsdcAmountOnWithdraw() external {
        uint256 depositUsdc = 1_000e6;

        vm.startPrank(user);
        usdcToken.approve(address(kipu), depositUsdc);
        kipu.depositWithUsdc(depositUsdc);

        uint256 badAmountUsd = 500e18 + 1;

        vm.expectRevert(KipuBankV2.InvalidUsdcAmount.selector);
        kipu.withdrawWithUsdc(badAmountUsd);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // New Tests Requested
    // -------------------------------------------------------------------------

    /**
     * @notice Verifies that ReentrancyGuard prevents reentrant withdrawals.
     * @dev
     * - Uses a malicious ReentrancyAttacker contract.
     * - The attack transaction should revert.
     * - Bank state must remain unchanged.
     */
    function testReentrancyGuardPreventsReentering() external {
        ReentrancyAttacker attacker = new ReentrancyAttacker(kipu);

        uint256 initialBankUsd = kipu.getContractBalanceUsd();

        vm.expectRevert();
        attacker.attack{value: 1 ether}();

        uint256 finalBankUsd = kipu.getContractBalanceUsd();
        assertEq(
            finalBankUsd,
            initialBankUsd,
            "Bank USD balance should remain unchanged after failed reentrancy attack"
        );
    }

    /**
     * @notice Ensures deposits of zero amount revert as InvalidAmount.
     * @dev
     * - Tests ETH, BTC and USDC deposit functions with amount 0.
     */
    function testDepositZeroAmountReverts() external {
        // ETH deposit with zero value
        vm.prank(user);
        vm.expectRevert(KipuBankV2.InvalidAmount.selector);
        kipu.depositWithEth{value: 0}();

        // BTC deposit with zero amount
        vm.prank(user);
        vm.expectRevert(KipuBankV2.InvalidAmount.selector);
        kipu.depositWithBtc(0);

        // USDC deposit with zero amount
        vm.prank(user);
        vm.expectRevert(KipuBankV2.InvalidAmount.selector);
        kipu.depositWithUsdc(0);
    }

    /**
     * @notice Ensures withdrawals from an address with no USD balance revert.
     * @dev
     * - Tests ETH, BTC and USDC withdrawal paths for a non-existent user balance.
     */
    function testWithdrawFromNonExistingUserReverts() external {
        vm.prank(user);
        vm.expectRevert(KipuBankV2.InsufficientBalance.selector);
        kipu.withdrawWithEth(1e18);

        vm.prank(user);
        vm.expectRevert(KipuBankV2.InsufficientBalance.selector);
        kipu.withdrawWithBtc(1e18);

        vm.prank(user);
        vm.expectRevert(KipuBankV2.InsufficientBalance.selector);
        kipu.withdrawWithUsdc(1e18);
    }

    /**
     * @notice Verifies that the contract USD balance matches the sum
     *         of all users' USD balances after multiple deposits.
     */
    function testContractBalanceAfterMultipleUsersDeposit() external {
        // user deposits 1 ETH
        uint256 depositEth = 1 ether;
        vm.prank(user);
        kipu.depositWithEth{value: depositEth}();
        uint256 userUsd1 = depositEth.getPriceFeedConversionRate(ethFeed);

        // user2 deposits 1 BTC
        uint256 depositBtc = 1e18;
        vm.startPrank(user2);
        btcToken.approve(address(kipu), depositBtc);
        kipu.depositWithBtc(depositBtc);
        vm.stopPrank();
        uint256 userUsd2 = depositBtc.getPriceFeedConversionRate(btcFeed);

        uint256 totalExpected = userUsd1 + userUsd2;

        uint256 contractUsd = kipu.getContractBalanceUsd();
        assertEq(
            contractUsd,
            totalExpected,
            "Contract USD balance should equal sum of all users' USD balances"
        );

        uint256 u1 = kipu.userBalanceUsd(user);
        uint256 u2 = kipu.userBalanceUsd(user2);

        assertEq(u1, userUsd1, "User1 USD balance mismatch");
        assertEq(u2, userUsd2, "User2 USD balance mismatch");
    }

    /**
     * @notice Ensures the receive() function reverts when ETH is sent directly.
     */
    function testReceiveFunctionRevertsOnDirectEthTransfer() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(KipuBankV2.InvalidDepositPath.selector);
        // Empty calldata triggers receive(), expectRevert cuida da falha
        address(kipu).call{value: 1 ether}("");
    }

    /**
     * @notice Ensures the fallback() function reverts when called with unknown data.
     */
    function testFallbackFunctionRevertsOnUnknownCall() external {
        vm.prank(user);
        vm.expectRevert(KipuBankV2.InvalidDepositPath.selector);
        // Non-matching function signature triggers fallback()
        address(kipu).call(abi.encodeWithSignature("nonExistingFunction()"));
    }
}
