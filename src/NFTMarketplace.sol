// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EthCredits} from "./common/EthCredits.sol";

/// @notice Custodial fixed-price ERC721 marketplace, with immutable 2.5% fee and pull payments.
contract NFTMarketplace is EthCredits {
    error InvalidInput();
    error Unauthorized();
    address public immutable treasury;
    uint256 public listingCount;

    struct Listing {
        address seller;
        IERC721 nft;
        uint256 tokenId;
        uint256 price;
        bool active;
    }
    mapping(uint256 => Listing) public listings;
    event Listed(
        uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, uint256 price
    );
    event Bought(uint256 indexed id, address indexed buyer, address indexed recipient, uint256 fee);
    event Cancelled(uint256 indexed id);

    constructor(address feeTreasury) {
        if (feeTreasury == address(0) || feeTreasury == address(this)) revert InvalidInput();
        treasury = feeTreasury;
    }

    /// @notice Escrow caller's approved NFT at a nonzero wei price.
    function list(IERC721 nft, uint256 tokenId, uint256 price) external nonReentrant returns (uint256 id) {
        if (address(nft).code.length == 0 || price == 0) revert InvalidInput();
        id = listingCount++;
        listings[id] = Listing(msg.sender, nft, tokenId, price, true);
        emit Listed(id, msg.sender, address(nft), tokenId, price);
        nft.transferFrom(msg.sender, address(this), tokenId);
        if (nft.ownerOf(tokenId) != address(this)) revert InvalidInput();
    }

    /// @notice Buy a live listing for exactly its price; split proceeds before NFT receiver callback.
    function buy(uint256 id, address recipient) external payable nonReentrant {
        Listing storage l = listings[id];
        if (!l.active || msg.value != l.price || recipient == address(0) || recipient == address(this)) {
            revert InvalidInput();
        }
        l.active = false;
        uint256 fee = Math.mulDiv(msg.value, 250, 10000);
        _credit(treasury, fee);
        _credit(l.seller, msg.value - fee);
        emit Bought(id, msg.sender, recipient, fee);
        l.nft.safeTransferFrom(address(this), recipient, l.tokenId);
    }

    /// @notice Seller cancels a live listing and recovers its NFT.
    function cancel(uint256 id) external nonReentrant {
        Listing storage l = listings[id];
        if (!l.active) revert InvalidInput();
        if (msg.sender != l.seller) revert Unauthorized();
        l.active = false;
        emit Cancelled(id);
        l.nft.transferFrom(address(this), msg.sender, l.tokenId);
    }
}
