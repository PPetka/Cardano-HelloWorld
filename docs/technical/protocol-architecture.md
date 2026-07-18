# Lotto Protocol Architecture v1

Date: 2026-07-18  
Code reference: `src/LottoValidator.hs`  
Related documents:

- `docs/overview/business-overview.md`
- `docs/overview/product-overview.md`
- `docs/technical/plutus-architecutre.md`
- `docs/oracle/oracle-architecture-v1.md`

## Purpose

This document describes the lotto protocol rules precisely, without going into
Plutus implementation mechanics.

It is more detailed than the overview documents, but less code-focused than the
Plutus architecture document. Treat it as the business/protocol requirements for
the validator.

## Protocol Goal

The protocol controls one active lottery round at a time.

Each round has three pieces of state:

- **Round end time**: the deadline for ticket buying.
  Ticket buys must happen before this time. Draws must happen at or after this
  time.

- **Participants**: the wallets that bought tickets in the current round.
  A wallet can appear at most once in this list during a round.

- **Pot**: the Lovelace prize pool controlled by the lottery.
  The recorded pot must match the actual funds locked at the lottery contract.

Each validator instance also has fixed configuration:

- **Maintainer**: the wallet intended to receive the maintenance fee.
  This matters once payout enforcement is implemented.

- **Ticket price**: the exact price of one ticket.
  Every valid ticket must increase the pot by exactly this amount.

- **Randomness provider keys**: the public identities of the three configured
  randomness providers.
  Draw randomness must be signed by these configured providers.

## State Model

The protocol is a simple state machine:

```text
current lottery state
  -> proposed action
  -> validator checks protocol rules
  -> next lottery state
```

There are two allowed actions:

- **Buy ticket**
  Adds one buyer to the current round. The same round continues with one more
  participant and a larger pot.

- **Draw**
  Closes the current round. Winners are selected and a new round begins, or the
  round follows the low-participation rollover path.

The validator must reject any action that does not fit one of these two state
transitions.

## Buy Ticket Requirements

The buy-ticket action adds one participant to the current round.

Required information:

- buyer wallet;
- current round end time;
- current participants;
- current recorded pot;
- current funds controlled by the lottery;
- proposed next lottery state.

Validation rules:

- **Buying window**
  The transaction must be valid before the round end time.
  This prevents late ticket purchases after the draw window starts.

- **Pot integrity**
  The current recorded pot must match the current locked funds.
  This prevents the rest of the protocol from trusting a false pot number.

- **No duplicate ticket**
  The buyer must not already be in the participant list.
  This enforces one ticket per wallet per round.

- **Buyer authorization**
  The buyer must approve the transaction.
  This prevents someone else from adding a wallet without consent.

- **Pot increase**
  The next recorded pot must equal the current pot plus the ticket price.
  This ensures every accepted ticket increases the recorded prize pool correctly.

- **Funds increase**
  The next lottery funds must equal the current lottery funds plus the ticket
  price.
  This ensures the money is actually locked, not only written into state.

- **Participant update**
  The next participant list must add the buyer and preserve existing
  participants.
  This ensures the ticket is recorded in the next round state.

- **Round continuity**
  The round end time must stay the same.
  Buying a ticket must not move the deadline.

Current participant ordering rule:

```text
new participant list = buyer added before existing participants
```

This ordering matters because winner selection later uses participant positions.
Backends, tests, and audits must treat this as part of the protocol.

## Draw Requirements

The draw action closes the current round.

Required information:

- current round end time;
- current participants;
- current recorded pot;
- current funds controlled by the lottery;
- three signed randomness inputs, one from each configured provider;
- proposed next lottery state;
- payout outputs, once payout enforcement is implemented.

Validation rules:

- **Draw window**
  The transaction must be valid at or after the round end time.
  This prevents drawing before ticket buying closes.

- **Pot integrity**
  The current recorded pot must match the current locked funds.
  This prevents payout logic from trusting a false pot number.

- **Randomness authorization**
  Each randomness input must be signed by its configured provider.
  This prevents the backend from inventing draw randomness.

- **Randomness binding**
  Each signed message must be tied to the current round state.
  This reduces replay risk from old signed randomness.

- **Provider order**
  Provider 1, provider 2, and provider 3 inputs must be used in their configured
  order.
  This makes the draw result deterministic and auditable.

- **State transition**
  The next lottery state must follow either the new-round path or the rollover
  path.
  This prevents arbitrary state rewrites.

## Randomness Protocol Requirement

Randomness is not an ordinary local feature of a smart contract. The contract can
verify data, but it cannot privately create a fresh random number.

For this protocol, randomness is handled one layer above the validator:

1. Three independent providers each create a random input.
2. Each provider signs a message for the current lottery state and its own input.
3. The draw transaction submits all three signed inputs.
4. The validator checks that the signatures match the configured provider keys.
5. The validator combines the accepted inputs into one draw seed.
6. Winner positions are derived from that draw seed.

The detailed byte format and signature rules are specified in
`docs/oracle/oracle-architecture-v1.md`.

Protocol requirement:

```text
No signed randomness input = no valid draw.
Wrong provider signature = no valid draw.
Signed input for the wrong lottery state = no valid draw.
```

## Winner Selection Requirements

Winner selection must be deterministic once the draw randomness is accepted.

The current design requires:

1. **Combine randomness**
   Hash the three signed provider inputs together in fixed order.

2. **Derive winner positions**
   Derive three separate values from the combined draw seed.

3. **Fit positions to the participant list**
   Convert each derived value into an index within the current participant list.

4. **Prevent duplicate winners**
   Remove each selected winner before selecting the next winner.

The same accepted draw inputs and same participant list must always produce the
same winners.

## New-Round Path

When the round has enough participants for a normal draw, the protocol should:

- select three distinct winners from the current participant list;
- verify that winner and maintainer payments match the published payout rule;
- create the next lottery state for a fresh round;
- move the round end time forward by one day;
- start the next participant list empty;
- set the next recorded pot to match the funds locked for the next round.

Current implementation status:

```text
Winner selection exists.
Payout verification is not complete.
```

Payout enforcement is the main blocker before the draw path can be considered
economically safe.

## Low-Participation Rollover Path

The current protocol has a separate path for low participation.

When there are fewer than three participants:

- the draw does not pay winners;
- existing participants stay in the round state;
- the prize pool remains controlled by the lottery;
- the round end time moves forward by one day.

This rule is intentionally kept in this protocol document rather than the
general overview documents because it is an implementation-level business rule,
not part of the simple public explanation.

## Backend Responsibilities

The backend is responsible for building transactions that satisfy the protocol.
It is not trusted to bypass the protocol.

For ticket buying, the backend must:

- read the active lottery state and current pot;
- include the buyer and buyer approval;
- build the next state with the buyer added;
- preserve the current round deadline;
- increase the recorded pot by exactly the ticket price;
- ensure the next lottery output contains the increased pot;
- set the transaction time range before the round ends.

For drawing, the backend must:

- read the active lottery state, participants, and pot;
- collect signed randomness inputs from all configured providers;
- make sure those inputs are signed for this exact lottery state;
- include the signed inputs in the configured provider order;
- build either the new-round state or the rollover state;
- include winner and maintainer payments once payout enforcement is implemented;
- set the transaction time range at or after the round end.

## Current Production Gaps

- **Payout verification is incomplete**
  Winners can be selected, but payments are not yet enforced by the validator.

- **Prize split is not finalized**
  The protocol needs exact percentages or amounts before payout checks can be
  implemented.

- **Maintainer fee is not finalized**
  The validator needs an exact fee rule before it can enforce maintainer payment.

- **Participant list is unbounded**
  Very large rounds may become expensive or impractical.

- **Transaction withholding is possible**
  A builder who sees the draw result may choose not to submit an unfavorable
  draw.

- **Negative tests are missing**
  Unauthorized buyers, bad signatures, wrong timing, and wrong state transitions
  need explicit tests.

- **Deployment artifacts are incomplete**
  Blueprint generation and production checks are still needed.

## v2 Candidates

Likely next improvements:

- define the exact prize split and maintainer fee;
- implement payout verification against transaction outputs;
- test unauthorized buyer actions;
- test duplicate ticket attempts;
- test buy and draw time boundaries;
- test rollover with zero, one, and two participants;
- test wrong randomness provider, wrong state binding, and wrong provider order;
- bound participant list size or redesign ticket representation;
- improve randomness fairness with stronger publication or commit-reveal design;
- generate validator blueprints and measure script size/execution budget.
