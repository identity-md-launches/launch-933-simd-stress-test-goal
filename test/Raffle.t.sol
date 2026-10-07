// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {Raffle} from "../src/Raffle.sol";
import {EthCredits} from "../src/common/EthCredits.sol";

contract RaffleReceiver {
    Raffle public raffle;
    bool public reject;
    bool public blocked;

    constructor(Raffle r) {
        raffle = r;
    }

    function buy() external payable {
        raffle.buyTicket{value: msg.value}();
    }

    function claim(bool refuse) external {
        reject = refuse;
        raffle.withdrawPayments();
    }

    receive() external payable {
        require(!reject);
        (bool success,) = address(raffle).call(abi.encodeCall(raffle.withdrawPayments, ()));
        blocked = !success;
    }
}

contract RaffleTest is TestBase {
    Raffle raffle;
    bytes32 constant SEED = keccak256("test-only seed");

    function setUp() public {
        raffle = new Raffle(address(this), 1 ether, 10, 1 days, 1 days);
        vm.deal(address(this), 10 ether);
        raffle.open{value: 10 ether}(keccak256(abi.encode(SEED, address(raffle), block.chainid)));
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
    }

    function testRevealConservationAndPrizeClaim() public {
        vm.prank(ALICE);
        raffle.buyTicket{value: 1 ether}();
        vm.prank(BOB);
        raffle.buyTicket{value: 1 ether}();
        vm.warp(raffle.saleEnd());
        raffle.reveal(SEED);
        address winner = raffle.winner();
        ok(winner == ALICE || winner == BOB);
        eq(raffle.credits(winner), 2 ether);
        eq(raffle.totalCredits(), 12 ether);
        vm.prank(winner);
        raffle.withdrawPayments();
        raffle.withdrawPayments();
        eq(address(raffle).balance, 0);
    }

    function testTimeoutRefundAndBondForfeiture() public {
        vm.prank(ALICE);
        raffle.buyTicket{value: 1 ether}();
        vm.prank(BOB);
        raffle.buyTicket{value: 1 ether}();
        vm.warp(raffle.revealEnd());
        raffle.expire();
        vm.prank(ALICE);
        raffle.refund();
        vm.prank(BOB);
        raffle.refund();
        eq(raffle.credits(ALICE), 6 ether);
        eq(raffle.totalCredits(), 12 ether);
        vm.prank(ALICE);
        vm.expectRevert(Raffle.InvalidInput.selector);
        raffle.refund();
    }

    function testWrongSeedEarlyLateAndUnauthorizedReveal() public {
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.reveal(SEED);
        vm.warp(raffle.saleEnd());
        vm.expectRevert(Raffle.InvalidInput.selector);
        raffle.reveal(0);
        vm.prank(ALICE);
        vm.expectRevert(Raffle.Unauthorized.selector);
        raffle.reveal(SEED);
        vm.warp(raffle.revealEnd());
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.reveal(SEED);
    }

    function testLateEntryWrongPaymentAndCap() public {
        vm.prank(ALICE);
        vm.expectRevert(Raffle.InvalidInput.selector);
        raffle.buyTicket{value: 2 ether}();
        for (uint256 i; i < 10; ++i) {
            vm.prank(ALICE);
            raffle.buyTicket{value: 1 ether}();
        }
        vm.prank(BOB);
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.buyTicket{value: 1 ether}();
        vm.warp(raffle.saleEnd());
        vm.prank(BOB);
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.buyTicket{value: 1 ether}();
    }

    function testEmptyRoundReturnsBond() public {
        vm.warp(raffle.saleEnd());
        raffle.reveal(SEED);
        eq(raffle.credits(address(this)), 10 ether);
        eq(raffle.winner(), address(0));
    }

    function testSettlementFailureAndReentrantPrizeClaim() public {
        RaffleReceiver receiver = new RaffleReceiver(raffle);
        vm.deal(address(this), 1 ether);
        receiver.buy{value: 1 ether}();
        vm.warp(raffle.saleEnd());
        raffle.reveal(SEED);
        vm.expectRevert(EthCredits.PaymentFailed.selector);
        receiver.claim(true);
        eq(raffle.credits(address(receiver)), 1 ether);
        receiver.claim(false);
        ok(receiver.blocked());
        eq(address(receiver).balance, 1 ether);
        eq(raffle.credits(address(receiver)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRefundSolvency(uint256 raw) public {
        uint256 count = bound(raw, 1, 10);
        for (uint256 i; i < count; ++i) {
            vm.prank(ALICE);
            raffle.buyTicket{value: 1 ether}();
        }
        vm.warp(raffle.revealEnd());
        raffle.expire();
        vm.prank(ALICE);
        raffle.refund();
        eq(raffle.totalCredits(), address(raffle).balance);
    }

    function testInvalidCommitAndInsufficientBondCanRetry() public {
        Raffle other = new Raffle(address(this), 1 ether, 10, 1 days, 1 days);
        vm.deal(address(this), 10 ether);
        vm.expectRevert(Raffle.InvalidInput.selector);
        other.open{value: 10 ether}(0);
        vm.expectRevert(Raffle.InvalidInput.selector);
        other.open{value: 9 ether}(keccak256("seed"));
        eq(uint256(other.state()), uint256(Raffle.State.Created));
        eq(address(other).balance, 0);
        vm.prank(ALICE);
        vm.expectRevert(Raffle.Unauthorized.selector);
        other.open(keccak256("seed"));
    }

    function testRevertedRevealDoesNotChooseWinnerOrAllocateBond() public {
        vm.prank(ALICE);
        raffle.buyTicket{value: 1 ether}();
        vm.warp(raffle.saleEnd());
        vm.expectRevert(Raffle.InvalidInput.selector);
        raffle.reveal(bytes32(uint256(1)));
        eq(uint256(raffle.state()), uint256(Raffle.State.Open));
        eq(raffle.winner(), address(0));
        eq(raffle.totalCredits(), 0);
        raffle.reveal(SEED);
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.reveal(SEED);
        vm.warp(raffle.revealEnd());
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.expire();
        vm.prank(ALICE);
        vm.expectRevert(Raffle.WrongState.selector);
        raffle.refund();
    }

    event Expired(uint256 refundPerTicket);

    function testBusinessEventIncludesActorAndAmount() public {
        vm.prank(ALICE);
        raffle.buyTicket{value: 1 ether}();
        vm.warp(raffle.revealEnd());
        vm.expectEmit(false, false, false, true, address(raffle));
        emit Expired(11 ether);
        raffle.expire();
    }
}
