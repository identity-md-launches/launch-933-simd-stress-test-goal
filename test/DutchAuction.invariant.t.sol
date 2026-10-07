// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockNFT} from "./helpers/Mocks.sol";
import {DutchAuction} from "../src/DutchAuction.sol";

contract DutchHandler is ActorHandler {
    MockNFT public nft;
    DutchAuction public auction;
    uint256 public received;
    uint256 public withdrawn;
    uint256 public terminal;
    address public recipient;

    constructor() {
        nft = new MockNFT();
        nft.mint(address(this), 1);
        auction = new DutchAuction(nft, 1, 10 ether, 2 ether, 1 days);
        nft.approve(address(auction), 1);
        auction.activate();
        ++successfulCalls;
        for (uint256 i; i < 3; ++i) {
            vm.deal(actor(i), 100 ether);
        }
    }

    function buy(uint256 who, uint256 raw, uint256 to) public {
        uint256 amount = bound(raw, 1 ether, 20 ether);
        address user = actor(who);
        address receiver = actor(to);
        vm.prank(user);
        (bool success,) = address(auction).call{value: amount}(
            abi.encodeCall(auction.buy, (receiver, 10 ether, vm.getBlockTimestamp()))
        );
        if (success) {
            received += amount;
            recipient = receiver;
            terminal = uint256(DutchAuction.State.Sold);
            ++successfulCalls;
        }
    }

    function cancel() public {
        try auction.cancel() {
            terminal = uint256(DutchAuction.State.Cancelled);
            ++successfulCalls;
        } catch {}
    }

    function withdraw(uint256 who) public {
        uint256 beforeCash = address(auction).balance;
        address user = who % 4 == 3 ? address(this) : actor(who);
        if (callAs(user, address(auction), abi.encodeCall(auction.withdrawPayments, ()))) {
            withdrawn += beforeCash - address(auction).balance;
        }
    }
}

contract DutchAuctionInvariantTest is InvariantBase {
    DutchHandler private handler;

    function setUp() public {
        handler = new DutchHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_NFTAndProceedsHaveSingleOwners() public view {
        DutchAuction auction = handler.auction();
        eq(address(auction).balance + handler.withdrawn(), handler.received());
        eq(auction.totalCredits(), address(auction).balance);
        eq(
            auction.credits(ALICE) + auction.credits(BOB) + auction.credits(CAROL)
                + auction.credits(address(handler)),
            auction.totalCredits()
        );
        if (handler.terminal() > 0) eq(uint256(auction.state()), handler.terminal());
        address owner = auction.state() == DutchAuction.State.Active
            ? address(auction)
            : auction.state() == DutchAuction.State.Sold ? handler.recipient() : address(handler);
        eq(handler.nft().ownerOf(1), owner);
        ok(auction.price() >= 2 ether && auction.price() <= 10 ether);
    }
}
