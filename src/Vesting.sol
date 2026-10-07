// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Separately funded linear token grants with cliffs and optional owner revocation.
contract Vesting is Ownable2Step, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error Unauthorized();
    IERC20 public immutable token;
    uint256 public grantCount;

    struct Grant {
        address beneficiary;
        uint256 total;
        uint256 released;
        uint256 start;
        uint256 cliff;
        uint256 end;
        bool revocable;
        bool revoked;
        uint256 vestedAtRevocation;
    }
    mapping(uint256 => Grant) public grants;
    event Created(
        uint256 indexed id,
        address indexed beneficiary,
        uint256 amount,
        uint256 start,
        uint256 cliff,
        uint256 end,
        bool revocable
    );
    event Released(uint256 indexed id, uint256 amount);
    event Revoked(uint256 indexed id, uint256 vested, uint256 returned);

    constructor(IERC20 asset, address admin) Ownable(admin) {
        if (address(asset).code.length == 0) revert InvalidInput();
        token = asset;
    }

    /// @notice Owner funds a new independent grant from their own balance; all amounts use token base units.
    function create(
        address beneficiary,
        uint256 amount,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        bool revocable
    ) external nonReentrant onlyOwner returns (uint256 id) {
        if (
            beneficiary == address(0) || beneficiary == address(this) || start < block.timestamp
                || duration == 0 || duration > 10 * 365 days || cliff < start || cliff > start + duration
        ) revert InvalidInput();
        uint256 received = token.pull(amount);
        id = grantCount++;
        grants[id] = Grant(beneficiary, received, 0, start, cliff, start + duration, revocable, false, 0);
        emit Created(id, beneficiary, received, start, cliff, start + duration, revocable);
    }

    /// @notice Total vested base units, including those already paid; a revoked grant never grows again.
    function vested(uint256 id) public view returns (uint256) {
        Grant storage g = grants[id];
        if (g.beneficiary == address(0)) revert InvalidInput();
        if (g.revoked) return g.vestedAtRevocation;
        if (block.timestamp < g.cliff) return 0;
        return Math.mulDiv(g.total, Math.min(block.timestamp, g.end) - g.start, g.end - g.start);
    }

    /// @notice Only the beneficiary releases their accrued entitlement, with a minimum net token output.
    function release(uint256 id, uint256 minimum) external nonReentrant {
        Grant storage g = grants[id];
        if (g.beneficiary != msg.sender) revert Unauthorized();
        uint256 amount = vested(id) - g.released;
        if (amount == 0) revert InvalidInput();
        g.released += amount;
        emit Released(id, amount);
        token.send(msg.sender, amount, minimum);
    }

    /// @notice Owner freezes a revocable grant, preserving vested claims and returning only unvested tokens.
    function revoke(uint256 id, uint256 minimum) external nonReentrant onlyOwner {
        Grant storage g = grants[id];
        if (!g.revocable || g.revoked) revert InvalidInput();
        uint256 accrued = vested(id);
        uint256 refund = g.total - accrued;
        g.revoked = true;
        g.vestedAtRevocation = accrued;
        emit Revoked(id, accrued, refund);
        if (refund > 0) token.send(msg.sender, refund, minimum);
    }
}
