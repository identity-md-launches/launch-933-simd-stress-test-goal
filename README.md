# SIMD Solidity portfolio

This bounded delivery implements contracts **1–19 in order**. Contracts **20–45 are not started**; their scope and outstanding risks are recorded individually. No placeholder contracts are presented as implementations. No transactions were deployed or broadcast.

See [the portfolio table](docs/SUMMARY.md), [per-contract analysis](docs/ANALYSIS.md), and [security review](docs/SECURITY_REVIEW.md).

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, targets Paris, enables the optimizer with 200 runs, and configures 256 cases per fuzz test. All application sources use `pragma solidity ^0.8.24`. No RPC, environment variables, FFI, filesystem cheatcodes, or external test services are needed. Each test creates fresh local fixtures. The required OpenZeppelin Contracts **5.1.0** sources and MIT license are ordinary files under `lib/openzeppelin-contracts`; no package installation or submodules are needed to build. Foundry and the pinned compiler must already be available to the offline verifier. Tests use a small local cheatcode interface rather than an external test framework.

## Shared assumptions and operation

- Amounts are token **base units** unless expressly labelled as a price or percentage. Lending reads both token precisions and supports 0–18 decimals; the oracle adapter supports feed precision up to 36. Other token accounting does not assume a token precision.
- SafeERC20 handles false-return and no-return token APIs. Incoming transfers debit only `msg.sender`, measure the actual receipt, and credit that receipt. Supported taxed tokens charge the receiver by deducting from the requested transfer amount. Rebases, sender surcharges, confiscation, dishonest balances, and tokens that change these semantics are unsupported. Operators must check configured tokens and any token upgrade authority.
- Net-output minima let users reject unexpectedly taxed transfers. ERC-4626 exact deposit/mint/withdraw/redeem and flash loans require exact receipt; taxed transfers revert atomically. Vault users can instead use `depositReceived` and queued claims. Ordinary donations never grant the donor privileged withdrawal rights.
- Value-moving entry points share OpenZeppelin's reentrancy lock. Outgoing entitlements are consumed before transfers. Inbound receipt measurement necessarily occurs before final crediting under that lock. Applications should not use these contracts' transient spot balances as an external collateral oracle.
- ETH payments are pull credits except for explicitly approved Timelock/MultiSig calls. A recipient contract must accept ETH to withdraw its own credit. Rejecting recipients cannot block other recipients. Forced ETH donations are not liabilities and generally remain unallocated; there is no universal admin sweep.
- Contracts are immutable and have no proxy, hidden pause, upgrade, or rescue authority. Where Ownable2Step is inherited, `transferOwnership`, `acceptOwnership`, and `renounceOwnership` remain available and emit OpenZeppelin events. Renouncing permanently disables the owner functions. Read every role table before assigning owners.
- Deadlines use timestamps with hour/day-scale windows. Callers should act well before the boundary. Keepers, liquidators, queue processors, and relayers are external operational responsibilities; the repository runs none of them.

## Configuration before any separately authorized deployment

Every token, feed, administrator, treasury and counterparty is a constructor parameter. No chain address from the reference tables is embedded or claimed verified. Check code, semantics, token precision, feed quote direction, heartbeat and network-specific oracle protections independently.

For governance integration: deploy the timestamp-checkpoint voting token and Timelock with a bootstrap admin; deploy Governor using those addresses; have the bootstrap admin call `nominateAdmin(governor)`; call `Governor.acceptTimelockAdmin()`; then construct DAOTreasury with that Governor and Timelock. The treasury constructor verifies the handover. A block-number IVotes token is rejected. Governor holds no execution ETH: fund Timelock for proposal call values and fund DAOTreasury for treasury spending. Timelock's admin must remain Governor for treasury spending to work.

The analysis supplies other constructor parameters and policy choices. In particular, raffle randomness trusts the operator; bridge signatures trust an immutable relayer quorum; insurance claim legitimacy trusts its owner; vault yield comes only from externally supplied donations. These mechanisms are educational implementations with explicit economic limits, not claims of production readiness. The review here was performed by the implementing contributor; an independent adversarial review remains outstanding.
