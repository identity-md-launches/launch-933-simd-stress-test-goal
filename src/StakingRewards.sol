// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Stake one token and earn a separately funded token during fixed reward periods.
contract StakingRewards is Ownable2Step, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error PeriodActive();
    uint256 private constant PRECISION = 1e27;
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    uint256 public totalStaked;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public storedRewardPerToken;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public paidRewardPerToken;
    mapping(address => uint256) public rewards;
    event PeriodFunded(uint256 received, uint256 rate, uint256 finish);
    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);

    constructor(IERC20 stakeToken, IERC20 earnToken, address admin) Ownable(admin) {
        if (
            address(stakeToken).code.length == 0 || address(earnToken).code.length == 0
                || stakeToken == earnToken
        ) revert InvalidInput();
        stakingToken = stakeToken;
        rewardToken = earnToken;
    }

    /// @notice Accumulated rewards per staked base unit, scaled to 1e27.
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return storedRewardPerToken;
        uint256 elapsed = Math.min(block.timestamp, periodFinish) - lastUpdate;
        return storedRewardPerToken + Math.mulDiv(elapsed * rewardRate, PRECISION, totalStaked);
    }

    /// @notice Claimable reward base units for an account, including the current period.
    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + Math.mulDiv(balanceOf[account], rewardPerToken() - paidRewardPerToken[account], PRECISION);
    }

    /// @notice Owner funds and starts a new period after the previous one ends; rate is receipt/duration.
    function fundPeriod(uint256 amount, uint256 duration) external nonReentrant onlyOwner {
        if (block.timestamp < periodFinish) revert PeriodActive();
        if (duration < 1 hours || duration > 365 days || amount > 1e36) revert InvalidInput();
        _update(address(0));
        uint256 received = rewardToken.pull(amount);
        rewardRate = received / duration;
        if (rewardRate == 0) revert InvalidInput();
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit PeriodFunded(received, rewardRate, periodFinish);
    }

    /// @notice Stake caller funds, crediting the amount actually received.
    function stake(uint256 amount) external nonReentrant {
        _update(msg.sender);
        uint256 received = stakingToken.pull(amount);
        balanceOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Withdraw caller's principal without forfeiting earned rewards.
    function withdraw(uint256 amount, uint256 minimum) external nonReentrant {
        _update(msg.sender);
        if (amount == 0 || amount > balanceOf[msg.sender]) revert InvalidInput();
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        emit Withdrawn(msg.sender, amount);
        stakingToken.send(msg.sender, amount, minimum);
    }

    /// @notice Pull accrued rewards; minimum applies after any output transfer tax.
    function claim(uint256 minimum) external nonReentrant {
        _update(msg.sender);
        uint256 amount = rewards[msg.sender];
        if (amount == 0) revert InvalidInput();
        rewards[msg.sender] = 0;
        emit RewardPaid(msg.sender, amount);
        rewardToken.send(msg.sender, amount, minimum);
    }

    function _update(address account) private {
        storedRewardPerToken = rewardPerToken();
        lastUpdate = Math.min(block.timestamp, periodFinish);
        if (account != address(0)) {
            rewards[account] = earned(account);
            paidRewardPerToken[account] = storedRewardPerToken;
        }
    }
}
