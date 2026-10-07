// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {TokenBridgeLock} from "../src/TokenBridgeLock.sol";

contract BridgeHandler is ActorHandler {
    MockToken public token;
    TokenBridgeLock public bridge;
    uint256 private key1 = 11;
    uint256 private key2 = 22;
    uint256 public locked;
    uint256 public unlocked;
    uint256 public locks;
    mapping(bytes32 => bool) public used;
    bool public badAuthorization;

    constructor() {
        token = new MockToken(6);
        if (vm.addr(key1) > vm.addr(key2)) (key1, key2) = (key2, key1);
        address[] memory relayers = new address[](2);
        relayers[0] = vm.addr(key1);
        relayers[1] = vm.addr(key2);
        bridge = new TokenBridgeLock(token, relayers, 2);
        for (uint256 i; i < 3; ++i) {
            token.mint(actor(i), 1000000e6);
            vm.prank(actor(i));
            token.approve(address(bridge), type(uint256).max);
        }
        lock(0, 1000e6 - 1);
    }

    function lock(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(actor(who), address(bridge), abi.encodeCall(bridge.lock, (amount, bytes32(uint256(1)))))) {
            locked += amount;
            ++locks;
        }
    }

    function unlock(uint256 who, uint256 rawId, uint256 rawAmount, bool tamper) public {
        bytes32 id = bytes32(1 + rawId % 32);
        uint256 cash = token.balanceOf(address(bridge));
        if (cash == 0) return;
        uint256 amount = bound(rawAmount, 1, cash);
        address user = actor(who);
        bytes32 digest = bridge.unlockDigest(id, user, amount, vm.getBlockTimestamp());
        bytes[] memory sigs = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key1, digest);
        sigs[0] = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(key2, digest);
        sigs[1] = abi.encodePacked(r, s, v);
        if (tamper) sigs[1] = sigs[0];
        if (callAs(
                user,
                address(bridge),
                abi.encodeCall(bridge.unlock, (id, amount, vm.getBlockTimestamp(), sigs, amount))
            )) {
            if (tamper || used[id]) badAuthorization = true;
            unlocked += amount;
            used[id] = true;
        }
    }
}

contract TokenBridgeLockInvariantTest is InvariantBase {
    BridgeHandler private handler;

    function setUp() public {
        handler = new BridgeHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_OnlyDistinctSignaturesReleaseCustodyOnce() public view {
        TokenBridgeLock bridge = handler.bridge();
        eq(handler.token().balanceOf(address(bridge)) + handler.unlocked(), handler.locked());
        eq(bridge.nonce(), handler.locks());
        ok(!handler.badAuthorization());
        for (uint256 id = 1; id <= 32; ++id) {
            ok(bridge.processed(bytes32(id)) == handler.used(bytes32(id)));
        }
    }
}
