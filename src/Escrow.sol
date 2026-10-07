// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {EthCredits} from "./common/EthCredits.sol";

/// @notice One ETH purchase agreement with buyer release, arbitration and bounded refund timeouts.
contract Escrow is EthCredits {
    error Unauthorized();
    error WrongState();
    error InvalidInput();
    enum State {
        AwaitingDeposit,
        Funded,
        Delivered,
        Disputed,
        Settled
    }
    State public state;
    address public immutable buyer;
    address public immutable seller;
    address public immutable arbiter;
    uint256 public immutable amount;
    uint256 public immutable deliveryDeadline;
    uint256 public refundAt;
    event Deposited(uint256 amount);
    event Delivered(bytes32 indexed evidence, uint256 refundAt);
    event Disputed(address indexed by, bytes32 indexed evidence, uint256 refundAt);
    event Settled(uint256 buyerAmount, uint256 sellerAmount);

    constructor(address purchaser, address vendor, address resolver, uint256 price, uint256 duration) {
        if (
            purchaser == address(0) || vendor == address(0) || resolver == address(0) || purchaser == vendor
                || purchaser == resolver || vendor == resolver || price == 0 || duration < 1 days
                || duration > 365 days
        ) revert InvalidInput();
        buyer = purchaser;
        seller = vendor;
        arbiter = resolver;
        amount = price;
        deliveryDeadline = block.timestamp + duration;
        refundAt = deliveryDeadline;
    }

    /// @notice Buyer deposits the exact agreed price before the delivery deadline.
    function deposit() external payable nonReentrant {
        if (msg.sender != buyer) revert Unauthorized();
        if (state != State.AwaitingDeposit || block.timestamp >= deliveryDeadline) revert WrongState();
        if (msg.value != amount) revert InvalidInput();
        state = State.Funded;
        emit Deposited(msg.value);
    }

    /// @notice Seller records delivery and starts a three-day buyer review window.
    function deliver(bytes32 evidence) external nonReentrant {
        if (msg.sender != seller) revert Unauthorized();
        if (state != State.Funded || block.timestamp >= deliveryDeadline) revert WrongState();
        state = State.Delivered;
        refundAt = block.timestamp + 3 days;
        emit Delivered(evidence, refundAt);
    }

    /// @notice Buyer accepts delivery, assigning all escrow to the seller's pull balance.
    function release() external nonReentrant {
        if (msg.sender != buyer) revert Unauthorized();
        if (state != State.Delivered) revert WrongState();
        _settle(0);
    }

    /// @notice Either party disputes funding or delivery before timeout; arbitration lasts seven days.
    function dispute(bytes32 evidence) external nonReentrant {
        if (msg.sender != buyer && msg.sender != seller) revert Unauthorized();
        if ((state != State.Funded && state != State.Delivered) || block.timestamp >= refundAt) {
            revert WrongState();
        }
        state = State.Disputed;
        refundAt = block.timestamp + 7 days;
        emit Disputed(msg.sender, evidence, refundAt);
    }

    /// @notice Arbiter selects the buyer's share; the seller receives the remainder, before arbitration times out.
    function resolve(uint256 buyerAmount) external nonReentrant {
        if (msg.sender != arbiter) revert Unauthorized();
        if (state != State.Disputed || block.timestamp >= refundAt) revert WrongState();
        if (buyerAmount > amount) revert InvalidInput();
        _settle(buyerAmount);
    }

    /// @notice Anyone triggers a full buyer refund after an unresolved funded, delivered or disputed timeout.
    function timeoutRefund() external nonReentrant {
        if (state == State.AwaitingDeposit || state == State.Settled || block.timestamp < refundAt) {
            revert WrongState();
        }
        _settle(amount);
    }

    function _settle(uint256 buyerAmount) private {
        state = State.Settled;
        _credit(buyer, buyerAmount);
        _credit(seller, amount - buyerAmount);
        emit Settled(buyerAmount, amount - buyerAmount);
    }
}
