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
        vm.warp(vm.getBlockTimestamp() + 10 days);
        escrow.timeoutRefund();
        eq(escrow.credits(ALICE), 1 ether);
    }

    function testDeliveredAndDisputedTimeouts() public {
        fund();
        vm.prank(BOB);
        escrow.deliver(0);
        vm.prank(BOB);
        escrow.dispute(0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
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

    /// forge-config: default.fuzz.runs = 1000
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

    function testWrongPaymentAndDuplicateDepositPreserveEscrow() public {
        vm.prank(ALICE);
        vm.expectRevert(Escrow.InvalidInput.selector);
        escrow.deposit{value: 1 ether - 1}();
        eq(uint256(escrow.state()), uint256(Escrow.State.AwaitingDeposit));
        fund();
        vm.prank(ALICE);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.deposit{value: 1 ether}();
        eq(address(escrow).balance, 1 ether);
    }

    function testOversizedResolutionCanRetryAndSettledStateIsTerminal() public {
        fund();
        vm.prank(BOB);
        escrow.dispute(0);
        vm.prank(CAROL);
        vm.expectRevert(Escrow.InvalidInput.selector);
        escrow.resolve(1 ether + 1);
        eq(uint256(escrow.state()), uint256(Escrow.State.Disputed));
        eq(escrow.totalCredits(), 0);
        vm.prank(CAROL);
        escrow.resolve(0);
        vm.warp(escrow.refundAt());
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.timeoutRefund();
        vm.prank(ALICE);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.dispute(0);
        eq(escrow.credits(BOB), 1 ether);
    }

    function testExactDeliveryDeadlineRejectsDeliveryAndAllowsRefund() public {
        fund();
        vm.warp(escrow.deliveryDeadline());
        vm.prank(BOB);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.deliver(0);
        vm.prank(ALICE);
        vm.expectRevert(Escrow.WrongState.selector);
        escrow.dispute(0);
        escrow.timeoutRefund();
        eq(escrow.credits(ALICE), 1 ether);
    }

    event Delivered(bytes32 indexed evidence, uint256 refundAt);

    function testBusinessEventIncludesActorAndAmount() public {
        fund();
        bytes32 evidence = keccak256("delivery");
        vm.expectEmit(true, false, false, true, address(escrow));
        emit Delivered(evidence, vm.getBlockTimestamp() + 3 days);
        vm.prank(BOB);
        escrow.deliver(evidence);
    }
}
