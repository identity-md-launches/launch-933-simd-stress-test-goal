// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenIO} from "./common/TokenIO.sol";
import {EthCredits} from "./common/EthCredits.sol";

interface ITreasuryTimelock {
    /// @notice Current timelock administrator, required to remain the configured Governor.
    function admin() external view returns (address);
}

/// @notice Treasury controlled solely by a fixed Governor through its fixed Timelock.
contract DAOTreasury is EthCredits {
    using TokenIO for IERC20;
    error Unauthorized();
    error InvalidInput();
    address public immutable governor;
    ITreasuryTimelock public immutable timelock;
    event ETHFunded(address indexed sender, uint256 amount);
    event TokenFunded(address indexed token, address indexed sender, uint256 received);
    event ETHAllocated(address indexed recipient, uint256 amount);
    event TokenSpent(address indexed token, address indexed recipient, uint256 amount);
    modifier onlyGovernance() {
        if (msg.sender != address(timelock) || timelock.admin() != governor) revert Unauthorized();
        _;
    }

    constructor(address votingGovernor, ITreasuryTimelock executor) {
        if (
            votingGovernor.code.length == 0 || address(executor).code.length == 0
                || executor.admin() != votingGovernor
        ) {
            revert InvalidInput();
        }
        governor = votingGovernor;
        timelock = executor;
    }

    /// @notice Accept ETH donations; they grant no voting or withdrawal rights.
    receive() external payable {
        emit ETHFunded(msg.sender, msg.value);
    }

    /// @notice Deposit caller tokens and emit the actual receipt, including receiver transfer taxes.
    function fundToken(IERC20 token, uint256 amount) external nonReentrant {
        uint256 received = token.pull(amount);
        emit TokenFunded(address(token), msg.sender, received);
    }

    /// @notice Timelocked governance allocates unreserved ETH as a recipient pull payment.
    function spendETH(address recipient, uint256 amount) external nonReentrant onlyGovernance {
        if (
            recipient == address(0) || recipient == address(this) || amount == 0
                || amount > address(this).balance - totalCredits
        ) revert InvalidInput();
        _credit(recipient, amount);
        emit ETHAllocated(recipient, amount);
    }

    /// @notice Timelocked governance sends a chosen ERC20 amount with a recipient net-output minimum.
    function spendToken(IERC20 token, address recipient, uint256 amount, uint256 minimum)
        external
        nonReentrant
        onlyGovernance
    {
        if (amount == 0) revert InvalidInput();
        emit TokenSpent(address(token), recipient, amount);
        token.send(recipient, amount, minimum);
    }
}
