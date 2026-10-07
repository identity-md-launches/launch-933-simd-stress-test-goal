// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGovernanceTimelock {
    /// @notice Queue one call for execution after the timelock delay.
    function queue(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        returns (bytes32);
    /// @notice Execute an already authorized operation.
    function execute(bytes32 operation) external returns (bytes memory);
    /// @notice Accept a previously nominated admin handover.
    function acceptAdmin() external;
}

interface ITimestampVotes is IVotes {
    /// @notice Clock must use timestamps as described by CLOCK_MODE.
    function CLOCK_MODE() external view returns (string memory);
}

/// @notice Single-call timestamp governance with 4% quorum, one-day delay and three-day vote.
contract Governor is ReentrancyGuard {
    error InvalidInput();
    error WrongState();
    error AlreadyVoted();
    ITimestampVotes public immutable token;
    IGovernanceTimelock public immutable timelock;
    uint256 public proposalCount;
    enum State {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Cancelled
    }

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint256 snapshot;
        uint256 deadline;
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        bytes32 operation;
        bool queued;
        bool executed;
        bool cancelled;
    }
    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    event Proposed(
        uint256 indexed id,
        address indexed proposer,
        address target,
        uint256 value,
        bytes data,
        bytes32 descriptionHash,
        uint256 snapshot,
        uint256 deadline
    );
    event Voted(uint256 indexed id, address indexed voter, uint8 support, uint256 weight);
    event Queued(uint256 indexed id, bytes32 indexed operation);
    event Executed(uint256 indexed id, bytes32 resultHash);
    event Cancelled(uint256 indexed id);
    event TimelockAdminAccepted();

    constructor(ITimestampVotes votes, IGovernanceTimelock executor) {
        if (
            address(votes).code.length == 0 || address(executor).code.length == 0
                || keccak256(bytes(votes.CLOCK_MODE())) != keccak256("mode=timestamp")
        ) revert InvalidInput();
        token = votes;
        timelock = executor;
    }

    /// @notice Submit one call; proposer needs nonzero delegated votes at the previous second.
    function propose(address target, uint256 value, bytes calldata data, bytes32 descriptionHash)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (
            target == address(0) || data.length > 16384
                || token.getPastVotes(msg.sender, block.timestamp - 1) == 0
        ) {
            revert InvalidInput();
        }
        id = ++proposalCount;
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.target = target;
        p.value = value;
        p.data = data;
        p.snapshot = block.timestamp + 1 days;
        p.deadline = p.snapshot + 3 days;
        emit Proposed(id, msg.sender, target, value, data, descriptionHash, p.snapshot, p.deadline);
    }

    /// @notice Derive the proposal lifecycle state; ties and zero turnout are defeated.
    function state(uint256 id) public view returns (State) {
        Proposal storage p = proposals[id];
        if (p.proposer == address(0)) revert InvalidInput();
        if (p.cancelled) return State.Cancelled;
        if (p.executed) return State.Executed;
        if (p.queued) return State.Queued;
        if (block.timestamp <= p.snapshot) return State.Pending;
        if (block.timestamp <= p.deadline) return State.Active;
        uint256 needed = quorum(id);
        return p.forVotes > p.againstVotes && p.forVotes + p.abstainVotes >= needed
            ? State.Succeeded
            : State.Defeated;
    }

    /// @notice Quorum is ceil(4% of the historical total supply), with a minimum of one unit.
    function quorum(uint256 id) public view returns (uint256) {
        Proposal storage p = proposals[id];
        if (p.proposer == address(0)) revert InvalidInput();
        return Math.max(1, Math.mulDiv(token.getPastTotalSupply(p.snapshot), 4, 100, Math.Rounding.Ceil));
    }

    /// @notice Return snapshot, deadline and the three vote tallies.
    function details(uint256 id) external view returns (uint256, uint256, uint256, uint256, uint256) {
        Proposal storage p = proposals[id];
        if (p.proposer == address(0)) revert InvalidInput();
        return (p.snapshot, p.deadline, p.againstVotes, p.forVotes, p.abstainVotes);
    }

    /// @notice Vote once with historical weight: 0 against, 1 for, 2 abstain.
    function castVote(uint256 id, uint8 support) external nonReentrant {
        if (state(id) != State.Active) revert WrongState();
        if (support > 2) revert InvalidInput();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        Proposal storage p = proposals[id];
        uint256 weight = token.getPastVotes(msg.sender, p.snapshot);
        if (weight == 0) revert InvalidInput();
        hasVoted[id][msg.sender] = true;
        if (support == 0) p.againstVotes += weight;
        else if (support == 1) p.forVotes += weight;
        else p.abstainVotes += weight;
        emit Voted(id, msg.sender, support, weight);
    }

    /// @notice Anyone can queue a successful proposal; its exact call is immutable.
    function queue(uint256 id) external nonReentrant {
        if (state(id) != State.Succeeded) revert WrongState();
        Proposal storage p = proposals[id];
        p.queued = true;
        p.operation = timelock.queue(p.target, p.value, p.data, bytes32(id));
        emit Queued(id, p.operation);
    }

    /// @notice Anyone can execute a queued proposal after the timelock permits it.
    function execute(uint256 id) external nonReentrant {
        if (state(id) != State.Queued) revert WrongState();
        Proposal storage p = proposals[id];
        p.executed = true;
        bytes memory result = timelock.execute(p.operation);
        emit Executed(id, keccak256(result));
    }

    /// @notice Proposer may cancel only during the initial voting delay.
    function cancel(uint256 id) external nonReentrant {
        if (state(id) != State.Pending || proposals[id].proposer != msg.sender) revert WrongState();
        proposals[id].cancelled = true;
        emit Cancelled(id);
    }

    /// @notice Complete deployment handover when the timelock has nominated this Governor.
    function acceptTimelockAdmin() external nonReentrant {
        timelock.acceptAdmin();
        emit TimelockAdminAccepted();
    }
}
