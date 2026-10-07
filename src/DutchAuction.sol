// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EthCredits} from "./common/EthCredits.sol";

/// @notice One escrowed NFT sold for ETH at a linearly declining price; excess ETH is refundable by pull.
contract DutchAuction is EthCredits {
    error InvalidInput();
    error WrongState();
    error Unauthorized();
    IERC721 public immutable nft;
    uint256 public immutable tokenId;
    address public immutable seller;
    uint256 public immutable startPrice;
    uint256 public immutable floorPrice;
    uint256 public immutable duration;
    uint256 public startedAt;
    enum State {
        Created,
        Active,
        Sold,
        Cancelled
    }
    State public state;
    event Activated(uint256 startedAt);
    event Sold(address indexed buyer, address indexed recipient, uint256 price);
    event Cancelled();

    constructor(IERC721 collection, uint256 id, uint256 initial, uint256 floor, uint256 secondsToFloor) {
        if (
            address(collection).code.length == 0 || floor == 0 || initial < floor || secondsToFloor < 1 hours
                || secondsToFloor > 365 days
        ) revert InvalidInput();
        nft = collection;
        tokenId = id;
        seller = msg.sender;
        startPrice = initial;
        floorPrice = floor;
        duration = secondsToFloor;
    }

    /// @notice Seller escrows the NFT and starts the price clock after approving this auction.
    function activate() external nonReentrant {
        if (msg.sender != seller) revert Unauthorized();
        if (state != State.Created) revert WrongState();
        state = State.Active;
        startedAt = block.timestamp;
        emit Activated(startedAt);
        nft.transferFrom(msg.sender, address(this), tokenId);
        if (nft.ownerOf(tokenId) != address(this)) revert InvalidInput();
    }

    /// @notice Current wei price, clamped at the floor once duration elapses.
    function price() public view returns (uint256) {
        if (state == State.Created) return startPrice;
        uint256 elapsed = Math.min(block.timestamp - startedAt, duration);
        return startPrice - Math.mulDiv(startPrice - floorPrice, elapsed, duration);
    }

    /// @notice First eligible buyer wins; seller proceeds and any overpayment become pull credits.
    function buy(address recipient, uint256 maxPrice, uint256 deadline) external payable nonReentrant {
        if (state != State.Active) revert WrongState();
        uint256 cost = price();
        if (
            recipient == address(0) || recipient == address(this) || block.timestamp > deadline
                || cost > maxPrice || msg.value < cost
        ) revert InvalidInput();
        state = State.Sold;
        _credit(seller, cost);
        _credit(msg.sender, msg.value - cost);
        emit Sold(msg.sender, recipient, cost);
        nft.safeTransferFrom(address(this), recipient, tokenId);
    }

    /// @notice Seller can cancel before activation or reclaim an unsold NFT after it reaches its floor.
    function cancel() external nonReentrant {
        if (msg.sender != seller) revert Unauthorized();
        State previous = state;
        if (previous != State.Created && (previous != State.Active || block.timestamp < startedAt + duration))
        {
            revert WrongState();
        }
        state = State.Cancelled;
        emit Cancelled();
        if (previous == State.Active) nft.transferFrom(address(this), seller, tokenId);
    }
}
