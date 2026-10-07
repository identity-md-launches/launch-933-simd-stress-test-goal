// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {Governor, ITimestampVotes, IGovernanceTimelock} from "../src/Governor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract VoteToken is ERC20Votes {
    constructor() ERC20("Votes", "V") EIP712("Votes", "1") {}

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract GovernanceExecutorMock {
    uint256 public executed;

    function queue(address, uint256, bytes calldata, bytes32 salt) external pure returns (bytes32) {
        return salt;
    }

    function execute(bytes32) external returns (bytes memory) {
        ++executed;
        return "";
    }
    function acceptAdmin() external {}
}

contract GovernorTest is TestBase {
    VoteToken token;
    GovernanceExecutorMock executor;
    Governor governor;

    function setUp() public {
        vm.warp(100 days);
        token = new VoteToken();
        executor = new GovernanceExecutorMock();
        governor = new Governor(ITimestampVotes(address(token)), IGovernanceTimelock(address(executor)));
        token.mint(ALICE, 600);
        token.mint(BOB, 400);
        vm.prank(ALICE);
        token.delegate(ALICE);
        vm.prank(BOB);
        token.delegate(BOB);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function proposal() internal returns (uint256 id) {
        vm.prank(ALICE);
        return governor.propose(CAROL, 0, "", keccak256("proposal"));
    }

    function testLifecycleAndQuorum() public {
        uint256 id = proposal();
        eq(uint256(governor.state(id)), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        eq(governor.quorum(id), 40);
        vm.prank(ALICE);
        governor.castVote(id, 1);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        eq(uint256(governor.state(id)), 3);
        governor.queue(id);
        governor.execute(id);
        eq(executor.executed(), 1);
        vm.expectRevert(Governor.WrongState.selector);
        governor.execute(id);
    }

    function testHistoricalWeightCannotMoveAndVoteTwice() public {
        uint256 id = proposal();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(ALICE);
        token.transfer(BOB, 600);
        vm.prank(ALICE);
        governor.castVote(id, 1);
        vm.prank(BOB);
        governor.castVote(id, 0);
        (,, uint256 againstVotes, uint256 forVotes,) = governor.details(id);
        eq(againstVotes, 400);
        eq(forVotes, 600);
        vm.prank(ALICE);
        vm.expectRevert(Governor.AlreadyVoted.selector);
        governor.castVote(id, 1);
    }

    function testDelayCancelAndInvalidProposal() public {
        vm.prank(CAROL);
        vm.expectRevert(Governor.InvalidInput.selector);
        governor.propose(CAROL, 0, "", 0);
        uint256 id = proposal();
        vm.prank(ALICE);
        vm.expectRevert(Governor.WrongState.selector);
        governor.castVote(id, 1);
        vm.prank(BOB);
        vm.expectRevert(Governor.WrongState.selector);
        governor.cancel(id);
        vm.prank(ALICE);
        governor.cancel(id);
        eq(uint256(governor.state(id)), 6);
    }

    function testNoVotesDefeatsProposal() public {
        uint256 id = proposal();
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);
        eq(uint256(governor.state(id)), 2);
        vm.expectRevert(Governor.WrongState.selector);
        governor.queue(id);
    }

    function testAgainstDoesNotMeetQuorumAndInvalidSupport() public {
        uint256 id = proposal();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(ALICE);
        vm.expectRevert(Governor.InvalidInput.selector);
        governor.castVote(id, 3);
        vm.prank(ALICE);
        governor.castVote(id, 0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        eq(uint256(governor.state(id)), 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzTalliesBoundedBySupply(uint8 a, uint8 b) public {
        uint256 id = proposal();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(ALICE);
        governor.castVote(id, a % 3);
        vm.prank(BOB);
        governor.castVote(id, b % 3);
        (,, uint256 n, uint256 y, uint256 abstain) = governor.details(id);
        eq(n + y + abstain, 1000);
    }

    function testExactSnapshotAndDeadlineBoundaries() public {
        uint256 id = proposal();
        (uint256 snapshot, uint256 deadline,,,) = governor.details(id);
        vm.warp(snapshot);
        vm.prank(ALICE);
        vm.expectRevert(Governor.WrongState.selector);
        governor.castVote(id, 1);
        vm.warp(snapshot + 1);
        vm.prank(ALICE);
        governor.castVote(id, 1);
        vm.warp(deadline);
        vm.prank(BOB);
        governor.castVote(id, 2);
        vm.expectRevert(Governor.WrongState.selector);
        governor.queue(id);
        vm.warp(deadline + 1);
        governor.queue(id);
        vm.expectRevert(Governor.WrongState.selector);
        governor.queue(id);
        vm.prank(ALICE);
        vm.expectRevert(Governor.WrongState.selector);
        governor.cancel(id);
    }

    function testInvalidTargetCalldataAndUnknownProposal() public {
        vm.prank(ALICE);
        vm.expectRevert(Governor.InvalidInput.selector);
        governor.propose(address(0), 0, "", 0);
        bytes memory oversized = new bytes(16385);
        vm.prank(ALICE);
        vm.expectRevert(Governor.InvalidInput.selector);
        governor.propose(CAROL, 0, oversized, 0);
        eq(governor.proposalCount(), 0);
        vm.expectRevert(Governor.InvalidInput.selector);
        governor.state(1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzQuorumRoundsUpForSmallSupply(uint256 raw) public {
        uint256 supply = bound(raw, 1, 10000);
        VoteToken small = new VoteToken();
        Governor g = new Governor(ITimestampVotes(address(small)), IGovernanceTimelock(address(executor)));
        small.mint(ALICE, supply);
        vm.prank(ALICE);
        small.delegate(ALICE);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(ALICE);
        uint256 id = g.propose(CAROL, 0, "", 0);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        uint256 quorum = g.quorum(id);
        ok(quorum * 100 >= supply * 4);
        ok((quorum - 1) * 100 < supply * 4);
    }
}
