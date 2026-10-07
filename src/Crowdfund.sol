// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {EthCredits} from "./common/EthCredits.sol";

/// @notice One all-or-nothing ETH campaign with immutable goal, creator and deadline.
contract Crowdfund is EthCredits {
    error InvalidInput();
    error WrongState();
    error Unauthorized();
    address public immutable creator;
    uint256 public immutable goal;
    uint256 public immutable deadline;
    uint256 public totalPledged;
    bool public claimed;
    mapping(address => uint256) public pledged;
    event Pledged(address indexed backer, uint256 amount);
    event CreatorClaimed(uint256 amount);
    event Refunded(address indexed backer, uint256 amount);

    constructor(address beneficiary, uint256 target, uint256 duration) {
        if (beneficiary == address(0) || target == 0 || duration < 1 days || duration > 365 days) {
            revert InvalidInput();
        }
        creator = beneficiary;
        goal = target;
        deadline = block.timestamp + duration;
    }

    /// @notice Pledge ETH before the deadline; multiple contributions aggregate per caller.
    function pledge() external payable nonReentrant {
        if (block.timestamp >= deadline) revert WrongState();
        if (msg.value == 0) revert InvalidInput();
        pledged[msg.sender] += msg.value;
        totalPledged += msg.value;
        emit Pledged(msg.sender, msg.value);
    }

    /// @notice Creator converts a successful campaign into a pull payment once the deadline passes.
    function claim() external nonReentrant {
        if (msg.sender != creator) revert Unauthorized();
        if (block.timestamp < deadline || totalPledged < goal || claimed) revert WrongState();
        claimed = true;
        _credit(creator, totalPledged);
        emit CreatorClaimed(totalPledged);
    }

    /// @notice A backer obtains a pull refund after a campaign misses its goal.
    function refund() external nonReentrant {
        if (block.timestamp < deadline || totalPledged >= goal) revert WrongState();
        uint256 amount = pledged[msg.sender];
        if (amount == 0) revert InvalidInput();
        pledged[msg.sender] = 0;
        _credit(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }
}
