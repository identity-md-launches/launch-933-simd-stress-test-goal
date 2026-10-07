// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {TokenBridgeLock} from "../src/TokenBridgeLock.sol";

contract TokenBridgeLockTest is TestBase {
    MockToken token;
    TokenBridgeLock bridge;
    uint256 key1;
    uint256 key2;

    function setUp() public {
        token = new MockToken(6);
        key1 = 11;
        key2 = 22;
        if (vm.addr(key1) > vm.addr(key2)) (key1, key2) = (key2, key1);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(key1);
        signers[1] = vm.addr(key2);
        bridge = new TokenBridgeLock(token, signers, 2);
        token.mint(address(this), 1000e6);
        token.approve(address(bridge), 1000e6);
        bridge.lock(1000e6, bytes32(uint256(1)));
    }

    function signatures(TokenBridgeLock b, bytes32 id, address to, uint256 amount, uint256 deadline)
        internal
        returns (bytes[] memory sigs)
    {
        bytes32 digest = b.unlockDigest(id, to, amount, deadline);
        sigs = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key1, digest);
        sigs[0] = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(key2, digest);
        sigs[1] = abi.encodePacked(r, s, v);
    }

    function testUnlockAndReplayProtection() public {
        bytes32 id = keccak256("source");
        bytes[] memory sigs = signatures(bridge, id, ALICE, 100e6, block.timestamp);
        vm.prank(ALICE);
        bridge.unlock(id, 100e6, block.timestamp, sigs, 100e6);
        eq(token.balanceOf(ALICE), 100e6);
        vm.prank(ALICE);
        vm.expectRevert(TokenBridgeLock.InvalidAuthorization.selector);
        bridge.unlock(id, 100e6, block.timestamp, sigs, 0);
    }

    function testDuplicateAndWrongRecipientRejected() public {
        bytes32 id = keccak256("source");
        bytes[] memory sigs = signatures(bridge, id, ALICE, 100e6, block.timestamp);
        vm.prank(BOB);
        vm.expectRevert();
        bridge.unlock(id, 100e6, block.timestamp, sigs, 0);
        sigs[1] = sigs[0];
        vm.prank(ALICE);
        vm.expectRevert(TokenBridgeLock.InvalidAuthorization.selector);
        bridge.unlock(id, 100e6, block.timestamp, sigs, 0);
    }

    function testExpiredAndCrossContractSignaturesRejected() public {
        bytes32 id = keccak256("source");
        bytes[] memory sigs = signatures(bridge, id, ALICE, 100e6, block.timestamp);
        vm.warp(block.timestamp + 1);
        vm.prank(ALICE);
        vm.expectRevert(TokenBridgeLock.InvalidAuthorization.selector);
        bridge.unlock(id, 100e6, block.timestamp - 1, sigs, 0);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(key1);
        signers[1] = vm.addr(key2);
        TokenBridgeLock other = new TokenBridgeLock(token, signers, 2);
        sigs = signatures(other, id, ALICE, 100e6, block.timestamp);
        vm.prank(ALICE);
        vm.expectRevert();
        bridge.unlock(id, 100e6, block.timestamp, sigs, 0);
    }

    function testTaxedLockAndNonces() public {
        token.setTax(100);
        token.mint(address(this), 100e6);
        token.approve(address(bridge), 100e6);
        eq(bridge.lock(100e6, bytes32(uint256(2))), 1);
        eq(token.balanceOf(address(bridge)), 1099e6);
        eq(bridge.nonce(), 2);
    }

    function testFuzzSignedAmountConservation(uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        bytes32 id = keccak256("source");
        bytes[] memory sigs = signatures(bridge, id, ALICE, amount, block.timestamp);
        vm.prank(ALICE);
        bridge.unlock(id, amount, block.timestamp, sigs, amount);
        eq(token.balanceOf(ALICE) + token.balanceOf(address(bridge)), 1000e6);
    }
}
