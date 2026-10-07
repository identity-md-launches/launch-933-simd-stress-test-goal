// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {Raffle} from "../src/Raffle.sol";

contract RaffleHandler is ActorHandler {
    Raffle public raffle;
    bytes32 private constant SEED = keccak256("invariant seed");
    uint256 public paid;
    uint256 public withdrawn;
    uint256 public terminal;

    constructor() {
        raffle = new Raffle(address(this), 1 ether, 10, 1 days, 1 days);
        vm.deal(address(this), 10 ether);
        raffle.open{value: 10 ether}(keccak256(abi.encode(SEED, address(raffle), block.chainid)));
        paid = 10 ether;
        ++successfulCalls;
        for (uint256 i; i < 3; ++i) {
            vm.deal(actor(i), 100 ether);
        }
    }

    function buy(uint256 who, bool exact) public {
        uint256 amount = exact ? 1 ether : 1 ether + 1;
        vm.prank(actor(who));
        (bool success,) = address(raffle).call{value: amount}(abi.encodeCall(raffle.buyTicket, ()));
        if (success) {
            paid += amount;
            ++successfulCalls;
        }
    }

    function reveal(bool correct) public {
        try raffle.reveal(correct ? SEED : bytes32(0)) {
            terminal = uint256(Raffle.State.Drawn);
            ++successfulCalls;
        } catch {}
    }

    function expire() public {
        try raffle.expire() {
            terminal = uint256(Raffle.State.Expired);
            ++successfulCalls;
        } catch {}
    }

    function refund(uint256 who) public {
        callAs(actor(who), address(raffle), abi.encodeCall(raffle.refund, ()));
    }

    function withdraw(uint256 who) public {
        uint256 beforeCash = address(raffle).balance;
        if (callAs(
                who % 4 == 3 ? address(this) : actor(who),
                address(raffle),
                abi.encodeCall(raffle.withdrawPayments, ())
            )) withdrawn += beforeCash - address(raffle).balance;
    }
}

contract RaffleInvariantTest is InvariantBase {
    RaffleHandler private handler;

    function setUp() public {
        handler = new RaffleHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_BondPrizeAndRefundsRemainSolvent() public view {
        Raffle raffle = handler.raffle();
        eq(address(raffle).balance + handler.withdrawn(), handler.paid());
        eq(
            raffle.credits(ALICE) + raffle.credits(BOB) + raffle.credits(CAROL)
                + raffle.credits(address(handler)),
            raffle.totalCredits()
        );
        uint256 pendingRefunds;
        if (raffle.state() == Raffle.State.Expired) {
            pendingRefunds = (raffle.ticketsHeld(ALICE) + raffle.ticketsHeld(BOB) + raffle.ticketsHeld(CAROL))
                * raffle.refundPerTicket();
        }
        ok(raffle.totalCredits() + pendingRefunds <= address(raffle).balance);
        if (raffle.state() == Raffle.State.Drawn || raffle.state() == Raffle.State.Expired) {
            eq(raffle.totalCredits() + pendingRefunds, address(raffle).balance);
        }
        if (handler.terminal() > 0) eq(uint256(raffle.state()), handler.terminal());
        ok(raffle.ticketCount() <= raffle.maxTickets());
    }
}
