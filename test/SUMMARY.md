# Test extension summary

All changes delivered by this assignment are under `test/`. Existing production contracts, dependencies, project configuration and `docs/` were preserved. The repository contains contracts 1–19; contracts 20–45 have no implementation to test. No dependency installation, fork, FFI or deployment is required.

The suite contains **212 tests**, comprising **194 unit/property tests** (including **24 fuzz tests**) and **18 stateful invariant tests**. This adds **94 tests** to the accepted 118-test baseline. Each fuzz test requests 1,000 runs. Each invariant requests 256 runs at depth 64 with `fail-on-revert = true`, for 294,912 randomized handler calls across the 18 invariant suites per full campaign.

“Complete” below describes the test extension for an existing contract, including failure paths, fuzzing and a handler for stateful value/vote accounting. Coverage boundaries are described in [ANALYSIS.md](ANALYSIS.md). It does not change the implementation status in the existing portfolio documentation.

| # | Contract | Test extension status | Source lines | Direct unit/fuzz tests | Invariants | Main residual risk |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 1 | LendingPool | complete | 206 | 16 | 1 | Oracle price gaps can leave unrecoverable debt |
| 2 | Vault4626 | complete | 192 | 13 | 1 | Claim reservations must stay separate from active shares |
| 3 | StakingRewards | complete | 103 | 11 | 1 | Unfunded or over-counted rewards |
| 4 | Governor | complete | 180 | 9 | 1 | Snapshot voting power must not multiply after transfers |
| 5 | Timelock | complete | 109 | 10 | 1 | Delay bypass or reused operation identifiers |
| 6 | MultiSig | complete | 151 | 8 | 1 | Stale owner confirmations surviving membership changes |
| 7 | DutchAuction | complete | 88 | 8 | 1 | NFT receiver callback can invalidate settlement |
| 8 | NFTMarketplace | complete | 66 | 9 | 1 | Custody and fee-credit double counting |
| 9 | Vesting | complete | 97 | 9 | 1 | Revocation must preserve vested entitlements |
| 10 | Escrow | complete | 101 | 10 | 1 | Settlement replay or timeout races |
| 11 | Raffle | complete | 114 | 10 | 1 | Operator knows entropy and can bias ticket placement |
| 12 | TokenBridgeLock | complete | 80 | 11 | 1 | Relayer compromise permits validly signed theft |
| 13 | PriceOracleAdapter | complete | 40 | 7 | 0 | Stale, incomplete or incorrectly scaled prices |
| 14 | ConstantProductAMM | complete | 109 | 8 | 1 | Swap rounding and reserve/accounting divergence |
| 15 | FlashLender | complete | 75 | 9 | 1 | Borrower callback or underpayment drains capital |
| 16 | InsurancePool | complete | 94 | 9 | 1 | Trusted claim approver socialises losses |
| 17 | Crowdfund | complete | 56 | 8 | 1 | Creator claim and backer refund both paying out |
| 18 | DAOTreasury | complete | 70 | 8 | 1 | Governance allocation reuses reserved ETH |
| 19 | Subscription | complete | 99 | 10 | 1 | Keeper inactivity and repeated billing |
| 20 | PerpetualsLite | not started — implementation absent | 0 | 0 | 0 | Price gaps cause insolvent liquidation |
| 21 | StableSwap2 | not started — implementation absent | 0 | 0 | 0 | Depeg and invariant convergence |
| 22 | RevenueSplitter | not started — implementation absent | 0 | 0 | 0 | Insolvent proportional accounting |
| 23 | Allowlist721 | not started — implementation absent | 0 | 0 | 0 | Merkle proof bypass |
| 24 | RateLimitedMinter | not started — implementation absent | 0 | 0 | 0 | Daily issuance limit bypass |
| 25 | EmergencyPausableRegistry | not started — implementation absent | 0 | 0 | 0 | Guardian/editor privilege misuse |
| 26 | SoulboundBadge | not started — implementation absent | 0 | 0 | 0 | Inherited transfer bypass |
| 27 | Permit2612Token | not started — implementation absent | 0 | 0 | 0 | Permit replay |
| 28 | BatchAirdrop | not started — implementation absent | 0 | 0 | 0 | Claim-index reuse |
| 29 | DCAVault | not started — implementation absent | 0 | 0 | 0 | Keeper slippage |
| 30 | LimitOrderBook | not started — implementation absent | 0 | 0 | 0 | Partial-fill rounding |
| 31 | BondingCurveSale | not started — implementation absent | 0 | 0 | 0 | Unbacked sellback liabilities |
| 32 | ReferralRewards | not started — implementation absent | 0 | 0 | 0 | Self-referral farming |
| 33 | SavingsLock | not started — implementation absent | 0 | 0 | 0 | Penalty payout blocks exit |
| 34 | VotingEscrow | not started — implementation absent | 0 | 0 | 0 | Voting-power history corruption |
| 35 | GaugeController | not started — implementation absent | 0 | 0 | 0 | Epoch over-allocation |
| 36 | NameRegistry | not started — implementation absent | 0 | 0 | 0 | Normalization ambiguity |
| 37 | Tipping | not started — implementation absent | 0 | 0 | 0 | Leaderboard manipulation |
| 38 | LotteryCommitReveal | not started — implementation absent | 0 | 0 | 0 | Last-revealer withholding |
| 39 | WrappedETH | not started — implementation absent | 0 | 0 | 0 | Repeated ETH withdrawal |
| 40 | CreditDelegation | not started — implementation absent | 0 | 0 | 0 | Unauthorized delegated debt |
| 41 | StreamingPayments | not started — implementation absent | 0 | 0 | 0 | Cancellation double counting |
| 42 | BountyBoard | not started — implementation absent | 0 | 0 | 0 | Acceptance/refund race |
| 43 | WhitelistSale | not started — implementation absent | 0 | 0 | 0 | Decimals and sale caps |
| 44 | ProofOfAttendance | not started — implementation absent | 0 | 0 | 0 | Cross-event signature replay |
| 45 | KeeperRegistry | not started — implementation absent | 0 | 0 | 0 | Unfair or repeated slashing |

The table excludes seven additional contract-specific callback tests in `CallbackHardening.t.sol` and four shared token-compatibility tests in `TokenCompatibility.t.sol`; these are included in the overall total. Source lines count the production file including comments and blank lines. Direct tests include the existing accepted tests.

## Verification

`forge build` passed. `forge test` passed: 212 tests across 39 suites, zero failures and zero skips. `git diff --check` and the path-scope check passed. All runs use local token, NFT, feed and callback stand-ins. `test/scratch/` contains only disposable run artifacts and is not needed by any submitted test. No submitted test imports scratch content.

No confirmed implementation defect was found by these added checks. Existing trust/economic limitations remain: oracle failure and bad debt, operator-controlled raffle entropy, relayer honesty, governance control and owner-approved insurance claims. Live Chainlink/feed and unusual real-token integration runs remain owed; they require a separately configured fork environment and are not part of the offline default suite.
