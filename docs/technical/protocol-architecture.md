    # Lotto Business Architecture Overview v1

Date: 2026-07-17  
Code reference: `src/LottoValidator.hs`  
Related documents:

- `docs/lotto-plutus-architecture-v1.md`
- `docs/oracle-architecture-v1.md`

## Purpose

This document explains the lotto protocol at a business and product level. It
describes what the lottery is trying to enforce, who interacts with it, and what
must happen during each round.

For the Plutus-specific implementation shape, validator entry point, dependency
tree, and helper-level diagrams, see `docs/lotto-plutus-architecture-v1.md`.
For oracle signing and draw randomness, see `docs/oracle-architecture-v1.md`.

## Actors

- **Buyer**: a wallet that buys one ticket for the current round.
- **Maintainer**: the configured wallet intended to receive the maintenance fee
  once payout checking is implemented.
- **Oracle services**: three independent services that sign randomness for a
  draw.
- **Transaction builder/backend**: off-chain code that reads the current lottery
  UTxO and builds valid `BuyTicket` or `Draw` transactions.
- **Validator**: the on-chain script that accepts or rejects each attempted state
  transition.

## High-Level Contract Shape

The lottery is one stateful on-chain UTxO. That UTxO carries the current lottery
state and locks the current pot.

```text
current lotto UTxO
  state: round end time, participants, pot
  value: pot Lovelace

transaction
  action: BuyTicket or Draw

next lotto UTxO
  state: updated round state
  value: updated pot Lovelace
```

Every valid transaction consumes the current lotto UTxO and creates exactly one
next lotto UTxO. This keeps the contract state moving forward in a simple,
auditable way.

## Round Lifecycle

1. A round starts with a `LotteryDatum`.
2. Buyers may buy tickets before `ldRoundEndTime`.
3. Each accepted ticket adds one participant and increases the pot by
   `lpTicketPrice`.
4. At or after `ldRoundEndTime`, the backend submits a `Draw` transaction.
5. If there are at least three participants, the validator selects three winners
   from oracle-backed randomness and starts a new round.
6. If there are fewer than three participants, the round rolls over: participants
   and pot stay in the contract, and the round end time moves forward by one
   day.

## On-Chain State

The current lottery state is:

```haskell
data LotteryDatum = LotteryDatum
  { ldRoundEndTime :: POSIXTime
  , ldParticipants :: [PubKeyHash]
  , ldPot :: Lovelace
  }
```

- `ldRoundEndTime` controls when buying stops and drawing may start.
- `ldParticipants` is the ticket list for the current round.
- `ldPot` is the contract's recorded pot size.

The validator also checks that `ldPot` matches the real Lovelace locked in the
current lotto UTxO. This matters because the datum is only a claim about state;
the actual UTxO value is the money the contract can control.

The fixed validator configuration is:

```haskell
data LotteryParams = LotteryParams
  { lpMaintainer :: PubKeyHash
  , lpTicketPrice :: Lovelace
  , lpOracle1PublicKey :: BuiltinByteString
  , lpOracle2PublicKey :: BuiltinByteString
  , lpOracle3PublicKey :: BuiltinByteString
  }
```

These parameters define this validator instance: maintainer, ticket price, and
oracle identities.

## Buy Ticket Flow

The `BuyTicket buyer` action means "add this buyer to the current round."

The validator accepts the transaction only when:

1. The transaction is valid before `ldRoundEndTime`.
2. The current UTxO value matches `ldPot`.
3. The buyer is not already in `ldParticipants`.
4. The buyer signed the transaction.
5. The next datum increases `ldPot` by exactly `lpTicketPrice`.
6. The next UTxO actually locks the increased pot.
7. The next datum keeps the same round end time and prepends the buyer to the
   participant list.

The current business rule is one ticket per `PubKeyHash` per round. That is easy
to audit, but it means one wallet cannot intentionally buy multiple tickets in
the same round.

## Draw Flow

The `Draw oracleSeed1 oracleSeed2 oracleSeed3` action means "close this round
using the configured oracle randomness."

The validator accepts the transaction only when:

1. The transaction is valid at or after `ldRoundEndTime`.
2. The current UTxO value matches `ldPot`.
3. All three oracle seeds are signed by the configured oracle public keys.
4. The next state follows either the payout/new-round rule or the rollover rule.

The detailed byte-level oracle scheme is in `docs/oracle-architecture-v1.md`.
At this level, the important rule is that the transaction builder cannot simply
invent randomness. The submitted seeds must be signed by the configured oracle
keys for the current lottery state.

## Winner Selection

Winner selection is deterministic once the three oracle seeds are known.

The validator:

1. Hashes the three oracle seeds together in fixed order.
2. Derives three separate hashes from the combined seed.
3. Converts each derived hash into a participant index.
4. Removes each selected winner before selecting the next one.

Removing selected winners prevents the same participant from winning multiple
prize slots in one draw.

## New Round Path

When there are at least three participants, the draw should:

- select three winners;
- verify winner and maintainer payouts;
- create the next lottery UTxO;
- advance `ldRoundEndTime` by one day;
- reset `ldParticipants` to `[]`;
- set the next `ldPot` to the Lovelace actually locked at the next lottery UTxO.

Important current gap: payout verification is not implemented yet. The validator
currently selects winners but does not enforce payment outputs.

## Rollover Path

When there are fewer than three participants, no payout happens.

The next lottery UTxO must:

- advance `ldRoundEndTime` by one day;
- keep the same participants;
- keep the same pot;
- lock exactly that pot again.

This avoids partial-prize rules and keeps funds in the contract for the next
round.

## Backend Responsibilities

For `BuyTicket`, the backend must:

1. Find the current lottery UTxO.
2. Read and decode `LotteryDatum`.
3. Ensure the buyer is not already in `ldParticipants`.
4. Include the buyer signature.
5. Create exactly one next lottery UTxO with:
   - same `ldRoundEndTime`;
   - `buyer : current participants`;
   - `ldPot + lpTicketPrice`;
   - actual Lovelace value equal to current pot plus ticket price.
6. Set a validity interval strictly before `ldRoundEndTime`.

For `Draw`, the backend must:

1. Find the current lottery UTxO.
2. Read and decode `LotteryDatum`.
3. Wait until the transaction validity range can start at or after
   `ldRoundEndTime`.
4. Ask all three oracles for seeds and signatures for this exact current state.
5. Build the `Draw` redeemer in configured oracle order.
6. Create either the rollover next UTxO or the new-round next UTxO.
7. After payout logic is implemented, create the winner and maintainer outputs.

## Current Production Gaps

- `verifyPayouts` does not yet verify real payment outputs.
- `calculateFees` is placeholder logic.
- The participant list is unbounded and stored directly in the datum.
- The single shared state UTxO can become a concurrency bottleneck.
- The oracle design verifies signatures but does not prevent a transaction
  builder from withholding a completed draw transaction.
- A lotto validator blueprint has not yet been generated.

## v2 Candidates

Likely next improvements:

- implement real payout verification against `txInfoOutputs`;
- define the exact prize split and maintainer fee;
- add tests for unauthorized buyers and duplicate tickets;
- add tests for buy/draw time-boundary behavior;
- add tests for rollover with zero, one, and two participants;
- add oracle signature negative tests from `docs/oracle-architecture-v1.md`;
- bound participant list size or redesign ticket representation;
- generate a lotto validator blueprint;
- profile script size and execution budget before optimizing helper structure.
