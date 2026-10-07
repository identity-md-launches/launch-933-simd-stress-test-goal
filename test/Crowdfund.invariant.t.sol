// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {Crowdfund} from "../src/Crowdfund.sol";

contract CrowdfundHandler is ActorHandler {
    Crowdfund public campaign;
    uint256 public paid;
    uint256 public withdrawn;
    bool public claimed;

    constructor() {
        campaign = new Crowdfund(CAROL, 10 ether, 10 days);
        for (uint256 i; i < 3; ++i) {
            vm.deal(actor(i), 1000 ether);
        }
        pledge(0, 1 ether - 1);
    }

    function pledge(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 5 ether);
        vm.prank(actor(who));
        (bool success,) = address(campaign).call{value: amount}(abi.encodeCall(campaign.pledge, ()));
        if (success) {
            paid += amount;
            ++successfulCalls;
        }
    }

    function claim(uint256 who) public {
        if (callAs(actor(who), address(campaign), abi.encodeCall(campaign.claim, ()))) claimed = true;
    }

    function refund(uint256 who) public {
        callAs(actor(who), address(campaign), abi.encodeCall(campaign.refund, ()));
    }

    function withdraw(uint256 who) public {
        uint256 beforeCash = address(campaign).balance;
        if (callAs(actor(who), address(campaign), abi.encodeCall(campaign.withdrawPayments, ()))) {
            withdrawn += beforeCash - address(campaign).balance;
        }
    }
}

contract CrowdfundInvariantTest is InvariantBase {
    CrowdfundHandler private handler;

    function setUp() public {
        handler = new CrowdfundHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_PledgesCannotBeClaimedAndRefunded() public view {
        Crowdfund campaign = handler.campaign();
        eq(address(campaign).balance + handler.withdrawn(), handler.paid());
        eq(campaign.totalPledged(), handler.paid());
        eq(campaign.credits(ALICE) + campaign.credits(BOB) + campaign.credits(CAROL), campaign.totalCredits());
        ok(campaign.totalCredits() <= address(campaign).balance);
        if (handler.claimed()) {
            ok(campaign.claimed());
            ok(campaign.totalPledged() >= campaign.goal());
            eq(campaign.totalCredits(), address(campaign).balance);
        }
        if (campaign.totalPledged() < campaign.goal()) {
            eq(
                campaign.pledged(ALICE) + campaign.pledged(BOB) + campaign.pledged(CAROL)
                    + campaign.totalCredits(),
                address(campaign).balance
            );
        }
    }
}
