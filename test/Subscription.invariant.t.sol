// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Subscription} from "../src/Subscription.sol";

contract SubscriptionHandler is ActorHandler {
    MockToken public token;
    Subscription public subscription;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public merchantPaid;
    uint256 public purchases;
    bool public badRenewal;

    constructor() {
        token = new MockToken(6);
        subscription = new Subscription(token, address(this), 10e6);
        for (uint256 i; i < 3; ++i) {
            token.mint(actor(i), 1000000e6);
            vm.prank(actor(i));
            token.approve(address(subscription), type(uint256).max);
        }
        deposit(0, 100e6 - 1);
    }

    function deposit(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(actor(who), address(subscription), abi.encodeCall(subscription.deposit, (amount)))) {
            deposited += amount;
        }
    }

    function subscribe(uint256 who) public {
        uint256 beforeRevenue = subscription.revenue();
        if (callAs(actor(who), address(subscription), abi.encodeCall(subscription.subscribe, ()))) {
            if (subscription.revenue() > beforeRevenue) ++purchases;
        }
    }

    function cancel(uint256 who) public {
        callAs(actor(who), address(subscription), abi.encodeCall(subscription.cancel, ()));
    }

    function renew(uint256 who, uint256 keeper) public {
        address user = actor(who);
        bool optedIn = subscription.autoRenew(user);
        uint256 expiry = subscription.paidUntil(user);
        if (callAs(actor(keeper), address(subscription), abi.encodeCall(subscription.renew, (user)))) {
            ++purchases;
            if (
                !optedIn || vm.getBlockTimestamp() < expiry
                    || subscription.paidUntil(user) != vm.getBlockTimestamp() + 30 days
            ) badRenewal = true;
        }
    }

    function withdraw(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(
                actor(who), address(subscription), abi.encodeCall(subscription.withdraw, (amount, amount))
            )) withdrawn += amount;
    }

    function revenue() public {
        uint256 amount = subscription.revenue();
        try subscription.withdrawRevenue(amount) {
            merchantPaid += amount;
            ++successfulCalls;
        } catch {}
    }
}

contract SubscriptionInvariantTest is InvariantBase {
    SubscriptionHandler private handler;

    function setUp() public {
        handler = new SubscriptionHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_PrepaidFundsAndEarnedRevenueStaySeparate() public view {
        Subscription subscription = handler.subscription();
        uint256 cash = handler.token().balanceOf(address(subscription));
        eq(
            subscription.prepaid(ALICE) + subscription.prepaid(BOB) + subscription.prepaid(CAROL),
            subscription.totalPrepaid()
        );
        eq(subscription.totalPrepaid() + subscription.revenue(), cash);
        eq(cash + handler.withdrawn() + handler.merchantPaid(), handler.deposited());
        eq(subscription.revenue() + handler.merchantPaid(), handler.purchases() * subscription.monthlyPrice());
        ok(!handler.badRenewal());
    }
}
