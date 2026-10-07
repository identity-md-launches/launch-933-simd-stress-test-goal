// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {PriceOracleAdapter, IPriceFeed} from "../src/PriceOracleAdapter.sol";

contract PriceFeedMock {
    uint8 public decimals;
    int256 public answer = 2000e8;
    uint256 public updated;
    uint80 public round = 2;
    uint80 public answered = 2;

    constructor(uint8 d) {
        decimals = d;
        updated = block.timestamp;
    }

    function configure(int256 a, uint256 time, uint80 r) external {
        answer = a;
        updated = time;
        answered = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updated, updated, answered);
    }
}

contract PriceOracleAdapterTest is TestBase {
    PriceFeedMock feed;
    PriceOracleAdapter adapter;

    function setUp() public {
        vm.warp(100 days);
        feed = new PriceFeedMock(8);
        adapter = new PriceOracleAdapter(IPriceFeed(address(feed)));
    }

    function testNormalizationAndHourBoundary() public {
        eq(adapter.price(), 2000e18);
        vm.warp(block.timestamp + 1 hours);
        eq(adapter.price(), 2000e18);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
    }

    function testNonPositiveFutureAndIncompleteRound() public {
        feed.configure(0, block.timestamp, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
        feed.configure(-1, block.timestamp, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
        feed.configure(1e8, block.timestamp + 1, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
        feed.configure(1e8, block.timestamp, 1);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
    }

    function testHighDecimalFeedAndDustRejection() public {
        PriceFeedMock high = new PriceFeedMock(24);
        PriceOracleAdapter a = new PriceOracleAdapter(IPriceFeed(address(high)));
        high.configure(2e24, block.timestamp, 2);
        eq(a.price(), 2e18);
        high.configure(1, block.timestamp, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        a.price();
    }

    function testFuzzNormalization(uint256 raw, uint256 age) public {
        uint256 value = bound(raw, 1, 1e30);
        age = bound(age, 0, 1 hours);
        feed.configure(int256(value), block.timestamp - age, 2);
        eq(adapter.price(), value * 1e10);
    }
}
