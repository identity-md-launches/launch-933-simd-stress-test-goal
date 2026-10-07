// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowHandler is ActorHandler {
    Escrow public escrow;
    uint256 public paid;
    uint256 public withdrawn;
    bool public settled;

    constructor() {
        escrow = new Escrow(ALICE, BOB, CAROL, 1 ether, 10 days);
        vm.deal(ALICE, 100 ether);
        deposit(0, true);
    }

    function deposit(uint256 who, bool exact) public {
        vm.prank(actor(who));
        (bool success,) = address(escrow).call{value: exact ? 1 ether : 0}(abi.encodeCall(escrow.deposit, ()));
        if (success) {
            paid += 1 ether;
            ++successfulCalls;
        }
    }

    function deliver(uint256 who) public {
        callAs(actor(who), address(escrow), abi.encodeCall(escrow.deliver, (bytes32(0))));
    }

    function dispute(uint256 who) public {
        callAs(actor(who), address(escrow), abi.encodeCall(escrow.dispute, (bytes32(0))));
    }

    function release(uint256 who) public {
        if (callAs(actor(who), address(escrow), abi.encodeCall(escrow.release, ()))) settled = true;
    }

    function resolve(uint256 who, uint256 raw) public {
        if (callAs(actor(who), address(escrow), abi.encodeCall(escrow.resolve, (bound(raw, 0, 2 ether))))) {
            settled = true;
        }
    }

    function timeout() public {
        if (callAs(ALICE, address(escrow), abi.encodeCall(escrow.timeoutRefund, ()))) settled = true;
    }

    function withdraw(uint256 who) public {
        uint256 beforeCash = address(escrow).balance;
        if (callAs(actor(who), address(escrow), abi.encodeCall(escrow.withdrawPayments, ()))) {
            withdrawn += beforeCash - address(escrow).balance;
        }
    }
}

contract EscrowInvariantTest is InvariantBase {
    EscrowHandler private handler;

    function setUp() public {
        handler = new EscrowHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_SettlementNeverReopensOrPaysTwice() public view {
        Escrow escrow = handler.escrow();
        eq(address(escrow).balance + handler.withdrawn(), handler.paid());
        eq(escrow.credits(ALICE) + escrow.credits(BOB), escrow.totalCredits());
        eq(escrow.credits(CAROL), 0);
        ok(escrow.totalCredits() <= address(escrow).balance);
        if (handler.settled()) {
            eq(uint256(escrow.state()), uint256(Escrow.State.Settled));
            eq(escrow.totalCredits(), address(escrow).balance);
        } else {
            eq(escrow.totalCredits(), 0);
            eq(handler.withdrawn(), 0);
        }
        eq(handler.paid(), 1 ether);
    }
}
