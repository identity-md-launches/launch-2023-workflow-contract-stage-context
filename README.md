# FOLIR — FolirPayments

Payment-receipt contract for the FOLIR test release on **Sepolia (chain id 11155111)**. No token, pool or
mainnet release. This repository holds the contract, its Foundry tests and its ABI
(`docs/abi/FolirPayments.json`). The website, publication and deployment are handled by later steps.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Compiler pinned in `foundry.toml`: solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`, EVM `cancun`.
`forge-std` is vendored as plain files under `lib/forge-std`. The contract has no other dependencies.

## Behaviour

| Payer | Total | Swarm-funding recipient | Treasury recipient |
| --- | --- | --- | --- |
| Standard | 0.75 units | 0.50 units | 0.25 units |
| Holds ≥ 1 configured identity NFT | 0.50 units | 0.50 units | nothing |

- A *unit* is `10 ** decimals()` of the allowlisted payment token. Decimals are read once by
  `setPaymentToken` and must be between 2 and 36.
- `pay(orderId, token)`: the payer first calls `approve(FolirPayments, total)` on the payment token
  (`quote(payer)` returns the total). `token` must equal the allowlisted `paymentToken`, so a payer is never
  charged in a token other than the one they named. Tokens move directly from the payer to each recipient
  with `transferFrom`. The contract never holds tokens and rejects ETH.
- **Duplicate receipts are not possible:** a receipt is keyed by `keccak256(abi.encode(payer, orderId))`.
  Paying the same `(payer, orderId)` again reverts with `ReceiptAlreadyExists`. `orderId` cannot be zero.
  Because the key includes the payer, nobody else can use up another payer's order id first.
- Each receipt stores a sequential `number` (starting at 1), the payer, orderId, token, both amounts, the
  recipients at the time of payment, whether the identity discount applied, and the timestamp. Read receipts
  with `getReceipt(payer, orderId)`, `getReceiptByNumber(n)`, `isPaid(payer, orderId)` or the
  `PaymentReceived` event.
- The discount depends on the payer's NFT balance (`balanceOf(payer) > 0`) when they pay.
- The contract **starts paused**. `unpause()` reverts with a specific `…NotConfigured` error until the payment
  token, swarm recipient, treasury recipient and identity NFT are all set.
- Reentrancy: `pay` is `nonReentrant` and records the receipt before any token transfer.
- Tokens that return `false`, or revert, make the whole payment revert, so no receipt is left behind.
  Tokens that return nothing (USDT-style) are accepted.

## Deployment parameters

| Contract | Constructor argument | Value |
| --- | --- | --- |
| `FolirPayments` | `address owner_` | `$owner` (the launch owner, `0xd470133a27b58a2949d2a0be9414204db3eb0ab4`) |

The constructor makes no external calls, needs no code at any address and accepts no ETH. The owner is the
argument, never `msg.sender` (the factory) or `tx.origin`. There are no other deployment-time values. The
token, recipients and NFT are owner-set after launch (see below), because the brief does not give their
Sepolia addresses.

## After launch

The owner must make these calls, in this order, before anyone can pay. Each emits an event. Each setter can
be called again later to change the value.

| Setter | Set it to | Where the owner gets it |
| --- | --- | --- |
| `setPaymentToken(address)` | The test ERC-20 on Sepolia used for payments (emits `PaymentTokenSet`) | The test token the requester chooses or deploys; it must have `decimals()` between 2 and 36 and be a standard, non-fee-on-transfer ERC-20 |
| `setSwarmRecipient(address)` | The swarm-funding wallet that gets 0.50 units per payment (emits `SwarmRecipientSet`) | The requester's swarm-funding address |
| `setTreasuryRecipient(address)` | The treasury wallet that gets 0.25 units per standard payment; must be different from the swarm recipient (emits `TreasuryRecipientSet`) | The requester's treasury address |
| `setIdentityNft(address)` | The test ERC-721 identity NFT on Sepolia (emits `IdentityNftSet`) | The test NFT collection the requester chooses or deploys |
| `unpause()` | — (emits `Unpaused`) | Call once all four are set |

Until these are set: `pay` reverts with `IsPaused`, `quote` reverts with `PaymentTokenNotConfigured`, and
`unpause` reverts with the first missing setting's error.

## Owner powers and trust assumptions

The owner (two-step transfer: `transferOwnership` then `acceptOwnership`; `transferOwnership(address(0))`
cancels a pending transfer) can:

- pause and unpause payments (unpause only when fully configured);
- change the payment token, both recipients and the identity NFT at any time, including while unpaused.
  Payments made before a change keep their stored receipt. A pending payment that names the old token
  reverts with `TokenNotAllowlisted` and is not charged.

The owner cannot move payers' tokens beyond what each payer approved for a single `pay` call's amount, cannot
edit or delete receipts, and has no withdrawal function, because the contract never holds funds. Payers
should approve only the quoted amount, not an unlimited allowance. If they approve more, a later owner
change of recipients would only affect payments they make themselves.

Assumptions:

- The payment token is a standard ERC-20 with no transfer fee and no rebasing. A fee-on-transfer token would
  deliver less than the recorded amounts. The owner is responsible for allowlisting a suitable token.
- The identity NFT's `balanceOf` must not revert. If it does, payments revert until the owner sets a working
  NFT.
- The NFT discount is checked at payment time. NFTs that can be transferred can be lent for a discount; this
  is acceptable for a test release.
- Receipts prove payment only. Delivering the "analysis" off-chain from a receipt is the frontend's or
  operator's job.

## Operational responsibilities

- **IMD services** (after this stage): publish the source, attest it, generate and review `launch.json`, and
  deploy through the launch factory on Sepolia. This assignment does not deploy, broadcast or sign anything.
- **Owner** (`$owner`): complete "After launch", keep the owner key safe, pause if a problem is found.
- **Frontend**: use the deployed address from the deployment handoff and `docs/abi/FolirPayments.json`.
  Generate a unique non-zero `orderId` per purchase (for example `keccak256(wallet, plan, nonce)`), call
  `quote`, `approve` exactly `total`, then `pay(orderId, paymentToken)`. Show receipts from `getReceipt` and
  `PaymentReceived`.

## Security notes

Tests are not an audit. An independent adversarial review is required before release. Checks run here:
`forge build`, `forge test` (34 tests: unit, failure-path, reentrancy, fund-conservation fuzz and a
factory-deployment rehearsal with an opcode scan), `forge fmt --check`. Slither and Mythril were not run.
