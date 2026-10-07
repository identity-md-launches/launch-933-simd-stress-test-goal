# Contributor security review

This review covers the 19 implemented application contracts and two shared helpers. It is the implementing contributor's adversarial review, not an independent audit. The 26 unstarted contracts have no security conclusion. No deployment, broadcast, funded wallet access or frontend was attempted.

## Verification evidence

Toolchain: Foundry 1.8.3, Solidity 0.8.26, optimizer 200 runs, Paris EVM. Local verification completed with:

```sh
forge build
forge test --fuzz-runs 1024 --threads 4
forge fmt --check
slither . --filter-paths 'lib/|test/'
```

The Foundry suite contains **118 tests in 19 suites**, with zero failures or skips in the recorded full run. All 19 applications have a fuzz property, for **19,456 generated cases** in the 1,024-run check. Tests have fresh fixtures and do not use environment variables, FFI, RPCs or filesystem cheatcodes. Build and format checks pass. Slither **0.11.6** analyzed application paths, with libraries and test fixtures excluded from reported findings, not excluded from dependency compilation. Its result is **0 high, 11 medium, 43 low and 9 informational findings**. Slither returns a nonzero exit status when findings exist; it did not return a clean/no-findings result. No detector suppression or exclusion of application contracts was added. Mythril, formal verification and an independent human audit were not run.

Foundry's built-in lint also emits warnings. They are not compiler failures and were reviewed separately below. A passing build or test suite is evidence about the exercised cases, not proof of security.

## Prior rejection and concrete repairs

1. **Arbitrary ERC20 source removed structurally.** `TokenIO.pull` has only token/amount parameters and calls `safeTransferFrom(msg.sender, address(this), amount)`. There is no victim/source parameter. Repayment on another borrower's behalf still spends only the payer's funds. Keeper subscription renewals debit explicit prepaid credit, never a user's wallet allowance. Flash borrowing requires receiver equal to caller. The regression test grants BOB an allowance and confirms CAROL cannot debit it through supply.
2. **Timelock execution consumes stored authorization.** `execute(bytes32)` accepts no destination, amount or calldata. Only admin or an already authorized self-call can execute; readiness and one-time state are checked before using the stored call. Tests cover unauthorized calls, the full delay, retry after failure and replay. The authorized arbitrary target is an intended governance capability, not permissionless arbitrary ETH sending.
3. **Measured transfers and shared locks.** Every entry point using the token helper holds its application's reentrancy guard. Net inbound credits can only be calculated after transfer; the lock spans that measurement and state update. Outbound balance/share/claim effects precede transfer. Callback tests attempt lending interest accrual, queue processing, NFT cancellation, repeated ETH withdrawal and nested flash borrowing. None succeeds.
4. **Flash repayment reasoning simplified.** Exact principal is sent only to the borrower-caller; the callback must return the standard magic; measured caller repayment must cover principal plus the rounded-up fee. Repayment no longer uses a pre-callback balance as a post-callback condition. Unsupported rebases and sender surcharges remain explicit token assumptions. For supported tokens, exact principal debit and measured repayment imply ending assets increase by at least the fee.
5. **Lending fractional-interest loss repaired.** Each checkpoint carries the remainder from full-precision interest division, including repeated checkpoints too small to accrue a full raw token unit individually. The regression accumulates 100 such checkpoints. Carry is at most one unit because both fractional terms are below the denominator. This is deterministic financial arithmetic, never randomness.
6. **Oracle-free debt-free exit.** A borrower with no debt can retrieve collateral even if the oracle returns an invalid price. Debt-bearing removal still checks LTV. A regression sets price to zero and verifies the debt-free exit.
7. **Other review repairs.** Local variables now initialize explicitly; Governor records a hash of execution return data; the adapter checks feed start/update ordering as well as age. NonReentrant is the first modifier on value-moving admin methods. Existing events and safety checks were retained rather than silencing analyzers.

## Slither finding triage

All 11 medium findings are `incorrect-equality`. They identify numeric zero checks, not assertions that a contract's ETH/token balance must exactly equal some expected balance. A direct donation cannot bypass these guards or deadlock a valid positive entitlement. The exact checks were retained because their intent is explicit.

| Location | Reported equality and review |
|---|---|
| `TokenIO.pull` | Reject zero net receipts; a receipt above the requested amount is also rejected. |
| `LendingPool.supply` | Reject zero minted shares and enforce minimum shares. Prevents a zero-share deposit loss. |
| `LendingPool._repay` (two findings) | Reject zero shares burned; clear fractional interest only after all debt shares have been extinguished. Neither comparison uses a raw donation-sensitive token balance. |
| `Vault4626.depositReceived` | Reject zero shares, enforce minimum and forbid the vault as receiver. |
| `Vault4626._deposit` | Authenticate caller, reject zero asset/share inputs and disallow self-receiver deposits. |
| `Vault4626._withdraw` | Reject zero share burns; a nonzero dust share redemption may return zero assets. |
| `StakingRewards.claim` | Reject a zero accrued reward claim. |
| `Vesting.release` | Reject release when no newly vested amount is available. |
| `InsurancePool.payPremium` | Reject zero shares/minimum-share failure after measured premium receipt. |
| `Governor.propose` | Reject a proposer with zero historical delegated voting power. |

The 43 low findings are timestamp uses. Time determines interest, reward accrual, auction prices and protocol deadlines, never entropy. Hour/day-scale windows limit slight validator skew; integrations must avoid assuming exact-second fairness. No protection against transaction censorship is claimed.

Nine informational findings concern inherited dead code (2), intentional low-level ETH/call execution (3), interface-shaped implementations without explicit interface inheritance (3), and a conventional uppercase clock-mode method (1). Timelock/MultiSig calls are authorized and effects precede calls; ETH credit withdrawal sends only the caller's consumed entitlement. The Governor clock interface and borrower interfaces are deliberately local, permitting application source independence.

## Foundry lint review

- **Arbitrary ETH/reentrancy:** Timelock and MultiSig send only a stored approved call. `EthCredits` sends only the caller's credited balance. The linter reports OpenZeppelin `_status` reset after external calls, while the same modifier sets the entered state before the function body. The post-body reset is not an unlocked callback window. Explicit callback tests substantiate this distinction.
- **Events after calls:** Measured inbound receipts cannot be emitted until they are known. The enclosing guard prevents application reentry; events describe finalized amounts. These calls do not grant arbitrary-token trust or promise protection against dishonest `balanceOf` results.
- **Missing access-control events:** `Governor.cancel`, `MultiSig.revoke`, and `Subscription.cancel` immediately emit `Cancelled`, `Revoked`, and `Cancelled`, respectively, including the proposal/account identity. These are heuristic misses.
- **Address/type checks:** DAOTreasury requires nonempty code for both governance dependencies, which rejects zero addresses. Oracle signed-to-unsigned conversion is dominated by `answer > 0`, so it cannot turn a negative answer into a huge price.
- **Reverts in bounded loops:** Relayer/owner validation deliberately reverts on invalid input. At most 32 entries are processed, and threshold signatures have a fixed bounded length.
- **Test timestamp mutation warnings:** Test fixtures intentionally warp time around protocol boundaries. All executed assertions pass under the pinned compiler/settings. The tests do not read or mutate process environment state.

## Economic and operational limits left explicit

| Area | Residual risk / operational responsibility |
|---|---|
| Lending | Validate feed direction and freshness; run liquidators; market gaps can create bad debt with no writeoff or backstop. |
| Vault | Arrange external yield funding and queue processing. No investment strategy exists; redemption queue is optional, not a mandatory delay on standard ERC4626 withdrawals. |
| Governance/multisig | Protect voting/owner keys and inspect call data. A legitimate malicious quorum can spend funds; no guardian veto exists. |
| Raffle | Operator knows the seed and can bias participation. Bonded commit/reveal is not a fairness proof or VRF. |
| Bridge | Relayer quorum has custody-equivalent power and must assign source identifiers uniquely. No source-chain verification or relayer rotation is supplied. |
| Oracle | Freshness checks cannot detect a fresh false quote; L2 sequencer checks and market-specific sanity bounds remain deployment requirements. |
| AMM | LPs accept depeg/impermanent loss; traders must set slippage and deadlines. Donated excess reserves have no recovery path. |
| Insurance | Claim owner decides legitimacy; 5x coverage is not an actuarial solvency guarantee. Losses reduce share value. |
| Escrow | Seller must dispute a silent buyer before review expiry; unresolved arbitration defaults to buyer refund. |
| Subscription | Keeper availability and off-chain service delivery are not guaranteed. Only prepaid balances can be renewed. |
| Asset integrations | Receiver taxes are supported where documented. Rebases, sender surcharges, confiscations, lying balances and future token upgrades can invalidate accounting assumptions. |
| ETH recipients | A contract rejecting ETH retains its own credit indefinitely; no admin can redirect another recipient's claim. |

## Reproducible dependencies and boundary checks

OpenZeppelin sources were copied as ordinary files from the `@openzeppelin/contracts` **5.1.0** npm archive, including their transitive Solidity imports. Archive SHA-256: `fcddd83ee65457e2dd40d207010c885b45cdf6ea2360ca8c9d4cf2cca5e2b3b2`. The matching upstream MIT license is included in `lib/openzeppelin-contracts/LICENSE`. No compiler binaries, node_modules, git submodules or remote imports are dependencies of the delivered project. Test-only analyzer installation and intermediate logs stayed under `/tmp`.

Source inspection found no application `tx.origin`, `delegatecall`, `selfdestruct`, FFI, filesystem cheatcode or environment-variable test use. Application data arrays are bounded at 16 KiB for governance/multisig/flash calls, and owner/relayer sets are capped at 32. Queue settlement and payout operations process one entry/account at a time. The user-controlled NFT and ERC20 implementations remain external trust boundaries, not proof obligations discharged by using SafeERC20.
