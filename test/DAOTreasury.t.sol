// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {DAOTreasury, ITreasuryTimelock} from "../src/DAOTreasury.sol";
import {Timelock} from "../src/Timelock.sol";
import {Governor, ITimestampVotes, IGovernanceTimelock} from "../src/Governor.sol";
import {VoteToken} from "./Governor.t.sol";

contract DAOTreasuryTest is TestBase {
    VoteToken votes;
    Governor governor;
    Timelock timelock;
    DAOTreasury treasury;
    MockToken token;

    function setUp() public {
        vm.warp(100 days);
        votes = new VoteToken();
        timelock = new Timelock(address(this));
        governor = new Governor(ITimestampVotes(address(votes)), IGovernanceTimelock(address(timelock)));
        timelock.nominateAdmin(address(governor));
        governor.acceptTimelockAdmin();
        treasury = new DAOTreasury(address(governor), ITreasuryTimelock(address(timelock)));
        votes.mint(ALICE, 100);
        vm.prank(ALICE);
        votes.delegate(ALICE);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.deal(address(treasury), 10 ether);
        token = new MockToken(6);
        token.mint(address(treasury), 1000e6);
    }

    function govern(bytes memory data) internal {
        vm.prank(ALICE);
        uint256 id = governor.propose(address(treasury), 0, data, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(ALICE);
        governor.castVote(id, 1);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        governor.queue(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        governor.execute(id);
    }

    function testGovernanceETHSpendingAndWithdrawal() public {
        govern(abi.encodeCall(treasury.spendETH, (BOB, 2 ether)));
        eq(treasury.credits(BOB), 2 ether);
        vm.prank(BOB);
        treasury.withdrawPayments();
        eq(BOB.balance, 2 ether);
    }

    function testGovernanceTokenSpending() public {
        govern(abi.encodeCall(treasury.spendToken, (token, BOB, 100e6, 100e6)));
        eq(token.balanceOf(BOB), 100e6);
    }

    function testDirectAndGovernorCallsCannotSpend() public {
        vm.expectRevert(DAOTreasury.Unauthorized.selector);
        treasury.spendETH(BOB, 1 ether);
        vm.prank(address(governor));
        vm.expectRevert(DAOTreasury.Unauthorized.selector);
        treasury.spendToken(token, BOB, 1, 0);
    }

    function testReservedFundsCannotBeAllocatedAgain() public {
        govern(abi.encodeCall(treasury.spendETH, (BOB, 10 ether)));
        vm.prank(address(timelock));
        vm.expectRevert(DAOTreasury.InvalidInput.selector);
        treasury.spendETH(ALICE, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAuthorizedAllocationSolvency(uint256 raw) public {
        uint256 amount = bound(raw, 1, 10 ether);
        vm.prank(address(timelock));
        treasury.spendETH(BOB, amount);
        eq(treasury.totalCredits(), amount);
        ok(treasury.totalCredits() <= address(treasury).balance);
    }

    function testAdminHandoverDisablesTreasurySpending() public {
        vm.prank(address(timelock));
        timelock.nominateAdmin(CAROL);
        vm.prank(CAROL);
        timelock.acceptAdmin();
        vm.prank(address(timelock));
        vm.expectRevert(DAOTreasury.Unauthorized.selector);
        treasury.spendETH(BOB, 1 ether);
        vm.prank(address(timelock));
        vm.expectRevert(DAOTreasury.Unauthorized.selector);
        treasury.spendToken(token, BOB, 1e6, 0);
        eq(treasury.totalCredits(), 0);
        eq(token.balanceOf(address(treasury)), 1000e6);
    }

    function testInvalidRecipientsAndTokenSlippageRollback() public {
        vm.prank(address(timelock));
        vm.expectRevert(DAOTreasury.InvalidInput.selector);
        treasury.spendETH(address(0), 1);
        vm.prank(address(timelock));
        vm.expectRevert(DAOTreasury.InvalidInput.selector);
        treasury.spendETH(address(treasury), 1);
        token.setTax(100);
        vm.prank(address(timelock));
        vm.expectRevert();
        treasury.spendToken(token, BOB, 100e6, 100e6);
        eq(token.balanceOf(address(treasury)), 1000e6);
        eq(token.balanceOf(BOB), 0);
        vm.prank(address(timelock));
        treasury.spendToken(token, BOB, 100e6, 99e6);
        eq(token.balanceOf(BOB), 99e6);
    }

    event ETHAllocated(address indexed recipient, uint256 amount);

    function testBusinessEventIncludesActorAndAmount() public {
        vm.expectEmit(true, false, false, true, address(treasury));
        emit ETHAllocated(BOB, 1 ether);
        vm.prank(address(timelock));
        treasury.spendETH(BOB, 1 ether);
    }
}
