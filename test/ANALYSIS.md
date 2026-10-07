# Test hardening analysis

This report describes the test-only extension. The accepted production design and full role/security documentation remain in `docs/ANALYSIS.md`; no production implementation was modified. The sections follow the assigned order. The tests do not assert known economic trust limitations as safe behavior. No confirmed implementation defect requiring a findings report was reproduced.

## Harness and coverage boundaries

Each stateful contract has a separate handler and invariant test contract. Foundry targets only that handler. Inputs are bounded, actors are fixed to three addresses, and time advances monotonically. Test-side timestamp reads use `vm.getBlockTimestamp()` so the optimizer cannot reuse a cached read across `vm.warp`. Expected rejected protocol calls are caught so random sequences continue; any unhandled handler revert fails the campaign. The Timelock target callback is explicitly excluded from direct random dispatch. Ghost inflow/outflow counters update only after successful operations. Operations that create growing collections are capped at 32 except the vault queue, which is bounded by sequence depth. Assertions inspect liabilities and independent receipts, not just matching getters.

Inline settings travel with the submission: 1,000 iterations per fuzz test; 256 invariant runs, 64 calls per run, and fail-on-revert enabled. Mock tokens use mixed precisions and optional receiver taxes. Callback tests check the exact ReentrancyGuard error. Additional shared token-compatibility tests exercise empty ERC20 return data, false return values and pausing, including rollback of transfers that mutated balances before returning false. No external URL, environment mutation, fork, FFI, downloaded dependency or scratch file is needed.

## 1. LendingPool

**Status: complete — test extension for the existing implementation.**

Suppliers lend one token while borrowers pledge a different token. A price feed limits borrowing and permits liquidation with a bonus when a position becomes unsafe.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Suppliers control their supply shares; borrowers control collateral and debt; third parties may repay or liquidate; there is no administrator in the lending market. |

**Lifecycle.** Supply creates claims; collateral enables borrowing; accrual increases debt; repayment and liquidation reduce debt; withdrawals burn supply shares subject to cash availability.

**Risks and test evidence.**

- **Over-borrowing or removing backing.** Borrowing over the 75% limit and collateral removal below the limit revert. Healthy positions cannot be liquidated.
- **Cash unavailable despite positive assets.** A supplier attempting a full withdrawal while funds are lent out receives InsufficientLiquidity; their shares are unchanged.
- **Rounding and repeat accrual.** Fuzz round trips conserve cash, fractional interest survives repeated accrual, and the handler reconciles debt assets plus repayments to borrowing plus accrued interest. The sum of three rounded debts is at most two units above aggregate debt.
- **Transfer tax or output slippage.** Taxed supply, collateral and repayment use receipts; rejected supply and borrow minima restore balances, debt and shares.
- **Callback reentrancy or third-party allowance theft.** Existing callback coverage blocks nested accrual during supply; callers cannot debit another token approver. Random calls reconcile collateral, supply shares and debt shares across three actors.

**Coverage and trust limits.** The handler varies price, time, supply, withdrawal, collateral, borrowing, repayment and liquidation. It uses untaxed 6-decimal loan and 8-decimal collateral tokens. It does not model oracle freshness, adversarial rebases, sender surcharges or extreme price gaps producing bad debt. There is no proof that arbitrary bad debt can be recovered.

**Gas note.** Liquidation performs debt accrual, oracle reads, two token transfers and multiple position updates. This is a structural observation, not a production gas benchmark.

**Files.** `LendingPool.t.sol` and `LendingPool.invariant.t.sol`.

## 2. Vault4626

**Status: complete — test extension for the existing implementation.**

Depositors own shares in donated yield. They can redeem immediately or escrow shares in a one-day FIFO queue, then pull assets reserved by the processor.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | The owner sets the cap and uses two-step ownership transfer. Shareholders deposit, redeem, transfer, queue and cancel their own shares. Anyone processes the queue; claimants withdraw only their own reserved assets. |

**Lifecycle.** Deposits mint live shares; requests escrow shares; cancellation returns them; processing burns escrowed shares and reserves assets; claiming consumes only the reservation.

**Risks and test evidence.**

- **Depositing over capacity.** Deposits exceeding the cap revert; reducing the cap to zero still permits existing shareholders to redeem.
- **Queue theft or phantom entries.** A caller without shares cannot create a request; an unauthorized or repeated cancellation fails. The handler sums live queue entries and compares them with vault-held shares.
- **Claim reserves spent by live shares.** Reservations equal the sum of actor claim balances, are excluded from totalAssets and remain backed after immediate redemptions.
- **Rounding extraction and donation attack.** Fuzzed deposit/redeem round trips cannot profit from rounding. Existing tests cover virtual-share donation protection and upward withdrawal/mint rounding.
- **Tax, failed claim or reentrancy.** Rejected taxed deposits and claims leave custody and entitlements intact, claims can retry at a net minimum, and callbacks cannot process the queue during a deposit.

**Coverage and trust limits.** The handler randomizes deposits, donations, share transfers, requests, cancellations, processing, claims and immediate redemptions. Its three actors transfer only among themselves. Direct accidental share transfers to the vault, rebasing assets and real strategies are outside coverage. Yield is a donation, not an external strategy return.

**Gas note.** Deposit/mint and queue request create token/share storage entries; processing updates the FIFO, share supply and claim reservation. This is a structural observation, not a production gas benchmark.

**Files.** `Vault4626.t.sol` and `Vault4626.invariant.t.sol`.

## 3. StakingRewards

**Status: complete — test extension for the existing implementation.**

Users keep ownership of staking principal and earn a separately funded reward token during fixed periods. The owner must fund each new reward schedule.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | The owner funds periods after the previous period ends. Stakers deposit, withdraw their own principal and claim their own rewards; the owner has no tested principal extraction path. |

**Lifecycle.** Funding starts a schedule; staking checkpoints rewards; time accumulates rewards up to periodFinish; withdrawal preserves earned rewards; later funding starts another schedule without erasing unpaid rewards.

**Risks and test evidence.**

- **Underfunded schedule.** Funding that rounds to a zero reward rate reverts and returns the attempted funding. Invalid duration and active-period replacement are rejected.
- **Idle emissions captured by first staker.** Existing tests prove time with no stake is not credited retroactively to a later arrival.
- **Lost rewards across withdrawal or period rollover.** Full withdrawal preserves earned rewards, and a new period leaves old unpaid rewards available.
- **Reward insolvency.** The randomized three-actor handler checks accrued rewards plus all remaining scheduled emissions against held rewards. Paid rewards plus custody equal lifetime funding.
- **Token callbacks and taxes.** Receipt-based taxed staking/funding are retained; failed output minima restore principal and rewards. Callback tests verify the exact guard error during stake, funding, claim and withdrawal.

**Coverage and trust limits.** The handler varies stake, partial withdrawal, claims, funding and time over multiple periods using 6- and 8-decimal tokens. It does not randomize token taxes, ownership transfer or hostile token supply changes. Rounding dust is permitted only when it stays in the funded reward reserve.

**Gas note.** First-time staking and funding update multiple reward checkpoints and execute transferFrom. This is a structural observation, not a production gas benchmark.

**Files.** `StakingRewards.t.sol` and `StakingRewards.invariant.t.sol`.

## 4. Governor

**Status: complete — test extension for the existing implementation.**

Delegated token holders propose and vote on a single immutable call. A successful proposal must meet 4% historical quorum and pass through a timelock before execution.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Holders with prior-second voting power propose. Snapshot holders vote once. Anyone queues or executes eligible proposals. Only the proposer cancels during the initial delay. |

**Lifecycle.** Pending lasts through the snapshot timestamp; voting is active through the deadline; success depends on support and quorum; queue and execute advance successful proposals; cancellation is terminal.

**Risks and test evidence.**

- **Voting before or after the window.** Exact snapshot, snapshot-plus-one, deadline and deadline-plus-one tests establish the voting and queuing boundaries.
- **Power reused after transfer or delegation.** Existing tests preserve historical weight after a transfer. Random transfers, delegations and votes cannot make proposal tallies exceed historical total supply.
- **Quorum rounded down for small supplies.** A 1,000-run property proves quorum is the smallest whole unit satisfying 4%, including very small total supplies.
- **Invalid or unauthorized proposals.** No-vote callers, zero targets, oversized calldata and unknown proposal IDs are rejected. Invalid support and duplicate votes do not change accepted tallies.
- **Cancelled/executed proposal replay.** The handler records terminal states and matches execution count to executed proposals; queued proposals cannot be queued or cancelled again.

**Coverage and trust limits.** The random handler uses the timestamp-voting token and an executor stand-in, caps proposal creation at 32, and does not mint after setup. Existing Timelock and DAOTreasury unit tests cover real execution integration. Random governance calls do not prove resistance to vote buying, flash voting power acquired before the snapshot or malicious governance decisions.

**Gas note.** Propose stores a dynamic call payload and the proposal metadata. This is a structural observation, not a production gas benchmark.

**Files.** `Governor.t.sol` and `Governor.invariant.t.sol`.

## 5. Timelock

**Status: complete — test extension for the existing implementation.**

An administrator queues exact calls and can execute them after two days or cancel them permanently. Administration changes require nomination and acceptance.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | The admin or a queued self-call may queue, execute, cancel and nominate. Only the nominated successor accepts. Depositing ETH grants no authority. |

**Lifecycle.** A unique operation is queued with a fixed readyAt; it becomes executable at that time and ends as done or cancelled. Failed target calls roll execution back so the same operation can retry.

**Risks and test evidence.**

- **Delay bypass.** The suite rejects execution one second before readiness and accepts it at the exact readiness timestamp. Random successful calls check the stored delay.
- **Cancelled or completed IDs reused.** Both terminal states reject execution and salt reuse; random operation flags agree with independent ghost records.
- **Non-admin spending.** Unauthorized queue, cancellation and execution are rejected; the handler actively attempts non-admin execution.
- **Target revert destroys retryability.** Failed target execution preserves the done flag and funding, and a later successful retry executes the authorized payload.
- **Handover hijack.** Unauthorized acceptance and acceptance by a replaced nominee fail; the old admin loses authority after the new nominee accepts.

**Coverage and trust limits.** The handler queues up to 32 value-bearing operations, advances time, toggles target failure, cancels and executes, and reconciles ETH with actual successful spending. The callback-only target entry point is excluded from fuzz dispatch so tests exercise it through Timelock. Random admin handovers and arbitrary hostile calldata are not modeled.

**Gas note.** Queue stores dynamic calldata; execution gas is dominated by the authorized target. This is a structural observation, not a production gas benchmark.

**Files.** `Timelock.t.sol` and `Timelock.invariant.t.sol`.

## 6. MultiSig

**Status: complete — test extension for the existing implementation.**

A bounded group of owners confirms transactions. Execution requires enough current confirmations, and owner/threshold changes must themselves be approved wallet calls.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Owners submit, confirm and revoke. Anyone executes approved calls. Only the wallet itself changes owners or threshold; these changes invalidate outstanding transactions by epoch. |

**Lifecycle.** Submission starts unconfirmed; confirmations accumulate and may be revoked; threshold approval permits one execution. Owner changes move the epoch, invalidating old unexecuted transactions.

**Risks and test evidence.**

- **Invalid initial owner set.** Duplicate or zero owners and thresholds of zero or greater than owner count are rejected.
- **Unapproved spend or replay.** Unit tests reject insufficient confirmations and repeated execution; the handler checks approval before successful spending and reconciles ETH.
- **Duplicate confirmation and unauthorized revocation.** An owner cannot confirm twice; an unconfirmed owner cannot revoke another owner's vote. Random stored confirmation counts equal the three independent owner flags.
- **Direct membership/threshold edits.** External owner calls to administrative functions fail; only approved self-calls can change them.
- **Stale approvals after owner changes or failed calls.** Unit tests cover adding/removing owners and epoch invalidation. The random handler changes threshold through approved self-calls; failed execution preserves confirmations and the unexecuted state.

**Coverage and trust limits.** The random handler caps transactions at 32 and uses three fixed owners, plus approved threshold changes. Membership additions/removals are deterministic tests, not random actions. Compromised owners meeting the threshold are authorized to spend; the suite does not treat that trust assumption as a prevented attack.

**Gas note.** Submit stores dynamic calldata; execution cost depends on the selected target. This is a structural observation, not a production gas benchmark.

**Files.** `MultiSig.t.sol` and `MultiSig.invariant.t.sol`.

## 7. DutchAuction

**Status: complete — test extension for the existing implementation.**

The seller escrows one NFT. Its price declines linearly to a floor, and the first acceptable buyer receives it while proceeds and excess ETH become withdrawable credits.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | The seller activates and eventually cancels. Buyers choose recipient, maximum price and deadline. Credit owners pull only their own payments. |

**Lifecycle.** Created becomes Active through custody transfer; Active becomes Sold on purchase or Cancelled once the floor time is reached. Terminal states cannot reactivate.

**Risks and test evidence.**

- **Price underflow or incorrect decline.** Fuzzed time changes prove the price is monotonic and stays between start and floor prices.
- **Underpayment, stale deadline or price slippage.** Invalid purchase parameters revert before irreversible settlement; NFT custody and credits remain untouched.
- **Bad NFT recipient callback.** A recipient without ERC721 receiver support causes the sale to roll back, restoring state, custody and ETH accounting.
- **Second sale or early cancellation.** Duplicate purchase, repeated activation, early cancellation and non-seller cancellation are rejected.
- **Overpayment lost or multiple payouts.** The handler reconciles incoming ETH and withdrawals, sums buyer/seller credits and tracks final NFT ownership across buy/cancel/withdraw sequences.

**Coverage and trust limits.** The handler uses a standard local NFT and three buyers, random overpayment, time and seller cancellation. Hostile NFT collections, seller key compromise and transaction ordering effects remain outside randomized coverage. Pull refunds are supported; buyers must initiate their own withdrawal.

**Gas note.** Buy updates credits and performs a safe NFT transfer with an external receiver callback. This is a structural observation, not a production gas benchmark.

**Files.** `DutchAuction.t.sol` and `DutchAuction.invariant.t.sol`.

## 8. NFTMarketplace

**Status: complete — test extension for the existing implementation.**

A seller escrows an NFT for a fixed ETH price. A sale allocates 2.5% to the treasury and the rest to the seller; each payee withdraws independently.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | NFT owners list approved assets and cancel their own live listings. Buyers pay exactly the listed price. Seller and treasury credits have separate pull withdrawals. |

**Lifecycle.** Listing transfers custody and creates an active entry; buying or seller cancellation ends the entry permanently; credit withdrawal does not reopen it.

**Risks and test evidence.**

- **No approval or zero-price phantom listings.** Failed escrow transfer and zero price leave the listing counter and NFT ownership unchanged.
- **Unauthorized cancel or stale purchase.** Non-sellers cannot cancel, and cancelled or sold listings cannot be purchased again.
- **Wrong ETH amount.** Overpayment and underpayment are rejected, preventing ambiguous sale/refund accounting.
- **Receiver rejection or callback reentry.** Rejected NFT receiver calls restore the active listing and credits. Existing tests block callback reentry and let a rejecting seller accrue payment without blocking the sale.
- **Fee rounding or credit insolvency.** Fuzzed fee allocation conserves exact sale revenue; random listings, buys, cancels and withdrawals reconcile ETH, custody and terminal owners.

**Coverage and trust limits.** The random handler caps listings at 32 and creates independent NFTs; it does not relist transferred NFTs or test nonstandard collection behavior. Forced ETH is outside its equality model. Callback and failed ETH receiver cases are separate deterministic tests.

**Gas note.** List creates a multi-field listing and transfers custody; buy performs the receiver callback and credit writes. This is a structural observation, not a production gas benchmark.

**Files.** `NFTMarketplace.t.sol` and `NFTMarketplace.invariant.t.sol`.

## 9. Vesting

**Status: complete — test extension for the existing implementation.**

An owner funds independent linear token grants. Beneficiaries receive nothing before a cliff, and revocation returns only the part not yet vested.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | The owner creates and revokes revocable grants. Only the beneficiary releases vested tokens. Two-step ownership operations retain OpenZeppelin semantics. |

**Lifecycle.** A funded grant accrues after its cliff until its end; release consumes accrued entitlement; revocation permanently freezes vested entitlement and returns the rest.

**Risks and test evidence.**

- **Invalid timing or unfunded grant.** Zero duration, invalid cliff, disallowed beneficiary and zero amount fail without advancing grant count or spending owner funding.
- **Early or unauthorized release.** Pre-cliff and non-beneficiary release fail; beneficiaries cannot release the same accrued amount twice.
- **Revocation takes vested tokens.** Tests preserve vested claims at revocation and return only unvested funding, including before-cliff and fully vested boundaries.
- **Taxed outputs destroy entitlements.** Rejected output minima roll back both released amount and revocation status; a lower net minimum can retry both operations.
- **Multiple grants, callbacks or over-release.** Random grants, releases, revocations and time reconcile each outstanding obligation to custody. Frozen grants never accrue further; funding/release/refund callbacks return the guard error.

**Coverage and trust limits.** The handler has three beneficiaries and at most 32 grants, with no random ownership changes or token taxes. Separate unit tests cover taxed inputs/outputs. Insolvency from rebases or token-side confiscation is not prevented by these properties.

**Gas note.** Create initializes many grant fields and pulls funding. This is a structural observation, not a production gas benchmark.

**Files.** `Vesting.t.sol` and `Vesting.invariant.t.sol`.

## 10. Escrow

**Status: complete — test extension for the existing implementation.**

One buyer deposits an agreed ETH price. The seller records delivery; the buyer accepts, either party disputes, or a timed refund ends an unresolved agreement.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Only the buyer deposits and releases. Only the seller delivers. Either party disputes. Only the arbiter resolves. Anyone triggers an eligible timeout; settlement recipients pull credits. |

**Lifecycle.** AwaitingDeposit becomes Funded, then Delivered or Disputed. Release, arbitration or timeout moves to Settled. Review/arbitration transitions establish their own bounded refund deadlines.

**Risks and test evidence.**

- **Wrong deposit or duplicate funding.** Only the exact price is accepted and a second deposit fails without increasing held value.
- **Unauthorized lifecycle actions.** Unauthorized delivery and arbitration fail; the random handler also varies callers across lifecycle methods.
- **Oversized arbitration allocation.** A refund above the escrow amount fails without ending the dispute; the arbiter can retry with a valid split.
- **Deadline boundary manipulation.** At the exact delivery deadline, delivery and new dispute fail and timeout succeeds. Existing tests cover unresolved delivered/disputed timeouts.
- **Repeated settlement or payout.** Random release, resolve, timeout and withdrawal sequences conserve the single deposit and prove the settled state stays closed. The arbiter never receives settlement credits.

**Coverage and trust limits.** The three actors are distinct funded EOAs; failed/reentrant ETH receivers are tested through other contracts sharing EthCredits. The suite does not resolve the off-chain truth of delivery or prevent a malicious arbiter choosing any permitted split. Timeout transaction ordering remains part of the published lifecycle.

**Gas note.** Settlement updates lifecycle and two credit balances; withdrawal invokes the receiver. This is a structural observation, not a production gas benchmark.

**Files.** `Escrow.t.sol` and `Escrow.invariant.t.sol`.

## 11. Raffle

**Status: complete — test extension for the existing implementation.**

An operator commits a seed before selling tickets and posts a forfeitable bond. Timely reveal pays one ticket holder; failure to reveal lets tickets share the bond and receive refunds.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | The operator opens and reveals. Buyers purchase tickets. Anyone expires a missed reveal. Ticket holders request refunds; credit holders withdraw prizes, bond and refunds. |

**Lifecycle.** Created becomes Open; sales stop at saleEnd; reveal is allowed until revealEnd; Drawn or Expired ends the round. Expired holders convert tickets to credits once.

**Risks and test evidence.**

- **Missing commitment or insufficient bond.** Invalid commitments, insufficient funding and unauthorized open fail without changing initial state or retaining ETH.
- **Bad seed or wrong reveal time.** Wrong, early, late and unauthorized reveals fail without choosing a winner or allocating the bond.
- **Ticket cap or incorrect payment.** Late tickets, cap overflow and wrong payment revert; random buying cannot exceed maximum tickets.
- **Repeated refund, draw or expired transition.** Duplicate refund and terminal-state transitions fail. Random round transitions remain terminal and unreclaimed refunds are included in the solvency check.
- **Failed or reentrant prize withdrawal.** Existing tests restore rejected recipient claims and block repeated callback withdrawal. Bond, prizes and outstanding ticket refunds reconcile to held ETH.

**Coverage and trust limits.** The handler randomizes tickets, reveal validity, expiry, refunds, withdrawals and time. The operator already knows the seed: it can arrange ticket positions or choose participation strategically. Tests establish financial conservation, not unbiased randomness. That economic limitation is already documented and is not asserted as secure.

**Gas note.** Ticket buying creates ticket-owner storage; reveal allocates credits in constant time without looping over buyers. This is a structural observation, not a production gas benchmark.

**Files.** `Raffle.t.sol` and `Raffle.invariant.t.sol`.

## 12. TokenBridgeLock

**Status: complete — test extension for the existing implementation.**

Users lock tokens and receive a local event nonce. A recipient later presents an EIP712 authorization signed by a threshold of distinct relayers to release custody.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Anyone locks their own funds. Immutable relayers authorize releases off-chain; recipients submit their own signed claims. There is no admin relayer rotation or real cross-chain verification. |

**Lifecycle.** Each successful lock increments nonce; each successful unlock permanently marks its source ID processed. Failed signature, liquidity or minimum-output checks leave the ID retryable.

**Risks and test evidence.**

- **Signature duplication or ordering.** Duplicate, unsorted and incorrectly counted signatures fail; the handler attempts duplicate signatures and records any improper success.
- **Recipient, amount or domain changed.** Wrong recipient, altered amount, another contract and another chain all invalidate previously obtained signatures.
- **Source replay or expired authorization.** Used source IDs and expired signatures cannot release tokens again; randomized processed flags equal ghost source records.
- **Insufficient liquidity or taxed output.** Failed liquidity and output minimum checks preserve source IDs and custody; adding funding or choosing a valid net minimum allows retry.
- **Wrong lock destination or callback reentry.** Zero destination fails without nonce advancement, net receipts are emitted for taxed locks, and lock/unlock token callbacks return the exact guard error.

**Coverage and trust limits.** The handler uses a sorted two-of-two relayer set and 32 source IDs. It conserves locked/unlocked amounts across three recipients. Authorized but dishonest relayers can drain custody; signature validity does not prove a remote event occurred. Live bridge infrastructure and relay availability are deliberately absent.

**Gas note.** Unlock verifies a bounded threshold-sized signature list and performs an external token transfer. This is a structural observation, not a production gas benchmark.

**Files.** `TokenBridgeLock.t.sol` and `TokenBridgeLock.invariant.t.sol`.

## 13. PriceOracleAdapter

**Status: complete — test extension for the existing implementation.**

The adapter converts a Chainlink-style feed answer to an 18-decimal price only when the answer and round timestamps are valid and no more than one hour old.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | There are no administrators or mutating price methods; deployment selects an immutable feed. Anyone reads the normalized price. |

**Lifecycle.** A read either returns a fresh completed positive price or reverts; the adapter itself has no accumulating balance or lifecycle state.

**Risks and test evidence.**

- **Stale data accepted.** Exact one-hour data is accepted and one-hour-plus-one is rejected. A 1,000-run stale-age property covers a broad stale range.
- **Non-positive answers.** Zero and negative answers fail instead of being cast into large unsigned values.
- **Future, missing or incomplete update.** Future updates, zero timestamps and answeredInRound below round are rejected.
- **Decimal normalization or rounding inflation.** Fuzzing spans every supported precision from 0 to 36 and proves the result is the mathematical floor. Results smaller than one output unit are rejected.
- **Invalid feed configuration.** An address without code and precision above 36 cannot be selected. Local feeds reproduce documented return data without requiring network access.

**Coverage and trust limits.** There is no invariant handler because the adapter holds neither value nor votes nor mutable accounting. The local feed does not reproduce every external feed anomaly, including arbitrary feed reverts or timestamp-start/round-zero combinations. Real feed availability, sequencer downtime and economic price correctness remain unverified and need deployment-specific integration coverage.

**Gas note.** Price is a read call dominated by the feed invocation and normalization arithmetic. This is a structural observation, not a production gas benchmark.

**Files.** `PriceOracleAdapter.t.sol`.

## 14. ConstantProductAMM

**Status: complete — test extension for the existing implementation.**

Users provide two tokens for LP shares and trade against tracked reserves with a 0.3% input fee. A minimum initial share balance stays permanently burned.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Anyone supplies liquidity, swaps or redeems only their own LP shares. There is no privileged pool administrator. |

**Lifecycle.** Initial liquidity burns 1,000 shares and starts reserves; later deposits mint proportional shares; swaps update reserves; removal burns user shares while minimum shares remain.

**Risks and test evidence.**

- **Insufficient initial seed or empty swap.** A root equal to minimum liquidity and swaps before initial liquidity fail without retaining input tokens.
- **Product reduced by swap rounding.** Per-swap fuzzing and random swaps in both directions ensure the tracked reserve product never decreases on successful swaps.
- **Slippage consumes funds or LP shares.** Rejected output minima restore reserves and input/output balances; rejected removal minima preserve LP shares.
- **Donation stolen through accounting.** Random donations are tracked separately from reserves; actual balances equal reserves plus cumulative donations. Existing liquidity tests limit donation recovery by a later depositor.
- **Transfer tax, reserve divergence or callbacks.** Mixed 6/8-decimal and taxed swaps are covered; aggregate shares equal the three actors plus burned shares. Liquidity and swap callbacks return the guard error.

**Coverage and trust limits.** The random handler varies add/remove, bidirectional swaps, LP transfers and donations with untaxed tokens. Taxes are deterministic integration cases. Extreme reserve limits, malicious rebases, sandwich economics and price discovery are not established by the product invariant.

**Gas note.** Initial addLiquidity computes a square root and initializes reserves and minimum liquidity; swaps perform two transfers. This is a structural observation, not a production gas benchmark.

**Files.** `ConstantProductAMM.t.sol` and `ConstantProductAMM.invariant.t.sol`.

## 15. FlashLender

**Status: complete — test extension for the existing implementation.**

The owner makes token capital available for atomic flash borrowing. A borrower must repay principal and a rounded-up 0.09% fee before the loan returns.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Anyone funds liquidity. The owner withdraws idle capital. A borrower must call for itself and implement the expected callback; arbitrary callers cannot force a receiver into borrowing. |

**Lifecycle.** Outside a loan capital is idle. A loan transfers principal, invokes the borrower, validates return data and pulls repayment; any failure rolls the entire loan back.

**Risks and test evidence.**

- **Zero, excess or unsupported borrowing.** Zero principal, more than available liquidity and unsupported tokens are rejected before delivering capital.
- **Bad callback or no repayment.** Wrong callback result and absent repayment approval revert with lender balances preserved.
- **Fee rounded down to free tiny loans.** Fuzzing verifies the ceiling fee and exact capital increase for successful loans, including one-unit inputs.
- **Nested loan or third-party borrower forcing.** Callback reentry is blocked and maxFlashLoan returns zero inside the callback. The caller must match the receiver.
- **Owner slippage or unauthorized withdrawal.** Non-owner withdrawal and failed taxed output minimum preserve capital. Random funding, withdrawal and loans reconcile capital with successful fees only.

**Coverage and trust limits.** The handler alternates four borrower modes and bounds principal to held liquidity, with pre-funded fees. It does not model borrower contracts returning arbitrary-length data or token behavior changing during callback. Funding is owner-controlled capital, not depositor shares; donors receive no redemption right.

**Gas note.** FlashLoan invokes an arbitrary borrower and transfers out and back; its gas depends on borrower logic. This is a structural observation, not a production gas benchmark.

**Files.** `FlashLender.t.sol` and `FlashLender.invariant.t.sol`.

## 16. InsurancePool

**Status: complete — test extension for the existing implementation.**

Premium payers receive pool shares and coverage. The owner approves evidence-based claims, which are reserved before payout and reduce assets backing remaining shares.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Members pay premiums, request an exit, claim approved funds and exit after cooldown. The owner approves claims within available coverage and assets. |

**Lifecycle.** Premiums create shares and coverage; approval decreases coverage and reserves a claim; claiming consumes the reserve; exit request surrenders coverage and starts a seven-day cooldown; exit burns all member shares.

**Risks and test evidence.**

- **Unauthorized or oversized claim approval.** Non-owner approvals, claims exceeding coverage, zero claims and claims exceeding available assets fail.
- **Reserved claims spent by exiting members.** Unit tests and the random handler verify reserved claims survive other members' exits and equal the sum of claim balances.
- **Cooldown restarted or coverage retained.** An exiting member cannot pay new premiums or restart the cooldown; coverage is zero throughout exit. Exact readiness allows exit while the previous second does not.
- **Taxed or failed payment destroys claim.** A rejected claim output minimum leaves both member claim and reservation intact; a valid lower minimum can retry.
- **Share/accounting divergence or callbacks.** Random premiums, approvals, claims, exits and time conserve pool capital and shares. Premium/claim/exit callbacks return the guard error.

**Coverage and trust limits.** The handler uses three members and conventional tokens, with owner approvals deliberately randomized. It does not establish the truth of claim evidence, actuarial sustainability or owner fairness. Deterministic tests cover taxed output; token rebases and administrative ownership transitions remain outside sequence coverage.

**Gas note.** PayPremium touches member shares, total shares and coverage and pulls funding; approval updates claim reserves. This is a structural observation, not a production gas benchmark.

**Files.** `InsurancePool.t.sol` and `InsurancePool.invariant.t.sol`.

## 17. Crowdfund

**Status: complete — test extension for the existing implementation.**

Backers fund an ETH campaign before its deadline. After expiry the creator gets the whole funded goal or backers obtain their individual refunds if the goal was missed.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Anyone pledges their own ETH. Only the creator claims a successful campaign. Backers refund only their own pledge and credit holders withdraw their own credits. |

**Lifecycle.** Pledges accumulate before the deadline; success enables a single creator credit; failure enables one refund per backer; pull withdrawal consumes credits independently.

**Risks and test evidence.**

- **Zero or deadline-late funding.** Zero pledge and funding at the exact deadline are rejected; a fuzzed deadline property proves no funding is retained.
- **Early or unauthorized campaign claim.** Only the creator may claim after the deadline and after reaching the goal; replay is rejected.
- **Goal met but refund also allowed.** Backers cannot refund before or after a successful creator claim.
- **Forced ETH fakes success.** Existing tests prove goal checks use recorded pledges rather than raw ETH balance.
- **Refund/claim double counting.** Random funding, claiming, refunds and withdrawals preserve total recorded receipts. A missed-goal campaign reconciles remaining pledges plus pull credits with held ETH.

**Coverage and trust limits.** The handler uses three backers, a fixed creator and randomized time. Forced ETH is a deterministic case, excluded from the handler's exact cash equation. It does not model off-chain fulfillment or promise any creator behavior after a legitimate payout.

**Gas note.** A first pledge writes two accounting slots; settlement creates pull credits. This is a structural observation, not a production gas benchmark.

**Files.** `Crowdfund.t.sol` and `Crowdfund.invariant.t.sol`.

## 18. DAOTreasury

**Status: complete — test extension for the existing implementation.**

The treasury receives ETH and tokens and permits spending only from its configured Timelock while that Timelock remains administered by the configured Governor.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Anyone donates. Only the authorized governance path allocates ETH or sends tokens. ETH recipients withdraw only their credited allocation. |

**Lifecycle.** Funding increases available custody; ETH allocation reserves an amount without pushing it; withdrawal consumes it. Token spending transfers immediately; an admin handover disables new spending.

**Risks and test evidence.**

- **Direct caller impersonates governance.** Direct and Governor calls fail, while real Governor-to-Timelock unit workflows spend both token and ETH successfully.
- **Timelock admin replaced.** After admin handover, even Timelock-origin spending is rejected because its current admin is no longer the configured Governor.
- **Reserved ETH allocated twice.** A second allocation exceeding unreserved funds fails. Random allocations and withdrawals keep total credits no greater than custody.
- **Invalid recipients or failed token minimum.** Invalid ETH recipients fail; taxed token output with an excessive minimum restores treasury custody and recipient balance.
- **Funding/spending callbacks or conservation failure.** Token callbacks return the guard error. Random donations, allocations, token spending and withdrawals reconcile both ETH and token lifetime inflows/outflows.

**Coverage and trust limits.** The handler uses real deployment handover, but simulates authorized calls with a Timelock prank to focus on treasury accounting. Full governance delay is covered deterministically, not in random treasury sequences. Passing authorization does not make a governance-approved malicious expenditure safe. Token-side rebases and arbitrary multi-token inventories are not randomized.

**Gas note.** Token spending includes external token balance/transfer calls; ETH allocation writes reservation slots. This is a structural observation, not a production gas benchmark.

**Files.** `DAOTreasury.t.sol` and `DAOTreasury.invariant.t.sol`.

## 19. Subscription

**Status: complete — test extension for the existing implementation.**

Users prepay tokens for 30-day service periods. Keepers can renew opted-in expired accounts, and the merchant withdraws only amounts earned from purchased periods.

| Roles | Tested permissions |
| --- | --- |
| Contract participants | Subscribers deposit, subscribe, cancel and withdraw unused prepaid funds. Any keeper renews an eligible account. Only the merchant withdraws earned revenue. |

**Lifecycle.** Deposit creates prepaid balance; subscribe enables renewal and buys access when needed; expiry permits one new month from the current time; cancel disables future billing without removing purchased access.

**Risks and test evidence.**

- **Insufficient funds leaves a billing opt-in.** A failed subscribe rolls autoRenew, prepaid, revenue and paidUntil back to the previous state.
- **Repeated or early renewal.** Renewal before expiry and a second call at the same expiry fail; the exact expiry permits one new month.
- **Cancellation or late keeper overcharges.** Cancelled users cannot be renewed. Resuming active access and late keeper calls do not charge for unused missed periods.
- **Merchant takes prepaid or user takes revenue.** Authorization tests separate the two balances; random lifetime purchase counts match earned plus withdrawn merchant revenue.
- **Tax, callback or failed withdrawal.** Taxed input is net credited; rejected subscriber and merchant minima preserve entitlements; deposit/principal/revenue callbacks return the exact guard error.

**Coverage and trust limits.** Random actions include deposit, subscribe, cancel, renew by other actors, principal/revenue withdrawal and time. The handler checks totalPrepaid plus revenue exactly against token custody. It does not guarantee keepers remain online, service is delivered or the token cannot later pause. Separate legacy-token tests prove pauses and false return values preserve account claims.

**Gas note.** Initial subscribe and renew update prepaid, totalPrepaid, revenue and expiry; token deposit/withdrawal cost depends on token logic. This is a structural observation, not a production gas benchmark.

**Files.** `Subscription.t.sol` and `Subscription.invariant.t.sol`.

## 20. PerpetualsLite

**Status: not started — implementation absent.**

No `src/PerpetualsLite.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 21. StableSwap2

**Status: not started — implementation absent.**

No `src/StableSwap2.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 22. RevenueSplitter

**Status: not started — implementation absent.**

No `src/RevenueSplitter.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 23. Allowlist721

**Status: not started — implementation absent.**

No `src/Allowlist721.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 24. RateLimitedMinter

**Status: not started — implementation absent.**

No `src/RateLimitedMinter.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 25. EmergencyPausableRegistry

**Status: not started — implementation absent.**

No `src/EmergencyPausableRegistry.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 26. SoulboundBadge

**Status: not started — implementation absent.**

No `src/SoulboundBadge.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 27. Permit2612Token

**Status: not started — implementation absent.**

No `src/Permit2612Token.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 28. BatchAirdrop

**Status: not started — implementation absent.**

No `src/BatchAirdrop.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 29. DCAVault

**Status: not started — implementation absent.**

No `src/DCAVault.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 30. LimitOrderBook

**Status: not started — implementation absent.**

No `src/LimitOrderBook.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 31. BondingCurveSale

**Status: not started — implementation absent.**

No `src/BondingCurveSale.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 32. ReferralRewards

**Status: not started — implementation absent.**

No `src/ReferralRewards.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 33. SavingsLock

**Status: not started — implementation absent.**

No `src/SavingsLock.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 34. VotingEscrow

**Status: not started — implementation absent.**

No `src/VotingEscrow.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 35. GaugeController

**Status: not started — implementation absent.**

No `src/GaugeController.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 36. NameRegistry

**Status: not started — implementation absent.**

No `src/NameRegistry.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 37. Tipping

**Status: not started — implementation absent.**

No `src/Tipping.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 38. LotteryCommitReveal

**Status: not started — implementation absent.**

No `src/LotteryCommitReveal.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 39. WrappedETH

**Status: not started — implementation absent.**

No `src/WrappedETH.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 40. CreditDelegation

**Status: not started — implementation absent.**

No `src/CreditDelegation.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 41. StreamingPayments

**Status: not started — implementation absent.**

No `src/StreamingPayments.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 42. BountyBoard

**Status: not started — implementation absent.**

No `src/BountyBoard.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 43. WhitelistSale

**Status: not started — implementation absent.**

No `src/WhitelistSale.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 44. ProofOfAttendance

**Status: not started — implementation absent.**

No `src/ProofOfAttendance.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.

## 45. KeeperRegistry

**Status: not started — implementation absent.**

No `src/KeeperRegistry.sol` exists in this accepted repository. There is no contract lifecycle, role implementation or deployed accounting to exercise. Implementing it is outside this test-only assignment. Unit, fuzz, invariant, gas and integration coverage remain owed when an implementation is provided. No tests asserting the requested behavior against an invented substitute were added.
