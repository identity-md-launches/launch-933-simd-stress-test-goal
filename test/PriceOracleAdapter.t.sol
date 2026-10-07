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
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        eq(adapter.price(), 2000e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
    }

    function testNonPositiveFutureAndIncompleteRound() public {
        feed.configure(0, vm.getBlockTimestamp(), 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
        feed.configure(-1, vm.getBlockTimestamp(), 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
        feed.configure(1e8, vm.getBlockTimestamp() + 1, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
        feed.configure(1e8, vm.getBlockTimestamp(), 1);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
    }

    function testHighDecimalFeedAndDustRejection() public {
        PriceFeedMock high = new PriceFeedMock(24);
        PriceOracleAdapter a = new PriceOracleAdapter(IPriceFeed(address(high)));
        high.configure(2e24, vm.getBlockTimestamp(), 2);
        eq(a.price(), 2e18);
        high.configure(1, vm.getBlockTimestamp(), 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        a.price();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzNormalization(uint256 raw, uint256 age) public {
        uint256 value = bound(raw, 1, 1e30);
        age = bound(age, 0, 1 hours);
        feed.configure(int256(value), vm.getBlockTimestamp() - age, 2);
        eq(adapter.price(), value * 1e10);
    }

    function testUnsupportedPrecisionAndEmptyCode() public {
        vm.expectRevert(PriceOracleAdapter.InvalidFeed.selector);
        new PriceOracleAdapter(IPriceFeed(ALICE));
        PriceFeedMock invalid = new PriceFeedMock(37);
        vm.expectRevert(PriceOracleAdapter.InvalidFeed.selector);
        new PriceOracleAdapter(IPriceFeed(address(invalid)));
        feed.configure(1e8, 0, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEverySupportedDecimalAndDust(uint256 raw, uint8 decimals) public {
        decimals %= 37;
        uint256 answer = bound(raw, 1, 1e36);
        PriceFeedMock source = new PriceFeedMock(decimals);
        PriceOracleAdapter normalized = new PriceOracleAdapter(IPriceFeed(address(source)));
        source.configure(int256(answer), vm.getBlockTimestamp(), 2);
        uint256 unit = 10 ** uint256(decimals);
        uint256 expected = answer * 1e18 / unit;
        if (expected == 0) {
            vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
            normalized.price();
        } else {
            uint256 result = normalized.price();
            ok(result * unit <= answer * 1e18);
            ok((result + 1) * unit > answer * 1e18);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzStalePricesAlwaysRevert(uint256 raw) public {
        uint256 age = bound(raw, 1 hours + 1, 30 days);
        feed.configure(2000e8, vm.getBlockTimestamp() - age, 2);
        vm.expectRevert(PriceOracleAdapter.InvalidPrice.selector);
        adapter.price();
    }
}
