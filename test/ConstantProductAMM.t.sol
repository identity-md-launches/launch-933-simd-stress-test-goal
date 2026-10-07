// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";

contract ConstantProductAMMTest is TestBase {
    MockToken first;
    MockToken second;
    ConstantProductAMM amm;

    function setUp() public {
        first = new MockToken(6);
        second = new MockToken(8);
        amm = new ConstantProductAMM(first, second);
        first.mint(address(this), 1000000e6);
        second.mint(address(this), 1000000e8);
        first.approve(address(amm), type(uint256).max);
        second.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10000e6, 10000e8, 1, vm.getBlockTimestamp());
    }

    function testSwapFeeAndInvariant() public {
        uint256 k = amm.reserve0() * amm.reserve1();
        uint256 expected = uint256(100e6) * 997 * 10000e8 / (10000e6 * 1000 + 100e6 * 997);
        eq(amm.swap(first, 100e6, expected, vm.getBlockTimestamp()), expected);
        ok(amm.reserve0() * amm.reserve1() >= k);
    }

    function testLiquiditySharesAndMinimumBurn() public {
        eq(amm.balanceOf(address(1)), 1000);
        uint256 shares = amm.addLiquidity(100e6, 200e8, 1, vm.getBlockTimestamp());
        (uint256 a, uint256 b) = amm.removeLiquidity(shares, 0, 0, vm.getBlockTimestamp());
        ok(a <= 100e6 && b <= 100e8);
        amm.removeLiquidity(amm.balanceOf(address(this)), 0, 0, vm.getBlockTimestamp());
        eq(amm.totalSupply(), 1000);
        ok(amm.reserve0() > 0 && amm.reserve1() > 0);
    }

    function testTaxedInputAndOutput() public {
        first.setTax(100);
        second.setTax(100);
        uint256 before = second.balanceOf(address(this));
        uint256 gross = amm.swap(first, 100e6, 0, vm.getBlockTimestamp());
        eq(amm.reserve0(), 10099e6);
        eq(second.balanceOf(address(this)) - before, gross - gross / 100);
        eq(first.balanceOf(address(amm)), amm.reserve0());
        eq(second.balanceOf(address(amm)), amm.reserve1());
    }

    function testDeadlineSlippageAndWrongToken() public {
        vm.warp(10);
        vm.expectRevert(ConstantProductAMM.InvalidInput.selector);
        amm.swap(first, 100e6, 0, 9);
        vm.expectRevert();
        amm.swap(first, 100e6, 10000e8, 10);
        MockToken wrong = new MockToken(18);
        vm.expectRevert(ConstantProductAMM.InvalidInput.selector);
        amm.swap(wrong, 1, 0, 10);
    }

    function testDonationsCannotBeStolenThroughLiquidity() public {
        first.transfer(address(amm), 100e6);
        eq(amm.reserve0(), 10000e6);
        uint256 shares = amm.addLiquidity(100e6, 100e8, 1, vm.getBlockTimestamp());
        (uint256 amount,) = amm.removeLiquidity(shares, 0, 0, vm.getBlockTimestamp());
        ok(amount <= 100e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzKNondecreasing(uint256 raw, bool reverse) public {
        uint256 amount = bound(raw, 1e4, 1000e6);
        uint256 k = amm.reserve0() * amm.reserve1();
        amm.swap(reverse ? second : first, amount, 0, vm.getBlockTimestamp());
        ok(amm.reserve0() * amm.reserve1() >= k);
        eq(first.balanceOf(address(amm)), amm.reserve0());
        eq(second.balanceOf(address(amm)), amm.reserve1());
    }

    function testOutputSlippageRollsBackSwapAndLiquidityBurn() public {
        uint256 r0 = amm.reserve0();
        uint256 r1 = amm.reserve1();
        uint256 shares = amm.balanceOf(address(this));
        vm.expectRevert();
        amm.swap(first, 100e6, type(uint256).max, vm.getBlockTimestamp());
        vm.expectRevert();
        amm.removeLiquidity(shares, type(uint256).max, 0, vm.getBlockTimestamp());
        eq(amm.reserve0(), r0);
        eq(amm.reserve1(), r1);
        eq(amm.balanceOf(address(this)), shares);
        eq(first.balanceOf(address(amm)), r0);
        eq(second.balanceOf(address(amm)), r1);
    }

    function testMinimumInitialLiquidityAndEmptySwap() public {
        ConstantProductAMM empty = new ConstantProductAMM(first, second);
        first.approve(address(empty), type(uint256).max);
        second.approve(address(empty), type(uint256).max);
        vm.expectRevert(ConstantProductAMM.InvalidInput.selector);
        empty.addLiquidity(1000, 1000, 0, vm.getBlockTimestamp());
        eq(empty.totalSupply(), 0);
        eq(first.balanceOf(address(empty)), 0);
        vm.expectRevert(ConstantProductAMM.InvalidInput.selector);
        empty.swap(first, 1e6, 0, vm.getBlockTimestamp());
        vm.expectRevert();
        amm.addLiquidity(0, 1, 0, vm.getBlockTimestamp());
    }
}
