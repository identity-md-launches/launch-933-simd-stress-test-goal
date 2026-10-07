// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Mutual insurance: premiums buy pool shares and 5x coverage; approved claims socialise losses.
contract InsurancePool is Ownable2Step, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error NotReady();
    IERC20 public immutable token;
    uint256 public totalShares;
    uint256 public reservedClaims;
    uint256 public constant EXIT_COOLDOWN = 7 days;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public coverage;
    mapping(address => uint256) public exitAt;
    mapping(address => uint256) public claims;
    event PremiumPaid(address indexed member, uint256 received, uint256 shares, uint256 coverage);
    event ClaimApproved(address indexed member, uint256 amount, bytes32 indexed evidence);
    event ClaimPaid(address indexed member, uint256 amount);
    event ExitRequested(address indexed member, uint256 readyAt);
    event Exited(address indexed member, uint256 shares, uint256 assets);

    constructor(IERC20 asset, address admin) Ownable(admin) {
        if (address(asset).code.length == 0) revert InvalidInput();
        token = asset;
    }

    /// @notice Unreserved assets backing all member shares, including socialised claim losses.
    function totalAssets() public view returns (uint256) {
        return token.balanceOf(address(this)) - reservedClaims;
    }

    /// @notice Pay caller funds for pool shares and cumulative 5x coverage; unavailable while exiting.
    function payPremium(uint256 amount, uint256 minShares) external nonReentrant {
        if (exitAt[msg.sender] > 0) revert NotReady();
        uint256 assets = totalAssets();
        uint256 received = token.pull(amount);
        uint256 minted = Math.mulDiv(received, totalShares + 1e6, assets + 1);
        if (minted == 0 || minted < minShares) revert InvalidInput();
        shares[msg.sender] += minted;
        totalShares += minted;
        coverage[msg.sender] += received * 5;
        emit PremiumPaid(msg.sender, received, minted, coverage[msg.sender]);
    }

    /// @notice Owner verifies off-chain loss evidence and reserves a claim within coverage and available assets.
    function approveClaim(address member, uint256 amount, bytes32 evidence) external nonReentrant onlyOwner {
        if (exitAt[member] > 0 || amount == 0 || amount > coverage[member] || amount > totalAssets()) {
            revert InvalidInput();
        }
        coverage[member] -= amount;
        claims[member] += amount;
        reservedClaims += amount;
        emit ClaimApproved(member, amount, evidence);
    }

    /// @notice Member pulls already reserved claims; net received tokens must meet their minimum.
    function claim(uint256 minimum) external nonReentrant {
        uint256 amount = claims[msg.sender];
        if (amount == 0) revert InvalidInput();
        claims[msg.sender] = 0;
        reservedClaims -= amount;
        emit ClaimPaid(msg.sender, amount);
        token.send(msg.sender, amount, minimum);
    }

    /// @notice Start a seven-day exit and permanently surrender remaining coverage; approved claims remain payable.
    function requestExit() external nonReentrant {
        if (shares[msg.sender] == 0 || exitAt[msg.sender] > 0) revert InvalidInput();
        exitAt[msg.sender] = block.timestamp + EXIT_COOLDOWN;
        coverage[msg.sender] = 0;
        emit ExitRequested(msg.sender, exitAt[msg.sender]);
    }

    /// @notice Redeem all caller shares after cooldown at the current pool value, which may include losses.
    function exit(uint256 minimum) external nonReentrant {
        uint256 ready = exitAt[msg.sender];
        if (ready == 0 || block.timestamp < ready) revert NotReady();
        uint256 burned = shares[msg.sender];
        uint256 amount = Math.mulDiv(burned, totalAssets() + 1, totalShares + 1e6);
        shares[msg.sender] = 0;
        totalShares -= burned;
        exitAt[msg.sender] = 0;
        emit Exited(msg.sender, burned, amount);
        if (amount > 0) token.send(msg.sender, amount, minimum);
        else if (minimum > 0) revert InvalidInput();
    }
}
