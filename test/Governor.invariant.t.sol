// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {VoteToken, GovernanceExecutorMock} from "./Governor.t.sol";
import {Governor, ITimestampVotes, IGovernanceTimelock} from "../src/Governor.sol";

contract GovernorHandler is ActorHandler {
    VoteToken public token;
    Governor public governor;
    GovernanceExecutorMock public executor;
    mapping(uint256 => uint256) public terminal;

    constructor() {
        token = new VoteToken();
        executor = new GovernanceExecutorMock();
        governor = new Governor(ITimestampVotes(address(token)), IGovernanceTimelock(address(executor)));
        for (uint256 i; i < 3; ++i) {
            token.mint(actor(i), (i + 1) * 100);
            vm.prank(actor(i));
            token.delegate(actor(i));
        }
        vm.warp(vm.getBlockTimestamp() + 1);
        propose(0);
    }

    function propose(uint256 who) public {
        if (governor.proposalCount() >= 32) return;
        callAs(
            actor(who), address(governor), abi.encodeCall(governor.propose, (CAROL, 0, bytes(""), bytes32(0)))
        );
    }

    function transfer(uint256 who, uint256 to, uint256 raw) public {
        address user = actor(who);
        uint256 balance = token.balanceOf(user);
        if (balance > 0) {
            callAs(user, address(token), abi.encodeCall(token.transfer, (actor(to), bound(raw, 1, balance))));
        }
    }

    function delegate(uint256 who, uint256 to) public {
        callAs(actor(who), address(token), abi.encodeCall(token.delegate, (actor(to))));
    }

    function vote(uint256 who, uint256 rawId, uint8 support) public {
        uint256 id = 1 + rawId % governor.proposalCount();
        callAs(actor(who), address(governor), abi.encodeCall(governor.castVote, (id, support % 4)));
    }

    function transition(uint256 rawId, uint8 action, uint256 who) public {
        uint256 id = 1 + rawId % governor.proposalCount();
        if (action % 3 == 0) callAs(actor(who), address(governor), abi.encodeCall(governor.cancel, (id)));
        else if (action % 3 == 1) callAs(actor(who), address(governor), abi.encodeCall(governor.queue, (id)));
        else callAs(actor(who), address(governor), abi.encodeCall(governor.execute, (id)));
        Governor.State state = governor.state(id);
        if (state == Governor.State.Executed || state == Governor.State.Cancelled) {
            terminal[id] = uint256(state);
        }
    }
}

contract GovernorInvariantTest is InvariantBase {
    GovernorHandler private handler;

    function setUp() public {
        vm.warp(100 days);
        handler = new GovernorHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_VotesCannotMultiplyByTransferOrDelegation() public view {
        Governor governor = handler.governor();
        uint256 executed;
        for (uint256 id = 1; id <= governor.proposalCount(); ++id) {
            (uint256 snapshot,, uint256 againstVotes, uint256 forVotes, uint256 abstain) =
                governor.details(id);
            if (vm.getBlockTimestamp() > snapshot) {
                ok(againstVotes + forVotes + abstain <= handler.token().getPastTotalSupply(snapshot));
            }
            if (handler.terminal(id) > 0) eq(uint256(governor.state(id)), handler.terminal(id));
            if (governor.state(id) == Governor.State.Executed) ++executed;
        }
        eq(handler.executor().executed(), executed);
        eq(handler.token().totalSupply(), 600);
        ok(handler.successfulCalls() > 0);
    }
}
