// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Independent two-token constant product AMM with 0.3% input fee and fungible LP shares.
contract ConstantProductAMM is ERC20, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error Slippage();
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    address public constant BURN_ACCOUNT = address(1);
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event Swapped(address indexed trader, address indexed tokenIn, uint256 received, uint256 output);
    event ReservesUpdated(uint256 reserve0, uint256 reserve1);

    constructor(IERC20 first, IERC20 second) ERC20("SIMD Pair LP", "SPLP") {
        if (address(first).code.length == 0 || address(second).code.length == 0 || first == second) {
            revert InvalidInput();
        }
        token0 = first;
        token1 = second;
    }

    /// @notice Deposit up to the supplied maxima; taxed inputs mint shares from actual receipts.
    function addLiquidity(uint256 max0, uint256 max1, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (block.timestamp > deadline || max0 == 0 || max1 == 0) revert InvalidInput();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 supply = totalSupply();
        if (supply > 0) {
            uint256 needed1 = Math.mulDiv(max0, r1, r0);
            if (needed1 <= max1) max1 = needed1;
            else max0 = Math.mulDiv(max1, r0, r1);
        }
        uint256 amount0 = token0.pull(max0);
        uint256 amount1 = token1.pull(max1);
        if (amount0 > type(uint112).max - r0 || amount1 > type(uint112).max - r1) revert InvalidInput();
        if (supply == 0) {
            uint256 root = Math.sqrt(amount0 * amount1);
            if (root <= MINIMUM_LIQUIDITY) revert InvalidInput();
            shares = root - MINIMUM_LIQUIDITY;
            _mint(BURN_ACCOUNT, MINIMUM_LIQUIDITY);
        } else {
            shares = Math.min(Math.mulDiv(amount0, supply, r0), Math.mulDiv(amount1, supply, r1));
        }
        if (shares == 0 || shares < minShares) revert Slippage();
        _setReserves(r0 + amount0, r1 + amount1);
        _mint(msg.sender, shares);
        emit LiquidityAdded(msg.sender, amount0, amount1, shares);
    }

    /// @notice Burn caller LP shares for proportional reserves, enforcing net output minima.
    function removeLiquidity(uint256 shares, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline || shares == 0) revert InvalidInput();
        uint256 supply = totalSupply();
        amount0 = Math.mulDiv(shares, reserve0, supply);
        amount1 = Math.mulDiv(shares, reserve1, supply);
        if (amount0 == 0 || amount1 == 0) revert InvalidInput();
        _burn(msg.sender, shares);
        _setReserves(reserve0 - amount0, reserve1 - amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
        token0.send(msg.sender, amount0, min0);
        token1.send(msg.sender, amount1, min1);
    }

    /// @notice Swap caller funds to the other token; minimum is net output and deadline bounds stale orders.
    function swap(IERC20 input, uint256 amount, uint256 minimum, uint256 deadline)
        external
        nonReentrant
        returns (uint256 output)
    {
        if (block.timestamp > deadline || (input != token0 && input != token1) || totalSupply() == 0) revert InvalidInput();
        bool zeroForOne = input == token0;
        uint256 rIn = zeroForOne ? reserve0 : reserve1;
        uint256 rOut = zeroForOne ? reserve1 : reserve0;
        uint256 received = input.pull(amount);
        if (received > type(uint112).max - rIn) revert InvalidInput();
        uint256 afterFee = received * 997;
        output = Math.mulDiv(afterFee, rOut, rIn * 1000 + afterFee);
        if (output == 0) revert Slippage();
        if (zeroForOne) _setReserves(rIn + received, rOut - output);
        else _setReserves(rOut - output, rIn + received);
        emit Swapped(msg.sender, address(input), received, output);
        (zeroForOne ? token1 : token0).send(msg.sender, output, minimum);
    }

    function _setReserves(uint256 r0, uint256 r1) private {
        reserve0 = r0;
        reserve1 = r1;
        emit ReservesUpdated(r0, r1);
    }
}
