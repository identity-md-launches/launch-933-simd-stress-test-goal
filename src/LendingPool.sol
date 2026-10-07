// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

interface ILendingPrice {
    /// @notice Loan tokens per whole collateral token, scaled to 1e18; must reject stale prices.
    function price() external view returns (uint256);
}

/// @notice Immutable isolated lending market: 75% LTV, 80% liquidation threshold, 5% bonus.
contract LendingPool is ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error UnsafePosition();
    error InsufficientLiquidity();
    error Slippage();
    IERC20 public immutable loanToken;
    IERC20 public immutable collateralToken;
    ILendingPrice public immutable oracle;
    uint256 public immutable loanUnit;
    uint256 public immutable collateralUnit;
    uint256 public totalSupplyShares;
    uint256 public totalDebtShares;
    uint256 public debtAssets;
    uint256 public interestRemainder;
    uint256 public lastAccrual;
    mapping(address => uint256) public supplyShares;
    mapping(address => uint256) public debtShares;
    mapping(address => uint256) public collateral;
    event Supplied(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);
    event CollateralChanged(address indexed user, uint256 balance);
    event Borrowed(address indexed user, uint256 assets, uint256 shares);
    event Repaid(address indexed payer, address indexed borrower, uint256 assets, uint256 shares);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 repaid, uint256 seized);
    event InterestAccrued(uint256 interest, uint256 timestamp);

    constructor(IERC20Metadata loan, IERC20Metadata security, ILendingPrice feed) {
        if (
            address(loan) == address(security) || address(loan).code.length == 0
                || address(security).code.length == 0 || address(feed).code.length == 0
        ) revert InvalidInput();
        uint8 ld = loan.decimals();
        uint8 cd = security.decimals();
        if (ld > 18 || cd > 18) revert InvalidInput();
        loanToken = loan;
        collateralToken = security;
        oracle = feed;
        loanUnit = 10 ** ld;
        collateralUnit = 10 ** cd;
        lastAccrual = block.timestamp;
    }

    /// @notice Annualised rate (1e18 scale): 2% base plus 20% times utilisation.
    function borrowRate() public view returns (uint256) {
        uint256 assets = loanToken.balanceOf(address(this)) + debtAssets;
        return 2e16 + (assets > 0 ? Math.mulDiv(debtAssets, 2e17, assets) : 0);
    }

    /// @notice Total debt including interest since the last checkpoint.
    function currentDebt() public view returns (uint256) {
        (uint256 interest,) = _pendingInterest();
        return debtAssets + interest;
    }

    /// @notice Rounded-up debt of an account, in loan token base units.
    function debtOf(address user) public view returns (uint256) {
        return totalDebtShares > 0
            ? Math.mulDiv(debtShares[user], currentDebt(), totalDebtShares, Math.Rounding.Ceil)
            : 0;
    }

    /// @notice Checkpoint interest; no token transfers or privileged caller.
    function accrue() external nonReentrant {
        _accrue();
    }

    /// @notice Supply caller's tokens; minted shares reflect net received assets.
    function supply(uint256 amount, uint256 minShares) external nonReentrant returns (uint256 shares) {
        _accrue();
        uint256 assets = loanToken.balanceOf(address(this)) + debtAssets;
        uint256 received = loanToken.pull(amount);
        shares = Math.mulDiv(received, totalSupplyShares + 1e6, assets + 1);
        if (shares == 0 || shares < minShares) revert Slippage();
        totalSupplyShares += shares;
        supplyShares[msg.sender] += shares;
        emit Supplied(msg.sender, received, shares);
    }

    /// @notice Burn caller's shares and withdraw available cash; minAssets is net of token tax.
    function withdraw(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        _accrue();
        if (shares == 0 || shares > supplyShares[msg.sender]) revert InvalidInput();
        uint256 cash = loanToken.balanceOf(address(this));
        assets = Math.mulDiv(shares, cash + debtAssets + 1, totalSupplyShares + 1e6);
        if (assets > cash) revert InsufficientLiquidity();
        supplyShares[msg.sender] -= shares;
        totalSupplyShares -= shares;
        emit Withdrawn(msg.sender, assets, shares);
        loanToken.send(msg.sender, assets, minAssets);
    }

    /// @notice Add net received collateral to the caller's position.
    function addCollateral(uint256 amount) external nonReentrant {
        collateral[msg.sender] += collateralToken.pull(amount);
        emit CollateralChanged(msg.sender, collateral[msg.sender]);
    }

    /// @notice Remove collateral only while maintaining the 75% borrowing LTV.
    function removeCollateral(uint256 amount, uint256 minimum) external nonReentrant {
        _accrue();
        if (amount == 0 || amount > collateral[msg.sender]) revert InvalidInput();
        collateral[msg.sender] -= amount;
        uint256 debt = debtOf(msg.sender);
        if (debt > 0 && debt > Math.mulDiv(_value(collateral[msg.sender]), 7500, 10000)) {
            revert UnsafePosition();
        }
        emit CollateralChanged(msg.sender, collateral[msg.sender]);
        collateralToken.send(msg.sender, amount, minimum);
    }

    /// @notice Borrow to the caller; debt shares round upward, net output must meet minimum.
    function borrow(uint256 amount, uint256 minimum) external nonReentrant {
        _accrue();
        if (amount == 0) revert InvalidInput();
        if (amount > loanToken.balanceOf(address(this))) revert InsufficientLiquidity();
        uint256 shares = totalDebtShares > 0
            ? Math.mulDiv(amount, totalDebtShares, debtAssets, Math.Rounding.Ceil)
            : amount;
        totalDebtShares += shares;
        debtShares[msg.sender] += shares;
        debtAssets += amount;
        if (debtOf(msg.sender) > Math.mulDiv(_value(collateral[msg.sender]), 7500, 10000)) {
            revert UnsafePosition();
        }
        emit Borrowed(msg.sender, amount, shares);
        loanToken.send(msg.sender, amount, minimum);
    }

    /// @notice Pay a borrower's debt using only caller funds; requested amount cannot exceed debt.
    function repay(address borrower, uint256 amount) external nonReentrant returns (uint256 received) {
        _accrue();
        if (amount == 0 || amount > debtOf(borrower)) revert InvalidInput();
        received = loanToken.pull(amount);
        _repay(borrower, received);
    }

    /// @notice Repay an unsafe position and seize collateral at a 5% bonus, rounded down.
    function liquidate(address borrower, uint256 amount, uint256 minCollateral) external nonReentrant {
        _accrue();
        uint256 debt = debtOf(borrower);
        if (debt <= Math.mulDiv(_value(collateral[borrower]), 8000, 10000)) revert UnsafePosition();
        if (amount == 0 || amount > debt) revert InvalidInput();
        uint256 received = loanToken.pull(amount);
        uint256 p = oracle.price();
        if (p == 0) revert InvalidInput();
        uint256 seized = Math.mulDiv(Math.mulDiv(received, 1e18, loanUnit), collateralUnit, p);
        seized = Math.mulDiv(seized, 10500, 10000);
        if (seized == 0 || seized > collateral[borrower]) revert InvalidInput();
        _repay(borrower, received);
        collateral[borrower] -= seized;
        emit CollateralChanged(borrower, collateral[borrower]);
        emit Liquidated(msg.sender, borrower, received, seized);
        collateralToken.send(msg.sender, seized, minCollateral);
    }

    function _value(uint256 amount) private view returns (uint256) {
        uint256 p = oracle.price();
        if (p == 0) revert InvalidInput();
        return Math.mulDiv(Math.mulDiv(amount, p, collateralUnit), loanUnit, 1e18);
    }

    function _accrue() private {
        (uint256 interest, uint256 remainder) = _pendingInterest();
        debtAssets += interest;
        interestRemainder = remainder;
        lastAccrual = block.timestamp;
        emit InterestAccrued(interest, block.timestamp);
    }

    function _pendingInterest() private view returns (uint256 interest, uint256 remainder) {
        uint256 denominator = 365 days * 1e18;
        uint256 factor = borrowRate() * (block.timestamp - lastAccrual);
        uint256 fractional = mulmod(debtAssets, factor, denominator) + interestRemainder;
        // Both terms are less than denominator, so their sum carries at most one base unit.
        uint256 carry = fractional >= denominator ? 1 : 0;
        interest = Math.mulDiv(debtAssets, factor, denominator) + carry;
        remainder = fractional - carry * denominator;
    }

    function _repay(address borrower, uint256 received) private {
        uint256 owed = Math.mulDiv(debtShares[borrower], debtAssets, totalDebtShares, Math.Rounding.Ceil);
        uint256 shares =
            received >= owed ? debtShares[borrower] : Math.mulDiv(received, totalDebtShares, debtAssets);
        if (shares == 0) revert InvalidInput();
        debtShares[borrower] -= shares;
        totalDebtShares -= shares;
        debtAssets = totalDebtShares > 0 ? debtAssets - received : 0;
        if (totalDebtShares == 0) interestRemainder = 0;
        emit Repaid(msg.sender, borrower, received, shares);
    }
}
