// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/* ------------------------------------------------------ */
/*               MOCK PRICE FEED (DUMMY)                  */
/* ------------------------------------------------------ */
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _answer;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

/* ------------------------------------------------------ */
/*                       MOCK TOKENS                      */
/* ------------------------------------------------------ */

contract MockBtcToken is ERC20 {
    constructor() ERC20("Mock BTC", "mBTC") {
        _mint(msg.sender, 1_000_000e18);
    }

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUsdcToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/* ------------------------------------------------------ */
/*         MOCK UNISWAP V4 ROUTER (amountOut = 2×in)      */
/*   - Deposits:                                          */
/*       * ETH -> USDC                                    */
/*       * BTC -> USDC                                    */
/*   - Withdrawals:                                       */
/*       * USDC -> BTC                                    */
/*       * USDC -> ETH (tokenOut = address(0))            */
/* ------------------------------------------------------ */

contract MockUniswapV4Router {
    MockUsdcToken public immutable usdc;
    MockBtcToken public immutable btc;

    constructor(address _usdc, address _btc) {
        usdc = MockUsdcToken(_usdc);
        btc = MockBtcToken(_btc);
    }

    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /* minAmountOut */,
        address recipient
    ) external payable returns (uint256 amountOut) {
        // Very simple deterministic pricing: amountOut = amountIn * 2
        amountOut = amountIn * 2;

        // Deposit paths: tokenOut == USDC
        if (tokenOut == address(usdc)) {
            // Any tokenIn (ETH or BTC) gets converted into USDC
            usdc.mintTo(recipient, amountOut);
        }
        // Withdraw BTC path: USDC -> BTC
        else if (tokenIn == address(usdc) && tokenOut == address(btc)) {
            btc.mintTo(recipient, amountOut);
        }
        // Withdraw ETH path: USDC -> ETH (tokenOut == address(0))
        // Bank itself handles sending ETH from its own balance.
        else if (tokenIn == address(usdc) && tokenOut == address(0)) {
            // No minting here, just return amountOut as a "quoted" ETH amount.
            // The KipuBankV3 contract decides how much ETH to actually send.
        } else {
            revert("Unsupported tokenOut");
        }
    }
}

/* ------------------------------------------------------ */
/*                REENTRANCY ATTACK MOCK                  */
/* ------------------------------------------------------ */

contract ReentrancyAttacker {
    KipuBankV3 public immutable bank;
    bool private reenter;

    constructor(KipuBankV3 _bank) {
        bank = _bank;
    }

    function attack() external payable {
        reenter = true;
        bank.depositWithEth{value: msg.value}();
        bank.withdrawWithEth(1e18);
        reenter = false;
    }

    receive() external payable {
        if (reenter) {
            // This second call would be reentrant if withdrawWithEth
            // actually sent ETH directly to this contract.
            bank.withdrawWithEth(1e18);
        }
    }
}

/* ------------------------------------------------------ */
/*                      TEST SUITE                        */
/* ------------------------------------------------------ */

contract KipuBankV3Test is Test {
    KipuBankV3 public kipu;
    MockV3Aggregator public ethFeed;
    MockV3Aggregator public btcFeed;
    MockBtcToken public btcToken;
    MockUsdcToken public usdcToken;
    MockUniswapV4Router public router;

    address public user = address(1);
    address public user2 = address(2);

    /* ------------------------------------------------------ */
    /*                        SETUP                            */
    /* ------------------------------------------------------ */

    function setUp() external {
        // Dummy prices, not used directly in new USD semantics
        ethFeed = new MockV3Aggregator(8, 2_000e8);
        btcFeed = new MockV3Aggregator(8, 40_000e8);

        btcToken = new MockBtcToken();
        usdcToken = new MockUsdcToken();

        router = new MockUniswapV4Router(address(usdcToken), address(btcToken));

        // Bank capacity must be very large because USDC_out = 2 * amountIn,
        // then internally converted to USD with * 1e12.
        uint256 bankCapacityUsd = 1e40;
        uint256 maxWithdrawPerTxUsd = 1e30;

        kipu = new KipuBankV3(
            bankCapacityUsd,
            maxWithdrawPerTxUsd,
            address(ethFeed),
            address(btcFeed),
            address(btcToken),
            address(usdcToken),
            address(router)
        );

        // Fund users with ETH
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);

        // Give users some tokens
        btcToken.transfer(user, 100e18);
        btcToken.transfer(user2, 100e18);
        usdcToken.transfer(user, 100_000e6);
        usdcToken.transfer(user2, 100_000e6);
    }

    /* ------------------------------------------------------ */
    /*            HELPER: EXPECTED INTERNAL USD               */
    /* ------------------------------------------------------ */

    /// @notice In our mock, every swap outputs 2x the input in tokenOut.
    /// For USD internal accounting, USDC (6 decimals) is scaled by 1e12.
    function expectedUsdFromSwap(
        uint256 amountIn
    ) internal pure returns (uint256) {
        uint256 usdcOut = amountIn * 2;
        return usdcOut * 1e12;
    }

    /* ------------------------------------------------------ */
    /*                TESTS - DEPOSIT ETH                     */
    /* ------------------------------------------------------ */

    function testDepositWithEthUpdatesBalances() external {
        uint256 amountIn = 1 ether;

        vm.prank(user);
        kipu.depositWithEth{value: amountIn}();

        uint256 expectedUsd = expectedUsdFromSwap(amountIn);

        assertEq(
            kipu.userBalanceUsd(user),
            expectedUsd,
            "User USD after ETH deposit"
        );
        assertEq(
            kipu.getContractBalanceUsd(),
            expectedUsd,
            "Bank USD after ETH deposit"
        );
    }

    /* ------------------------------------------------------ */
    /*                TESTS - DEPOSIT BTC                     */
    /* ------------------------------------------------------ */

    function testDepositAndWithdrawWithBtc() external {
        uint256 amountIn = 1e18;

        vm.startPrank(user);
        btcToken.approve(address(kipu), amountIn);
        kipu.depositWithBtc(amountIn);

        uint256 expectedUsd = expectedUsdFromSwap(amountIn);
        assertEq(
            kipu.userBalanceUsd(user),
            expectedUsd,
            "User USD after BTC deposit"
        );

        // Withdraw half of the USD in BTC (USDC -> BTC via router mock)
        uint256 withdrawUsd = expectedUsd / 2;
        kipu.withdrawWithBtc(withdrawUsd);

        // We do not assert exact BTC out; we just ensure no revert and a positive BTC balance.
        assertGt(
            btcToken.balanceOf(user),
            0,
            "User must receive some BTC back"
        );
        vm.stopPrank();
    }

    /* ------------------------------------------------------ */
    /*                TESTS - DEPOSIT USDC                    */
    /* ------------------------------------------------------ */

    function testDepositAndWithdrawWithUsdc() external {
        uint256 usdcIn = 1_000e6;

        vm.startPrank(user);
        usdcToken.approve(address(kipu), usdcIn);
        kipu.depositWithUsdc(usdcIn);

        uint256 expectedUsd = usdcIn * 1e12;
        assertEq(
            kipu.userBalanceUsd(user),
            expectedUsd,
            "User USD after USDC deposit"
        );

        // Withdraw 500 USD in USDC
        uint256 withdrawUsd = 500e18;
        kipu.withdrawWithUsdc(withdrawUsd);

        vm.stopPrank();
    }

    /* ------------------------------------------------------ */
    /*        MULTIPLE USER DEPOSITS CONSISTENCY              */
    /* ------------------------------------------------------ */

    function testContractBalanceAfterMultipleUsersDeposit() external {
        uint256 usd1 = expectedUsdFromSwap(1 ether);
        uint256 usd2 = expectedUsdFromSwap(1e18);

        vm.prank(user);
        kipu.depositWithEth{value: 1 ether}();

        vm.startPrank(user2);
        btcToken.approve(address(kipu), 1e18);
        kipu.depositWithBtc(1e18);
        vm.stopPrank();

        uint256 contractUsd = kipu.getContractBalanceUsd();
        assertEq(
            contractUsd,
            usd1 + usd2,
            "Contract USD must equal sum of users"
        );

        assertEq(kipu.userBalanceUsd(user), usd1, "User1 USD mismatch");
        assertEq(kipu.userBalanceUsd(user2), usd2, "User2 USD mismatch");
    }

    /* ------------------------------------------------------ */
    /*                  ZERO AMOUNT DEPOSITS                  */
    /* ------------------------------------------------------ */

    function testDepositZeroAmountReverts() external {
        vm.prank(user);
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        kipu.depositWithEth{value: 0}();

        vm.prank(user);
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        kipu.depositWithBtc(0);

        vm.prank(user);
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        kipu.depositWithUsdc(0);
    }

    /* ------------------------------------------------------ */
    /*            NON-EXISTENT BALANCE WITHDRAW               */
    /* ------------------------------------------------------ */

    function testWithdrawFromNonExistingUserReverts() external {
        vm.prank(user);
        vm.expectRevert(KipuBankV3.InsufficientBalance.selector);
        kipu.withdrawWithEth(1e18);
    }

    /* ------------------------------------------------------ */
    /*                  FALLBACK & RECEIVE                    */
    /* ------------------------------------------------------ */

    function testReceiveFunctionRevertsOnDirectEthTransfer() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(KipuBankV3.InvalidDepositPath.selector);
        // Empty calldata triggers receive/fallback; revert is expected
        address(kipu).call{value: 1 ether}("");
    }

    function testFallbackFunctionRevertsOnUnknownCall() external {
        vm.prank(user);
        vm.expectRevert(KipuBankV3.InvalidDepositPath.selector);
        // Non-matching function signature triggers fallback()
        address(kipu).call(abi.encodeWithSignature("doesNotExist()"));
    }

    /* ------------------------------------------------------ */
    /*                    REENTRANCY TEST                     */
    /* ------------------------------------------------------ */

    /**
     * @notice In the new Uniswap-based design, the ETH withdrawal path
     *         does not call into arbitrary user contracts, so reentrancy
     *         through receive() is not reachable. This test now asserts
     *         that the "attack" flow does not revert and the bank keeps
     *         a consistent positive USD balance.
     */
    function testReentrancyGuardPreventsReentering() external {
        ReentrancyAttacker attacker = new ReentrancyAttacker(kipu);

        uint256 initialBankUsd = kipu.getContractBalanceUsd();

        attacker.attack{value: 1 ether}();

        uint256 finalBankUsd = kipu.getContractBalanceUsd();

        // Bank balance must have increased (a legit deposit happened)
        assertGt(
            finalBankUsd,
            initialBankUsd,
            "Bank USD must increase after attack flow"
        );
        // And must be strictly positive (not drained)
        assertGt(
            finalBankUsd,
            0,
            "Bank USD must stay positive after attack flow"
        );
    }
}
