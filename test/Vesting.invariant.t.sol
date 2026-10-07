// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Vesting} from "../src/Vesting.sol";

contract VestingHandler is ActorHandler {
    MockToken public token;
    Vesting public vesting;
    uint256 public funded;
    uint256 public paid;
    uint256 public returned;
    mapping(uint256 => uint256) public frozen;
    mapping(uint256 => bool) public revoked;

    constructor() {
        token = new MockToken(6);
        vesting = new Vesting(token, address(this));
        token.mint(address(this), 1000000e6);
        token.approve(address(vesting), type(uint256).max);
        create(0, 1000e6 - 1, 0, true);
    }

    function create(uint256 who, uint256 raw, uint256 cliffRaw, bool revocable) public {
        if (vesting.grantCount() >= 32) return;
        uint256 amount = bound(raw, 1, 1000e6);
        vesting.create(
            actor(who),
            amount,
            vm.getBlockTimestamp(),
            vm.getBlockTimestamp() + bound(cliffRaw, 0, 10 days),
            30 days,
            revocable
        );
        funded += amount;
        ++successfulCalls;
    }

    function release(uint256 who, uint256 raw) public {
        uint256 beforeCash = token.balanceOf(address(vesting));
        if (callAs(
                actor(who), address(vesting), abi.encodeCall(vesting.release, (raw % vesting.grantCount(), 0))
            )) paid += beforeCash - token.balanceOf(address(vesting));
    }

    function revoke(uint256 raw) public {
        uint256 id = raw % vesting.grantCount();
        uint256 beforeCash = token.balanceOf(address(vesting));
        try vesting.revoke(id, 0) {
            returned += beforeCash - token.balanceOf(address(vesting));
            frozen[id] = vesting.vested(id);
            revoked[id] = true;
            ++successfulCalls;
        } catch {}
    }
}

contract VestingInvariantTest is InvariantBase {
    VestingHandler private handler;

    function setUp() public {
        handler = new VestingHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_EveryUnreleasedGrantRemainsBacked() public view {
        Vesting vesting = handler.vesting();
        uint256 liability;
        for (uint256 id; id < vesting.grantCount(); ++id) {
            (, uint256 total, uint256 released,,,,, bool revoked, uint256 frozen) = vesting.grants(id);
            ok(released <= vesting.vested(id) && vesting.vested(id) <= total);
            liability += (revoked ? frozen : total) - released;
            if (handler.revoked(id)) {
                ok(revoked);
                eq(vesting.vested(id), handler.frozen(id));
            }
        }
        eq(handler.token().balanceOf(address(vesting)), liability);
        eq(liability + handler.paid() + handler.returned(), handler.funded());
    }
}
