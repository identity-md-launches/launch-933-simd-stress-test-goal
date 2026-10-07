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
        vm.warp(vm.getBlockTimestamp() + 7 days);
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
        vm.warp(vm.getBlockTimestamp() + 7 days);
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
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(BOB);
        pool.exit(0);
        vm.prank(ALICE);
        pool.claim(2000e6);
        eq(token.balanceOf(ALICE), 2000e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSolvency(uint256 raw) public {
        uint256 amount = bound(raw, 1, 2000e6);
        pool.approveClaim(ALICE, amount, 0);
        eq(pool.totalAssets() + pool.reservedClaims(), token.balanceOf(address(pool)));
        vm.prank(ALICE);
        pool.claim(amount);
        eq(pool.reservedClaims(), 0);
        eq(pool.totalAssets(), token.balanceOf(address(pool)));
    }

    function testExitingMemberCannotPayPremiumOrRestartCooldown() public {
        token.mint(ALICE, 100e6);
        vm.prank(ALICE);
        token.approve(address(pool), 100e6);
        vm.prank(ALICE);
        pool.requestExit();
        uint256 ready = pool.exitAt(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(InsurancePool.NotReady.selector);
        pool.payPremium(100e6, 0);
        vm.prank(ALICE);
        vm.expectRevert(InsurancePool.InvalidInput.selector);
        pool.requestExit();
        eq(pool.exitAt(ALICE), ready);
        vm.warp(ready - 1);
        vm.prank(ALICE);
        vm.expectRevert(InsurancePool.NotReady.selector);
        pool.exit(0);
        vm.warp(ready);
        vm.prank(ALICE);
        pool.exit(1000e6);
    }

    function testRevertedClaimKeepsReservationAndCanRetry() public {
        pool.approveClaim(ALICE, 500e6, 0);
        token.setTax(100);
        vm.prank(ALICE);
        vm.expectRevert();
        pool.claim(500e6);
        eq(pool.claims(ALICE), 500e6);
        eq(pool.reservedClaims(), 500e6);
        eq(pool.totalAssets(), 1500e6);
        vm.prank(ALICE);
        pool.claim(495e6);
        eq(pool.reservedClaims(), 0);
        eq(token.balanceOf(ALICE), 495e6);
        vm.prank(ALICE);
        vm.expectRevert(InsurancePool.InvalidInput.selector);
        pool.claim(0);
    }

    function testZeroPremiumAndApprovalDoNotChangeAccounting() public {
        vm.prank(ALICE);
        vm.expectRevert();
        pool.payPremium(0, 0);
        vm.expectRevert(InsurancePool.InvalidInput.selector);
        pool.approveClaim(ALICE, 0, 0);
        eq(pool.totalShares(), 2000e12);
        eq(pool.reservedClaims(), 0);
    }

    event ClaimApproved(address indexed member, uint256 amount, bytes32 indexed evidence);

    function testBusinessEventIncludesActorAndAmount() public {
        bytes32 evidence = keccak256("loss evidence");
        vm.expectEmit(true, true, false, true, address(pool));
        emit ClaimApproved(ALICE, 100e6, evidence);
        pool.approveClaim(ALICE, 100e6, evidence);
    }
}
