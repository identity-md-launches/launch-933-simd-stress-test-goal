// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockNFT} from "./helpers/Mocks.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";

contract MarketHandler is ActorHandler {
    MockNFT public nft;
    NFTMarketplace public market;
    uint256 public received;
    uint256 public withdrawn;
    mapping(uint256 => address) public finalOwner;

    constructor() {
        nft = new MockNFT();
        market = new NFTMarketplace(CAROL);
        for (uint256 i; i < 3; ++i) {
            vm.deal(actor(i), 1000 ether);
            vm.prank(actor(i));
            nft.setApprovalForAll(address(market), true);
        }
        list(0, 1 ether - 1);
    }

    function list(uint256 who, uint256 raw) public {
        if (market.listingCount() >= 32) return;
        uint256 id = market.listingCount();
        address user = actor(who);
        nft.mint(user, id);
        vm.prank(user);
        market.list(nft, id, bound(raw, 1, 10 ether));
        ++successfulCalls;
    }

    function buy(uint256 who, uint256 raw, bool wrongPrice) public {
        uint256 id = raw % market.listingCount();
        (,,, uint256 price,) = market.listings(id);
        uint256 paid = price + (wrongPrice ? 1 : 0);
        address user = actor(who);
        vm.prank(user);
        (bool success,) = address(market).call{value: paid}(abi.encodeCall(market.buy, (id, user)));
        if (success) {
            received += paid;
            finalOwner[id] = user;
            ++successfulCalls;
        }
    }

    function cancel(uint256 who, uint256 raw) public {
        uint256 id = raw % market.listingCount();
        address user = actor(who);
        if (callAs(user, address(market), abi.encodeCall(market.cancel, (id)))) finalOwner[id] = user;
    }

    function withdraw(uint256 who) public {
        uint256 beforeCash = address(market).balance;
        if (callAs(actor(who), address(market), abi.encodeCall(market.withdrawPayments, ()))) {
            withdrawn += beforeCash - address(market).balance;
        }
    }
}

contract NFTMarketplaceInvariantTest is InvariantBase {
    MarketHandler private handler;

    function setUp() public {
        handler = new MarketHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_CustodyAndPullCreditConservation() public view {
        NFTMarketplace market = handler.market();
        eq(address(market).balance + handler.withdrawn(), handler.received());
        eq(market.totalCredits(), address(market).balance);
        eq(market.credits(ALICE) + market.credits(BOB) + market.credits(CAROL), market.totalCredits());
        for (uint256 id; id < market.listingCount(); ++id) {
            (,,,, bool active) = market.listings(id);
            eq(handler.nft().ownerOf(id), active ? address(market) : handler.finalOwner(id));
            if (handler.finalOwner(id) != address(0)) ok(!active);
        }
    }
}
