// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken, MockPrice, CallbackToken} from "./helpers/Mocks.sol";
import {LendingPool, ILendingPrice} from "../src/LendingPool.sol";

contract LendingPoolTest is TestBase {
    MockToken loan;
    MockToken collateral;
    MockPrice price;
    LendingPool pool;

    function setUp() public {
        loan = new MockToken(6);
        collateral = new MockToken(8);
        price = new MockPrice();
        pool = new LendingPool(loan, collateral, ILendingPrice(address(price)));
        loan.mint(address(this), 100000e6);
        loan.approve(address(pool), type(uint256).max);
        pool.supply(10000e6, 1);
        collateral.mint(ALICE, 1000e8);
        vm.startPrank(ALICE);
        collateral.approve(address(pool), type(uint256).max);
        loan.approve(address(pool), type(uint256).max);
        pool.addCollateral(1000e8);
        vm.stopPrank();
    }

    function testBorrowRepayAndWithdraw() public {
        vm.startPrank(ALICE);
        pool.borrow(1000e6, 1000e6);
        eq(pool.debtOf(ALICE), 1000e6);
        pool.repay(ALICE, 1000e6);
        pool.removeCollateral(1000e8, 1000e8);
        vm.stopPrank();
        pool.withdraw(pool.supplyShares(address(this)), 10000e6);
        eq(loan.balanceOf(address(pool)), 0);
    }

    function testInterestAndUtilisation() public {
        eq(pool.borrowRate(), 2e16);
        vm.prank(ALICE);
        pool.borrow(1000e6, 0);
        eq(pool.borrowRate(), 4e16);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrue();
        eq(pool.debtOf(ALICE), 1040e6);
    }

    function testLiquidationFivePercent() public {
        vm.prank(ALICE);
        pool.borrow(1500e6, 0);
        price.setPrice(1e18);
        pool.liquidate(ALICE, 500e6, 525e8);
        eq(collateral.balanceOf(address(this)), 525e8);
        eq(pool.debtOf(ALICE), 1000e6);
    }

    function testRevertOverBorrowAndHealthyLiquidation() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.UnsafePosition.selector);
        pool.borrow(1500e6 + 1, 0);
        vm.prank(ALICE);
        pool.borrow(100e6, 0);
        vm.expectRevert(LendingPool.UnsafePosition.selector);
        pool.liquidate(ALICE, 1e6, 0);
    }

    function testRevertUnsafeRemovalAndOverRepay() public {
        vm.prank(ALICE);
        pool.borrow(1500e6, 0);
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.UnsafePosition.selector);
        pool.removeCollateral(1e8, 0);
        vm.expectRevert(LendingPool.InvalidInput.selector);
        pool.repay(ALICE, 1501e6);
    }

    function testTaxedSupplyAndCollateral() public {
        loan.setTax(100);
        uint256 beforeShares = pool.totalSupplyShares();
        pool.supply(100e6, 1);
        eq(pool.totalSupplyShares() - beforeShares, 99e12);
        collateral.setTax(100);
        collateral.mint(address(this), 100e8);
        collateral.approve(address(pool), 100e8);
        pool.addCollateral(100e8);
        eq(pool.collateral(address(this)), 99e8);
    }

    function testTaxedRepayCreditsOnlyReceived() public {
        vm.prank(ALICE);
        pool.borrow(1000e6, 0);
        loan.setTax(100);
        vm.prank(ALICE);
        pool.repay(ALICE, 1000e6);
        eq(pool.debtOf(ALICE), 10e6);
    }

    function testCannotDebitAnotherApprover() public {
        loan.mint(BOB, 100e6);
        vm.prank(BOB);
        loan.approve(address(pool), 100e6);
        vm.prank(CAROL);
        vm.expectRevert();
        pool.supply(100e6, 0);
        eq(loan.balanceOf(BOB), 100e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzBorrowConservation(uint256 raw) public {
        uint256 amount = bound(raw, 1, 1500e6);
        uint256 cash = loan.balanceOf(address(pool));
        vm.startPrank(ALICE);
        pool.borrow(amount, amount);
        eq(loan.balanceOf(address(pool)) + pool.debtAssets(), cash);
        pool.repay(ALICE, amount);
        vm.stopPrank();
        eq(loan.balanceOf(address(pool)), cash);
        eq(pool.totalDebtShares(), 0);
    }

    function testFrequentAccrualDoesNotEraseFractionalInterest() public {
        vm.prank(ALICE);
        pool.borrow(1e6, 0);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 100; ++i) {
            vm.warp(start + i * 100);
            pool.accrue();
        }
        ok(pool.debtOf(ALICE) > 1e6);
        ok(pool.interestRemainder() > 0);
    }

    function testDebtFreeCollateralExitDoesNotNeedWorkingOracle() public {
        price.setPrice(0);
        vm.prank(ALICE);
        pool.removeCollateral(1000e8, 1000e8);
        eq(collateral.balanceOf(ALICE), 1000e8);
    }

    function testTokenCallbackCannotAccrueDuringSupply() public {
        CallbackToken callback = new CallbackToken();
        LendingPool guarded = new LendingPool(callback, collateral, ILendingPrice(address(price)));
        callback.mint(address(this), 10 ether);
        callback.approve(address(guarded), 10 ether);
        callback.configure(address(guarded), abi.encodeCall(guarded.accrue, ()));
        guarded.supply(10 ether, 1);
        ok(callback.blocked());
    }

    function testZeroInputsAndSlippageRollback() public {
        vm.expectRevert(LendingPool.InvalidInput.selector);
        pool.borrow(0, 0);
        vm.expectRevert(LendingPool.InvalidInput.selector);
        pool.withdraw(0, 0);
        vm.expectRevert(LendingPool.InvalidInput.selector);
        pool.repay(ALICE, 0);
        uint256 cash = loan.balanceOf(address(pool));
        uint256 shares = pool.totalSupplyShares();
        vm.expectRevert(LendingPool.Slippage.selector);
        pool.supply(100e6, type(uint256).max);
        eq(loan.balanceOf(address(pool)), cash);
        eq(pool.totalSupplyShares(), shares);
    }

    function testIlliquidWithdrawalPreservesSupplierShares() public {
        vm.prank(ALICE);
        pool.borrow(1500e6, 0);
        uint256 shares = pool.supplyShares(address(this));
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdraw(shares, 0);
        eq(pool.supplyShares(address(this)), shares);
        eq(pool.totalSupplyShares(), shares);
    }

    function testRevertedBorrowOutputMinimumRollsBackDebt() public {
        loan.setTax(100);
        vm.prank(ALICE);
        vm.expectRevert();
        pool.borrow(100e6, 100e6);
        eq(pool.totalDebtShares(), 0);
        eq(pool.debtAssets(), 0);
        eq(loan.balanceOf(address(pool)), 10000e6);
    }

    event Borrowed(address indexed user, uint256 assets, uint256 shares);

    function testBusinessEventIncludesActorAndAmount() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit Borrowed(ALICE, 100e6, 100e6);
        vm.prank(ALICE);
        pool.borrow(100e6, 100e6);
    }
}
