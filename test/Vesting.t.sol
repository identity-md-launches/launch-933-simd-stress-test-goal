// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Vesting} from "../src/Vesting.sol";

contract VestingTest is TestBase {
    MockToken token;
    Vesting vesting;

    function setUp() public {
        token = new MockToken(6);
        vesting = new Vesting(token, address(this));
        token.mint(address(this), 10000e6);
        token.approve(address(vesting), type(uint256).max);
    }

    function grant(bool revocable) internal returns (uint256) {
        return vesting.create(
            ALICE, 1000e6, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 10 days, 100 days, revocable
        );
    }

    function testCliffLinearAndFullRelease() public {
        uint256 id = grant(true);
        vm.warp(vm.getBlockTimestamp() + 9 days);
        eq(vesting.vested(id), 0);
        vm.prank(ALICE);
        vm.expectRevert(Vesting.InvalidInput.selector);
        vesting.release(id, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        eq(vesting.vested(id), 100e6);
        vm.prank(ALICE);
        vesting.release(id, 100e6);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        vm.prank(ALICE);
        vesting.release(id, 900e6);
        eq(token.balanceOf(ALICE), 1000e6);
    }

    function testRevocationPreservesVested() public {
        uint256 id = grant(true);
        vm.warp(vm.getBlockTimestamp() + 25 days);
        vesting.revoke(id, 750e6);
        eq(token.balanceOf(address(vesting)), 250e6);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        vm.prank(ALICE);
        vesting.release(id, 250e6);
        eq(token.balanceOf(ALICE), 250e6);
        vm.expectRevert(Vesting.InvalidInput.selector);
        vesting.revoke(id, 0);
    }

    function testBeforeCliffRevokeReturnsAll() public {
        uint256 id = grant(true);
        vesting.revoke(id, 1000e6);
        eq(token.balanceOf(address(vesting)), 0);
    }

    function testIrrevocableAndAccessControl() public {
        uint256 id = grant(false);
        vm.expectRevert(Vesting.InvalidInput.selector);
        vesting.revoke(id, 0);
        vm.prank(BOB);
        vm.expectRevert(Vesting.Unauthorized.selector);
        vesting.release(id, 0);
        vm.prank(BOB);
        vm.expectRevert();
        vesting.revoke(id, 0);
    }

    function testTaxedGrantAndMultipleBeneficiaries() public {
        token.setTax(100);
        uint256 id = grant(true);
        eq(token.balanceOf(address(vesting)), 990e6);
        token.setTax(0);
        vesting.create(BOB, 500e6, vm.getBlockTimestamp(), vm.getBlockTimestamp(), 50 days, false);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        eq(vesting.vested(id), 990e6);
        vm.prank(BOB);
        vesting.release(1, 500e6);
        eq(token.balanceOf(address(vesting)), 990e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRevocationConservation(uint256 raw) public {
        uint256 elapsed = bound(raw, 0, 200 days);
        uint256 id = grant(true);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 accrued = vesting.vested(id);
        uint256 balance = token.balanceOf(address(this));
        vesting.revoke(id, 0);
        eq(token.balanceOf(address(this)) - balance + accrued, 1000e6);
        if (accrued > 0) {
            vm.prank(ALICE);
            vesting.release(id, accrued);
        }
        eq(token.balanceOf(address(vesting)), 0);
    }

    function testInvalidSchedulesAndEmptyGrantsLeaveFundingUntouched() public {
        uint256 cash = token.balanceOf(address(this));
        vm.expectRevert(Vesting.InvalidInput.selector);
        vesting.create(ALICE, 100e6, vm.getBlockTimestamp(), vm.getBlockTimestamp(), 0, true);
        vm.expectRevert(Vesting.InvalidInput.selector);
        vesting.create(ALICE, 100e6, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 2 days, 1 days, true);
        vm.expectRevert(Vesting.InvalidInput.selector);
        vesting.create(address(vesting), 100e6, vm.getBlockTimestamp(), vm.getBlockTimestamp(), 1 days, true);
        vm.expectRevert();
        vesting.create(ALICE, 0, vm.getBlockTimestamp(), vm.getBlockTimestamp(), 1 days, true);
        eq(vesting.grantCount(), 0);
        eq(token.balanceOf(address(this)), cash);
    }

    function testRevertedTaxedReleaseAndRevocationAreRetryable() public {
        uint256 id = grant(true);
        vm.warp(vm.getBlockTimestamp() + 50 days);
        token.setTax(100);
        vm.prank(ALICE);
        vm.expectRevert();
        vesting.release(id, 500e6);
        (,, uint256 released,,,,,,) = vesting.grants(id);
        eq(released, 0);
        vm.expectRevert();
        vesting.revoke(id, 500e6);
        (,,,,,,, bool revoked,) = vesting.grants(id);
        ok(!revoked);
        vesting.revoke(id, 495e6);
        vm.prank(ALICE);
        vesting.release(id, 495e6);
        eq(token.balanceOf(address(vesting)), 0);
    }

    event Revoked(uint256 indexed id, uint256 vested, uint256 returned);

    function testBusinessEventIncludesActorAndAmount() public {
        uint256 id = grant(true);
        vm.warp(vm.getBlockTimestamp() + 50 days);
        vm.expectEmit(true, false, false, true, address(vesting));
        emit Revoked(id, 500e6, 500e6);
        vesting.revoke(id, 500e6);
    }
}
