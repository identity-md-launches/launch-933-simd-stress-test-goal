// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockNFT} from "./helpers/Mocks.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";
import {EthCredits} from "../src/common/EthCredits.sol";

contract MarketReentrantBuyer {
    NFTMarketplace public market;
    bool public blocked;

    constructor(NFTMarketplace m) {
        market = m;
    }

    function buy(uint256 id) external payable {
        market.buy{value: msg.value}(id, address(this));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (bool success,) = address(market).call(abi.encodeCall(market.cancel, (0)));
        blocked = !success;
        return this.onERC721Received.selector;
    }
}

contract RejectingSeller {
    function list(MockNFT nft, NFTMarketplace m) external {
        nft.approve(address(m), 1);
        m.list(nft, 1, 1 ether);
    }

    function withdraw(NFTMarketplace m) external {
        m.withdrawPayments();
    }
}

contract NFTMarketplaceTest is TestBase {
    MockNFT nft;
    NFTMarketplace market;

    function setUp() public {
        nft = new MockNFT();
        market = new NFTMarketplace(CAROL);
        nft.mint(ALICE, 1);
        vm.prank(ALICE);
        nft.approve(address(market), 1);
        vm.deal(BOB, 100 ether);
    }

    function listing(uint256 price) internal returns (uint256) {
        vm.prank(ALICE);
        return market.list(nft, 1, price);
    }

    function testBuyFeeAndPullPayments() public {
        uint256 id = listing(1 ether);
        vm.prank(BOB);
        market.buy{value: 1 ether}(id, BOB);
        eq(nft.ownerOf(1), BOB);
        eq(market.credits(CAROL), 0.025 ether);
        eq(market.credits(ALICE), 0.975 ether);
        vm.prank(ALICE);
        market.withdrawPayments();
        eq(ALICE.balance, 0.975 ether);
        vm.prank(ALICE);
        vm.expectRevert(EthCredits.NothingToWithdraw.selector);
        market.withdrawPayments();
    }

    function testCancelAndUnauthorized() public {
        uint256 id = listing(1 ether);
        vm.prank(BOB);
        vm.expectRevert(NFTMarketplace.Unauthorized.selector);
        market.cancel(id);
        vm.prank(ALICE);
        market.cancel(id);
        eq(nft.ownerOf(1), ALICE);
        vm.prank(BOB);
        vm.expectRevert(NFTMarketplace.InvalidInput.selector);
        market.buy{value: 1 ether}(id, BOB);
    }

    function testWrongPriceAndDuplicateBuy() public {
        uint256 id = listing(1 ether);
        vm.prank(BOB);
        vm.expectRevert(NFTMarketplace.InvalidInput.selector);
        market.buy{value: 2 ether}(id, BOB);
        vm.prank(BOB);
        market.buy{value: 1 ether}(id, BOB);
        vm.prank(BOB);
        vm.expectRevert(NFTMarketplace.InvalidInput.selector);
        market.buy{value: 1 ether}(id, BOB);
    }

    function testReceiverCallbackCannotReenter() public {
        uint256 id = listing(1 ether);
        MarketReentrantBuyer buyer = new MarketReentrantBuyer(market);
        vm.deal(address(this), 1 ether);
        buyer.buy{value: 1 ether}(id);
        ok(buyer.blocked());
        eq(nft.ownerOf(1), address(buyer));
    }

    function testRejectingSellerDoesNotBlockSale() public {
        RejectingSeller seller = new RejectingSeller();
        MockNFT other = new MockNFT();
        other.mint(address(seller), 1);
        seller.list(other, market);
        vm.prank(BOB);
        market.buy{value: 1 ether}(0, BOB);
        vm.expectRevert(EthCredits.PaymentFailed.selector);
        seller.withdraw(market);
        eq(market.credits(address(seller)), 0.975 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeConservation(uint256 raw) public {
        uint256 price = bound(raw, 1, 100 ether);
        uint256 id = listing(price);
        vm.prank(BOB);
        market.buy{value: price}(id, BOB);
        eq(market.credits(ALICE) + market.credits(CAROL), price);
        eq(market.credits(CAROL), price * 250 / 10000);
    }

    function testRejectedNFTReceiverRollsBackSaleAndCredits() public {
        uint256 id = listing(1 ether);
        vm.prank(BOB);
        vm.expectRevert();
        market.buy{value: 1 ether}(id, address(this));
        (,,,, bool active) = market.listings(id);
        ok(active);
        eq(nft.ownerOf(1), address(market));
        eq(market.totalCredits(), 0);
        eq(address(market).balance, 0);
        vm.prank(BOB);
        market.buy{value: 1 ether}(id, BOB);
        eq(nft.ownerOf(1), BOB);
    }

    function testMissingApprovalAndZeroPriceCannotCreateListing() public {
        vm.prank(ALICE);
        nft.approve(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert();
        market.list(nft, 1, 1 ether);
        eq(market.listingCount(), 0);
        eq(nft.ownerOf(1), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(NFTMarketplace.InvalidInput.selector);
        market.list(nft, 1, 0);
        vm.expectRevert(NFTMarketplace.InvalidInput.selector);
        market.cancel(99);
    }

    event Listed(
        uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, uint256 price
    );

    function testBusinessEventIncludesActorAndAmount() public {
        vm.expectEmit(true, true, true, true, address(market));
        emit Listed(0, ALICE, address(nft), 1, 1 ether);
        listing(1 ether);
    }
}
