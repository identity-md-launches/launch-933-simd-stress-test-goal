// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract StakingHandler is ActorHandler {
    MockToken public principal;
    MockToken public reward;
    StakingRewards public staking;
    uint256 public funded;
    uint256 public paid;

    constructor() {
        principal = new MockToken(6);
        reward = new MockToken(8);
        staking = new StakingRewards(principal, reward, address(this));
        reward.mint(address(this), 1e24);
        reward.approve(address(staking), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            principal.mint(actor(i), 1000000e6);
            vm.prank(actor(i));
            principal.approve(address(staking), type(uint256).max);
        }
        fund(86400e8 - 3600, 0);
        stake(0, 100e6 - 1);
    }

    function fund(uint256 raw, uint256 durationRaw) public {
        uint256 duration = bound(durationRaw, 1 hours, 7 days);
        uint256 amount = bound(raw, duration, 1e15);
        try staking.fundPeriod(amount, duration) {
            funded += amount;
            ++successfulCalls;
        } catch {}
    }

    function stake(uint256 who, uint256 raw) public {
        callAs(actor(who), address(staking), abi.encodeCall(staking.stake, (bound(raw, 1, 1000e6))));
    }

    function withdraw(uint256 who, uint256 raw) public {
        uint256 balance = staking.balanceOf(actor(who));
        if (balance > 0) {
            callAs(
                actor(who), address(staking), abi.encodeCall(staking.withdraw, (bound(raw, 1, balance), 0))
            );
        }
    }

    function claim(uint256 who) public {
        uint256 beforeCash = reward.balanceOf(address(staking));
        if (callAs(actor(who), address(staking), abi.encodeCall(staking.claim, (0)))) {
            paid += beforeCash - reward.balanceOf(address(staking));
        }
    }
}

contract StakingRewardsInvariantTest is InvariantBase {
    StakingHandler private handler;

    function setUp() public {
        handler = new StakingHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_PrincipalAndRewardSolvency() public view {
        StakingRewards staking = handler.staking();
        eq(
            staking.balanceOf(ALICE) + staking.balanceOf(BOB) + staking.balanceOf(CAROL),
            staking.totalStaked()
        );
        eq(handler.principal().balanceOf(address(staking)), staking.totalStaked());
        uint256 cash = handler.reward().balanceOf(address(staking));
        eq(cash + handler.paid(), handler.funded());
        uint256 owed = staking.earned(ALICE) + staking.earned(BOB) + staking.earned(CAROL);
        uint256 future = vm.getBlockTimestamp() < staking.periodFinish()
            ? (staking.periodFinish() - vm.getBlockTimestamp()) * staking.rewardRate()
            : 0;
        ok(owed + future <= cash);
        ok(staking.lastUpdate() <= vm.getBlockTimestamp() && staking.lastUpdate() <= staking.periodFinish());
        ok(handler.successfulCalls() >= 2);
    }
}
