// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {InsurancePool} from "../src/InsurancePool.sol";

contract InsuranceHandler is ActorHandler {
    MockToken public token;
    InsurancePool public pool;
    uint256 public premiums;
    uint256 public paid;

    constructor() {
        token = new MockToken(6);
        pool = new InsurancePool(token, address(this));
        for (uint256 i; i < 3; ++i) {
            token.mint(actor(i), 1000000e6);
            vm.prank(actor(i));
            token.approve(address(pool), type(uint256).max);
        }
        premium(0, 1000e6 - 1);
        premium(1, 1000e6 - 1);
    }

    function premium(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(actor(who), address(pool), abi.encodeCall(pool.payPremium, (amount, 1)))) {
            premiums += amount;
        }
    }

    function approve(uint256 who, uint256 raw) public {
        try pool.approveClaim(actor(who), bound(raw, 1, 3000e6), bytes32(0)) {
            ++successfulCalls;
        } catch {}
    }

    function claim(uint256 who) public {
        uint256 beforeCash = token.balanceOf(address(pool));
        if (callAs(actor(who), address(pool), abi.encodeCall(pool.claim, (0)))) {
            paid += beforeCash - token.balanceOf(address(pool));
        }
    }

    function requestExit(uint256 who) public {
        callAs(actor(who), address(pool), abi.encodeCall(pool.requestExit, ()));
    }

    function exit(uint256 who) public {
        uint256 beforeCash = token.balanceOf(address(pool));
        if (callAs(actor(who), address(pool), abi.encodeCall(pool.exit, (0)))) {
            paid += beforeCash - token.balanceOf(address(pool));
        }
    }
}

contract InsurancePoolInvariantTest is InvariantBase {
    InsuranceHandler private handler;

    function setUp() public {
        handler = new InsuranceHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_ApprovedClaimsSurvivePremiumsAndExits() public view {
        InsurancePool pool = handler.pool();
        uint256 cash = handler.token().balanceOf(address(pool));
        eq(cash + handler.paid(), handler.premiums());
        eq(pool.claims(ALICE) + pool.claims(BOB) + pool.claims(CAROL), pool.reservedClaims());
        ok(pool.reservedClaims() <= cash);
        eq(pool.totalAssets() + pool.reservedClaims(), cash);
        eq(pool.shares(ALICE) + pool.shares(BOB) + pool.shares(CAROL), pool.totalShares());
        for (uint256 i; i < 3; ++i) {
            address user = i == 0 ? ALICE : i == 1 ? BOB : CAROL;
            if (pool.exitAt(user) > 0) eq(pool.coverage(user), 0);
        }
    }
}
