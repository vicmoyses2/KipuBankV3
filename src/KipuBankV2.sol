// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverter} from "./PriceConverter.sol";

/**
 * @title KipuBankV2
 * @notice A multi-currency on-chain bank that supports deposits and withdrawals
 *         in ETH (native), BTC (ERC20, 18 decimals) and USDC (ERC20, 6 decimals),
 *         while internally tracking balances in USD with 18 decimals of precision.
 * @dev
 * - Relies on Chainlink price feeds for ETH/USD and BTC/USD conversions.
 * - USDC is treated as a soft-pegged 1:1 representation of USD.
 * - Internal accounting for USD uses 18 decimals.
 */
contract KipuBankV2 is ReentrancyGuard {
    using PriceConverter for uint256;

    // -------------------------------------------------------------------------
    // Immutable System Configuration
    // -------------------------------------------------------------------------

    /// @notice Maximum aggregate capacity of the bank in USD (18 decimals).
    uint256 public immutable i_bankCapacityUsd;

    /// @notice Maximum withdrawal amount per transaction in USD (18 decimals).
    uint256 public immutable i_maxWithdrawPerTxUsd;

    // -------------------------------------------------------------------------
    // State: Global Counters & Price Feeds
    // -------------------------------------------------------------------------

    /// @notice Total number of successful deposits across all users.
    uint256 public depositCount;

    /// @notice Total number of successful withdrawals across all users.
    uint256 public withdrawCount;

    /// @notice Chainlink price feed for ETH/USD pair.
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    /// @notice Chainlink price feed for BTC/USD pair.
    AggregatorV3Interface public immutable btcUsdPriceFeed;

    /// @notice ERC20 token used to represent BTC.
    IERC20 public immutable btcToken;

    /// @notice ERC20 token representing USDC (expected 6 decimals).
    IERC20 public immutable usdcToken;

    // -------------------------------------------------------------------------
    // State: User Balances
    // -------------------------------------------------------------------------

    /**
     * @notice Raw token balances for a user, stored in token-native units.
     * @dev
     * - `eth` is denominated in wei (18 decimals).
     * - `btc` is denominated in token units (assumed 18 decimals).
     * - `usdc` is denominated in token units (assumed 6 decimals).
     */
    struct UserTokenBalances {
        uint256 eth;
        uint256 btc;
        uint256 usdc;
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
     * @notice Initializes the KipuBankV2 contract with its configuration.
     * @param bankCapacityUsd Maximum aggregate bank capacity, in USD (18 decimals).
     * @param maxWithdrawPerTxUsd Maximum allowed withdrawal per transaction, in USD.
     * @param ethUsdPriceFeed_ Chainlink ETH/USD price feed address.
     * @param btcUsdPriceFeed_ Chainlink BTC/USD price feed address.
     * @param btcToken_ ERC20 token address representing BTC.
     * @param usdcToken_ ERC20 token address representing USDC (6 decimals).
     */
    constructor(
        uint256 bankCapacityUsd,
        uint256 maxWithdrawPerTxUsd,
        address ethUsdPriceFeed_,
        address btcUsdPriceFeed_,
        address btcToken_,
        address usdcToken_
    ) {
        i_bankCapacityUsd = bankCapacityUsd;
        i_maxWithdrawPerTxUsd = maxWithdrawPerTxUsd;
        ethUsdPriceFeed = AggregatorV3Interface(ethUsdPriceFeed_);
        btcUsdPriceFeed = AggregatorV3Interface(btcUsdPriceFeed_);
        btcToken = IERC20(btcToken_);
        usdcToken = IERC20(usdcToken_);
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
     * @return ethBalance The user's ETH balance (in wei).
     * @return btcBalance The user's BTC token balance (18 decimals).
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
     * @notice Deposits ETH into the bank, crediting the user in USD.
     * @dev
     * - `msg.value` is interpreted as an ETH amount in wei (18 decimals).
     * - The corresponding USD value is computed using the ETH/USD price feed.
     */
    function depositWithEth()
        external
        payable
        nonReentrant
        onlyPositiveAmount(msg.value)
    {
        uint256 amountUsd = msg.value.getPriceFeedConversionRate(
            ethUsdPriceFeed
        );

        _checkBankCapacityUsdAfterDeposit(amountUsd);

        _userTokenBalances[msg.sender].eth += msg.value;
        userBalanceUsd[msg.sender] += amountUsd;
        totalBankBalanceUsd += amountUsd;

        depositCount++;
        emit SuccessfullyDeposited(msg.sender, amountUsd);
    }

    /**
     * @notice Deposits BTC (ERC20) into the bank, crediting the user in USD.
     * @dev
     * - The BTC token is assumed to use 18 decimals.
     * - The caller must have approved this contract to spend `amountBtc`.
     * @param amountBtc The amount of BTC tokens to deposit (18 decimals).
     */
    function depositWithBtc(
        uint256 amountBtc
    ) external nonReentrant onlyPositiveAmount(amountBtc) {
        bool ok = btcToken.transferFrom(msg.sender, address(this), amountBtc);
        if (!ok) revert TransferFailed();

        uint256 amountUsd = amountBtc.getPriceFeedConversionRate(
            btcUsdPriceFeed
        );

        _checkBankCapacityUsdAfterDeposit(amountUsd);

        _userTokenBalances[msg.sender].btc += amountBtc;
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
     * - The amount of ETH to send is derived from the current ETH/USD price.
     * @param amountUsd The USD amount (18 decimals) the user wishes to withdraw.
     */
    function withdrawWithEth(
        uint256 amountUsd
    )
        external
        nonReentrant
        onlyPositiveAmount(amountUsd)
        onlyExistingUser(msg.sender)
    {
        _commonWithdrawChecks(msg.sender, amountUsd);

        UserTokenBalances storage balances = _userTokenBalances[msg.sender];

        uint256 ethPrice = PriceConverter.getPriceFeed(ethUsdPriceFeed);
        uint256 ethAmountWei = (amountUsd * 1e18) / ethPrice;

        if (balances.eth < ethAmountWei) revert InsufficientBalance();

        balances.eth -= ethAmountWei;
        userBalanceUsd[msg.sender] -= amountUsd;
        totalBankBalanceUsd -= amountUsd;

        withdrawCount++;

        (bool ok, ) = payable(msg.sender).call{value: ethAmountWei}("");
        if (!ok) revert TransferFailed();

        emit SuccessfullyWithdrawn(msg.sender, amountUsd);
    }

    /**
     * @notice Withdraws an amount in USD, receiving BTC tokens as output.
     * @dev
     * - `amountUsd` is denominated in USD with 18 decimals.
     * - The BTC token amount is derived from the current BTC/USD price.
     * @param amountUsd The USD amount (18 decimals) the user wishes to withdraw.
     */
    function withdrawWithBtc(
        uint256 amountUsd
    )
        external
        nonReentrant
        onlyPositiveAmount(amountUsd)
        onlyExistingUser(msg.sender)
    {
        _commonWithdrawChecks(msg.sender, amountUsd);

        UserTokenBalances storage balances = _userTokenBalances[msg.sender];

        uint256 btcPrice = PriceConverter.getPriceFeed(btcUsdPriceFeed);
        uint256 btcAmount = (amountUsd * 1e18) / btcPrice;

        if (balances.btc < btcAmount) revert InsufficientBalance();

        balances.btc -= btcAmount;
        userBalanceUsd[msg.sender] -= amountUsd;
        totalBankBalanceUsd -= amountUsd;

        withdrawCount++;

        bool ok = btcToken.transfer(msg.sender, btcAmount);
        if (!ok) revert TransferFailed();

        emit SuccessfullyWithdrawn(msg.sender, amountUsd);
    }

    /**
     * @notice Withdraws an amount in USD, receiving USDC as output.
     * @dev
     * - `amountUsd` is denominated in USD with 18 decimals.
     * - To map to USDC's 6 decimals, `amountUsd` must be divisible by 1e12.
     * @param amountUsd The USD amount (18 decimals) the user wishes to withdraw.
     */
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
    // Fallback Handlers
    // -------------------------------------------------------------------------

    /**
     * @notice Rejects direct ETH transfers to the contract.
     * @dev Users should use {depositWithEth} instead of sending ETH directly.
     */
    receive() external payable {
        revert InvalidDepositPath();
    }

    /**
     * @notice Rejects unknown function calls and unwanted ETH transfers.
     */
    fallback() external payable {
        revert InvalidDepositPath();
    }
}
