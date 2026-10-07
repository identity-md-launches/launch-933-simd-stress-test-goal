// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken, MockPrice} from "./helpers/Mocks.sol";
import {LendingPool, ILendingPrice} from "../src/LendingPool.sol";

contract LendingHandler is ActorHandler {
    MockToken public loan;
    MockToken public security;
    MockPrice public oracle;
    LendingPool public pool;
    uint256 public supplied;
    uint256 public withdrawn;
    uint256 public borrowed;
    uint256 public repaid;
    uint256 public interest;
    uint256 public collateralIn;
    uint256 public collateralOut;

    constructor() {
        loan = new MockToken(6);
        security = new MockToken(8);
        oracle = new MockPrice();
        pool = new LendingPool(loan, security, ILendingPrice(address(oracle)));
        for (uint256 i; i < 3; ++i) {
            address who = actor(i);
            loan.mint(who, 1000000e6);
            security.mint(who, 1000000e8);
            vm.startPrank(who);
            loan.approve(address(pool), type(uint256).max);
            security.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        supply(0, 10000e6 - 1);
        addCollateral(0, 1000e8 - 1);
        borrow(0, 100e6 - 1);
    }

    function checkpoint() internal {
        uint256 beforeDebt = pool.debtAssets();
        pool.accrue();
        interest += pool.debtAssets() - beforeDebt;
    }

    function supply(uint256 who, uint256 raw) public {
        checkpoint();
        uint256 amount = bound(raw, 1, 10000e6);
        if (callAs(actor(who), address(pool), abi.encodeCall(pool.supply, (amount, 1)))) supplied += amount;
    }

    function withdraw(uint256 who, uint256 raw) public {
        checkpoint();
        address user = actor(who);
        uint256 shares = pool.supplyShares(user);
        if (shares == 0) return;
        uint256 beforeCash = loan.balanceOf(address(pool));
        if (callAs(user, address(pool), abi.encodeCall(pool.withdraw, (bound(raw, 1, shares), 0)))) {
            withdrawn += beforeCash - loan.balanceOf(address(pool));
        }
    }

    function addCollateral(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e8);
        if (callAs(actor(who), address(pool), abi.encodeCall(pool.addCollateral, (amount)))) {
            collateralIn += amount;
        }
    }

    function removeCollateral(uint256 who, uint256 raw) public {
        checkpoint();
        address user = actor(who);
        uint256 balance = pool.collateral(user);
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        if (callAs(user, address(pool), abi.encodeCall(pool.removeCollateral, (amount, amount)))) {
            collateralOut += amount;
        }
    }

    function borrow(uint256 who, uint256 raw) public {
        checkpoint();
        uint256 amount = bound(raw, 1, 1500e6);
        if (callAs(actor(who), address(pool), abi.encodeCall(pool.borrow, (amount, amount)))) {
            borrowed += amount;
        }
    }

    function repay(uint256 who, uint256 payer, uint256 raw) public {
        checkpoint();
        address user = actor(who);
        uint256 debt = pool.debtOf(user);
        if (debt == 0) return;
        uint256 amount = bound(raw, 1, debt);
        if (callAs(actor(payer), address(pool), abi.encodeCall(pool.repay, (user, amount)))) {
            repaid += amount;
        }
    }

    function liquidate(uint256 who, uint256 payer, uint256 raw) public {
        checkpoint();
        address user = actor(who);
        uint256 debt = pool.debtOf(user);
        if (debt == 0) return;
        uint256 amount = bound(raw, 1, debt);
        uint256 beforeCollateral = security.balanceOf(address(pool));
        if (callAs(actor(payer), address(pool), abi.encodeCall(pool.liquidate, (user, amount, 0)))) {
            repaid += amount;
            collateralOut += beforeCollateral - security.balanceOf(address(pool));
        }
    }

    function changePrice(uint256 raw) public {
        oracle.setPrice(bound(raw, 5e17, 4e18));
    }
}

contract LendingPoolInvariantTest is InvariantBase {
    LendingHandler private handler;

    function setUp() public {
        handler = new LendingHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_CashCollateralAndShareConservation() public view {
        LendingPool pool = handler.pool();
        eq(
            handler.loan().balanceOf(address(pool)) + handler.withdrawn() + handler.borrowed(),
            handler.supplied() + handler.repaid()
        );
        eq(handler.security().balanceOf(address(pool)) + handler.collateralOut(), handler.collateralIn());
        eq(
            pool.collateral(ALICE) + pool.collateral(BOB) + pool.collateral(CAROL),
            handler.security().balanceOf(address(pool))
        );
        eq(
            pool.supplyShares(ALICE) + pool.supplyShares(BOB) + pool.supplyShares(CAROL),
            pool.totalSupplyShares()
        );
        eq(pool.debtShares(ALICE) + pool.debtShares(BOB) + pool.debtShares(CAROL), pool.totalDebtShares());
        eq(pool.debtAssets() + handler.repaid(), handler.borrowed() + handler.interest());
        uint256 roundedDebt = pool.debtOf(ALICE) + pool.debtOf(BOB) + pool.debtOf(CAROL);
        ok(roundedDebt >= pool.currentDebt() && roundedDebt <= pool.currentDebt() + 2);
        ok(pool.borrowRate() >= 2e16 && pool.borrowRate() <= 22e16);
        if (pool.totalDebtShares() == 0) eq(pool.debtAssets(), 0);
        ok(handler.successfulCalls() >= 3);
    }
}
