// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockNFT} from "./helpers/Mocks.sol";
import {DutchAuction} from "../src/DutchAuction.sol";

contract DutchAuctionTest is TestBase {
    MockNFT nft;
    DutchAuction auction;

    function setUp() public {
        nft = new MockNFT();
        nft.mint(address(this), 1);
        auction = new DutchAuction(nft, 1, 10 ether, 2 ether, 1 days);
        nft.approve(address(auction), 1);
        auction.activate();
        vm.deal(ALICE, 20 ether);
        vm.deal(BOB, 20 ether);
    }

    function testBuyAndRefundExcess() public {
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        eq(auction.price(), 6 ether);
        vm.prank(ALICE);
        auction.buy{value: 8 ether}(ALICE, 6 ether, vm.getBlockTimestamp());
        eq(nft.ownerOf(1), ALICE);
        eq(auction.credits(ALICE), 2 ether);
        eq(auction.credits(address(this)), 6 ether);
        vm.prank(ALICE);
        auction.withdrawPayments();
        eq(ALICE.balance, 14 ether);
        auction.withdrawPayments();
        eq(address(auction).balance, 0);
    }

    function testCannotBuyTwiceOrUnderpay() public {
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.InvalidInput.selector);
        auction.buy{value: 1 ether}(ALICE, 10 ether, vm.getBlockTimestamp());
        vm.prank(ALICE);
        auction.buy{value: 10 ether}(ALICE, 10 ether, vm.getBlockTimestamp());
        vm.prank(BOB);
        vm.expectRevert(DutchAuction.WrongState.selector);
        auction.buy{value: 10 ether}(BOB, 10 ether, vm.getBlockTimestamp());
    }

    function testCancelOnlySellerAfterFloor() public {
        vm.expectRevert(DutchAuction.WrongState.selector);
        auction.cancel();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.Unauthorized.selector);
        auction.cancel();
        auction.cancel();
        eq(nft.ownerOf(1), address(this));
    }

    function testExpiredBuyerDeadline() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.InvalidInput.selector);
        auction.buy{value: 10 ether}(ALICE, 10 ether, vm.getBlockTimestamp() - 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzPriceMonotonicAndBounded(uint256 a, uint256 b) public {
        a = bound(a, 0, 10 days);
        b = bound(b, 0, 10 days);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + a);
        uint256 p1 = auction.price();
        vm.warp(start + a + b);
        uint256 p2 = auction.price();
        ok(p1 >= p2 && p2 >= 2 ether && p1 <= 10 ether);
    }

    function testSlippageAndInvalidRecipientLeaveNFTAndETHUntouched() public {
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.InvalidInput.selector);
        auction.buy{value: 10 ether}(ALICE, 10 ether - 1, vm.getBlockTimestamp());
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.InvalidInput.selector);
        auction.buy{value: 10 ether}(address(0), 10 ether, vm.getBlockTimestamp());
        vm.prank(ALICE);
        vm.expectRevert();
        auction.buy{value: 10 ether}(address(this), 10 ether, vm.getBlockTimestamp());
        eq(uint256(auction.state()), uint256(DutchAuction.State.Active));
        eq(nft.ownerOf(1), address(auction));
        eq(auction.totalCredits(), 0);
        eq(address(auction).balance, 0);
    }

    function testActivationCannotRepeatAndCancellationIsTerminal() public {
        vm.expectRevert(DutchAuction.WrongState.selector);
        auction.activate();
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.Unauthorized.selector);
        auction.activate();
        vm.warp(auction.startedAt() + auction.duration());
        auction.cancel();
        vm.expectRevert(DutchAuction.WrongState.selector);
        auction.activate();
        vm.expectRevert(DutchAuction.WrongState.selector);
        auction.cancel();
        vm.prank(ALICE);
        vm.expectRevert(DutchAuction.WrongState.selector);
        auction.buy{value: 2 ether}(ALICE, 2 ether, vm.getBlockTimestamp());
    }

    event Sold(address indexed buyer, address indexed recipient, uint256 price);

    function testBusinessEventIncludesActorAndAmount() public {
        vm.expectEmit(true, true, false, true, address(auction));
        emit Sold(ALICE, BOB, 10 ether);
        vm.prank(ALICE);
        auction.buy{value: 10 ether}(BOB, 10 ether, vm.getBlockTimestamp());
    }
}
