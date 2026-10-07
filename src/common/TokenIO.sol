// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Internal token accounting; callers must hold a reentrancy guard.
/// @dev Only conventional receiver-tax tokens are supported, never rebases or sender surcharges.
library TokenIO {
    using SafeERC20 for IERC20;
    error InvalidReceipt();
    error Slippage();

    /// @dev There is deliberately no arbitrary source address argument.
    function pull(IERC20 token, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBalance;
        if (received == 0 || received > amount) revert InvalidReceipt();
    }

    /// @dev All entitlement effects precede this call. Net output enforces the user's minimum.
    function send(IERC20 token, address recipient, uint256 amount, uint256 minimum) internal {
        if (recipient == address(this) || recipient == address(0)) revert InvalidReceipt();
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (token.balanceOf(recipient) - beforeBalance < minimum) revert Slippage();
    }
}
