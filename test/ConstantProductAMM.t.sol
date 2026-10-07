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
        amm.addLiquidity(10000e6, 10000e8, 1, block.timestamp);
    }

    function testSwapFeeAndInvariant() public {
        uint256 k = amm.reserve0() * amm.reserve1();
        uint256 expected = uint256(100e6) * 997 * 10000e8 / (10000e6 * 1000 + 100e6 * 997);
        eq(amm.swap(first, 100e6, expected, block.timestamp), expected);
        ok(amm.reserve0() * amm.reserve1() >= k);
    }

    function testLiquiditySharesAndMinimumBurn() public {
        eq(amm.balanceOf(address(1)), 1000);
        uint256 shares = amm.addLiquidity(100e6, 200e8, 1, block.timestamp);
        (uint256 a, uint256 b) = amm.removeLiquidity(shares, 0, 0, block.timestamp);
        ok(a <= 100e6 && b <= 100e8);
        amm.removeLiquidity(amm.balanceOf(address(this)), 0, 0, block.timestamp);
        eq(amm.totalSupply(), 1000);
        ok(amm.reserve0() > 0 && amm.reserve1() > 0);
    }

    function testTaxedInputAndOutput() public {
        first.setTax(100);
        second.setTax(100);
        uint256 before = second.balanceOf(address(this));
        uint256 gross = amm.swap(first, 100e6, 0, block.timestamp);
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
        uint256 shares = amm.addLiquidity(100e6, 100e8, 1, block.timestamp);
        (uint256 amount,) = amm.removeLiquidity(shares, 0, 0, block.timestamp);
        ok(amount <= 100e6);
    }

    function testFuzzKNondecreasing(uint256 raw, bool reverse) public {
        uint256 amount = bound(raw, 1e4, 1000e6);
        uint256 k = amm.reserve0() * amm.reserve1();
        amm.swap(reverse ? second : first, amount, 0, block.timestamp);
        ok(amm.reserve0() * amm.reserve1() >= k);
        eq(first.balanceOf(address(amm)), amm.reserve0());
        eq(second.balanceOf(address(amm)), amm.reserve1());
    }
}
