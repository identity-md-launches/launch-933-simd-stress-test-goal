// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Vault4626} from "../src/Vault4626.sol";

contract VaultHandler is ActorHandler {
    MockToken public token;
    Vault4626 public vault;
    uint256 public inflow;
    uint256 public outflow;

    constructor() {
        token = new MockToken(6);
        vault = new Vault4626(token, address(this), 1000000e6);
        for (uint256 i; i < 3; ++i) {
            token.mint(actor(i), 1000000e6);
            vm.prank(actor(i));
            token.approve(address(vault), type(uint256).max);
        }
        deposit(0, 100e6 - 1);
    }

    function deposit(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(actor(who), address(vault), abi.encodeCall(vault.deposit, (amount, actor(who))))) {
            inflow += amount;
        }
    }

    function yield(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 100e6);
        if (callAs(actor(who), address(vault), abi.encodeCall(vault.addYield, (amount)))) inflow += amount;
    }

    function redeem(uint256 who, uint256 raw) public {
        address user = actor(who);
        uint256 shares = vault.balanceOf(user);
        if (shares == 0) return;
        uint256 beforeCash = token.balanceOf(address(vault));
        if (callAs(user, address(vault), abi.encodeCall(vault.redeem, (bound(raw, 1, shares), user, user)))) {
            outflow += beforeCash - token.balanceOf(address(vault));
        }
    }

    function request(uint256 who, uint256 raw) public {
        address user = actor(who);
        uint256 shares = vault.balanceOf(user);
        if (shares > 0) {
            callAs(user, address(vault), abi.encodeCall(vault.requestRedeem, (bound(raw, 1, shares))));
        }
    }

    function cancel(uint256 who, uint256 raw) public {
        if (vault.tail() > 0) {
            callAs(actor(who), address(vault), abi.encodeCall(vault.cancelRequest, (raw % vault.tail())));
        }
    }

    function process() public {
        callAs(ALICE, address(vault), abi.encodeCall(vault.processNext, ()));
    }

    function claim(uint256 who) public {
        uint256 beforeCash = token.balanceOf(address(vault));
        if (callAs(actor(who), address(vault), abi.encodeCall(vault.claim, (0)))) {
            outflow += beforeCash - token.balanceOf(address(vault));
        }
    }

    function transferShares(uint256 who, uint256 to, uint256 raw) public {
        address user = actor(who);
        uint256 balance = vault.balanceOf(user);
        if (balance > 0) {
            callAs(user, address(vault), abi.encodeCall(vault.transfer, (actor(to), bound(raw, 1, balance))));
        }
    }
}

contract Vault4626InvariantTest is InvariantBase {
    VaultHandler private handler;

    function setUp() public {
        handler = new VaultHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_ReservedClaimsCannotBeRedeemedByShareholders() public view {
        Vault4626 vault = handler.vault();
        uint256 cash = handler.token().balanceOf(address(vault));
        eq(cash + handler.outflow(), handler.inflow());
        eq(vault.claimable(ALICE) + vault.claimable(BOB) + vault.claimable(CAROL), vault.reservedAssets());
        ok(vault.reservedAssets() <= cash);
        eq(vault.totalAssets() + vault.reservedAssets(), cash);
        eq(
            vault.balanceOf(ALICE) + vault.balanceOf(BOB) + vault.balanceOf(CAROL)
                + vault.balanceOf(address(vault)),
            vault.totalSupply()
        );
        uint256 escrow;
        for (uint256 id = vault.head(); id < vault.tail(); ++id) {
            (, uint256 shares,) = vault.requests(id);
            escrow += shares;
        }
        eq(escrow, vault.balanceOf(address(vault)));
        ok(vault.head() <= vault.tail());
        uint256 redeemable = vault.previewRedeem(vault.totalSupply());
        ok(redeemable <= vault.totalAssets());
        ok(handler.successfulCalls() > 0);
    }
}
