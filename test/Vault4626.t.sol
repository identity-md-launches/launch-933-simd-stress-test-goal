// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken, CallbackToken} from "./helpers/Mocks.sol";
import {Vault4626} from "../src/Vault4626.sol";

contract Vault4626Test is TestBase {
    MockToken token;
    Vault4626 vault;

    function setUp() public {
        token = new MockToken(6);
        vault = new Vault4626(token, address(this), 10000e6);
        token.mint(address(this), 100000e6);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositYieldRedeem() public {
        uint256 shares = vault.deposit(100e6, address(this));
        eq(shares, 100e12);
        vault.addYield(10e6);
        uint256 amount = vault.redeem(shares, address(this), address(this));
        ok(amount >= 110e6 - 1 && amount <= 110e6);
    }

    function testMintWithdrawRounding() public {
        vault.deposit(100e6, address(this));
        vault.addYield(7e6);
        uint256 cost = vault.previewMint(1234567);
        eq(vault.mint(1234567, ALICE), cost);
        uint256 burned = vault.previewWithdraw(12345);
        eq(vault.withdraw(12345, address(this), address(this)), burned);
    }

    function testQueueReservesAndClaim() public {
        uint256 shares = vault.deposit(100e6, address(this));
        vault.requestRedeem(shares / 2);
        vm.expectRevert(Vault4626.NotReady.selector);
        vault.processNext();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(BOB);
        vault.processNext();
        eq(vault.claimable(address(this)), 50e6);
        eq(vault.totalAssets(), 50e6);
        vault.redeem(shares / 2, address(this), address(this));
        eq(token.balanceOf(address(vault)), 50e6);
        vault.claim(50e6);
        eq(token.balanceOf(address(vault)), 0);
        vm.expectRevert(Vault4626.InvalidInput.selector);
        vault.claim(0);
    }

    function testQueueCancelCannotSteal() public {
        uint256 shares = vault.deposit(100e6, address(this));
        uint256 id = vault.requestRedeem(shares);
        vm.prank(ALICE);
        vm.expectRevert(Vault4626.InvalidInput.selector);
        vault.cancelRequest(id);
        vault.cancelRequest(id);
        vault.processNext();
        eq(vault.balanceOf(address(this)), shares);
    }

    function testCapAndAuthority() public {
        vm.expectRevert();
        vault.deposit(10001e6, address(this));
        vm.prank(ALICE);
        vm.expectRevert();
        vault.setCap(1);
        vault.setCap(100e6);
        vault.deposit(100e6, address(this));
        eq(vault.maxDeposit(ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert();
        vault.redeem(1e6, ALICE, address(this));
    }

    function testTaxedDepositExtensionAndOutput() public {
        token.setTax(100);
        vm.expectRevert(Vault4626.TransferTax.selector);
        vault.deposit(100e6, address(this));
        uint256 shares = vault.depositReceived(100e6, address(this), 99e12);
        eq(shares, 99e12);
        vm.expectRevert();
        vault.redeem(shares, address(this), address(this));
        vault.requestRedeem(shares);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.processNext();
        vault.claim(9801e4);
        eq(vault.totalAssets(), 0);
    }

    function testDonationAttackNoZeroShares() public {
        vault.deposit(1, address(this));
        token.transfer(address(vault), 1000e6);
        token.mint(ALICE, 100e6);
        vm.startPrank(ALICE);
        token.approve(address(vault), 100e6);
        uint256 shares = vault.depositReceived(100e6, ALICE, 1);
        ok(shares > 0);
        vm.stopPrank();
        uint256 recovered = vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        ok(recovered < 1000e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzNoRoundTripProfit(uint256 raw, uint256 donation) public {
        uint256 amount = bound(raw, 1, 1000e6);
        donation = bound(donation, 0, 1000e6);
        vault.deposit(100e6, ALICE);
        if (donation > 0) vault.addYield(donation);
        uint256 shares = vault.deposit(amount, address(this));
        uint256 returned = vault.redeem(shares, address(this), address(this));
        ok(returned <= amount);
        ok(vault.previewMint(1e6) >= vault.convertToAssets(1e6));
        ok(vault.previewWithdraw(1e6) >= vault.convertToShares(1e6));
    }

    function testTokenCallbackCannotProcessQueueDuringDeposit() public {
        CallbackToken callback = new CallbackToken();
        Vault4626 guarded = new Vault4626(callback, address(this), 100 ether);
        callback.mint(address(this), 20 ether);
        callback.approve(address(guarded), 20 ether);
        uint256 shares = guarded.deposit(10 ether, address(this));
        guarded.requestRedeem(shares);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        callback.configure(address(guarded), abi.encodeCall(guarded.processNext, ()));
        guarded.deposit(10 ether, address(this));
        ok(callback.blocked());
        eq(guarded.head(), 0);
    }

    function testQueueFailureDoesNotCreatePhantomRequests() public {
        vm.expectRevert(Vault4626.InvalidInput.selector);
        vault.requestRedeem(0);
        vm.expectRevert();
        vault.requestRedeem(1);
        eq(vault.tail(), 0);
        vm.expectRevert(Vault4626.NotReady.selector);
        vault.processNext();
        uint256 shares = vault.deposit(100e6, address(this));
        uint256 id = vault.requestRedeem(shares);
        vault.cancelRequest(id);
        vm.expectRevert(Vault4626.InvalidInput.selector);
        vault.cancelRequest(id);
        vault.processNext();
        eq(vault.head(), vault.tail());
        eq(vault.reservedAssets(), 0);
    }

    function testRevertedClaimPreservesReservationAndCanRetry() public {
        uint256 shares = vault.deposit(100e6, address(this));
        vault.requestRedeem(shares);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.processNext();
        token.setTax(100);
        vm.expectRevert();
        vault.claim(100e6);
        eq(vault.claimable(address(this)), 100e6);
        eq(vault.reservedAssets(), 100e6);
        eq(token.balanceOf(address(vault)), 100e6);
        vault.claim(99e6);
        eq(vault.reservedAssets(), 0);
    }

    function testCapReductionCannotFreezeExistingAssets() public {
        uint256 shares = vault.deposit(100e6, address(this));
        vault.setCap(0);
        vm.expectRevert();
        vault.deposit(1, ALICE);
        eq(vault.redeem(shares, address(this), address(this)), 100e6);
    }

    event CapSet(uint256 cap);

    function testBusinessEventIncludesActorAndAmount() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit CapSet(100e6);
        vault.setCap(100e6);
    }
}
