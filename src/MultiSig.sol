// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Bounded M-of-N wallet; membership changes invalidate all outstanding proposals.
contract MultiSig is ReentrancyGuard {
    error Unauthorized();
    error InvalidInput();
    error InvalidTransaction();
    error CallFailed();
    uint256 public constant MAX_OWNERS = 32;
    mapping(address => bool) public isOwner;
    uint256 public ownerCount;
    uint256 public threshold;
    uint256 public epoch;
    uint256 public transactionCount;

    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        uint256 epoch;
        uint256 confirmations;
        bool executed;
    }
    mapping(uint256 => Transaction) private transactions;
    mapping(uint256 => mapping(address => bool)) public confirmed;
    event Submitted(
        uint256 indexed id, address indexed owner, address target, uint256 value, bytes data, uint256 epoch
    );
    event Confirmed(uint256 indexed id, address indexed owner);
    event Revoked(uint256 indexed id, address indexed owner);
    event Executed(uint256 indexed id);
    event OwnerAdded(address indexed owner, uint256 epoch);
    event OwnerRemoved(address indexed owner, uint256 epoch);
    event ThresholdSet(uint256 threshold, uint256 epoch);
    event Funded(address indexed sender, uint256 amount);
    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert Unauthorized();
        _;
    }
    modifier onlySelf() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    constructor(address[] memory owners, uint256 required) {
        if (owners.length == 0 || owners.length > MAX_OWNERS || required == 0 || required > owners.length) {
            revert InvalidInput();
        }
        for (uint256 i; i < owners.length; ++i) {
            address owner = owners[i];
            if (owner == address(0) || owner == address(this) || isOwner[owner]) revert InvalidInput();
            isOwner[owner] = true;
            emit OwnerAdded(owner, 0);
        }
        ownerCount = owners.length;
        threshold = required;
        emit ThresholdSet(required, 0);
    }

    /// @notice Fund the wallet with ETH.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Owner submits one bounded call; submission does not imply confirmation.
    function submit(address target, uint256 value, bytes calldata data)
        external
        nonReentrant
        onlyOwner
        returns (uint256 id)
    {
        if (target == address(0) || data.length > 16384) revert InvalidInput();
        id = transactionCount++;
        transactions[id] = Transaction(target, value, data, epoch, 0, false);
        emit Submitted(id, msg.sender, target, value, data, epoch);
    }

    /// @notice Current owner confirms a live transaction once.
    function confirm(uint256 id) external nonReentrant onlyOwner {
        Transaction storage t = _live(id);
        if (confirmed[id][msg.sender]) revert InvalidTransaction();
        confirmed[id][msg.sender] = true;
        ++t.confirmations;
        emit Confirmed(id, msg.sender);
    }

    /// @notice Current owner revokes their own confirmation before execution.
    function revoke(uint256 id) external nonReentrant onlyOwner {
        Transaction storage t = _live(id);
        if (!confirmed[id][msg.sender]) revert InvalidTransaction();
        confirmed[id][msg.sender] = false;
        --t.confirmations;
        emit Revoked(id, msg.sender);
    }

    /// @notice Anyone executes a live, threshold-approved call once; failed calls roll back.
    function execute(uint256 id) external nonReentrant returns (bytes memory result) {
        Transaction storage t = _live(id);
        if (t.confirmations < threshold) revert InvalidTransaction();
        t.executed = true;
        emit Executed(id);
        bool success;
        (success, result) = t.target.call{value: t.value}(t.data);
        if (!success) revert CallFailed();
    }

    /// @notice Only a multisig-approved self-call can add an owner; invalidates pending transactions.
    function addOwner(address owner) external onlySelf {
        if (owner == address(0) || owner == address(this) || isOwner[owner] || ownerCount >= MAX_OWNERS) {
            revert InvalidInput();
        }
        isOwner[owner] = true;
        ++ownerCount;
        ++epoch;
        emit OwnerAdded(owner, epoch);
    }

    /// @notice Only a self-call can remove an owner and atomically select a valid new threshold.
    function removeOwner(address owner, uint256 required) external onlySelf {
        if (!isOwner[owner] || required == 0 || required >= ownerCount) revert InvalidInput();
        isOwner[owner] = false;
        --ownerCount;
        threshold = required;
        ++epoch;
        emit OwnerRemoved(owner, epoch);
        emit ThresholdSet(required, epoch);
    }

    /// @notice Only a self-call changes the threshold; all pending transactions are invalidated.
    function setThreshold(uint256 required) external onlySelf {
        if (required == 0 || required > ownerCount) revert InvalidInput();
        threshold = required;
        ++epoch;
        emit ThresholdSet(required, epoch);
    }

    /// @notice Read transaction metadata; calldata is available from the Submitted event.
    function transaction(uint256 id) external view returns (address, uint256, uint256, uint256, bool) {
        if (id >= transactionCount) revert InvalidTransaction();
        Transaction storage t = transactions[id];
        return (t.target, t.value, t.epoch, t.confirmations, t.executed);
    }

    function _live(uint256 id) private view returns (Transaction storage t) {
        if (id >= transactionCount) revert InvalidTransaction();
        t = transactions[id];
        if (t.executed || t.epoch != epoch) revert InvalidTransaction();
    }
}
