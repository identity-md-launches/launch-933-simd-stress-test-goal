// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Pull-only ETH accounting shared by otherwise independent applications.
abstract contract EthCredits is ReentrancyGuard {
    error NothingToWithdraw();
    error PaymentFailed();
    mapping(address => uint256) public credits;
    uint256 public totalCredits;
    event Credited(address indexed account, uint256 amount);
    event PaymentWithdrawn(address indexed account, uint256 amount);

    /// @notice Withdraw only the caller's credit; a failed receiver leaves the credit intact.
    function withdrawPayments() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        emit PaymentWithdrawn(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert PaymentFailed();
    }

    function _credit(address account, uint256 amount) internal {
        if (amount > 0) {
            credits[account] += amount;
            totalCredits += amount;
            emit Credited(account, amount);
        }
    }
}
