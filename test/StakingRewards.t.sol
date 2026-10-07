// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract StakingRewardsTest is TestBase {
    MockToken stakeToken;
    MockToken reward;
    StakingRewards staking;

    function setUp() public {
        stakeToken = new MockToken(6);
        reward = new MockToken(8);
        staking = new StakingRewards(stakeToken, reward, address(this));
        reward.mint(address(this), 1e16);
        reward.approve(address(staking), type(uint256).max);
        stakeToken.mint(ALICE, 100e6);
        stakeToken.mint(BOB, 100e6);
        vm.prank(ALICE);
        stakeToken.approve(address(staking), 100e6);
        vm.prank(BOB);
        stakeToken.approve(address(staking), 100e6);
    }

    function testStakeEarnWithdraw() public {
        staking.fundPeriod(86400e8, 1 days);
        vm.prank(ALICE);
        staking.stake(100e6);
        vm.warp(block.timestamp + 100);
        eq(staking.earned(ALICE), 100e8);
        vm.startPrank(ALICE);
        staking.withdraw(100e6, 100e6);
        staking.claim(100e8);
        vm.stopPrank();
        eq(reward.balanceOf(ALICE), 100e8);
        eq(staking.totalStaked(), 0);
    }

    function testTwoStakersAndPeriodEnd() public {
        staking.fundPeriod(86400e8, 1 days);
        vm.prank(ALICE);
        staking.stake(100e6);
        vm.prank(BOB);
        staking.stake(100e6);
        vm.warp(block.timestamp + 2 days);
        eq(staking.earned(ALICE), 43200e8);
        eq(staking.earned(BOB), 43200e8);
    }

    function testIdleTimeNotGivenToFirstStaker() public {
        staking.fundPeriod(86400e8, 1 days);
        vm.warp(block.timestamp + 100);
        vm.prank(ALICE);
        staking.stake(100e6);
        eq(staking.earned(ALICE), 0);
        vm.warp(block.timestamp + 10);
        eq(staking.earned(ALICE), 10e8);
    }

    function testAuthorityAndFixedPeriod() public {
        vm.prank(ALICE);
        vm.expectRevert();
        staking.fundPeriod(86400e8, 1 days);
        staking.fundPeriod(86400e8, 1 days);
        vm.expectRevert(StakingRewards.PeriodActive.selector);
        staking.fundPeriod(86400e8, 1 days);
        vm.warp(block.timestamp + 1 days);
        staking.fundPeriod(86400e8, 1 days);
    }

    function testInvalidActions() public {
        vm.expectRevert(StakingRewards.InvalidInput.selector);
        staking.fundPeriod(1, 1);
        vm.prank(ALICE);
        vm.expectRevert(StakingRewards.InvalidInput.selector);
        staking.withdraw(1, 0);
        vm.prank(ALICE);
        vm.expectRevert(StakingRewards.InvalidInput.selector);
        staking.claim(0);
    }

    function testTaxedStakeAndFunding() public {
        stakeToken.setTax(100);
        reward.setTax(100);
        staking.fundPeriod(86400e8, 1 days);
        eq(staking.rewardRate(), 99e6);
        vm.prank(ALICE);
        staking.stake(100e6);
        eq(staking.balanceOf(ALICE), 99e6);
    }

    function testFuzzRewardSolvency(uint256 raw, uint256 elapsed) public {
        uint256 amount = bound(raw, 1, 100e6);
        elapsed = bound(elapsed, 1, 2 days);
        staking.fundPeriod(86400e8, 1 days);
        vm.prank(ALICE);
        staking.stake(amount);
        vm.warp(block.timestamp + elapsed);
        uint256 owed = staking.earned(ALICE);
        ok(owed <= 86400e8);
        vm.prank(ALICE);
        staking.claim(owed);
        eq(reward.balanceOf(ALICE), owed);
        ok(staking.earned(ALICE) <= 1);
    }
}
