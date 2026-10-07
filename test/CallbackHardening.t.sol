// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken, CallbackToken} from "./helpers/Mocks.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {Vesting} from "../src/Vesting.sol";
import {TokenBridgeLock} from "../src/TokenBridgeLock.sol";
import {ConstantProductAMM} from "../src/ConstantProductAMM.sol";
import {InsurancePool} from "../src/InsurancePool.sol";
import {DAOTreasury, ITreasuryTimelock} from "../src/DAOTreasury.sol";
import {Subscription} from "../src/Subscription.sol";
import {VoteToken} from "./Governor.t.sol";
import {Governor, ITimestampVotes, IGovernanceTimelock} from "../src/Governor.sol";
import {Timelock} from "../src/Timelock.sol";

/// @dev Verify the guard's actual error, rather than accepting an authorization or balance failure.
contract CallbackHardeningTest is TestBase {
    bytes4 private constant REENTRY = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function assertGuard(CallbackToken token) internal view {
        ok(token.blocked());
        eq(uint32(token.callbackError()), uint32(REENTRY));
    }

    function testStakingPrincipalAndRewardCallbacksAreGuarded() public {
        CallbackToken principal = new CallbackToken();
        CallbackToken reward = new CallbackToken();
        StakingRewards staking = new StakingRewards(principal, reward, address(this));
        principal.mint(address(this), 100 ether);
        principal.approve(address(staking), type(uint256).max);
        reward.mint(address(this), 86400 ether);
        reward.approve(address(staking), type(uint256).max);
        principal.configure(address(staking), abi.encodeCall(staking.stake, (1)));
        staking.stake(100 ether);
        assertGuard(principal);
        reward.configure(address(staking), abi.encodeCall(staking.claim, (0)));
        staking.fundPeriod(86400 ether, 1 days);
        assertGuard(reward);
        vm.warp(vm.getBlockTimestamp() + 100);
        staking.claim(100 ether);
        assertGuard(reward);
        staking.withdraw(100 ether, 100 ether);
        assertGuard(principal);
        eq(staking.totalStaked(), 0);
    }

    function testVestingFundingReleaseAndRevocationCallbacksAreGuarded() public {
        CallbackToken token = new CallbackToken();
        Vesting vesting = new Vesting(token, address(this));
        token.mint(address(this), 100 ether);
        token.approve(address(vesting), type(uint256).max);
        token.configure(address(vesting), abi.encodeCall(vesting.release, (0, 0)));
        vesting.create(
            address(this), 100 ether, vm.getBlockTimestamp(), vm.getBlockTimestamp(), 10 days, true
        );
        assertGuard(token);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vesting.release(0, 50 ether);
        assertGuard(token);
        vesting.revoke(0, 50 ether);
        assertGuard(token);
        eq(token.balanceOf(address(vesting)), 0);
    }

    function testBridgeLockAndUnlockCallbacksAreGuarded() public {
        CallbackToken token = new CallbackToken();
        address[] memory relayers = new address[](1);
        relayers[0] = vm.addr(11);
        TokenBridgeLock bridge = new TokenBridgeLock(token, relayers, 1);
        token.mint(address(this), 100 ether);
        token.approve(address(bridge), type(uint256).max);
        token.configure(address(bridge), abi.encodeCall(bridge.lock, (1, bytes32(uint256(1)))));
        bridge.lock(100 ether, bytes32(uint256(1)));
        assertGuard(token);
        bytes32 id = keccak256("callback source");
        bytes32 digest = bridge.unlockDigest(id, address(this), 100 ether, vm.getBlockTimestamp());
        bytes[] memory signatures = new bytes[](1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(11, digest);
        signatures[0] = abi.encodePacked(r, s, v);
        bridge.unlock(id, 100 ether, vm.getBlockTimestamp(), signatures, 100 ether);
        assertGuard(token);
        eq(bridge.nonce(), 1);
        eq(token.balanceOf(address(bridge)), 0);
    }

    function testAMMLiquidityAndSwapCallbacksAreGuarded() public {
        CallbackToken first = new CallbackToken();
        MockToken second = new MockToken(6);
        ConstantProductAMM amm = new ConstantProductAMM(first, second);
        first.mint(address(this), 1000 ether);
        second.mint(address(this), 1000e6);
        first.approve(address(amm), type(uint256).max);
        second.approve(address(amm), type(uint256).max);
        first.configure(address(amm), abi.encodeCall(amm.addLiquidity, (1, 1, 0, vm.getBlockTimestamp())));
        amm.addLiquidity(100 ether, 100e6, 1, vm.getBlockTimestamp());
        assertGuard(first);
        amm.swap(first, 1 ether, 0, vm.getBlockTimestamp());
        assertGuard(first);
        amm.removeLiquidity(amm.balanceOf(address(this)), 0, 0, vm.getBlockTimestamp());
        assertGuard(first);
        eq(amm.totalSupply(), 1000);
    }

    function testInsurancePremiumClaimAndExitCallbacksAreGuarded() public {
        CallbackToken token = new CallbackToken();
        InsurancePool pool = new InsurancePool(token, address(this));
        token.mint(address(this), 100 ether);
        token.approve(address(pool), type(uint256).max);
        token.configure(address(pool), abi.encodeCall(pool.payPremium, (1, 0)));
        pool.payPremium(100 ether, 1);
        assertGuard(token);
        pool.approveClaim(address(this), 10 ether, 0);
        pool.claim(10 ether);
        assertGuard(token);
        pool.requestExit();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        pool.exit(0);
        assertGuard(token);
        eq(pool.totalShares(), 0);
        eq(pool.reservedClaims(), 0);
    }

    function testTreasuryFundingAndSpendingCallbacksAreGuarded() public {
        VoteToken votes = new VoteToken();
        Timelock lock = new Timelock(address(this));
        Governor governor = new Governor(ITimestampVotes(address(votes)), IGovernanceTimelock(address(lock)));
        lock.nominateAdmin(address(governor));
        governor.acceptTimelockAdmin();
        DAOTreasury treasury = new DAOTreasury(address(governor), ITreasuryTimelock(address(lock)));
        CallbackToken token = new CallbackToken();
        token.mint(address(this), 100 ether);
        token.approve(address(treasury), type(uint256).max);
        token.configure(address(treasury), abi.encodeCall(treasury.fundToken, (token, 1)));
        treasury.fundToken(token, 100 ether);
        assertGuard(token);
        vm.prank(address(lock));
        treasury.spendToken(token, ALICE, 100 ether, 100 ether);
        assertGuard(token);
        eq(token.balanceOf(ALICE), 100 ether);
    }

    function testSubscriptionDepositPrincipalAndRevenueCallbacksAreGuarded() public {
        CallbackToken token = new CallbackToken();
        Subscription sub = new Subscription(token, address(this), 10 ether);
        token.mint(address(this), 100 ether);
        token.approve(address(sub), type(uint256).max);
        token.configure(address(sub), abi.encodeCall(sub.deposit, (1)));
        sub.deposit(100 ether);
        assertGuard(token);
        sub.subscribe();
        sub.withdraw(90 ether, 90 ether);
        assertGuard(token);
        sub.withdrawRevenue(10 ether);
        assertGuard(token);
        eq(sub.totalPrepaid(), 0);
        eq(sub.revenue(), 0);
    }
}
