// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";

contract AMMHandler is ActorHandler {
    MockToken public first;
    MockToken public second;
    ConstantProductAMM public amm;
    uint256 public donated0;
    uint256 public donated1;
    bool public kDecreased;

    constructor() {
        first = new MockToken(6);
        second = new MockToken(8);
        amm = new ConstantProductAMM(first, second);
        for (uint256 i; i < 3; ++i) {
            first.mint(actor(i), 100000000e6);
            second.mint(actor(i), 100000000e8);
            vm.startPrank(actor(i));
            first.approve(address(amm), type(uint256).max);
            second.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(ALICE);
        amm.addLiquidity(10000e6, 10000e8, 1, vm.getBlockTimestamp());
        ++successfulCalls;
    }

    function add(uint256 who, uint256 raw0, uint256 raw1) public {
        callAs(
            actor(who),
            address(amm),
            abi.encodeCall(
                amm.addLiquidity, (bound(raw0, 1, 1000e6), bound(raw1, 1, 1000e8), 1, vm.getBlockTimestamp())
            )
        );
    }

    function remove(uint256 who, uint256 raw) public {
        uint256 shares = amm.balanceOf(actor(who));
        if (shares > 0) {
            callAs(
                actor(who),
                address(amm),
                abi.encodeCall(amm.removeLiquidity, (bound(raw, 1, shares), 0, 0, vm.getBlockTimestamp()))
            );
        }
    }

    function swap(uint256 who, uint256 raw, bool reverse) public {
        uint256 k = amm.reserve0() * amm.reserve1();
        if (callAs(
                actor(who),
                address(amm),
                abi.encodeCall(
                    amm.swap,
                    (
                        reverse ? second : first,
                        bound(raw, 1, reverse ? 1000e8 : 1000e6),
                        0,
                        vm.getBlockTimestamp()
                    )
                )
            )) {
            if (amm.reserve0() * amm.reserve1() < k) kDecreased = true;
        }
    }

    function donate(uint256 who, uint256 raw, bool reverse) public {
        uint256 amount = bound(raw, 1, 100e6);
        MockToken token = reverse ? second : first;
        if (callAs(actor(who), address(token), abi.encodeCall(token.transfer, (address(amm), amount)))) {
            if (reverse) donated1 += amount;
            else donated0 += amount;
        }
    }

    function transferShares(uint256 who, uint256 to, uint256 raw) public {
        uint256 balance = amm.balanceOf(actor(who));
        if (balance > 0) {
            callAs(
                actor(who), address(amm), abi.encodeCall(amm.transfer, (actor(to), bound(raw, 1, balance)))
            );
        }
    }
}

contract ConstantProductAMMInvariantTest is InvariantBase {
    AMMHandler private handler;

    function setUp() public {
        handler = new AMMHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_ReservesSharesAndSwapProduct() public view {
        ConstantProductAMM amm = handler.amm();
        eq(handler.first().balanceOf(address(amm)), amm.reserve0() + handler.donated0());
        eq(handler.second().balanceOf(address(amm)), amm.reserve1() + handler.donated1());
        eq(
            amm.balanceOf(ALICE) + amm.balanceOf(BOB) + amm.balanceOf(CAROL) + amm.balanceOf(address(1)),
            amm.totalSupply()
        );
        eq(amm.balanceOf(address(1)), 1000);
        ok(amm.reserve0() > 0 && amm.reserve1() > 0);
        ok(!handler.kDecreased());
    }
}
