// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Single-call timelock: immutable two-day minimum and two-step administration.
contract Timelock is ReentrancyGuard {
    error Unauthorized();
    error InvalidInput();
    error NotReady();
    error CallFailed();
    uint256 public constant MIN_DELAY = 2 days;
    address public admin;
    address public pendingAdmin;

    struct Operation {
        address target;
        uint256 value;
        bytes data;
        uint256 readyAt;
        bool done;
        bool cancelled;
    }
    mapping(bytes32 => Operation) private operations;
    event Queued(bytes32 indexed id, address indexed target, uint256 value, bytes data, uint256 readyAt);
    event Executed(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);
    event AdminNominated(address indexed nominee);
    event AdminAccepted(address indexed previousAdmin, address indexed newAdmin);
    event Funded(address indexed sender, uint256 amount);
    modifier onlyAdmin() {
        if (msg.sender != admin && msg.sender != address(this)) revert Unauthorized();
        _;
    }

    constructor(address initialAdmin) {
        if (initialAdmin == address(0) || initialAdmin == address(this)) revert InvalidInput();
        admin = initialAdmin;
        emit AdminAccepted(address(0), initialAdmin);
    }

    /// @notice Accept ETH for previously authorized value-bearing operations.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Hash the exact call and unique salt; completed or cancelled ids can never be reused.
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    /// @notice Admin schedules a bounded call at least two days ahead; a timelocked self-call is also authorized.
    function queue(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        onlyAdmin
        returns (bytes32 id)
    {
        if (target == address(0) || data.length > 16384) revert InvalidInput();
        id = hashOperation(target, value, data, salt);
        if (operations[id].readyAt > 0) revert InvalidInput();
        uint256 ready = block.timestamp + MIN_DELAY;
        operations[id] = Operation(target, value, data, ready, false, false);
        emit Queued(id, target, value, data, ready);
    }

    /// @notice Admin executes only the stored authorized call, once and after its delay.
    function execute(bytes32 id) external nonReentrant onlyAdmin returns (bytes memory result) {
        Operation storage op = operations[id];
        if (op.readyAt == 0 || block.timestamp < op.readyAt || op.done || op.cancelled) revert NotReady();
        op.done = true;
        emit Executed(id);
        bool success;
        (success, result) = op.target.call{value: op.value}(op.data);
        if (!success) revert CallFailed();
    }

    /// @notice Admin cancels an unexecuted operation permanently.
    function cancel(bytes32 id) external onlyAdmin {
        Operation storage op = operations[id];
        if (op.readyAt == 0 || op.done || op.cancelled) revert NotReady();
        op.cancelled = true;
        emit Cancelled(id);
    }

    /// @notice Admin nominates a successor; the old admin keeps authority until acceptance.
    function nominateAdmin(address nominee) external onlyAdmin {
        if (nominee == address(0) || nominee == address(this)) revert InvalidInput();
        pendingAdmin = nominee;
        emit AdminNominated(nominee);
    }

    /// @notice Only the nominated successor can complete the handover.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Unauthorized();
        address old = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminAccepted(old, msg.sender);
    }

    /// @notice Read the readiness timestamp and terminal flags for a stored operation.
    function status(bytes32 id) external view returns (uint256, bool, bool) {
        Operation storage op = operations[id];
        return (op.readyAt, op.done, op.cancelled);
    }
}
