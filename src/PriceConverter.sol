// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title PriceConverter
 * @notice Utility library for converting token amounts to USD using Chainlink price feeds.
 * @dev
 * - Assumes the underlying Chainlink price feeds return answers with 8 decimals.
 * - The library normalizes price values to 18 decimals for internal USD representation.
 */
library PriceConverter {
    /**
     * @notice Returns the latest price from a Chainlink price feed, normalized to 18 decimals.
     * @dev
     * - Typical Chainlink feeds (e.g., ETH/USD, BTC/USD) return answers with 8 decimals.
     * - The returned value is scaled by 1e10 so that the final result has 18 decimals.
     * @param priceFeed The Chainlink AggregatorV3Interface price feed instance.
     * @return price The latest price, scaled to 18 decimals.
     */
    function getPriceFeed(
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256 price) {
        (, int256 answer, , , ) = priceFeed.latestRoundData();

        // Ensure the feed answer is positive before casting to uint256
        require(answer > 0, "PriceConverter: invalid price");

        // Casting to 'uint256' is safe because we ensure 'answer > 0' above
        // and we assume the scaled value fits within uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer * 1e10);
    }

    /**
     * @notice Converts a token-denominated amount to USD, using a specified Chainlink price feed.
     * @dev
     * - `amount` is expected to use 18 decimals (e.g., ETH in wei or a token with 18 decimals).
     * - The price is retrieved via {getPriceFeed}, returning a value in USD with 18 decimals.
     * - The resulting USD amount is computed as `(price * amount) / 1e18`, maintaining 18 decimals.
     * @param amount The token amount to be converted to USD (18-decimal representation).
     * @param priceFeed The Chainlink price feed for the corresponding token/USD pair.
     * @return amountInUsd The USD value of the provided amount, using 18 decimals.
     */
    function getPriceFeedConversionRate(
        uint256 amount,
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256 amountInUsd) {
        uint256 price = getPriceFeed(priceFeed);
        amountInUsd = (price * amount) / 1e18;
    }
}
