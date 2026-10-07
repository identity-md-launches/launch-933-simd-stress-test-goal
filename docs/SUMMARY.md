# Delivery summary

**19 complete, 0 partial, 26 not started.** Work followed the requested order and stopped before PerpetualsLite so the completed portfolio could be tested and reviewed. No placeholder source/test files are counted as delivered behaviour. “Complete” is scoped to the documented assumptions, including operator-trusted raffle entropy, a simulated bridge, prepaid subscriptions and self-initiated flash loans.

The 118 named tests include one fuzz property for each of the 19 implementations. Lines count physical lines in each named application source (including comments/blank lines); they exclude tests, shared helpers and vendored OpenZeppelin sources. Implemented application lines: 2030. Unstarted risks are prospective design concerns, not findings about nonexistent code.

| # | Contract | Status | Source lines | Tests | Top risk |
|---|---|---|---:|---:|---|
| 1 | [LendingPool](../src/LendingPool.sol) | complete | 206 | 12 | Oracle errors and liquidation-gap bad debt |
| 2 | [Vault4626](../src/Vault4626.sol) | complete | 192 | 9 | Share-price rounding and withdrawal reserve isolation |
| 3 | [StakingRewards](../src/StakingRewards.sol) | complete | 103 | 7 | Funding/index rounding leaves undistributed rewards |
| 4 | [Governor](../src/Governor.sol) | complete | 180 | 6 | Voting-majority capture |
| 5 | [Timelock](../src/Timelock.sol) | complete | 109 | 6 | Malicious administrator after the delay |
| 6 | [MultiSig](../src/MultiSig.sol) | complete | 151 | 6 | Compromised or unavailable owner quorum |
| 7 | [DutchAuction](../src/DutchAuction.sol) | complete | 88 | 5 | Price/order races at the auction floor |
| 8 | [NFTMarketplace](../src/NFTMarketplace.sol) | complete | 66 | 6 | Malicious NFT collections and receivers |
| 9 | [Vesting](../src/Vesting.sol) | complete | 97 | 6 | Owner revocation before the cliff |
| 10 | [Escrow](../src/Escrow.sol) | complete | 101 | 6 | Silent-buyer refund unless seller disputes |
| 11 | [Raffle](../src/Raffle.sol) | complete | 114 | 7 | Operator-known seed can bias ticket selection |
| 12 | [TokenBridgeLock](../src/TokenBridgeLock.sol) | complete | 80 | 5 | Relayer quorum can fabricate unlocks |
| 13 | [PriceOracleAdapter](../src/PriceOracleAdapter.sol) | complete | 40 | 4 | Fresh but economically false feed prices |
| 14 | [ConstantProductAMM](../src/ConstantProductAMM.sol) | complete | 109 | 6 | MEV and LP impermanent loss |
| 15 | [FlashLender](../src/FlashLender.sol) | complete | 75 | 6 | Unsupported token behaviour during repayment |
| 16 | [InsurancePool](../src/InsurancePool.sol) | complete | 94 | 5 | Owner-approved fraudulent claims |
| 17 | [Crowdfund](../src/Crowdfund.sol) | complete | 56 | 5 | Creator fails to deliver the off-chain project |
| 18 | [DAOTreasury](../src/DAOTreasury.sol) | complete | 70 | 5 | Governance capture authorizes malicious spending |
| 19 | [Subscription](../src/Subscription.sol) | complete | 99 | 6 | Keeper inactivity and off-chain service failure |
| 20 | PerpetualsLite | not started | 0 | 0 | Prospective: Insolvent liquidations after price gaps |
| 21 | StableSwap2 | not started | 0 | 0 | Prospective: Invariant convergence under depegs |
| 22 | RevenueSplitter | not started | 0 | 0 | Prospective: Fee-token accounting breaks proportional solvency |
| 23 | Allowlist721 | not started | 0 | 0 | Prospective: Incorrect Merkle leaves bypass mint limits |
| 24 | RateLimitedMinter | not started | 0 | 0 | Prospective: Role rotation bypasses cumulative issuance limits |
| 25 | EmergencyPausableRegistry | not started | 0 | 0 | Prospective: Guardian or editor privilege misuse |
| 26 | SoulboundBadge | not started | 0 | 0 | Prospective: Transfer restriction bypass through an inherited path |
| 27 | Permit2612Token | not started | 0 | 0 | Prospective: Permit domain or nonce replay |
| 28 | BatchAirdrop | not started | 0 | 0 | Prospective: Proof or claim-index reuse drains allocation |
| 29 | DCAVault | not started | 0 | 0 | Prospective: Keeper trades without enforceable slippage limits |
| 30 | LimitOrderBook | not started | 0 | 0 | Prospective: Partial-fill rounding extracts maker collateral |
| 31 | BondingCurveSale | not started | 0 | 0 | Prospective: Sellback reserves fail to cover curve liability |
| 32 | ReferralRewards | not started | 0 | 0 | Prospective: Self-referral farming depletes reward pool |
| 33 | SavingsLock | not started | 0 | 0 | Prospective: Penalty payout blocks principal withdrawal |
| 34 | VotingEscrow | not started | 0 | 0 | Prospective: Historical voting power corrupted by lock changes |
| 35 | GaugeController | not started | 0 | 0 | Prospective: Reused voting power overallocates an epoch |
| 36 | NameRegistry | not started | 0 | 0 | Prospective: Ambiguous name normalization creates spoofed ownership |
| 37 | Tipping | not started | 0 | 0 | Prospective: Leaderboard manipulation or unbounded insertion cost |
| 38 | LotteryCommitReveal | not started | 0 | 0 | Prospective: Last revealer biases XOR by withholding |
| 39 | WrappedETH | not started | 0 | 0 | Prospective: Burn/payment order permits repeated withdrawal |
| 40 | CreditDelegation | not started | 0 | 0 | Prospective: Delegate creates debt against unwilling collateral owner |
| 41 | StreamingPayments | not started | 0 | 0 | Prospective: Cancellation and withdrawal double-count accrued funds |
| 42 | BountyBoard | not started | 0 | 0 | Prospective: Acceptance races an expired bounty refund |
| 43 | WhitelistSale | not started | 0 | 0 | Prospective: Decimals or tax accounting exceed inventory/caps |
| 44 | ProofOfAttendance | not started | 0 | 0 | Prospective: Signature replay across events, recipients or chains |
| 45 | KeeperRegistry | not started | 0 | 0 | Prospective: Ambiguous missed-upkeep evidence enables unfair slashing |

See [ANALYSIS.md](ANALYSIS.md) for each lifecycle, role, deployment assumption and coverage gap, and [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for verification evidence and static-analysis triage. Nothing was deployed.
