// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Fixed-price 30-day subscriptions, renewed by keepers from explicitly prepaid caller funds.
contract Subscription is ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error NotReady();
    error Unauthorized();
    IERC20 public immutable token;
    address public immutable merchant;
    uint256 public immutable monthlyPrice;
    uint256 public constant MONTH = 30 days;
    uint256 public revenue;
    uint256 public totalPrepaid;
    mapping(address => uint256) public prepaid;
    mapping(address => uint256) public paidUntil;
    mapping(address => bool) public autoRenew;
    event Deposited(address indexed subscriber, uint256 received);
    event Withdrawn(address indexed subscriber, uint256 amount);
    event RenewalEnabled(address indexed subscriber);
    event Renewed(address indexed subscriber, uint256 price, uint256 paidUntil);
    event Cancelled(address indexed subscriber);
    event RevenueWithdrawn(uint256 amount);

    constructor(IERC20 asset, address payee, uint256 price) {
        if (address(asset).code.length == 0 || payee == address(0) || payee == address(this) || price == 0) {
            revert InvalidInput();
        }
        token = asset;
        merchant = payee;
        monthlyPrice = price;
    }

    /// @notice Deposit caller tokens to their prepaid balance; receiver transfer taxes reduce the credited amount.
    function deposit(uint256 amount) external nonReentrant {
        uint256 received = token.pull(amount);
        prepaid[msg.sender] += received;
        totalPrepaid += received;
        emit Deposited(msg.sender, received);
    }

    /// @notice Enable renewals and buy a month if current access has expired; never charges twice for the same period.
    function subscribe() external nonReentrant {
        if (autoRenew[msg.sender]) revert NotReady();
        autoRenew[msg.sender] = true;
        emit RenewalEnabled(msg.sender);
        if (block.timestamp >= paidUntil[msg.sender]) _renew(msg.sender);
    }

    /// @notice Any keeper renews an opted-in, expired subscriber; a late call buys only one new month from now.
    function renew(address subscriber) external nonReentrant {
        if (!autoRenew[subscriber] || block.timestamp < paidUntil[subscriber]) revert NotReady();
        _renew(subscriber);
    }

    /// @notice Disable future billing at any time; existing paid access remains valid until expiry.
    function cancel() external nonReentrant {
        if (!autoRenew[msg.sender]) revert NotReady();
        autoRenew[msg.sender] = false;
        emit Cancelled(msg.sender);
    }

    /// @notice Withdraw caller's unused prepaid balance without affecting access already purchased.
    function withdraw(uint256 amount, uint256 minimum) external nonReentrant {
        if (amount == 0 || amount > prepaid[msg.sender]) revert InvalidInput();
        prepaid[msg.sender] -= amount;
        totalPrepaid -= amount;
        emit Withdrawn(msg.sender, amount);
        token.send(msg.sender, amount, minimum);
    }

    /// @notice Merchant withdraws only earned revenue; subscriber deposits are never merchant-withdrawable.
    function withdrawRevenue(uint256 minimum) external nonReentrant {
        if (msg.sender != merchant) revert Unauthorized();
        uint256 amount = revenue;
        if (amount == 0) revert InvalidInput();
        revenue = 0;
        emit RevenueWithdrawn(amount);
        token.send(msg.sender, amount, minimum);
    }

    /// @notice Whether the account has an unexpired paid subscription, regardless of renewal preference.
    function isActive(address subscriber) external view returns (bool) {
        return block.timestamp < paidUntil[subscriber];
    }

    function _renew(address subscriber) private {
        if (prepaid[subscriber] < monthlyPrice) revert InvalidInput();
        prepaid[subscriber] -= monthlyPrice;
        totalPrepaid -= monthlyPrice;
        revenue += monthlyPrice;
        paidUntil[subscriber] = block.timestamp + MONTH;
        emit Renewed(subscriber, monthlyPrice, paidUntil[subscriber]);
    }
}
