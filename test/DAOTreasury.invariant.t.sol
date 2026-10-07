// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {VoteToken} from "./Governor.t.sol";
import {Governor, ITimestampVotes, IGovernanceTimelock} from "../src/Governor.sol";
import {Timelock} from "../src/Timelock.sol";
import {DAOTreasury, ITreasuryTimelock} from "../src/DAOTreasury.sol";

contract TreasuryHandler is ActorHandler {
    DAOTreasury public treasury;
    Timelock public lock;
    Governor public governor;
    MockToken public token;
    uint256 public fundedETH;
    uint256 public fundedToken;
    uint256 public paidETH;
    uint256 public paidToken;
    bool public unauthorizedSpend;

    constructor() {
        VoteToken votes = new VoteToken();
        lock = new Timelock(address(this));
        governor = new Governor(ITimestampVotes(address(votes)), IGovernanceTimelock(address(lock)));
        lock.nominateAdmin(address(governor));
        governor.acceptTimelockAdmin();
        treasury = new DAOTreasury(address(governor), ITreasuryTimelock(address(lock)));
        token = new MockToken(6);
        for (uint256 i; i < 3; ++i) {
            vm.deal(actor(i), 1000 ether);
            token.mint(actor(i), 1000000e6);
            vm.prank(actor(i));
            token.approve(address(treasury), type(uint256).max);
        }
        fundETH(0, 10 ether - 1);
        fundToken(0, 1000e6 - 1);
    }

    function fundETH(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 10 ether);
        vm.prank(actor(who));
        (bool success,) = address(treasury).call{value: amount}("");
        if (success) {
            fundedETH += amount;
            ++successfulCalls;
        }
    }

    function fundToken(uint256 who, uint256 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(actor(who), address(treasury), abi.encodeCall(treasury.fundToken, (token, amount)))) {
            fundedToken += amount;
        }
    }

    function allocate(uint256 who, uint256 raw, bool authorized) public {
        address caller = authorized ? address(lock) : actor(who);
        bool success = callAs(
            caller,
            address(treasury),
            abi.encodeCall(treasury.spendETH, (actor(who), bound(raw, 1, 10 ether)))
        );
        if (success && !authorized) unauthorizedSpend = true;
    }

    function spendToken(uint256 who, uint256 raw, bool authorized) public {
        uint256 amount = bound(raw, 1, 1000e6);
        if (callAs(
                authorized ? address(lock) : actor(who),
                address(treasury),
                abi.encodeCall(treasury.spendToken, (token, actor(who), amount, amount))
            )) {
            paidToken += amount;
            if (!authorized) unauthorizedSpend = true;
        }
    }

    function withdraw(uint256 who) public {
        uint256 beforeCash = address(treasury).balance;
        if (callAs(actor(who), address(treasury), abi.encodeCall(treasury.withdrawPayments, ()))) {
            paidETH += beforeCash - address(treasury).balance;
        }
    }
}

contract DAOTreasuryInvariantTest is InvariantBase {
    TreasuryHandler private handler;

    function setUp() public {
        handler = new TreasuryHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_GovernanceCannotDoubleAllocateReservedETH() public view {
        DAOTreasury treasury = handler.treasury();
        eq(address(treasury).balance + handler.paidETH(), handler.fundedETH());
        eq(handler.token().balanceOf(address(treasury)) + handler.paidToken(), handler.fundedToken());
        eq(treasury.credits(ALICE) + treasury.credits(BOB) + treasury.credits(CAROL), treasury.totalCredits());
        ok(treasury.totalCredits() <= address(treasury).balance);
        ok(!handler.unauthorizedSpend());
    }
}
