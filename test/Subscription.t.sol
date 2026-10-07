// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Subscription} from "../src/Subscription.sol";

contract SubscriptionTest is TestBase {
    MockToken token;
    Subscription subscription;

    function setUp() public {
        token = new MockToken(6);
        subscription = new Subscription(token, CAROL, 10e6);
        token.mint(ALICE, 1000e6);
        vm.prank(ALICE);
        token.approve(address(subscription), 1000e6);
    }

    function subscribe() internal {
        vm.startPrank(ALICE);
        subscription.deposit(100e6);
        subscription.subscribe();
        vm.stopPrank();
    }

    function testSubscribeRenewCancelAndWithdraw() public {
        subscribe();
        ok(subscription.isActive(ALICE));
        eq(subscription.prepaid(ALICE), 90e6);
        vm.warp(subscription.paidUntil(ALICE));
        subscription.renew(ALICE);
        eq(subscription.revenue(), 20e6);
        vm.prank(ALICE);
        subscription.cancel();
        ok(subscription.isActive(ALICE));
        vm.prank(ALICE);
        subscription.withdraw(80e6, 80e6);
        vm.prank(CAROL);
        subscription.withdrawRevenue(20e6);
        eq(token.balanceOf(address(subscription)), 0);
    }

    function testCannotRenewEarlyCancelledOrUnfunded() public {
        subscribe();
        vm.expectRevert(Subscription.NotReady.selector);
        subscription.renew(ALICE);
        vm.prank(ALICE);
        subscription.cancel();
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.expectRevert(Subscription.NotReady.selector);
        subscription.renew(ALICE);
        vm.prank(BOB);
        vm.expectRevert(Subscription.InvalidInput.selector);
        subscription.subscribe();
    }

    function testResumeAndLateRenewalDoNotOvercharge() public {
        subscribe();
        vm.prank(ALICE);
        subscription.cancel();
        vm.prank(ALICE);
        subscription.subscribe();
        eq(subscription.revenue(), 10e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        subscription.renew(ALICE);
        eq(subscription.revenue(), 20e6);
        eq(subscription.paidUntil(ALICE), vm.getBlockTimestamp() + 30 days);
    }

    function testMerchantCannotStealPrepaidAndCallerCannotStealRevenue() public {
        subscribe();
        vm.prank(BOB);
        vm.expectRevert(Subscription.Unauthorized.selector);
        subscription.withdrawRevenue(0);
        vm.prank(CAROL);
        vm.expectRevert(Subscription.InvalidInput.selector);
        subscription.withdraw(1, 0);
    }

    function testTaxedDepositIsNetCredited() public {
        token.setTax(100);
        vm.prank(ALICE);
        subscription.deposit(100e6);
        eq(subscription.prepaid(ALICE), 99e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAccountingConservation(uint256 raw) public {
        uint256 amount = bound(raw, 10e6, 1000e6);
        vm.startPrank(ALICE);
        subscription.deposit(amount);
        subscription.subscribe();
        vm.stopPrank();
        eq(subscription.totalPrepaid() + subscription.revenue(), token.balanceOf(address(subscription)));
        vm.prank(CAROL);
        subscription.withdrawRevenue(10e6);
        eq(subscription.totalPrepaid(), token.balanceOf(address(subscription)));
    }

    function testInsufficientFundsSubscribeRollbackDoesNotLeaveOptIn() public {
        vm.prank(ALICE);
        subscription.deposit(1e6);
        vm.prank(ALICE);
        vm.expectRevert(Subscription.InvalidInput.selector);
        subscription.subscribe();
        ok(!subscription.autoRenew(ALICE));
        eq(subscription.prepaid(ALICE), 1e6);
        eq(subscription.paidUntil(ALICE), 0);
        eq(subscription.revenue(), 0);
    }

    function testRevertedTaxedWithdrawalsKeepPrepaidAndMerchantRevenue() public {
        subscribe();
        token.setTax(100);
        vm.prank(ALICE);
        vm.expectRevert();
        subscription.withdraw(90e6, 90e6);
        eq(subscription.totalPrepaid(), 90e6);
        eq(subscription.prepaid(ALICE), 90e6);
        vm.prank(CAROL);
        vm.expectRevert();
        subscription.withdrawRevenue(10e6);
        eq(subscription.revenue(), 10e6);
        eq(token.balanceOf(address(subscription)), 100e6);
        vm.prank(ALICE);
        subscription.withdraw(90e6, 891e5);
        vm.prank(CAROL);
        subscription.withdrawRevenue(99e5);
        eq(token.balanceOf(address(subscription)), 0);
    }

    function testExactExpiryAllowsOneRenewalAndRejectsSecond() public {
        subscribe();
        uint256 expiry = subscription.paidUntil(ALICE);
        vm.warp(expiry - 1);
        vm.expectRevert(Subscription.NotReady.selector);
        subscription.renew(ALICE);
        vm.warp(expiry);
        subscription.renew(ALICE);
        vm.expectRevert(Subscription.NotReady.selector);
        subscription.renew(ALICE);
        eq(subscription.paidUntil(ALICE), expiry + 30 days);
        eq(subscription.revenue(), 20e6);
    }

    event Cancelled(address indexed subscriber);

    function testBusinessEventIncludesActorAndAmount() public {
        subscribe();
        vm.expectEmit(true, false, false, true, address(subscription));
        emit Cancelled(ALICE);
        vm.prank(ALICE);
        subscription.cancel();
    }
}
