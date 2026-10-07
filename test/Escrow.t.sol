// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowTest is TestBase {
    Escrow escrow;

    function setUp() public {
        escrow = new Escrow(ALICE, BOB, CAROL, 1 ether, 10 days);
        vm.deal(ALICE, 2 ether);
    }

    function fund() internal {
        vm.prank(ALICE);
        escrow.deposit{value: 1 ether}();
    }

    function testDeliveryReleaseAndWithdraw() public {
        fund();
        vm.prank(BOB);
        escrow.deliver(keccak256("delivered"));
        vm.prank(ALICE);
        escrow.release();
        eq(escrow.credits(BOB), 1 ether);
        vm.prank(BOB);
        escrow.withdrawPayments();
        eq(BOB.balance, 1 ether);
    }

    function testArbitrationSplit() public {
        fund();
        vm.prank(ALICE);
        escrow.dispute(0);
        vm.prank(CAROL);
        escrow.resolve(0.3 ether);
        eq(escrow.credits(ALICE), 0.3 ether);
        eq(escrow.credits(BOB), 0.7 ether);
        vm.prank(CAROL);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.resolve(1 ether);
    }

    function testFundedTimeout() public {
        fund();
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.timeoutRefund();
        vm.warp(block.timestamp + 10 days);
        escrow.timeoutRefund();
        eq(escrow.credits(ALICE), 1 ether);
    }

    function testDeliveredAndDisputedTimeouts() public {
        fund();
        vm.prank(BOB);
        escrow.deliver(0);
        vm.prank(BOB);
        escrow.dispute(0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(CAROL);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.resolve(0);
        escrow.timeoutRefund();
        eq(escrow.credits(ALICE), 1 ether);
    }

    function testUnauthorizedAndWrongStates() public {
        vm.prank(BOB);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.deposit();
        fund();
        vm.prank(ALICE);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.release();
        vm.prank(CAROL);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.deliver(0);
        vm.prank(BOB);
        escrow.dispute(0);
        vm.prank(ALICE);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.resolve(0);
    }

    function testFuzzSettlementConservation(uint256 raw) public {
        uint256 refund = bound(raw, 0, 1 ether);
        fund();
        vm.prank(ALICE);
        escrow.dispute(0);
        vm.prank(CAROL);
        escrow.resolve(refund);
        eq(escrow.totalCredits(), 1 ether);
        eq(escrow.credits(ALICE) + escrow.credits(BOB), address(escrow).balance);
    }
}
