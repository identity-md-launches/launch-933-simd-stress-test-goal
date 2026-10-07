// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

interface IERC3156FlashBorrower {
    /// @notice Authorise repayment by returning keccak256("ERC3156FlashBorrower.onFlashLoan").
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32);
}

/// @notice ERC3156-interface lender of one held token; borrower contracts initiate their own loans.
contract FlashLender is Ownable2Step, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error RepaymentFailed();
    IERC20 public immutable token;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    event Funded(address indexed funder, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);

    constructor(IERC20 asset, address admin) Ownable(admin) {
        if (address(asset).code.length == 0) revert InvalidInput();
        token = asset;
    }

    /// @notice Maximum supported loan; zero for an unsupported token or during a loan callback.
    function maxFlashLoan(address asset) external view returns (uint256) {
        return asset == address(token) && !_reentrancyGuardEntered() ? token.balanceOf(address(this)) : 0;
    }

    /// @notice Fee is 0.09% rounded up to the nearest token base unit.
    function flashFee(address asset, uint256 amount) public view returns (uint256) {
        if (asset != address(token)) revert InvalidInput();
        return Math.mulDiv(amount, 9, 10000, Math.Rounding.Ceil);
    }

    /// @notice Donate caller funds as owner-controlled lending liquidity.
    function fund(uint256 amount) external nonReentrant {
        uint256 received = token.pull(amount);
        emit Funded(msg.sender, received);
    }

    /// @notice Owner withdraws idle capital and fees to themselves, outside any active loan.
    function withdraw(uint256 amount, uint256 minimum) external nonReentrant onlyOwner {
        if (amount == 0) revert InvalidInput();
        emit Withdrawn(msg.sender, amount);
        token.send(msg.sender, amount, minimum);
    }

    /// @notice Lend to msg.sender only; exact principal delivery and principal-plus-fee repayment are required.
    function flashLoan(IERC3156FlashBorrower receiver, address asset, uint256 amount, bytes calldata data)
        external
        nonReentrant
        returns (bool)
    {
        if (address(receiver) != msg.sender || amount == 0 || data.length > 16384) revert InvalidInput();
        uint256 fee = flashFee(asset, amount);
        if (amount > token.balanceOf(address(this))) revert InvalidInput();
        token.send(msg.sender, amount, amount);
        if (receiver.onFlashLoan(msg.sender, asset, amount, fee, data) != CALLBACK_SUCCESS) {
            revert RepaymentFailed();
        }
        uint256 received = token.pull(amount + fee);
        if (received < amount + fee) revert RepaymentFailed();
        emit FlashLoan(msg.sender, amount, fee);
        return true;
    }
}
