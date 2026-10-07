// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {Timelock} from "../src/Timelock.sol";
import {Governor, ITimestampVotes, IGovernanceTimelock} from "../src/Governor.sol";
import {VoteToken} from "./Governor.t.sol";

contract TimelockTarget {
    uint256 public value;
    bool public fail;

    function set(uint256 v) external payable {
        require(!fail);
        value = v;
    }

    function setFail(bool f) external {
        fail = f;
    }
}

contract TimelockTest is TestBase {
    Timelock lock;
    TimelockTarget target;

    function setUp() public {
        lock = new Timelock(address(this));
        target = new TimelockTarget();
        vm.deal(address(lock), 10 ether);
    }

    function enqueue(uint256 value) internal returns (bytes32) {
        return lock.queue(address(target), 1 ether, abi.encodeCall(target.set, (value)), bytes32(value));
    }

    function testExecuteAndPreventReplay() public {
        bytes32 id = enqueue(7);
        vm.expectRevert(Timelock.NotReady.selector);
        lock.execute(id);
        vm.warp(block.timestamp + 2 days);
        lock.execute(id);
        eq(target.value(), 7);
        eq(address(target).balance, 1 ether);
        vm.expectRevert(Timelock.NotReady.selector);
        lock.execute(id);
        vm.expectRevert(Timelock.InvalidInput.selector);
        enqueue(7);
    }

    function testCancelAndUnauthorized() public {
        bytes32 id = enqueue(1);
        vm.prank(ALICE);
        vm.expectRevert(Timelock.Unauthorized.selector);
        lock.cancel(id);
        vm.prank(ALICE);
        vm.expectRevert(Timelock.Unauthorized.selector);
        lock.execute(id);
        vm.prank(ALICE);
        vm.expectRevert(Timelock.Unauthorized.selector);
        enqueue(2);
        lock.cancel(id);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(Timelock.NotReady.selector);
        lock.execute(id);
    }

    function testRevertedCallCanRetry() public {
        bytes32 id = enqueue(8);
        target.setFail(true);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Timelock.CallFailed.selector);
        lock.execute(id);
        (, bool done,) = lock.status(id);
        ok(!done);
        target.setFail(false);
        lock.execute(id);
        eq(target.value(), 8);
    }

    function testTwoStepHandover() public {
        lock.nominateAdmin(ALICE);
        eq(lock.admin(), address(this));
        vm.prank(BOB);
        vm.expectRevert(Timelock.Unauthorized.selector);
        lock.acceptAdmin();
        vm.prank(ALICE);
        lock.acceptAdmin();
        eq(lock.admin(), ALICE);
        vm.expectRevert(Timelock.Unauthorized.selector);
        enqueue(1);
    }

    function testGovernorIntegration() public {
        vm.warp(100 days);
        VoteToken votes = new VoteToken();
        Governor governor = new Governor(ITimestampVotes(address(votes)), IGovernanceTimelock(address(lock)));
        lock.nominateAdmin(address(governor));
        governor.acceptTimelockAdmin();
        votes.mint(ALICE, 100);
        vm.prank(ALICE);
        votes.delegate(ALICE);
        vm.warp(block.timestamp + 1);
        vm.prank(ALICE);
        uint256 id = governor.propose(address(target), 1 ether, abi.encodeCall(target.set, (42)), 0);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ALICE);
        governor.castVote(id, 1);
        vm.warp(block.timestamp + 3 days);
        governor.queue(id);
        vm.expectRevert(Timelock.NotReady.selector);
        governor.execute(id);
        vm.warp(block.timestamp + 2 days);
        governor.execute(id);
        eq(target.value(), 42);
    }

    function testFuzzDelayNeverBypassed(uint256 raw) public {
        uint256 elapsed = bound(raw, 0, 2 days - 1);
        bytes32 id = enqueue(17);
        vm.warp(block.timestamp + elapsed);
        vm.expectRevert(Timelock.NotReady.selector);
        lock.execute(id);
    }
}
