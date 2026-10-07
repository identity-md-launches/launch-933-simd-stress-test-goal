// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPriceFeed {
    /// @notice Feed decimal precision.
    function decimals() external view returns (uint8);
    /// @notice Latest round id, signed price, start, update timestamp and answered round id.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Immutable Chainlink-style adapter returning positive, fresh 18-decimal prices.
contract PriceOracleAdapter {
    error InvalidFeed();
    error InvalidPrice();
    IPriceFeed public immutable feed;
    uint256 public immutable feedUnit;
    event FeedConfigured(address indexed feed, uint8 decimals);

    constructor(IPriceFeed source) {
        if (address(source).code.length == 0) revert InvalidFeed();
        uint8 decimals = source.decimals();
        if (decimals > 36) revert InvalidFeed();
        feed = source;
        feedUnit = 10 ** decimals;
        emit FeedConfigured(address(source), decimals);
    }

    /// @notice Normalise a completed, non-future round no more than one hour old, rounding down.
    function price() external view returns (uint256 result) {
        (uint80 round, int256 answer, uint256 started, uint256 updated, uint80 answeredInRound) =
            feed.latestRoundData();
        if (
            round == 0 || answer <= 0 || updated == 0 || started > updated || updated > block.timestamp
                || block.timestamp - updated > 1 hours || answeredInRound < round
        ) revert InvalidPrice();
        result = Math.mulDiv(uint256(answer), 1e18, feedUnit);
        if (result == 0) revert InvalidPrice();
    }
}
