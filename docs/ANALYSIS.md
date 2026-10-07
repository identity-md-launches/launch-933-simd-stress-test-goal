# Portfolio analysis

The implementations are independent application contracts. Shared OpenZeppelin code and internal transfer helpers are libraries, not shared deployed services. Named integrations use local interfaces. **Complete** means the requested local behaviour, success/failure tests, fuzz property and contributor review are delivered under the stated assumptions. It does not mean externally audited or safe for arbitrary assets. The README's token compatibility, timestamp, ETH receiver and ownership assumptions apply to every relevant section.

## 1. LendingPool

**Status: complete.** People supply one token to earn interest; borrowers deposit a different token as security and borrow against it. Borrowing is limited to 75% of collateral value. Above 80%, anyone can repay some debt and receive collateral worth the repayment plus a 5% bonus. Supplier shares represent available cash plus outstanding debt, while borrower debt shares allocate interest without visiting every account.

| Role | Functions and powers |
|---|---|
| Supplier | `supply`, `withdraw` own shares |
| Borrower | `addCollateral`, `removeCollateral`, `borrow` to self |
| Any payer/liquidator | `repay`, `liquidate`, spending only caller funds |
| Anyone | `accrue` and price/debt views |
| Administrator | None; tokens, oracle and risk constants are immutable |

**Lifecycle.** Supply creates shares; collateral opens borrowing capacity; borrowing adds debt shares. Every financial debt operation checkpoints interest. Repayment burns shares; collateral can leave if the remaining position is safe. Liquidation repays and seizes atomically. Debt-free collateral removal skips the oracle. Supplier withdrawals require enough unborrowed cash.

**Trust and configuration.** Choose distinct honest ERC20s with 0–18 decimals and an oracle returning loan tokens per whole collateral token at 1e18 precision. The oracle must reject stale observations. Annual rate is 2% plus 20% times utilization, sampled at each checkpoint; interest compounds when checkpointed. Fractional interest is carried forward, preventing callers from erasing interest with frequent checkpoints. Liquidators need independent monitoring and capital.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| An inflated feed permits excessive borrowing and drains lenders. | Immutable feed interface; choose the fresh-price adapter with correct quote direction. Feed honesty remains trusted. |
| Price gaps leave insufficient collateral for repayment plus bonus. | 75/80% buffers and permissionless partial liquidation help; there is no bad-debt writeoff, insurance or guaranteed lender redemption. |
| An attacker donates before a victim supplies, diluting rounded shares. | One virtual asset, one million virtual shares, downward share rounding and caller minimum shares. |
| A taxed transfer credits more collateral/cash than actually arrived. | Caller-only measured receipts; repayment burns debt only for received funds. |
| A token callback borrows during partially credited supply. | All mutations share a reentrancy lock; callback regression test attempts `accrue`. |
| Withdrawal demand exceeds liquid cash despite solvent collateral. | Withdrawals revert rather than spend collateral; lenders accept utilization-driven illiquidity. |

**Gas.** `liquidate` is normally the most expensive path: interest updates, oracle reads, debt/collateral writes and two token transfers. No account enumeration is used.

**Coverage.** Tests cover mixed 6/8 decimals, utilization, annual interest, fractional checkpoints, exact bonus, unsafe borrowing/removal, healthy-liquidation rejection, taxed supply/collateral/repayment, caller-bound funding and callback rejection. Fuzzing proves borrow/repay cash conservation. Extreme market gaps, real oracle outages and multi-year multi-borrower economic simulations are not covered.

## 2. Vault4626

**Status: complete.** This vault issues transferable shares for deposited tokens. Anyone may add yield by donating assets; there is no external strategy or promised return. An owner sets a deposit cap. Holders can use normal ERC-4626 redemption immediately or place shares into an optional first-in-first-out queue, wait one day, and claim a processed withdrawal later.

| Role | Functions and powers |
|---|---|
| Depositor/shareholder | ERC4626 `deposit`, `mint`, `withdraw`, `redeem`; ERC20 share transfers/approvals |
| Queuing shareholder | `requestRedeem`, `cancelRequest`, `claim` own positions |
| Anyone | `depositReceived`, `addYield`, `processNext`, standard previews/views |
| Owner/pending owner | `setCap`; two-step ownership transfer/acceptance and renunciation |

**Lifecycle.** Deposits mint shares; donations raise assets per share. A request escrows shares without fixing its price. After one day anyone processes the FIFO head, burns shares, prices the withdrawal and reserves assets. Claims consume reserved assets; cancellation returns unprocessed shares. A cancelled queue entry can be skipped in a single call. Normal redemption remains available for unescrowed shares.

**Trust and configuration.** Configure the asset, cap in raw asset units and owner. Exact ERC4626 paths reject recipient-tax transfers rather than issue misleading quotes. `depositReceived` prices net receipts with a minimum-share bound; queued `claim` supports net-output minima. Reserved assets are excluded from `totalAssets`, so donations after processing cannot increase old claims. The owner can stop new deposits by lowering the cap but cannot withdraw user funds or stop redemption.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| A tiny first deposit and large donation steal the next depositor's shares. | Six-decimal virtual-share offset, virtual asset and nonzero/minimum-share checks. |
| Rounding lets repeated mint/redeem cycles extract value. | OZ floor rounding on deposit/redeem and ceil rounding on mint/withdraw; fuzz round trips cannot profit. |
| Live shareholders withdraw tokens promised to processed requests. | Separate `reservedAssets` liabilities are subtracted from active asset valuation. |
| Cancelled or numerous requests force an unbounded processing loop. | Processing advances exactly one entry; no batch depends on the user population. Keeper availability remains a liveness dependency. |
| Transfer tax causes preview execution to overissue shares. | Exact paths revert; the measured extension prices only the actual receipt. |
| Token callback processes a queued redemption against intermediate balances. | Shared nonReentrant guard; an explicit callback test exercises that transition. |

**Gas.** `processNext` consumes queue storage, burns escrowed shares and creates a reserved claim. It has bounded cost; deposit also pays underlying token transfer costs.

**Coverage.** Standard previews, rounding, cap authority, allowance checks, yield, cancellation, claims, reserve isolation, donation attack, taxed alternatives and callback rejection are tested. Fuzzing checks no profitable deposit/redeem round trip. External strategies, rebases and formal ERC4626 conformance certification are outside this implementation.

## 3. StakingRewards

**Status: complete.** Users temporarily deposit a staking token and earn a different token over time. The owner supplies the rewards before a period starts and chooses its duration; received funding divided by duration sets the per-second rate. Users can withdraw their stake without surrendering already earned rewards. An active period cannot be replaced or cut short.

| Role | Functions and powers |
|---|---|
| Staker | `stake`, `withdraw`, `claim` own funds |
| Owner | `fundPeriod` after the previous finish; ownership transfer/renunciation |
| Pending owner | `acceptOwnership` |
| Anyone | `earned`, `rewardPerToken` and public accounting views |

**Lifecycle.** Idle funding starts a fixed reward period. Stake, withdrawal and claim checkpoint a cumulative rewards-per-token index and the caller's entitlement. Time after period finish earns nothing. A later owner-funded period resumes distributions without resetting earned claims. Seconds with no stake create no new user entitlement, and the first subsequent staker cannot claim those idle emissions.

**Trust and configuration.** Deploy with two distinct supported tokens and an owner. Durations range from one hour to one year; a funding call is bounded to 1e36 reward base units. Neither accounting nor rate calculation assumes 18 token decimals. Reward division and account index division round downward. Idle rewards and rounding dust stay in the contract without an owner recovery mechanism; new periods distribute new funding only. The owner controls future incentives but cannot seize principal or rewrite earned rewards.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Owner advertises unfunded emissions and later cannot pay. | Rate derives exclusively from measured funding transferred before the period starts. |
| Owner replaces an ongoing period to reduce users' earnings. | Funding reverts until `periodFinish`; no arbitrary rate setter exists. |
| A late staker takes historical rewards earned before their deposit. | Update the global and individual indices before increasing stake. |
| Taxed stake or reward funding creates unbacked accounting. | Credits and rate use net receipts; users can set net withdrawal/claim minima. |
| The staking asset is also the reward asset, mixing reserves. | Constructor requires distinct token contracts. |
| A callback withdraws principal twice or claims an intermediate balance. | Shared guard and entitlement reduction before outgoing transfers; malicious token administration remains unsupported. |
| Repeated tiny checkpoints discard reward fractions. | High 1e27 index precision limits dust; residual fractions remain undistributed rather than creating excess claims. |

**Gas.** `stake` is generally heaviest because it checkpoints two indices, measures a token transfer and updates stake totals. Work is constant per user interaction.

**Coverage.** Tests prove reward timing, two-staker allocation, post-period capping, idle time exclusion, owner restrictions, fixed periods, invalid withdrawals/claims and taxed receipts. Fuzzing bounds payout by funded rewards. Very long histories and malicious rebasing tokens are not modelled.

## 4. Governor

**Status: complete.** Token holders propose one call at a time and vote using voting power recorded at a historical timestamp. Voting opens after a one-day delay and lasts three days. Approval requires more votes for than against, and for plus abstain votes must reach 4% of the historical token supply. A successful proposal is then submitted to the separate Timelock.

| Role | Functions and powers |
|---|---|
| Holder with previous-second delegated votes | `propose` |
| Historical voter | `castVote` once per proposal |
| Proposer | `cancel` only during the initial delay |
| Anyone | `queue`, `execute`, `acceptTimelockAdmin`, lifecycle/views |
| Administrator | None; token and Timelock are immutable |

**Lifecycle.** Pending proposals become active strictly after their snapshot, when historical queries are valid. After the inclusive voting deadline they become defeated or succeeded. Success permits queueing once. Execution occurs through the immutable Timelock and rolls back its local executed flag if the call fails. Proposer cancellation is terminal and is unavailable once voting opens.

**Trust and configuration.** The voting token must implement honest IVotes checkpoints and report `mode=timestamp`; block-clock tokens are rejected. The Governor must become Timelock admin through nomination and acceptance. Quorum rounds upward with a one-unit minimum. Call data is bounded at 16 KiB and each proposal contains only one target/value pair. For/against/abstain values are 1/0/2 respectively. No quorum or voting-window admin setters exist.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| One holder votes, transfers tokens, and votes again from another address. | Weight and supply both use the immutable snapshot, with one vote per voter. |
| A flash-borrowed balance changes during the voting transaction. | Historical checkpoints prevent same-transaction voting manipulation; borrowing across the snapshot remains an economic governance risk. |
| A tiny turnout wins by rounding quorum to zero. | Quorum is ceil(4%) and at least one; against votes do not count toward it. |
| A proposer changes destination or calldata after voters approve. | Proposal data is stored once; queueing reads the stored call only. |
| Anyone prematurely executes an approved transfer. | Lifecycle gates plus Timelock's separate two-day check prevent early calls. |
| A malicious majority authorizes theft or a reverting call. | The contract faithfully enforces votes, not proposal quality; delay permits observation but there is no emergency veto. |

**Gas.** `propose` is most storage-heavy because it stores calldata; voting adds a receipt and tally. All operations have bounded work independent of voter count.

**Coverage.** Tests cover historical token movement, duplicate votes, quorum, state gates, cancellations, bad support values and zero turnout. Fuzzing proves combined tallies never exceed fixture supply. Real Timelock and treasury tests cover execution integration. Vote bribery, hostile majority capture and voting-token upgrades are not prevented or simulated.

## 5. Timelock

**Status: complete.** An administrator schedules an exact call and must wait at least two days before executing it. The destination, ETH amount and calldata are recorded when queued. Execution takes only the operation identifier, preventing a caller from swapping in different instructions later. Administration moves in two steps, so a mistyped nominee cannot silently replace the current administrator.

| Role | Functions and powers |
|---|---|
| Admin or scheduled self-call | `queue`, `execute`, `cancel`, `nominateAdmin` |
| Pending admin | `acceptAdmin` |
| Anyone | Send ETH; `hashOperation`, `status` and getters |

**Lifecycle.** A unique hash moves from absent to queued with `readyAt = now + 2 days`. It may be cancelled permanently or executed once after readiness. Failed calls roll back execution and can be retried. The identifier is never reusable, including after cancellation. There is no expiry window; a queued operation stays executable until cancellation or successful execution. A fresh salt creates a new identifier and starts a new delay.

**Trust and configuration.** Set the initial administrator at construction. For DAO integration it should hand over to Governor before funding. The two-day delay is immutable. Admin succession itself is immediate upon nominee acceptance; thus a bootstrap administrator can transfer its queue/execute authority without waiting, but cannot accelerate existing timestamps. Scheduled self-calls permit governance-driven administrative changes. ETH funding is separate from call authorization.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| An outsider submits an arbitrary target or drains ETH through execute. | Admin authorization and stored operation lookup; execute accepts no free-form destination or value. |
| An admin schedules, edits and immediately executes an operation. | Exact call hash, immutable stored call and mandatory readiness check. |
| Target reentry executes the same operation twice. | Mark done before calling, plus a reentrancy guard around execution. |
| A reverting target permanently consumes the operation. | Revert restores done flag and ETH transfer, permitting retry after the target is repaired. |
| Wrong-account handover permanently locks control. | Nomination/acceptance with zero and self-admin rejection; a lost accepted admin key still blocks administration. |
| A malicious admin queues harmful transfers and waits. | Delay provides notice, not censorship; admin is deliberately trusted to select calls. |

**Gas.** `queue` stores at most 16 KiB of calldata. `execute` cost additionally depends on the target; an expensive or reverting call affects that operation, not unrelated stored entries.

**Coverage.** Tests prove delay boundaries, replay rejection, cancellation, unauthorized access, handover, failure retry and Governor integration. Fuzzing checks every sampled time before two days is rejected. Key compromise, operational monitoring and exotic target return-data griefing are outside local coverage.

## 6. MultiSig

**Status: complete.** This wallet requires M confirmations from N owners before making a call or spending ETH. Owners submit, confirm and revoke approvals individually. Anyone can execute once the threshold is met. Adding/removing owners or changing the threshold requires the wallet itself to approve a call to its own management function, giving those changes the same collective authorization as a payment.

| Role | Functions and powers |
|---|---|
| Current owner | `submit`, `confirm`, `revoke` |
| Approved wallet self-call | `addOwner`, `removeOwner`, `setThreshold` |
| Anyone | `execute`, receive funding, metadata and confirmation views |

**Lifecycle.** Submission records immutable calldata, value and the current membership epoch. Confirmations accumulate and can be individually revoked before execution. Execution marks the transaction consumed before calling its target. Membership or threshold changes increment the epoch, invalidating every outstanding transaction from the previous epoch. Invalidated proposals must be resubmitted and reconfirmed; their old receipts cannot be revived by adding the same owner again.

**Trust and configuration.** Supply one to 32 unique nonzero owners and a threshold between one and owner count. The wallet cannot own itself. Constructor iteration is bounded by 32; normal calls do not iterate owners. Transaction calldata is capped at 16 KiB. There is no recovery guardian or privileged deployer after construction, and no arbitrary delegatecall endpoint. The collectively authorized target can nevertheless be any address.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| One owner directly changes membership to steal funds. | Management entry points require `msg.sender == address(this)` and therefore an approved self-call. |
| Removed owners' historic approvals still satisfy a later threshold. | Epoch binding invalidates all pending approvals whenever membership or threshold changes. |
| Duplicate owners or duplicate confirmations inflate voting weight. | Constructor rejects duplicates; confirmation mapping records one approval per owner. |
| A receiver callback executes an approved payment twice. | Executed flag is set before the call and shared reentrancy protection covers transaction mutations. |
| An invalid removal sets an unreachable threshold. | Removal atomically selects a positive threshold below the old owner count. |
| Enough owners collude or lose access. | Threshold distribution is the trust boundary; the code cannot prevent collusion or recover permanently lost quorum. |

**Gas.** `submit` is storage-heavy due to calldata. Execution's target determines additional cost. Confirmation/revocation and epoch changes are constant-time.

**Coverage.** Tests cover confirm/revoke/execute, insufficient approvals, duplicate and unauthorized actions, self-only management, removal, stale epochs and failed-call rollback. Fuzzing proves ETH conservation over arbitrary affordable payments. Signature aggregation is intentionally absent; long-term key custody and coordinated malicious owners are not covered.

## 7. DutchAuction

**Status: complete.** A seller escrows one NFT, starting a price that falls linearly from a configured initial price to a floor. The first successful buyer pays the current price and receives the NFT. Overpaid ETH is recorded as a refund claim, and seller proceeds are also claimed separately. The price remains at its floor until purchase or seller cancellation after the declining-price period ends.

| Role | Functions and powers |
|---|---|
| Seller/deployer | `activate`; `cancel` before activation or after the floor is reached |
| Buyer | `buy` with recipient, maximum price and deadline |
| Credited account | `withdrawPayments` own refund/proceeds |
| Anyone | `price`, state and configuration views |

**Lifecycle.** Created becomes active when the seller transfers the approved NFT into custody. Activation fixes the start timestamp. Active becomes sold on purchase, or cancelled by the seller after duration. Created may be cancelled without moving an NFT. Sold and cancelled are terminal. Credits are independent of auction state and persist until withdrawn.

**Trust and configuration.** Choose a real ERC721 collection, token id, positive floor, initial price at least the floor, and duration between one hour and one year. The deployer must be the seller. Approval precedes activation; custody is verified with `ownerOf`. No operator may change the price schedule after deployment. Purchasers choose a recipient capable of accepting an ERC721 safe transfer; the NFT collection's implementation remains trusted.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Seller transfers the NFT away after listing. | Activation takes custody; the seller cannot arbitrarily withdraw an active auction. |
| A validator changes transaction timing to alter the price. | Long duration, maximum-price and deadline checks bound exposure; small timestamp/ordering advantage remains. |
| Two buyers simultaneously try to purchase. | State becomes sold before the receiver callback; the second transaction reverts. |
| Refund or seller receiver rejects ETH and blocks the sale. | Both amounts use independent pull balances rather than immediate pushes. |
| An NFT receiver reenters and reuses escrow or credits. | State effects and credits precede safe transfer under the shared reentrancy guard. |
| Seller cancellation races a floor-price purchase. | Cancellation is allowed only after duration, but ordering can decide the winner then; buyers must accept this terminal race. |

**Gas.** `buy` stores two potential credits and performs an ERC721 safe transfer. Price computation itself is constant-time with full-precision multiplication.

**Coverage.** Tests cover midpoint pricing, excess refund, seller proceeds, ownership, underpayment, duplicate buy, cancellation timing/authority and buyer deadlines. Fuzzing proves price monotonicity and floor/start bounds. Malicious NFT collections and real-world NFT title/metadata authenticity are not verified.

## 8. NFTMarketplace

**Status: complete.** Sellers escrow NFTs at fixed ETH prices. A buyer pays the exact listing price and receives the NFT; 2.5% is assigned to an immutable treasury and the remainder to the seller. Sellers may cancel unsold listings. Money is held as individual withdrawal balances, so a seller who cannot receive ETH does not stop another person's purchase or payment.

| Role | Functions and powers |
|---|---|
| NFT owner | `list` caller-owned approved NFT |
| Listing seller | `cancel` while active |
| Buyer | `buy` at exact price, selecting an NFT recipient |
| Seller/treasury | `withdrawPayments` own earned credit |
| Administrator | None; fee treasury and 250-basis-point fee are immutable |

**Lifecycle.** Listing creates a unique id and escrows the NFT. Active listings become inactive through purchase or cancellation and cannot be reactivated. A later listing of the same NFT gets a new id. Purchase updates active state and payment liabilities before the recipient's ERC721 callback. Cancellation returns custody without sending ETH.

**Trust and configuration.** Configure a nonzero treasury capable of accepting ETH. Prices are wei, not oracle-derived values. Fees round down to the nearest wei and the seller receives the exact remainder, ensuring conservation. There is no collection allowlist, royalty integration, administrator confiscation, or seller approval of arbitrary account transfers. NFT identity and token compliance must be checked by buyers; an ERC721-shaped malicious contract can lie about ownership.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Seller revokes approval or moves a listed NFT before purchase. | Listing takes custody and checks ownership, eliminating later seller-side approval dependency. |
| Buyer underpays, or a stale transaction buys an inactive listing. | Exact price and active-state checks revert atomically. |
| Seller or treasury receive hook rejects ETH. | Proceeds are credits; withdrawal failure rolls back only that user's attempted withdrawal. |
| ERC721 receiver reenters cancellation during purchase. | Inactive flag and credit effects precede callback, and shared guard blocks reentry; explicitly tested. |
| Fee rounding creates or destroys money. | Fee is floored and seller gets `price - fee`; fuzzing checks their sum equals the payment. |
| An attacker lists someone else's approved NFT. | `transferFrom` uses the caller as source, never a caller-supplied victim address. |

**Gas.** `list` writes the full listing and performs custody transfer; `buy` adds credit writes and safe-transfer callback costs. No operation iterates listings.

**Coverage.** Tests cover buy/cancel, immutable fee split, unauthorized cancellation, price errors, duplicate purchase, repeat withdrawal rejection, rejecting sellers and receiver reentry. The fuzz property proves fee/payment conservation. Cross-market MEV, royalties and noncompliant NFT implementations are not covered.

## 9. Vesting

**Status: complete.** An owner funds separate grants for beneficiaries. Each grant releases tokens linearly from its start to its end, but nothing is payable before a cliff. After the cliff, the beneficiary can collect the accumulated amount, including accrual before the cliff. A grant marked revocable lets the owner recover only its unvested portion; already vested tokens stay claimable by the beneficiary.

| Role | Functions and powers |
|---|---|
| Owner | `create`, `revoke` eligible grants; ownership transfer/renunciation |
| Pending owner | `acceptOwnership` |
| Beneficiary | `release` own grant with net-output minimum |
| Anyone | `vested`, grant metadata and token views |

**Lifecycle.** Creation pulls owner funds and stores the measured grant amount. Before cliff, vested is zero. From cliff through end, vested follows elapsed/start duration. Each release increases a cumulative released counter. Revocation freezes the current vested amount and returns total minus vested to the current owner. A revoked grant never accrues again; an irrevocable grant has no early termination path.

**Trust and configuration.** Configure the asset and initial owner. Creation chooses beneficiary, start at or after now, cliff between start and end, duration up to ten years, and revocability. Multiple grants, even to the same beneficiary, remain independent. The funder is always the caller-owner, not a provided address. A cliff at end implements all-at-once vesting. The current owner receives any unvested refund even if ownership changed after funding; ownership transfer therefore includes that economic right.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Owner revokes and takes tokens already earned. | Refund excludes vested amount; a frozen vested cap preserves the beneficiary's remaining claim. |
| Beneficiary claims twice for the same elapsed time. | Released counter is increased before transfer and subtracted from total vested. |
| A beneficiary redirects another beneficiary's grant. | Release requires the exact stored beneficiary and pays the caller. |
| Fee-on-transfer funding creates an underfunded promise. | Grant total is measured from actual receipt; output minimum lets recipients reject excessive taxes. |
| Revocation just before a cliff defeats expected compensation. | This is an explicit owner power on revocable grants; irrevocable grants prevent it. Beneficiaries must inspect terms. |
| Token callback claims or revokes during a transfer. | All funding and payment mutations use the same guard and freeze entitlement effects first. |

**Gas.** `create` is heaviest because it writes schedule metadata and measures a transfer. Release and revocation are constant-time regardless of the number of beneficiaries.

**Coverage.** Tests cover cliff boundaries, partial/full release, pre-cliff revocation, frozen accrued claims, irrevocability, role restrictions, multiple beneficiaries and taxed funding. Fuzzing proves refund plus vested amount equals grant funding. Multi-decade timestamps and arbitrary token administration are not simulated.

## 10. Escrow

**Status: complete.** A buyer and seller agree on one ETH price. The buyer deposits it, the seller records delivery evidence, and the buyer can release payment. Either party can raise a dispute before its current timeout; a separate arbiter then divides the funds. If nobody resolves the current stage before its deadline, anyone can trigger a full buyer refund, avoiding indefinite custody.

| Role | Functions and powers |
|---|---|
| Buyer | `deposit`, `release`, `dispute` |
| Seller | `deliver`, `dispute` |
| Arbiter | `resolve` a disputed escrow before timeout |
| Anyone | `timeoutRefund` when due; views |
| Credited party | `withdrawPayments` own assigned amount |

**Lifecycle.** AwaitingDeposit becomes Funded through exact payment before delivery deadline. Seller delivery becomes Delivered and creates a three-day review window. Funded or Delivered may become Disputed, starting a seven-day arbitration window. Buyer acceptance, arbiter resolution, or timeout produces terminal Settled state. Settlement creates pull balances, never immediate receiver calls.

**Trust and configuration.** Buyer, seller and arbiter must be distinct, nonzero addresses. Configure positive wei price and delivery duration of one day to one year. Evidence is a hash only: neither delivery truth nor legal entitlement is verified on-chain. This design deliberately defaults to buyer refund when review or arbitration is unresolved. Sellers must dispute before a silent buyer's three-day review expires. Arbiter must act before seven days; late rulings revert.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Seller claims to deliver nothing and demands funds. | Delivery alone pays nothing; buyer release or arbiter decision is required. |
| Buyer accepts goods but stays silent until refund. | Seller may dispute within the review window; honest arbitration and monitoring are essential, not cryptographically enforced. |
| Arbiter disappears, trapping funds forever. | Seven-day dispute timeout returns funds to buyer without arbiter cooperation. |
| An unrelated caller changes delivery or settlement. | Immutable party checks and stage restrictions guard every transition. |
| Repeated release/resolve/refund duplicates payment. | All paths enter terminal Settled state before crediting amounts. |
| Recipient reentry or rejection interferes with the other party. | Shared pull-payment guard isolates withdrawal execution and preserves failed claims. |

**Gas.** Dispute and settlement perform several storage writes; ETH withdrawal includes an arbitrary receiver callback. No path loops over participants or evidence.

**Coverage.** Tests cover delivery/acceptance, split arbitration, funded/disputed timeouts, unauthorized transitions, early refund and duplicate resolution. Fuzzing proves every allowed split sums exactly to the deposit. Off-chain evidence validity, contractual disputes and economic fairness of the buyer-default rule are not testable locally.

## 11. Raffle

**Status: complete under an explicitly trusted-operator randomness model.** Players buy ETH tickets in one round. Before sales, an operator commits to a secret and posts a bond. After sales close, the operator reveals the secret, which deterministically selects a ticket. The winner receives a pull-payment prize. If the operator fails to reveal on time, entrants recover ticket costs plus a proportional share of the forfeited bond.

| Role | Functions and powers |
|---|---|
| Operator | `open` once with commitment/bond; `reveal` during reveal window |
| Player | `buyTicket`; `refund` own tickets after expiration |
| Anyone | `expire` after reveal deadline; round views |
| Winner/operator/refunded player | `withdrawPayments` own credit |

**Lifecycle.** Created becomes Open after commitment and bond funding. Sales last one hour to 30 days and accept at most the configured cap, no more than 10,000 tickets. Reveal then lasts one hour to seven days. Successful reveal becomes Drawn; timeout becomes Expired. Both are terminal. Empty rounds return the bond. Expired rounds share `bond / ticketCount` per ticket; integer-division dust goes to the operator, leaving exact total accounting.

**Trust and configuration.** Configure operator, ticket price, cap and both windows. Commitment is `keccak256(abi.encode(seed, raffleAddress, chainId))`; winner index hashes seed and commitment. Bond must cover maximum ticket revenue. **This is not verifiable unbiased randomness:** the operator knows the seed before sales and can manipulate its own participation or collude with entrants. The bond addresses withholding incentives only. No blockhash, timestamp or oracle mock is represented as production randomness.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Operator knows which ticket wins for a given final count and arranges entries. | Not eliminated by commit/reveal; operator fairness is an explicit trust assumption and production limitation. |
| Operator withholds an unfavourable reveal. | Public expiry refunds tickets and forfeits a bond at least equal to maximum revenue; outside incentives may still outweigh it. |
| Seed from another raffle or chain is reused accidentally. | Commitment includes contract address and chain id. |
| Late tickets alter the winner after the secret is public. | Sales end before reveal opens; entry cap and deadline are enforced. |
| Prize receiver rejects ETH or reenters to claim twice. | Pull balance and shared guard; failed withdrawal preserves credit and retry/reentry are tested. |
| A player requests several refunds for identical tickets. | Refund consumes all caller ticket count once before creating credit. |

**Gas.** `buyTicket` stores one ticket and account count. Reveal, expiry and refund never iterate ticket holders, so settlement cost does not grow with participation.

**Coverage.** Tests cover prize selection/claim, bond conservation, empty rounds, bad/early/late/unauthorized reveal, wrong payment, cap, late entry, duplicate refund, receiver failure and reentry. Fuzzing checks timeout solvency for different ticket counts. Unbiased distribution and resistance to operator collusion are expressly not proven.

## 12. TokenBridgeLock

**Status: complete as a signature-authorized lock/unlock simulator, not a real bridge.** Users lock a token and receive an event with a unique nonce, destination identifier and actual received amount. Releasing held tokens requires a configured number of relayers to sign an authorization. The recipient submits those signatures and receives tokens. No source-chain proof, cross-chain consensus or automatic relayer service is included.

| Role | Functions and powers |
|---|---|
| Token holder | `lock` own funds with a destination identifier |
| Immutable relayer quorum | Sign exact EIP712 unlock authorizations off-chain |
| Authorized recipient | `unlock` to self, supplying signatures and net-output minimum |
| Anyone | `unlockDigest`, nonce, relayer and processed-id views |
| Administrator | None; no relayer replacement or emergency sweep |

**Lifecycle.** Each lock increments a local nonce and increases held assets without creating an automatic refund right. For unlock, relayers sign a unique source id, recipient, amount and deadline. The recipient presents exactly threshold signatures in ascending signer-address order. Processing marks the source id consumed before payment. Failed payment rolls back consumption; a successful id can never be processed again.

**Trust and configuration.** Configure one supported token, one to 32 unique relayers and a valid threshold. Relayers are immutable for this deployment. They must assign source ids uniquely across all simulated source networks and verify whatever external event they claim to attest. EIP712 domain binds the local chain and this deployment. Sorted signatures avoid both duplicate counting and a quadratic signer search. The design has no connection to real funds on another chain.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Enough relayers fabricate an unlock and drain escrow. | Quorum limits single-key compromise but a malicious quorum has full custody power; no proof validation prevents collusion. |
| A signature is replayed across deployments or destinations. | Domain separation and typed recipient/amount/source/deadline fields bind the authorization. |
| Same relayer appears repeatedly to satisfy threshold. | Recovered addresses must be configured and strictly increasing. |
| Someone front-runs a recipient's signed unlock to steal it. | Digest recipient is always `msg.sender`, and tokens are sent only there. |
| Transfer tax makes emitted lock collateral larger than received. | Lock emits measured receipt; outbound claim includes a recipient-chosen minimum. |
| Lost keys or paused tokens strand escrow permanently. | No unsafe fallback exists; relayer availability and token administration remain external operational risks. |

**Gas.** `unlock` is most expensive because it performs up to 32 ECDSA recoveries plus receipt checking and transfer. Iteration is explicitly bounded by deployment threshold.

**Coverage.** Tests cover quorum success, duplicate signer rejection, wrong recipient, expiry, cross-contract replay, source replay, taxed lock/nonces and fuzzed unlock conservation. Chain-id mutation, source-chain truth and relayer infrastructure availability are not tested.

## 13. PriceOracleAdapter

**Status: complete.** This read-only adapter turns a Chainlink-style feed into one positive price with 18 decimal places. It refuses an answer older than one hour, a future update, an incomplete round or a non-positive price. Consumers therefore receive a consistently scaled answer or a revert instead of silently using obviously invalid data.

| Role | Functions and powers |
|---|---|
| Deployer | Selects immutable feed and validates decimal precision at construction |
| Anyone | `price` and immutable feed/unit views |
| Runtime administrator | None; feed cannot be swapped or freshness checks disabled |

**Lifecycle.** Construction verifies contract code and reads feed decimals, accepting at most 36. Thereafter the contract has no mutable accounting state. Each `price` call reads the latest round, validates timestamps/round relationship and computes `answer * 1e18 / feedUnit` with full-precision arithmetic. Exactly one-hour-old observations are accepted; older observations revert. Scaling that rounds a tiny positive value to zero is rejected.

**Trust and configuration.** Operators must choose the correct feed, quote direction, chain and market. A lending integration needs collateral priced in the loan token, not an unrelated USD rate. The fixed one-hour freshness ceiling must match the chosen feed heartbeat. This adapter does not check L2 sequencer uptime, market trading hours, deviation circuit breakers or feed admin upgrades. Those are unresolved deployment checks, not additional authority in this contract. `FeedConfigured` records the selected address and precision once.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| A stalled feed permits borrowing against an old price. | Reject updates older than one hour; downstream calls fail closed, which may also halt liquidations. |
| A negative signed answer is cast into a huge unsigned value. | Strict positivity is checked before conversion. |
| A malformed future timestamp bypasses age checks. | Future updates and started-after-updated rounds are rejected before subtraction. |
| A feed with six/eight/twenty-four decimals is mis-scaled. | Precision is read, bounded and normalized with `Math.mulDiv`; no assumed feed precision. |
| A round id reports a result from an older incomplete round. | Require a nonzero round and `answeredInRound >= round`. |
| A malicious feed reports a fresh but false price. | Freshness is not authenticity; the configured feed and its governance remain trusted, with no local economic sanity band. |

**Gas.** `price` makes one external view call and a full-precision arithmetic operation. There are no loops, token transfers or recurring storage writes; the feed's own execution dominates variable cost.

**Coverage.** Tests exercise normal scaling, exact hour boundary, stale/negative/zero/future/incomplete observations, 24-decimal values and zero-after-normalization. Fuzzing proves normalization over broad positive amounts and fresh ages. Live feed availability, sequencer failures and economically incorrect but structurally valid prices are not simulated.

## 14. ConstantProductAMM

**Status: complete.** This pair exchanges two tokens using the constant-product rule. Liquidity providers deposit both tokens and receive transferable LP shares; they recover a proportional reserve share by burning LP tokens. Every swap charges 0.3% of received input, retained in reserves for LPs. Initial liquidity permanently locks 1,000 LP units at address 1 to prevent the pool from being completely emptied.

| Role | Functions and powers |
|---|---|
| Liquidity provider | `addLiquidity`, `removeLiquidity`, LP ERC20 transfer/approval |
| Trader | `swap` caller funds for the other token |
| Anyone | Reserve, token and LP views |
| Administrator | None; pair, fee and minimum locked liquidity are immutable |

**Lifecycle.** First addition mints geometric-mean liquidity less the permanent lock. Later additions select nominal amounts close to reserve ratio and mint the smaller proportional share. Swaps add measured input and subtract output according to fee-adjusted constant-product math. Removal burns shares before paying proportional reserves. Accounting uses explicit reserves; unsolicited token transfers are ignored and cannot be harvested with a later LP deposit.

**Trust and configuration.** Choose two distinct supported tokens; reserve amounts are raw units and individually bounded to uint112. LP precision is an independent share denomination, not an assumption about token decimals. Initial amounts determine price. Receiver taxes are measured: input tax can cause imbalance and donate the excess side of an LP deposit to existing LPs. Users must set sensible minimum shares, net output minima and deadlines. There is no router, oracle or sync/skim function.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| A sandwich pushes execution to an unfavourable price. | Caller-selected net minimum and deadline bound loss; zero minima intentionally waive protection. |
| Taxed input is priced using a larger nominal amount. | Swap formula and reserve increments use actual receipt only. |
| Rounding reduces invariant or mints disproportionate LP ownership. | Outputs/shares round down; fuzzing verifies nondecreasing product after swaps. |
| A callback reuses old reserves to drain the output token. | Shared guard and reserve/share effects precede outgoing transfer. |
| Donation or final withdrawal creates an empty-pool inflation attack. | Permanent minimum LP lock and explicitly tracked reserves; donated excess is not withdrawable accounting. |
| A depeg or adverse price trend causes LP losses. | No mitigation promises a stable price; arbitrage and impermanent loss are inherent. This spot price must not secure lending. |

**Gas.** `addLiquidity` measures two token transfers and updates LP supply plus both reserves. Swap performs only one inbound and one outbound transfer, with constant-time math.

**Coverage.** Tests cover fee calculation, LP round trips, permanent minimum liquidity, mixed decimals, taxed input/output, slippage/deadline errors, wrong token and donations. Fuzzing proves product and reserve/balance consistency. Arbitrage sequences, severe token rebases and full MEV simulation are not covered.

## 15. FlashLender

**Status: complete with a documented self-initiated borrower restriction.** A borrower contract can temporarily borrow the lender's held token within one transaction. It receives a callback, then must return the full amount plus a 0.09% fee. Failure anywhere reverses the entire operation. Borrowers must initiate their own loans; third parties cannot make the lender debit another contract's approval by naming it as receiver.

| Role | Functions and powers |
|---|---|
| Borrower contract | `flashLoan`, with receiver equal to caller; callback must authorize repayment |
| Anyone | `fund` donated liquidity; `maxFlashLoan`, `flashFee` |
| Owner | `withdraw` idle liquidity/fees to self; ownership transfer/renunciation |
| Pending owner | `acceptOwnership` |

**Lifecycle.** Liquidity is held idle until a guarded flash call. The lender validates token, capacity, receiver and positive amount, sends exact principal, checks callback magic and measures repayment from the same caller. Success emits the amount and fee and releases the guard. During the callback, `maxFlashLoan` reports zero. Owner withdrawals share the guard and cannot run inside an active loan.

**Trust and configuration.** Configure the asset and capital owner. Funding is a donation to owner-controlled capital, not a redeemable depositor balance. Fee rounds upward to one raw unit for tiny loans. ERC3156 function shapes, initiator forwarding and callback magic are implemented, but integrations must respect receiver-equals-initiator. Exact transfer receipt is required both ways, so fee-on-transfer assets are safely rejected for flash loans. Rebases, sender surcharges and dishonest token balances are unsupported.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Someone names a victim contract and consumes its lender allowance. | Receiver must equal caller; incoming transfer helper never accepts an arbitrary source address. |
| Borrower keeps funds or returns wrong callback magic. | Exact callback hash and measured principal-plus-fee repayment; whole transaction reverts on failure. |
| Borrower recursively borrows against transient liquidity. | Reentrancy guard, zero callback-time capacity and explicit recursive-loan regression test. |
| Tiny loans round fees to zero and enable free borrowing. | Fee uses ceil(amount × 9 / 10,000). |
| Taxed transfer silently delivers too little or repays too little. | Exact principal net minimum and measured repayment lower bound both fail closed. |
| Owner removes promised liquidity or takes donated capital. | Owner is the explicit capital custodian; there are no depositor entitlements or guaranteed future capacity. |

**Gas.** `flashLoan` is most expensive: measured transfers, callback execution and repayment. Calldata is bounded; the borrower controls its callback gas consumption and bears the cost.

**Coverage.** Tests cover success, exact fee, owner withdrawal, unsupported asset, unauthorized withdrawal, callback failure, missing repayment, recursive reentry, caller binding and taxed principal rejection. Fuzzing proves lender gain equals the fee. Third-party initiated integrations and malicious token economics are not supported or certified.

## 16. InsurancePool

**Status: complete under a mutual-pool accounting model.** Members pay token premiums that buy a proportional interest in the pool and coverage equal to five times the paid amount. The owner verifies claims outside the contract and reserves approved payouts, limited by a member's remaining coverage and available assets. Claim costs reduce the value of every member's shares. A member can leave after a seven-day cooldown, receiving their current share value rather than a guaranteed premium refund.

| Role | Functions and powers |
|---|---|
| Member | `payPremium`, `claim`, `requestExit`, `exit` own balances |
| Owner | `approveClaim`; ownership transfer/renunciation |
| Pending owner | `acceptOwnership` |
| Anyone | Pool asset, coverage and claim views |

**Lifecycle.** Net premiums mint pool shares and add coverage. Claim approval deducts coverage and reserves a pull liability. Claim withdrawal removes that reserve without changing remaining shareholders' value. Exit request irreversibly surrenders unused coverage and starts a cooldown. After seven days exit burns all caller shares at current unreserved asset value. Approved claims survive exit request and remain payable. Once exit completes, the account may join again with new funding.

**Trust and configuration.** Configure one supported token and an owner responsible for evidence review. Coverage has no expiry, deductible or actuarial pricing model; the 5x multiplier and cooldown are fixed. Shares use virtual asset/share offsets and round down. Exiting members remain exposed to later claim approvals until they actually redeem. The owner has no unrestricted sweep but can assign available pool value to valid members through claim approval; claim honesty is a substantial trust assumption.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Owner fabricates claims for a colluding member. | Coverage and liquid-asset caps limit each approval, but economic legitimacy is not verified on-chain. |
| Members exit with funds already promised to claimants. | Reserved claims are excluded from redeemable `totalAssets`. |
| An exiting member both retains future coverage and withdraws capital. | Requesting exit zeroes coverage and prevents new claims/premiums until exit completes. |
| Taxed premiums create excessive shares or coverage. | Both use measured receipt, not the requested payment amount. |
| A queue-wide withdrawal run causes negative balances. | Each exit uses current proportional assets; losses are socialized rather than guaranteeing nominal redemption. |
| Reentrant claims or exits consume the same entitlement twice. | Shared lock and claim/share reductions precede transfers. |

**Gas.** `payPremium` and `approveClaim` write multiple accounting entries; neither iterates members. Exit has a single proportional calculation and token payout.

**Coverage.** Tests cover coverage creation, socialized losses, reserved claim survival, cooldown, coverage surrender, owner authority and asset/coverage limits. Fuzzing proves reserved plus unreserved assets equal held tokens around claims. Catastrophic correlated losses, claim fraud and actuarial adequacy are not modelled.

## 17. Crowdfund

**Status: complete.** Backers pledge ETH toward a fixed funding goal before a deadline. If total pledges reach the goal, the creator can claim the collected amount after the deadline. Otherwise, each backer can recover their contributions. The contract records ETH payment claims instead of pushing payments during campaign settlement, so one failing receiver cannot block everyone else.

| Role | Functions and powers |
|---|---|
| Backer | `pledge` before deadline; `refund` own pledge after failure |
| Creator | `claim` once after a successful campaign finishes |
| Credited account | `withdrawPayments` own claim |
| Anyone | Goal, deadline, pledge and claim views |
| Administrator | None; no goal edits, cancellation or campaign extension |

**Lifecycle.** Construction begins the pledge window. Pledges aggregate by address and in `totalPledged`. The deadline separates funding from settlement. A campaign with total at least the goal permits a single creator claim and prohibits refunds. A campaign below the goal permits per-backer refunds and prohibits creator claims. Refunding clears only the caller's pledge; historical total remains unchanged so the outcome cannot flip during settlement.

**Trust and configuration.** Choose nonzero creator, positive wei goal and duration from one day to one year. Exactly reaching the goal counts as success. The creator is trusted to deliver whatever off-chain project motivated funding; there is no milestone, arbitration or clawback mechanism. Backers accept irrevocable pledges until the deadline. Forced ETH transfers do not increase pledge totals and cannot make an otherwise failed campaign successful; such unaccounted ETH has no sweep path.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Creator changes the goal or deadline after collecting pledges. | All campaign terms are immutable; no owner setters exist. |
| Creator withdraws early or after missing the goal. | Deadline and total-goal checks guard the creator-only claim. |
| A refunded backer claims repeatedly. | The pledge is zeroed before a pull credit is created. |
| Forced ETH changes the success condition and strands refunds. | Success depends on recorded pledges, never contract balance. |
| Recipient failure or reentry disrupts settlements. | Common pull-payment accounting and reentrancy guard isolate withdrawals. |
| Creator receives money but never completes the advertised project. | This contract provides funding escrow only; no on-chain performance guarantee exists. |

**Gas.** `pledge` initializes or updates two counters. Settlement is constant-time per claimant, avoiding an unbounded refund loop. Withdrawal cost depends on the recipient's fallback.

**Coverage.** Tests prove exact-goal success, aggregated pledges, creator payout, failed-campaign refund, early/unauthorized/late-action rejection, duplicate settlement and forced-ETH isolation. Fuzzing checks that all recorded contributions become exactly one side's liabilities. Real project delivery, creator identity and social engineering are outside scope.

## 18. DAOTreasury

**Status: complete.** This treasury holds ETH and ERC20 tokens for a DAO. Spending must arrive from a specific Timelock while that Timelock is administered by a specific Governor. There is no separate treasury owner who can bypass voting. ETH allocations become recipient withdrawal claims; token spending follows the exact token, recipient, amount and minimum receipt approved through governance.

| Role | Functions and powers |
|---|---|
| Donor | Send ETH; `fundToken` using caller funds |
| Configured Timelock, while administered by configured Governor | `spendETH`, `spendToken` |
| ETH beneficiary | `withdrawPayments` own allocated ETH |
| Anyone | Immutable governance and ETH-credit views |
| Treasury administrator | None; no governance replacement or emergency sweep |

**Lifecycle.** Construction checks the Governor is already Timelock admin. Donations add assets without creating contributor rights. A completed governance proposal invokes a treasury spend through the Timelock. ETH spend reserves a credit rather than delivering immediately; withdrawal later consumes it. Token spend transfers immediately under the guard and reverts if the recipient receives less than the approved minimum. Further governance proposals may allocate remaining unreserved assets.

**Trust and configuration.** Configure real Governor and Timelock contract addresses after completing handover as described in README. The interface boundary permits standalone compilation, but a malicious contract that merely pretends to be a Timelock is not secure; operators must verify actual implementations. Runtime admin checks intentionally freeze treasury spending if Timelock administration leaves the fixed Governor. Existing ETH claimants can still withdraw. Changing this design requires a new treasury, not an upgrade.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| An EOA or Governor directly bypasses the delay to spend. | Caller must be the immutable Timelock, not merely the Governor address. |
| Timelock admin changes to an attacker while treasury trusts the old wiring. | Every spend verifies current Timelock admin still equals the fixed Governor. |
| Governance allocates the same ETH twice before recipients withdraw. | Available ETH is balance minus total outstanding credits. |
| A recipient reenters or rejects payment to disrupt other awards. | ETH uses independent guarded pulls; token spends share the guard and revert atomically. |
| Taxed token transfer delivers less than voters authorized. | Recipient balance delta must meet the proposal's explicit minimum. |
| A malicious voting majority approves theft or destroys the integration's liveness. | No local veto overrides governance; majority honesty and correct deployment are trust assumptions. |

**Gas.** `spendToken` includes external admin and token calls; `spendETH` performs credit accounting only. Proposal/voting costs belong to the independent Governor and Timelock.

**Coverage.** Real governance integration tests execute ETH and token spends after votes and delays. Other tests reject direct/Governor calls and double allocation. Fuzzing checks allocation solvency. Malicious replacement implementations, governance capture and live token allowlists are not simulated.

## 19. Subscription

**Status: complete using prepaid renewal balances.** A subscriber deposits tokens and enables a fixed-price monthly plan. A month means exactly 30 days. Anyone acting as a keeper can renew an expired subscription from that subscriber's prepaid balance, but only while the subscriber has opted in. Cancellation stops future charges immediately without taking away access already purchased, and unused deposits remain withdrawable.

| Role | Functions and powers |
|---|---|
| Subscriber | `deposit`, `subscribe`, `cancel`, `withdraw` own prepaid funds |
| Permissionless keeper | `renew` opted-in expired accounts with sufficient prepaid funds |
| Immutable merchant | `withdrawRevenue` already earned fees only |
| Anyone | `isActive` and accounting/configuration views |
| Administrator | None; token, merchant and price cannot be changed |

**Lifecycle.** Deposit creates measured prepaid credit without subscribing. Subscribe enables automatic renewal and buys a month if existing access is expired. At expiry, a keeper may move one monthly price from prepaid balance to earned revenue and set paid-until to now plus 30 days. Late keepers charge for only one new month, never back-bill missed months. Cancel disables renewal. Re-enabling while access remains valid does not charge again. Insufficient funds revert without consuming the opt-in or previous paid period.

**Trust and configuration.** Select a supported token, nonzero merchant and monthly price in raw units. Users must maintain prepaid funds; the contract never pulls a third party's wallet allowance during keeper calls. There is no keeper reward in this specification, so the merchant or users must arrange keeper availability. Merchant controls the off-chain service, not subscriber accounting. Withdrawals may leave an active subscription unfunded for its next renewal, which is intentional user control.

| Risk scenario and impact | Mitigation or remaining limit |
|---|---|
| Keeper renews repeatedly before expiry to drain deposits. | Renewal requires an expired paid-until timestamp and moves it forward on success. |
| Keeper bills months of downtime in one recovery transaction. | Every renewal buys only one month beginning now; no catch-up loop exists. |
| Merchant withdraws user deposits that have not been earned. | Separate prepaid and revenue accounting; merchant withdrawal consumes only revenue. |
| Cancellation is ignored by a later keeper transaction. | The current auto-renew flag is checked on-chain; transaction ordering at the expiry boundary still determines whether a charge precedes cancellation. |
| Fee-on-transfer deposits overcredit prepaid balances. | Actual receipt is measured; outgoing withdrawals support net minima. |
| Merchant never supplies the promised service, or keepers disappear. | No on-chain service proof or guaranteed renewal exists; subscriber can cancel and withdraw unused funds. |

**Gas.** Deposit is most transfer-heavy due to measurement; renewal updates only accounting and emits an event. There are no subscriber-wide loops or automatic mass billing.

**Coverage.** Tests prove subscription/renewal/cancellation, prepaid and merchant withdrawal, early/cancelled/unfunded rejection, re-enable behaviour, late renewal and taxed deposit. Fuzzing proves prepaid plus earned revenue equals holdings in the supported-token model. Keeper economics, calendar-month semantics and service quality are outside coverage.


## Unstarted scope

The following sections record requirements and prospective review questions only. No source, ABI, deployment parameters, tests or mitigations exist for these entries. Shorter analysis is intentional: a detailed security conclusion about unwritten code would be misleading. Roles and transitions below are planned scope, not implemented permissions.

## 20. PerpetualsLite

**Status: not started.** Single-market isolated-margin perpetual positions, oracle-derived funding and liquidation at 80% margin used.

| Planned roles and permissions | Implementation |
|---|---|
| Trader: margin/position actions; liquidator: unsafe closes; oracle adapter: market observations. | None |

**Intended lifecycle:** Deposit margin → open position → funding checkpoints → close or liquidation. None of these transitions is implemented.

**Trust assumptions and main risks to review:** funding/PnL insolvency; unauthorized margin use; stale/manipulated oracle; settlement callbacks; funding rounding and liquidation griefing. Principal unresolved scenario: insolvent liquidations after price gaps. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 21. StableSwap2

**Status: not started.** Two-stablecoin amplified invariant pool with a 0.04% trading fee.

| Planned roles and permissions | Implementation |
|---|---|
| LP: liquidity actions; trader: swaps; amplification governance: design undecided. | None |

**Intended lifecycle:** Initialize reserves → add liquidity → swap → proportional or single-asset withdrawal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** depeg loss; amplification control; unsafe external price assumptions; token callbacks; convergence, decimal scaling and rounding extraction. Principal unresolved scenario: invariant convergence under depegs. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 22. RevenueSplitter

**Status: not started.** Pull-based distribution of incoming ETH and ERC20 between payees by fixed shares.

| Planned roles and permissions | Implementation |
|---|---|
| Payee: release own entitlement; deployer: initial payee/share configuration. | None |

**Intended lifecycle:** Configure payees → receive income → accrue entitlements → release. None of these transitions is implemented.

**Trust assumptions and main risks to review:** donation accounting; share configuration authority; no price feed intended; receiver reentry; rounding dust and blocked payees. Principal unresolved scenario: fee-token accounting breaks proportional solvency. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 23. Allowlist721

**Status: not started.** Merkle-gated ERC721 minting with per-wallet caps and a one-time owner base-URI reveal.

| Planned roles and permissions | Implementation |
|---|---|
| Allowlisted buyer: mint; owner: reveal; holders: standard NFT actions. | None |

**Intended lifecycle:** Configure root and cap → allowlisted mint → one-time metadata reveal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** mint economics; root/reveal authority; no price oracle intended; receiver callbacks; duplicate claims and address-splitting grief. Principal unresolved scenario: incorrect merkle leaves bypass mint limits. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 24. RateLimitedMinter

**Status: not started.** Role-controlled ERC20 minting with a daily cap for each minter.

| Planned roles and permissions | Implementation |
|---|---|
| Admin: minter roles; minter: bounded daily mint; holder: ERC20 actions. | None |

**Intended lifecycle:** Grant role → mint against daily allowance → reset on a new day → revoke role. None of these transitions is implemented.

**Trust assumptions and main risks to review:** supply inflation; role escalation; no oracle intended; callback-compatible extensions; day-boundary and role-reset bypasses. Principal unresolved scenario: role rotation bypasses cumulative issuance limits. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 25. EmergencyPausableRegistry

**Status: not started.** Address metadata registry with guardian pause, owner unpause and change events.

| Planned roles and permissions | Implementation |
|---|---|
| Registrant/editor: scope undecided; guardian: pause; owner: unpause and role administration. | None |

**Intended lifecycle:** Register/update/remove records while active → guardian pause → owner recovery. None of these transitions is implemented.

**Trust assumptions and main risks to review:** metadata misuse; unauthorized edits; no price oracle intended; external metadata consumers; oversized data and indefinite pause griefing. Principal unresolved scenario: guardian or editor privilege misuse. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 26. SoulboundBadge

**Status: not started.** Non-transferable ERC721 badges issued and revoked by issuer roles.

| Planned roles and permissions | Implementation |
|---|---|
| Issuer: issue/revoke; admin: issuer administration; holder: read badge. | None |

**Intended lifecycle:** Issue → hold without transfer → issuer revocation. None of these transitions is implemented.

**Trust assumptions and main risks to review:** credential value; issuer compromise; no price oracle intended; safe-mint callbacks; revocation and ownership-rotation grief. Principal unresolved scenario: transfer restriction bypass through an inherited path. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 27. Permit2612Token

**Status: not started.** SIMD Stress Token (SST), 18 decimals, capped at 1,000,000 SST; no deployment mint; owner mint and EIP2612 permits.

| Planned roles and permissions | Implementation |
|---|---|
| Owner: capped mint; holder: transfer/approve/sign permit; relayer: submit permit. | None |

**Intended lifecycle:** Deploy empty → owner mint within cap → transfers/approvals → nonce-consuming permits. None of these transitions is implemented.

**Trust assumptions and main risks to review:** cap accounting; mint authority; no oracle intended; signature-verifier interactions; deadline/nonce races and signature malleability. Principal unresolved scenario: permit domain or nonce replay. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 28. BatchAirdrop

**Status: not started.** Merkle-proof token airdrop with claims until a deadline and owner sweep afterward.

| Planned roles and permissions | Implementation |
|---|---|
| Eligible claimant: claim; owner: sweep after expiry. | None |

**Intended lifecycle:** Fund and set distribution root → individual claims → deadline → unclaimed sweep. None of these transitions is implemented.

**Trust assumptions and main risks to review:** underfunding; premature sweep; no oracle intended; token callbacks; duplicate leaves and transfer-tax shortfalls. Principal unresolved scenario: proof or claim-index reuse drains allocation. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 29. DCAVault

**Status: not started.** Stablecoin deposits converted in fixed daily amounts into ETH through the specified AMM.

| Planned roles and permissions | Implementation |
|---|---|
| User: deposit/withdraw; keeper: daily swaps; AMM/WETH boundary: design undecided. | None |

**Intended lifecycle:** Deposit → wait for daily interval → bounded swap → allocate purchased ETH → withdrawal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** adverse execution; keeper misuse; AMM spot/oracle ambiguity; unwrap callbacks; daily accounting and dust griefing. Principal unresolved scenario: keeper trades without enforceable slippage limits. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 30. LimitOrderBook

**Status: not started.** One token-pair on-chain limit orders with partial fills, cancellation and expiry.

| Planned roles and permissions | Implementation |
|---|---|
| Maker: create/cancel; taker: fill within maker price and expiry. | None |

**Intended lifecycle:** Escrow order → partial fills → fully filled, cancelled or expired refund. None of these transitions is implemented.

**Trust assumptions and main risks to review:** unfavourable fills; cancellation authority; no external oracle intended; token callbacks; cumulative rounding and dust orders. Principal unresolved scenario: partial-fill rounding extracts maker collateral. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 31. BondingCurveSale

**Status: not started.** Linear bonding-curve sale with purchases, curve buyback and 1% spread.

| Planned roles and permissions | Implementation |
|---|---|
| Buyer/holder: buy/sell; reserve administration: design undecided. | None |

**Intended lifecycle:** Fund reserve/model → mint from integrated curve cost → burn for sellback proceeds. None of these transitions is implemented.

**Trust assumptions and main risks to review:** curve insolvency; reserve powers; no external oracle intended; payout reentry; integral rounding and spread arbitrage. Principal unresolved scenario: sellback reserves fail to cover curve liability. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 32. ReferralRewards

**Status: not started.** First-deposit referrer tracking with 1% rewards paid from a separately funded pool.

| Planned roles and permissions | Implementation |
|---|---|
| Depositor: initial referrer choice; funder: rewards funding; beneficiary: reward claim. | None |

**Intended lifecycle:** Fund rewards → first deposit fixes referral → accrue reward → pay/claim. None of these transitions is implemented.

**Trust assumptions and main risks to review:** reward farming; referral overwrite; no oracle intended; token callbacks; tiny-deposit rounding and Sybil griefing. Principal unresolved scenario: self-referral farming depletes reward pool. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 33. SavingsLock

**Status: not started.** ETH locked until a chosen date, with 10% early-exit penalty to a charity address.

| Planned roles and permissions | Implementation |
|---|---|
| Saver: open/withdraw/early exit; charity: penalty recipient. | None |

**Intended lifecycle:** Deposit with unlock date → mature withdrawal or early exit with penalty. None of these transitions is implemented.

**Trust assumptions and main risks to review:** penalty calculation; lock ownership; no oracle intended; recipient reentry; timestamp edges and rejecting charity. Principal unresolved scenario: penalty payout blocks principal withdrawal. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 34. VotingEscrow

**Status: not started.** Token locks of one week to four years with decaying voting power, amount increases and extensions.

| Planned roles and permissions | Implementation |
|---|---|
| Locker: create/increase/extend/withdraw; governance consumer: historical power views. | None |

**Intended lifecycle:** Create lock → power decays → increase/extend checkpoint → expiry and withdrawal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** vote economics; unauthorized lock modification; no price oracle intended; token callbacks; decay rounding and checkpoint growth. Principal unresolved scenario: historical voting power corrupted by lock changes. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 35. GaugeController

**Status: not started.** Weekly VotingEscrow-weighted voting over reward allocations to gauges.

| Planned roles and permissions | Implementation |
|---|---|
| VE holder: vote; gauge administrator: scope undecided; reward distributor: read weights. | None |

**Intended lifecycle:** Register gauge → weekly vote/checkpoint → freeze epoch weights → distribute. None of these transitions is implemented.

**Trust assumptions and main risks to review:** reward capture; gauge registration; VE snapshot trust; reward callbacks; weekly resets and unbounded gauge iteration. Principal unresolved scenario: reused voting power overallocates an epoch. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 36. NameRegistry

**Status: not started.** First-come names for a yearly ETH fee, with renewal, transfer, expiry and a grace period.

| Planned roles and permissions | Implementation |
|---|---|
| Registrant: register/renew/transfer; fee recipient and parameter authority: undecided. | None |

**Intended lifecycle:** Available → registered → expired grace → renewed or available again. None of these transitions is implemented.

**Trust assumptions and main risks to review:** fee economics; transfer authority; no oracle intended; receiver callbacks; normalization and expiry/grace races. Principal unresolved scenario: ambiguous name normalization creates spoofed ownership. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 37. Tipping

**Status: not started.** ETH tips with creator messages, pull withdrawal and a top-ten tipper leaderboard.

| Planned roles and permissions | Implementation |
|---|---|
| Tipper: send/message; creator: withdraw; anyone: ranking views. | None |

**Intended lifecycle:** Tip → credit creator/update ranking → creator withdrawal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** ranking Sybils; withdrawal authority; no oracle intended; receiver reentry; tied ranks, large messages and gas griefing. Principal unresolved scenario: leaderboard manipulation or unbounded insertion cost. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 38. LotteryCommitReveal

**Status: not started.** Players commit and reveal secrets; XOR of revealed secrets selects a winner and non-revealers forfeit.

| Planned roles and permissions | Implementation |
|---|---|
| Player: commit/reveal/claim; round-management authority: undecided. | None |

**Intended lifecycle:** Commit window → reveal window → XOR settlement → prize/refund paths. None of these transitions is implemented.

**Trust assumptions and main risks to review:** selective reveal; round powers; entropy authenticity; prize reentry; zero reveals and settlement timeout griefing. Principal unresolved scenario: last revealer biases xor by withholding. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 39. WrappedETH

**Status: not started.** Minimal wrapped ETH with deposit, withdrawal and ERC20 transfers.

| Planned roles and permissions | Implementation |
|---|---|
| Depositor/holder: mint by deposit, transfer, burn for withdrawal. | None |

**Intended lifecycle:** ETH deposit mints equal tokens → ERC20 transfers → burn and ETH withdrawal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** backing conservation; mint authority; no oracle intended; ETH reentry; forced ETH and recipient rejection. Principal unresolved scenario: burn/payment order permits repeated withdrawal. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 40. CreditDelegation

**Status: not started.** A lender delegates limited LendingPool borrowing power to a trusted borrower.

| Planned roles and permissions | Implementation |
|---|---|
| Delegator: set/revoke allowance; delegate: borrow within allowance; LendingPool: enforce debt/collateral accounting. | None |

**Intended lifecycle:** Approve credit → delegated draw → repay/revoke remaining allowance. None of these transitions is implemented.

**Trust assumptions and main risks to review:** credit default; consent enforcement; LendingPool oracle trust; transfer callbacks; allowance/debt rounding and revocation races. Principal unresolved scenario: delegate creates debt against unwilling collateral owner. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 41. StreamingPayments

**Status: not started.** Funded ERC20 streams accruing per second; recipient withdrawal and sender cancellation/refund.

| Planned roles and permissions | Implementation |
|---|---|
| Sender: fund/cancel; recipient: withdraw accrued funds. | None |

**Intended lifecycle:** Create funded stream → accrue/withdraw → finish or cancel with remainder refund. None of these transitions is implemented.

**Trust assumptions and main risks to review:** underfunding; cancellation authority; no oracle intended; token callbacks; fractional rates and timing races. Principal unresolved scenario: cancellation and withdrawal double-count accrued funds. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 42. BountyBoard

**Status: not started.** ETH bounties, work-hash submissions, poster acceptance/payment and expired unclaimed refunds.

| Planned roles and permissions | Implementation |
|---|---|
| Poster: create/accept/refund; hunter: submit work hash and claim accepted prize. | None |

**Intended lifecycle:** Post escrow → submissions → accepted winner or expiry refund. None of these transitions is implemented.

**Trust assumptions and main risks to review:** reward honesty; acceptance authority; no price oracle intended; ETH reentry; copied work and submission spam. Principal unresolved scenario: acceptance races an expired bounty refund. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 43. WhitelistSale

**Status: not started.** Fixed-price allowlisted ERC20 sale with wallet limits, hard cap and post-sale owner withdrawal.

| Planned roles and permissions | Implementation |
|---|---|
| Buyer: prove eligibility/buy; owner: post-sale proceeds withdrawal and configuration. | None |

**Intended lifecycle:** Fund inventory → allowlisted sale → limits or deadline reached → owner withdrawal. None of these transitions is implemented.

**Trust assumptions and main risks to review:** pricing/inventory mismatch; whitelist/admin control; fixed-price quote trust; token callbacks; wallet cap rounding and Sybil bypass. Principal unresolved scenario: decimals or tax accounting exceed inventory/caps. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 44. ProofOfAttendance

**Status: not started.** Organisers create events; attendees claim one non-transferable badge per event using organiser signatures.

| Planned roles and permissions | Implementation |
|---|---|
| Organiser: create/sign event claims; attendee: one claim per event. | None |

**Intended lifecycle:** Create event → authorise attendee signature → unique soulbound mint. None of these transitions is implemented.

**Trust assumptions and main risks to review:** credential farming; organiser authority; no price oracle intended; mint callbacks; signature nonces and duplicate badge grief. Principal unresolved scenario: signature replay across events, recipients or chains. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.

## 45. KeeperRegistry

**Status: not started.** Bonded keepers earn upkeep fees and may be slashed for owner-confirmed missed upkeep reports.

| Planned roles and permissions | Implementation |
|---|---|
| Keeper: register/perform/exit; reporter: report missed work; owner: confirm slashing. | None |

**Intended lifecycle:** Bond → assigned/eligible upkeep → fee or missed report → confirmation/slash → exit. None of these transitions is implemented.

**Trust assumptions and main risks to review:** fee/bond insolvency; slash authority; external upkeep truth; target callbacks; report replay and withdrawal/cooldown races. Principal unresolved scenario: ambiguous missed-upkeep evidence enables unfair slashing. No economic, access-control, oracle, reentrancy, rounding or griefing mitigation is delivered for this contract.

**Configuration and operation:** Constructor values, dependencies, authority boundaries and operational duties remain to be designed and checked before implementation.

**Gas and coverage:** No bytecode or gas profile; zero tests, fuzz cases or security findings against an implementation. Both required source and test files remain absent.
