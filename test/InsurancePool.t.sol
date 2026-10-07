// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {InsurancePool} from "../src/InsurancePool.sol";

contract InsurancePoolTest is TestBase {
    MockToken token;
    InsurancePool pool;

    function setUp() public {
        token = new MockToken(6);
        pool = new InsurancePool(token, address(this));
        token.mint(ALICE, 1000e6);
        token.mint(BOB, 1000e6);
        vm.startPrank(ALICE);
        token.approve(address(pool), 1000e6);
        pool.payPremium(1000e6, 1);
        vm.stopPrank();
        vm.startPrank(BOB);
        token.approve(address(pool), 1000e6);
        pool.payPremium(1000e6, 1);
        vm.stopPrank();
    }

    function testCoverageClaimAndSocialisedLoss() public {
        eq(pool.coverage(ALICE), 5000e6);
        pool.approveClaim(ALICE, 500e6, 0);
        eq(pool.totalAssets(), 1500e6);
        vm.prank(ALICE);
        pool.claim(500e6);
        eq(token.balanceOf(ALICE), 500e6);
        vm.prank(BOB);
        pool.requestExit();
        vm.warp(block.timestamp + 7 days);
        vm.prank(BOB);
        pool.exit(749e6);
        ok(token.balanceOf(BOB) >= 749e6 && token.balanceOf(BOB) <= 750e6);
    }

    function testCooldownAndCoverageSurrender() public {
        vm.prank(ALICE);
        pool.requestExit();
        eq(pool.coverage(ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(InsurancePool.NotReady.selector);
        pool.exit(0);
        vm.expectRevert(InsurancePool.InvalidInput.selector);
        pool.approveClaim(ALICE, 1, 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(ALICE);
        pool.exit(1000e6);
        eq(token.balanceOf(ALICE), 1000e6);
    }

    function testOnlyOwnerCoverageAndSolvencyCaps() public {
        vm.prank(ALICE);
        vm.expectRevert();
        pool.approveClaim(ALICE, 100e6, 0);
        vm.expectRevert(InsurancePool.InvalidInput.selector);
        pool.approveClaim(ALICE, 5001e6, 0);
        vm.expectRevert(InsurancePool.InvalidInput.selector);
        pool.approveClaim(ALICE, 2001e6, 0);
    }

    function testReservedClaimsSurviveExits() public {
        pool.approveClaim(ALICE, 2000e6, 0);
        vm.prank(BOB);
        pool.requestExit();
        vm.warp(block.timestamp + 7 days);
        vm.prank(BOB);
        pool.exit(0);
        vm.prank(ALICE);
        pool.claim(2000e6);
        eq(token.balanceOf(ALICE), 2000e6);
    }

    function testFuzzSolvency(uint256 raw) public {
        uint256 amount = bound(raw, 1, 2000e6);
        pool.approveClaim(ALICE, amount, 0);
        eq(pool.totalAssets() + pool.reservedClaims(), token.balanceOf(address(pool)));
        vm.prank(ALICE);
        pool.claim(amount);
        eq(pool.reservedClaims(), 0);
        eq(pool.totalAssets(), token.balanceOf(address(pool)));
    }
}
