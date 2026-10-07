// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MultiSig} from "../src/MultiSig.sol";

contract MultiSigTest is TestBase {
    MultiSig wallet;

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = ALICE;
        owners[1] = BOB;
        owners[2] = CAROL;
        wallet = new MultiSig(owners, 2);
        vm.deal(address(wallet), 10 ether);
    }

    function submit(address to, uint256 amount, bytes memory data) internal returns (uint256) {
        vm.prank(ALICE);
        return wallet.submit(to, amount, data);
    }

    function approve(uint256 id) internal {
        vm.prank(ALICE);
        wallet.confirm(id);
        vm.prank(BOB);
        wallet.confirm(id);
    }

    function testConfirmRevokeAndExecute() public {
        uint256 id = submit(CAROL, 1 ether, "");
        approve(id);
        vm.prank(ALICE);
        wallet.revoke(id);
        vm.expectRevert(MultiSig.InvalidTransaction.selector);
        wallet.execute(id);
        vm.prank(CAROL);
        wallet.confirm(id);
        wallet.execute(id);
        eq(CAROL.balance, 1 ether);
        vm.expectRevert(MultiSig.InvalidTransaction.selector);
        wallet.execute(id);
    }

    function testSelfOnlyMembershipAndEpochInvalidation() public {
        vm.prank(ALICE);
        vm.expectRevert(MultiSig.Unauthorized.selector);
        wallet.addOwner(address(this));
        uint256 pending = submit(CAROL, 1 ether, "");
        approve(pending);
        uint256 update = submit(address(wallet), 0, abi.encodeCall(wallet.addOwner, (address(this))));
        approve(update);
        wallet.execute(update);
        ok(wallet.isOwner(address(this)));
        eq(wallet.epoch(), 1);
        vm.expectRevert(MultiSig.InvalidTransaction.selector);
        wallet.execute(pending);
    }

    function testRemoveOwnerAndThreshold() public {
        uint256 id = submit(address(wallet), 0, abi.encodeCall(wallet.removeOwner, (BOB, 1)));
        approve(id);
        wallet.execute(id);
        eq(wallet.threshold(), 1);
        ok(!wallet.isOwner(BOB));
        vm.prank(BOB);
        vm.expectRevert(MultiSig.Unauthorized.selector);
        wallet.submit(CAROL, 1, "");
    }

    function testUnauthorizedDuplicateAndUnknownActions() public {
        vm.expectRevert(MultiSig.Unauthorized.selector);
        wallet.submit(CAROL, 0, "");
        uint256 id = submit(CAROL, 0, "");
        vm.prank(ALICE);
        wallet.confirm(id);
        vm.prank(ALICE);
        vm.expectRevert(MultiSig.InvalidTransaction.selector);
        wallet.confirm(id);
        vm.prank(BOB);
        vm.expectRevert(MultiSig.InvalidTransaction.selector);
        wallet.revoke(id);
        vm.expectRevert(MultiSig.InvalidTransaction.selector);
        wallet.execute(100);
    }

    function testRevertingCallPreservesApprovals() public {
        uint256 id = submit(address(wallet), 0, abi.encodeCall(wallet.setThreshold, (0)));
        approve(id);
        vm.expectRevert(MultiSig.CallFailed.selector);
        wallet.execute(id);
        (,,, uint256 votes, bool executed) = wallet.transaction(id);
        eq(votes, 2);
        ok(!executed);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzConservation(uint256 raw) public {
        uint256 amount = bound(raw, 0, 10 ether);
        uint256 id = submit(CAROL, amount, "");
        approve(id);
        wallet.execute(id);
        eq(address(wallet).balance + CAROL.balance, 10 ether);
    }

    function testInvalidOwnerSetsAndThresholds() public {
        address[] memory owners = new address[](2);
        owners[0] = ALICE;
        owners[1] = ALICE;
        vm.expectRevert(MultiSig.InvalidInput.selector);
        new MultiSig(owners, 1);
        owners[1] = address(0);
        vm.expectRevert(MultiSig.InvalidInput.selector);
        new MultiSig(owners, 1);
        owners[1] = BOB;
        vm.expectRevert(MultiSig.InvalidInput.selector);
        new MultiSig(owners, 0);
        vm.expectRevert(MultiSig.InvalidInput.selector);
        new MultiSig(owners, 3);
    }

    function testInvalidSubmissionAndDirectAdminActions() public {
        vm.prank(ALICE);
        vm.expectRevert(MultiSig.InvalidInput.selector);
        wallet.submit(address(0), 0, "");
        vm.prank(ALICE);
        vm.expectRevert(MultiSig.InvalidInput.selector);
        wallet.submit(CAROL, 0, new bytes(16385));
        eq(wallet.transactionCount(), 0);
        vm.prank(ALICE);
        vm.expectRevert(MultiSig.Unauthorized.selector);
        wallet.removeOwner(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(MultiSig.Unauthorized.selector);
        wallet.setThreshold(1);
    }
}
