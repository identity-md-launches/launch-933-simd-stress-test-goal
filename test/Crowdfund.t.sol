// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {Crowdfund} from "../src/Crowdfund.sol";

contract CrowdfundTest is TestBase {
    Crowdfund campaign;

    function setUp() public {
        campaign = new Crowdfund(CAROL, 10 ether, 1 days);
        vm.deal(ALICE, 20 ether);
        vm.deal(BOB, 20 ether);
    }

    function testGoalMetCreatorClaim() public {
        vm.prank(ALICE);
        campaign.pledge{value: 6 ether}();
        vm.prank(BOB);
        campaign.pledge{value: 4 ether}();
        vm.warp(campaign.deadline());
        vm.prank(CAROL);
        campaign.claim();
        eq(campaign.credits(CAROL), 10 ether);
        vm.prank(CAROL);
        campaign.withdrawPayments();
        eq(CAROL.balance, 10 ether);
        vm.prank(CAROL);
        vm.expectRevert(Crowdfund.WrongState.selector);
        campaign.claim();
    }

    function testMissedGoalRefund() public {
        vm.prank(ALICE);
        campaign.pledge{value: 2 ether}();
        vm.prank(ALICE);
        campaign.pledge{value: 1 ether}();
        vm.warp(campaign.deadline());
        vm.prank(ALICE);
        campaign.refund();
        eq(campaign.credits(ALICE), 3 ether);
        vm.prank(ALICE);
        vm.expectRevert(Crowdfund.InvalidInput.selector);
        campaign.refund();
    }

    function testEarlyAndUnauthorizedActions() public {
        vm.prank(ALICE);
        vm.expectRevert(Crowdfund.WrongState.selector);
        campaign.refund();
        vm.prank(CAROL);
        vm.expectRevert(Crowdfund.WrongState.selector);
        campaign.claim();
        vm.prank(ALICE);
        vm.expectRevert(Crowdfund.Unauthorized.selector);
        campaign.claim();
        vm.warp(campaign.deadline());
        vm.prank(ALICE);
        vm.expectRevert(Crowdfund.WrongState.selector);
        campaign.pledge{value: 1 ether}();
    }

    function testForcedEthDoesNotMeetGoal() public {
        vm.prank(ALICE);
        campaign.pledge{value: 1 ether}();
        vm.deal(address(campaign), 100 ether);
        vm.warp(campaign.deadline());
        vm.prank(ALICE);
        campaign.refund();
        eq(campaign.credits(ALICE), 1 ether);
        vm.prank(CAROL);
        vm.expectRevert(Crowdfund.WrongState.selector);
        campaign.claim();
    }

    function testFuzzConservation(uint256 raw) public {
        uint256 amount = bound(raw, 1, 20 ether);
        vm.prank(ALICE);
        campaign.pledge{value: amount}();
        vm.warp(campaign.deadline());
        if (amount >= 10 ether) {
            vm.prank(CAROL);
            campaign.claim();
        } else {
            vm.prank(ALICE);
            campaign.refund();
        }
        eq(campaign.totalCredits(), amount);
        eq(address(campaign).balance, amount);
    }
}
