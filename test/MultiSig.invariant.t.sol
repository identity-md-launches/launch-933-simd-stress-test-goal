// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MultiSig} from "../src/MultiSig.sol";

contract MultiSigHandler is ActorHandler {
    MultiSig public wallet;
    uint256 public sent;
    mapping(uint256 => bool) public executed;

    constructor() {
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            owners[i] = actor(i);
        }
        wallet = new MultiSig(owners, 2);
        vm.deal(address(wallet), 100 ether);
        submit(0, 1);
    }

    function submit(uint256 who, uint256 raw) public {
        if (wallet.transactionCount() >= 32) return;
        callAs(
            actor(who),
            address(wallet),
            abi.encodeCall(wallet.submit, (address(this), bound(raw, 1, 1 ether), bytes("")))
        );
    }

    function confirm(uint256 who, uint256 raw) public {
        callAs(actor(who), address(wallet), abi.encodeCall(wallet.confirm, (raw % wallet.transactionCount())));
    }

    function revoke(uint256 who, uint256 raw) public {
        callAs(actor(who), address(wallet), abi.encodeCall(wallet.revoke, (raw % wallet.transactionCount())));
    }

    function execute(uint256 raw) public {
        uint256 id = raw % wallet.transactionCount();
        (, uint256 value,, uint256 confirmations,) = wallet.transaction(id);
        uint256 required = wallet.threshold();
        if (callAs(BOB, address(wallet), abi.encodeCall(wallet.execute, (id)))) {
            require(confirmations >= required && !executed[id], "unapproved or replayed spend");
            executed[id] = true;
            sent += value;
        }
    }

    function changeThreshold(uint256 raw) public {
        // Exercise epoch invalidation using an actually approved self-call.
        if (wallet.transactionCount() >= 32) return;
        vm.prank(ALICE);
        uint256 id =
            wallet.submit(address(wallet), 0, abi.encodeCall(wallet.setThreshold, (bound(raw, 1, 3))));
        for (uint256 i; i < 3; ++i) {
            vm.prank(actor(i));
            wallet.confirm(id);
        }
        wallet.execute(id);
        executed[id] = true;
        ++successfulCalls;
    }
}

contract MultiSigInvariantTest is InvariantBase {
    MultiSigHandler private handler;

    function setUp() public {
        handler = new MultiSigHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_OnlyConfirmedTransactionsSpendOnce() public view {
        MultiSig wallet = handler.wallet();
        eq(address(wallet).balance + handler.sent(), 100 ether);
        eq(address(handler).balance, handler.sent());
        ok(wallet.threshold() > 0 && wallet.threshold() <= wallet.ownerCount());
        for (uint256 id; id < wallet.transactionCount(); ++id) {
            (,,, uint256 confirmations, bool executed) = wallet.transaction(id);
            uint256 count;
            for (uint256 who; who < 3; ++who) {
                address owner = who == 0 ? ALICE : who == 1 ? BOB : CAROL;
                if (wallet.confirmed(id, owner)) ++count;
            }
            eq(confirmations, count);
            ok(executed == handler.executed(id));
        }
    }
}
