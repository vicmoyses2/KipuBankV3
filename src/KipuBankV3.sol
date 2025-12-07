// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// >>> NEW: Minimal Uniswap V4 router interface used for token-to-USDC swaps.
/**
 * @dev This is a simplified interface for an external Uniswap V4-style router
 *      that executes single-pool swaps. The concrete implementation and
 *      routing details are expected to be provided by deployment configuration.
 *
 *      IMPORTANT: This interface is intentionally generic and does not reflect
 *      all Uniswap V4 features. It is designed for educational purposes and
 *      should be adapted to the actual deployed router on the target network.
 */
interface IUniswapV4Router {
    /**
     * @notice Swaps an exact amount of tokenIn for tokenOut via a single path.
     * @param tokenIn Address of the input token (use address(0) to represent native ETH).
     * @param tokenOut Address of the output token (USDC or other).
     * @param amountIn Exact amount of tokenIn to be swapped.
     * @param amountOutMinimum Minimum acceptable amount of tokenOut (slippage control).
     * @param recipient Address that will receive tokenOut.
     * @return amountOut The actual amount of tokenOut received.
     */
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) external payable returns (uint256 amountOut);
}

/**
 * @title KipuBankV3
 * @notice A multi-currency on-chain bank that supports deposits and withdrawals
 *         in ETH (native), BTC (ERC20, 18 decimals) and USDC (ERC20, 6 decimals),
 *         while internally tracking balances in USD with 18 decimals of precision.
 * @dev
 * - In this version, USDC is treated as the canonical asset held by the bank.
 * - Any deposit in a non-USDC asset (e.g. ETH or BTC) is immediately swapped
 *   to USDC via an external Uniswap V4 router and then credited to the user.
 * - The global bank capacity (in USD) is enforced using the actual USDC
 *   amount obtained from the swap, so the bank never exceeds its limit.
 * - Withdrawals may still be requested in ETH, BTC or USDC. For ETH/BTC,
 *   USDC is swapped back via Uniswap V4 and delivered to the user.
 * - USDC is treated as a soft-pegged 1:1 representation of USD.
 */
contract KipuBankV3 is ReentrancyGuard {
    // -------------------------------------------------------------------------
    // Immutable System Configuration
    // -------------------------------------------------------------------------

    /// @notice Maximum aggregate capacity of the bank in USD (18 decimals).
    uint256 public immutable i_bankCapacityUsd;

    /// @notice Maximum withdrawal amount per transaction in USD (18 decimals).
    uint256 public immutable i_maxWithdrawPerTxUsd;

    /// @notice Chainlink price feed for ETH/USD pair (kept for external consumers / analytics).
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    /// @notice Chainlink price feed for BTC/USD pair (kept for external consumers / analytics).
    AggregatorV3Interface public immutable btcUsdPriceFeed;

    /// @notice ERC20 token used to represent BTC.
    IERC20 public immutable btcToken;

    /// @notice ERC20 token representing USDC (expected 6 decimals).
    IERC20 public immutable usdcToken;

    /// @notice External router used to perform swaps via Uniswap V4.
    /// @dev This router is responsible for ETH/BTC <-> USDC conversions.
    // >>> NEW: Uniswap V4 router reference
    IUniswapV4Router public immutable uniswapRouter;

    // -------------------------------------------------------------------------
    // State: Global Counters
    // -------------------------------------------------------------------------

    /// @notice Total number of successful deposits across all users.
    uint256 public depositCount;

    /// @notice Total number of successful withdrawals across all users.
    uint256 public withdrawCount;

    // -------------------------------------------------------------------------
    // State: User Balances
    // -------------------------------------------------------------------------

    /**
     * @notice Raw token balances for a user, stored in token-native units.
     * @dev
     * - In this version, USDC is the canonical balance that is actually
     *   stored by the bank after any necessary swaps.
     * - `usdc` is denominated in token units (assumed 6 decimals).
     * - `eth` and `btc` fields are kept for backward compatibility and
     *   potential future extensions, but the effective accounting is
     *   done using USDC + USD (userBalanceUsd).
     */
    struct UserTokenBalances {
        uint256 eth; // Legacy / optional: may remain zero in this version.
        uint256 btc; // Legacy / optional: may remain zero in this version.
        uint256 usdc; // Canonical token held by the bank on behalf of the user.
    }

    /// @dev Mapping from user address to raw token balances.
    mapping(address => UserTokenBalances) private _userTokenBalances;

    /// @notice Mapping from user address to consolidated USD balance (18 decimals).
    mapping(address => uint256) public userBalanceUsd;

    /// @notice Total bank USD balance across all users (18 decimals).
    uint256 public totalBankBalanceUsd;

    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when adding more funds would exceed the bank's capacity.
    error ExceedsBankCapacity();

    /// @notice Thrown when a user attempts to use more balance than available.
    error InsufficientBalance();

    /// @notice Thrown when a zero amount or otherwise invalid amount is provided.
    error InvalidAmount();

    /// @notice Thrown when a withdrawal request exceeds the configured per-tx limit.
    error InvalidMaxWithdrawAmount();

    /// @notice Thrown when the contract receives unintended ETH (e.g. direct transfer).
    error InvalidDepositPath();

    /// @notice Thrown when a token or ETH transfer fails.
    error TransferFailed();

    /// @notice Thrown when a USDC-related amount cannot be represented with 6 decimals.
    error InvalidUsdcAmount();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a deposit operation is successfully completed.
     * @param user The address of the user performing the deposit.
     * @param amountUsd The value of the deposit in USD (18 decimals).
     */
    event SuccessfullyDeposited(address indexed user, uint256 amountUsd);

    /**
     * @notice Emitted when a withdrawal operation is successfully completed.
     * @param user The address of the user performing the withdrawal.
     * @param amountUsd The value of the withdrawal in USD (18 decimals).
     */
    event SuccessfullyWithdrawn(address indexed user, uint256 amountUsd);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @notice Ensures that the provided amount is strictly greater than zero.
     * @param amount The amount to be validated.
     */
    modifier onlyPositiveAmount(uint256 amount) {
        _onlyPositiveAmount(amount);
        _;
    }

    /**
     * @notice Internal helper for positive amount validation.
     * @param amount The amount to validate.
     */
    function _onlyPositiveAmount(uint256 amount) internal pure {
        if (amount == 0) revert InvalidAmount();
    }

    /**
     * @notice Ensures that the user already has a non-zero USD balance.
     * @param user The target user address.
     */
    modifier onlyExistingUser(address user) {
        _onlyExistingUser(user);
        _;
    }

    /**
     * @notice Internal helper to enforce non-zero user USD balance.
     * @param user The target user address.
     */
    function _onlyExistingUser(address user) internal view {
        if (userBalanceUsd[user] == 0) revert InsufficientBalance();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes the KipuBankV3 contract with its configuration.
     * @param bankCapacityUsd Maximum aggregate bank capacity, in USD (18 decimals).
     * @param maxWithdrawPerTxUsd Maximum allowed withdrawal per transaction, in USD.
     * @param ethUsdPriceFeed_ Chainlink ETH/USD price feed address.
     * @param btcUsdPriceFeed_ Chainlink BTC/USD price feed address.
     * @param btcToken_ ERC20 token address representing BTC.
     * @param usdcToken_ ERC20 token address representing USDC (6 decimals).
     * @param uniswapRouter_ External Uniswap V4 router address used for swaps.
     */
    // >>> UPDATED: constructor now receives the Uniswap router address.
    constructor(
        uint256 bankCapacityUsd,
        uint256 maxWithdrawPerTxUsd,
        address ethUsdPriceFeed_,
        address btcUsdPriceFeed_,
        address btcToken_,
        address usdcToken_,
        address uniswapRouter_
    ) {
        i_bankCapacityUsd = bankCapacityUsd;
        i_maxWithdrawPerTxUsd = maxWithdrawPerTxUsd;
        ethUsdPriceFeed = AggregatorV3Interface(ethUsdPriceFeed_);
        btcUsdPriceFeed = AggregatorV3Interface(btcUsdPriceFeed_);
        btcToken = IERC20(btcToken_);
        usdcToken = IERC20(usdcToken_);
        uniswapRouter = IUniswapV4Router(uniswapRouter_);
    }

    // -------------------------------------------------------------------------
    // Public View Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the total bank liquidity in USD (18 decimals).
     * @return The total USD balance managed by the bank.
     */
    function getContractBalanceUsd() external view returns (uint256) {
        return totalBankBalanceUsd;
    }

    /**
     * @notice Returns the consolidated USD balance for a given user.
     * @dev Reverts if the user has no recorded USD balance.
     * @param user The address of the user.
     * @return balanceUsd The user's balance denominated in USD (18 decimals).
     */
    function getUserBalanceUsd(
        address user
    ) external view returns (uint256 balanceUsd) {
        if (userBalanceUsd[user] == 0) revert InsufficientBalance();
        balanceUsd = userBalanceUsd[user];
    }

    /**
     * @notice Returns the raw token balances for a given user.
     * @param user The address of the user.
     * @return ethBalance The user's legacy ETH balance (may be zero in V3).
     * @return btcBalance The user's legacy BTC balance (may be zero in V3).
     * @return usdcBalance The user's USDC token balance (6 decimals).
     */
    function getUserTokenBalances(
        address user
    )
        external
        view
        returns (uint256 ethBalance, uint256 btcBalance, uint256 usdcBalance)
    {
        UserTokenBalances memory b = _userTokenBalances[user];
        return (b.eth, b.btc, b.usdc);
    }

    // -------------------------------------------------------------------------
    // Deposit Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Deposits ETH into the bank, swapping it to USDC and crediting the user in USD.
     * @dev
     * - `msg.value` is interpreted as an ETH amount in wei (18 decimals).
     * - ETH is immediately swapped to USDC via the Uniswap V4 router.
     * - The actual USDC amount received is scaled to USD (18 decimals) by `* 1e12`.
     * - The bank capacity is enforced based on the final USDC amount.
     */
    // >>> UPDATED: ETH deposits now go through a Uniswap swap into USDC.
    function depositWithEth()
        external
        payable
        nonReentrant
        onlyPositiveAmount(msg.value)
    {
        // Swap native ETH to USDC via the router (no slippage protection here:
        // for production systems, always pass a non-zero amountOutMinimum value).
        uint256 usdcAmountOut = _swapExactInputSingleToUsdc(
            address(0),
            msg.value
        );

        // Convert USDC (6 decimals) to USD value in 18 decimals.
        uint256 amountUsd = usdcAmountOut * 1e12;

        // Ensure the bank will not exceed its global capacity after this deposit.
        _checkBankCapacityUsdAfterDeposit(amountUsd);

        // Canonical balance is held in USDC and represented in USD internally.
        _userTokenBalances[msg.sender].usdc += usdcAmountOut;
        userBalanceUsd[msg.sender] += amountUsd;
        totalBankBalanceUsd += amountUsd;

        depositCount++;
        emit SuccessfullyDeposited(msg.sender, amountUsd);
    }

    /**
     * @notice Deposits BTC (ERC20) into the bank, swapping it to USDC and crediting the user in USD.
     * @dev
     * - The BTC token is assumed to use 18 decimals.
     * - The caller must have approved this contract to spend `amountBtc`.
     * - BTC is swapped to USDC via the Uniswap V4 router before balance updates.
     * @param amountBtc The amount of BTC tokens to deposit (18 decimals).
     */
    // >>> UPDATED: BTC deposits now go through a Uniswap swap into USDC.
    function depositWithBtc(
        uint256 amountBtc
    ) external nonReentrant onlyPositiveAmount(amountBtc) {
        // Pull BTC from user into this contract.
        bool okTransfer = btcToken.transferFrom(
            msg.sender,
            address(this),
            amountBtc
        );
        if (!okTransfer) revert TransferFailed();

        // Swap BTC -> USDC via router; bank holds the resulting USDC.
        uint256 usdcAmountOut = _swapExactInputSingleToUsdc(
            address(btcToken),
            amountBtc
        );

        // Compute USD value (18 decimals) based on USDC amount.
        uint256 amountUsd = usdcAmountOut * 1e12;

        // Enforce bank capacity using the real post-swap USDC amount.
        _checkBankCapacityUsdAfterDeposit(amountUsd);

        // Credit user in canonical USDC units and USD accounting.
        _userTokenBalances[msg.sender].usdc += usdcAmountOut;
        userBalanceUsd[msg.sender] += amountUsd;
        totalBankBalanceUsd += amountUsd;

        depositCount++;
        emit SuccessfullyDeposited(msg.sender, amountUsd);
    }

    /**
     * @notice Deposits USDC into the bank, crediting the user in USD.
     * @dev
     * - USDC is assumed to have 6 decimals.
     * - The USD value is calculated as `amountUsdc * 1e12` to reach 18 decimals.
     * - The caller must have approved this contract to spend `amountUsdc`.
     * @param amountUsdc The amount of USDC to deposit (6 decimals).
     */
    // >>> UNCHANGED LOGICALLY, BUT NOW CONSISTENT WITH USDC-CENTRIC MODEL.
    function depositWithUsdc(
        uint256 amountUsdc
    ) external nonReentrant onlyPositiveAmount(amountUsdc) {
        bool ok = usdcToken.transferFrom(msg.sender, address(this), amountUsdc);
        if (!ok) revert TransferFailed();

        uint256 amountUsd = amountUsdc * 1e12;

        _checkBankCapacityUsdAfterDeposit(amountUsd);

        _userTokenBalances[msg.sender].usdc += amountUsdc;
        userBalanceUsd[msg.sender] += amountUsd;
        totalBankBalanceUsd += amountUsd;

        depositCount++;
        emit SuccessfullyDeposited(msg.sender, amountUsd);
    }

    // -------------------------------------------------------------------------
    // Withdrawal Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Withdraws an amount in USD, receiving ETH as output.
     * @dev
     * - `amountUsd` is denominated in USD with 18 decimals.
     * - Internally, the user's USDC balance is decreased by `amountUsd / 1e12`.
     * - USDC is swapped to native ETH via the Uniswap V4 router and sent to the user.
     * @param amountUsd The USD amount (18 decimals) the user wishes to withdraw.
     */
    // >>> UPDATED: ETH withdrawals now use USDC as source and swap via Uniswap.
    function withdrawWithEth(
        uint256 amountUsd
    )
        external
        nonReentrant
        onlyPositiveAmount(amountUsd)
        onlyExistingUser(msg.sender)
    {
        _commonWithdrawChecks(msg.sender, amountUsd);

        // Enforce that the amount can be represented using 6-decimal USDC.
        if (amountUsd % 1e12 != 0) revert InvalidUsdcAmount();
        uint256 usdcAmount = amountUsd / 1e12;

        UserTokenBalances storage balances = _userTokenBalances[msg.sender];

        if (balances.usdc < usdcAmount) revert InsufficientBalance();

        balances.usdc -= usdcAmount;
        userBalanceUsd[msg.sender] -= amountUsd;
        totalBankBalanceUsd -= amountUsd;

        withdrawCount++;

        // Approve router to pull USDC from this contract.
        bool okApprove = usdcToken.approve(address(uniswapRouter), usdcAmount);
        if (!okApprove) revert TransferFailed();

        // Swap USDC -> ETH and send directly to the user.
        uint256 ethAmountOut = uniswapRouter.swapExactInputSingle(
            address(usdcToken),
            address(0), // native ETH represented as address(0) in this simplified interface
            usdcAmount,
            0, // amountOutMinimum set to 0 for simplicity (NOT for production)
            msg.sender
        );
        if (ethAmountOut == 0) revert TransferFailed();

        emit SuccessfullyWithdrawn(msg.sender, amountUsd);
    }

    /**
     * @notice Withdraws an amount in USD, receiving BTC tokens as output.
     * @dev
     * - `amountUsd` is denominated in USD with 18 decimals.
     * - Internally, user's USDC balance is decreased by `amountUsd / 1e12`.
     * - USDC is swapped to BTC via the Uniswap V4 router and sent to the user.
     * @param amountUsd The USD amount (18 decimals) the user wishes to withdraw.
     */
    // >>> UPDATED: BTC withdrawals now use USDC as source and swap via Uniswap.
    function withdrawWithBtc(
        uint256 amountUsd
    )
        external
        nonReentrant
        onlyPositiveAmount(amountUsd)
        onlyExistingUser(msg.sender)
    {
        _commonWithdrawChecks(msg.sender, amountUsd);

        // Enforce that the amount can be represented using 6-decimal USDC.
        if (amountUsd % 1e12 != 0) revert InvalidUsdcAmount();
        uint256 usdcAmount = amountUsd / 1e12;

        UserTokenBalances storage balances = _userTokenBalances[msg.sender];

        if (balances.usdc < usdcAmount) revert InsufficientBalance();

        balances.usdc -= usdcAmount;
        userBalanceUsd[msg.sender] -= amountUsd;
        totalBankBalanceUsd -= amountUsd;

        withdrawCount++;

        // Approve router to pull USDC from this contract.
        bool okApprove = usdcToken.approve(address(uniswapRouter), usdcAmount);
        if (!okApprove) revert TransferFailed();

        // Swap USDC -> BTC and send directly to the user.
        uint256 btcAmountOut = uniswapRouter.swapExactInputSingle(
            address(usdcToken),
            address(btcToken),
            usdcAmount,
            0, // amountOutMinimum set to 0 for simplicity (NOT for production)
            msg.sender
        );
        if (btcAmountOut == 0) revert TransferFailed();

        emit SuccessfullyWithdrawn(msg.sender, amountUsd);
    }

    /**
     * @notice Withdraws an amount in USD, receiving USDC as output.
     * @dev
     * - `amountUsd` is denominated in USD with 18 decimals.
     * - To map to USDC's 6 decimals, `amountUsd` must be divisible by 1e12.
     * @param amountUsd The USD amount (18 decimals) the user wishes to withdraw.
     */
    // >>> UNCHANGED IN BEHAVIOR, BUT NOW EXPLICITLY PART OF USDC-CENTRIC MODEL.
    function withdrawWithUsdc(
        uint256 amountUsd
    )
        external
        nonReentrant
        onlyPositiveAmount(amountUsd)
        onlyExistingUser(msg.sender)
    {
        _commonWithdrawChecks(msg.sender, amountUsd);

        if (amountUsd % 1e12 != 0) revert InvalidUsdcAmount();
        uint256 usdcAmount = amountUsd / 1e12;

        UserTokenBalances storage balances = _userTokenBalances[msg.sender];

        if (balances.usdc < usdcAmount) revert InsufficientBalance();

        balances.usdc -= usdcAmount;
        userBalanceUsd[msg.sender] -= amountUsd;
        totalBankBalanceUsd -= amountUsd;

        withdrawCount++;

        bool ok = usdcToken.transfer(msg.sender, usdcAmount);
        if (!ok) revert TransferFailed();

        emit SuccessfullyWithdrawn(msg.sender, amountUsd);
    }

    // -------------------------------------------------------------------------
    // Internal Validation Helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Performs common withdrawal constraints:
     *         - checks per-transaction withdrawal limit;
     *         - checks user has enough USD balance.
     * @param user The address of the user requesting the withdrawal.
     * @param amountUsd The USD value of the requested withdrawal (18 decimals).
     */
    function _commonWithdrawChecks(
        address user,
        uint256 amountUsd
    ) internal view {
        if (amountUsd > i_maxWithdrawPerTxUsd)
            revert InvalidMaxWithdrawAmount();
        _hasSufficientBalanceUsd(user, amountUsd);
    }

    /**
     * @notice Validates that adding a new USD deposit does not exceed capacity.
     * @param depositAmountUsd The USD value of the new deposit (18 decimals).
     */
    function _checkBankCapacityUsdAfterDeposit(
        uint256 depositAmountUsd
    ) private view {
        if (totalBankBalanceUsd + depositAmountUsd > i_bankCapacityUsd)
            revert ExceedsBankCapacity();
    }

    /**
     * @notice Verifies that the user has at least `amountUsd` in their USD balance.
     * @param user The address of the user.
     * @param amountUsd The USD amount to be checked (18 decimals).
     */
    function _hasSufficientBalanceUsd(
        address user,
        uint256 amountUsd
    ) private view {
        if (userBalanceUsd[user] < amountUsd) revert InsufficientBalance();
    }

    // -------------------------------------------------------------------------
    // Internal Swap Helpers (Uniswap V4)
    // -------------------------------------------------------------------------

    /**
     * @notice Internal helper that swaps an exact amount of a given token into USDC.
     * @dev
     * - If `tokenIn` is address(0), the function assumes native ETH is being swapped.
     * - For ERC20 inputs, the token must already be held by this contract.
     * - Uses a zero `amountOutMinimum` for simplicity; this is NOT appropriate
     *   for production deployments where slippage must be controlled.
     * @param tokenIn Address of the input token (or address(0) for native ETH).
     * @param amountIn Exact amount of tokenIn to swap.
     * @return usdcAmountOut Amount of USDC received from the swap.
     */
    // >>> NEW: Centralized swap helper to enforce consistent behavior.
    function _swapExactInputSingleToUsdc(
        address tokenIn,
        uint256 amountIn
    ) internal returns (uint256 usdcAmountOut) {
        if (tokenIn == address(0)) {
            // Native ETH path.
            usdcAmountOut = uniswapRouter.swapExactInputSingle{value: amountIn}(
                address(0),
                address(usdcToken),
                amountIn,
                0, // amountOutMinimum set to 0 for simplicity (NOT for production)
                address(this)
            );
        } else {
            // ERC20 path. Approve router to spend the input tokens.
            bool okApprove = IERC20(tokenIn).approve(
                address(uniswapRouter),
                amountIn
            );
            if (!okApprove) revert TransferFailed();

            usdcAmountOut = uniswapRouter.swapExactInputSingle(
                tokenIn,
                address(usdcToken),
                amountIn,
                0, // amountOutMinimum set to 0 for simplicity (NOT for production)
                address(this)
            );
        }

        if (usdcAmountOut == 0) revert TransferFailed();
    }

    // -------------------------------------------------------------------------
    // Fallback Handlers
    // -------------------------------------------------------------------------

    /**
     * @notice Rejects direct ETH transfers to the contract.
     * @dev Users should use {depositWithEth} instead of sending ETH directly.
     */
    function receive() external payable {
        revert InvalidDepositPath();
    }

    /**
     * @notice Rejects unknown function calls and unwanted ETH transfers.
     */
    fallback() external payable {
        revert InvalidDepositPath();
    }
}
