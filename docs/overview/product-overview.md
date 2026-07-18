# Lotto Product Overview v1

Date: 2026-07-17  
Code reference: `src/LottoValidator.hs`  
Related documents:

- `docs/lotto-business-architecture-v1.md`
- `docs/lotto-plutus-architecture-v1.md`
- `docs/oracle-architecture-v1.md`

## One-Sentence Summary

This is a transparent on-chain lottery where ticket buying, pot tracking, draw
timing, and winner selection are enforced by a smart contract instead of a
central operator.

## What It Does

The lotto contract runs repeated lottery rounds.

During a round, people can buy tickets. Each accepted ticket adds that buyer to
the participant list and increases the pot by the fixed ticket price.

When the round ends, the draw can happen. The contract uses randomness signed by
three independent oracle services to select three winners. If there are not
enough participants, the round rolls over instead of paying out.

The main idea is simple:

```text
buy tickets -> build pot -> close round -> select winners -> start next round
```

## Why Put This On-Chain?

A normal online lottery asks users to trust the operator:

- trust that ticket sales are recorded correctly;
- trust that the pot is not misstated;
- trust that the draw happens after the advertised deadline;
- trust that randomness is not manipulated;
- trust that the operator pays the right winners.

This contract moves the core rules into code that runs on-chain. Anyone can
inspect the transactions and verify that accepted actions followed the same
rules.

The design does not remove every trust assumption, especially around oracle
operation and transaction submission, but it makes the core lottery accounting
and state transitions public and enforceable.

## Who Is Involved?

- **Players** buy tickets.
- **The smart contract** enforces the round rules.
- **Oracle services** provide signed randomness for the draw.
- **The backend** builds transactions that interact with the contract.
- **The maintainer** is the configured wallet intended to receive a maintenance
  fee once payout logic is completed.

The backend can prepare transactions, but it cannot make the contract accept a
transaction that breaks the validator's rules.

## User Journey

1. A player opens the lotto app and sees the current round.
2. The app shows the ticket price, pot, participant count, and round end time.
3. The player buys a ticket by signing a transaction.
4. The contract checks that buying is still open, the player has not already
   bought a ticket, and the pot increases by the correct amount.
5. After the round closes, the backend collects signed randomness from the three
   oracles.
6. A draw transaction is submitted.
7. The contract verifies the oracle signatures and computes the winners.
8. The next round starts, or the current pot rolls over if there were fewer than
   three participants.

## What The Contract Guarantees Today

The current validator is designed to enforce these rules:

- tickets can only be bought before the round end time;
- one wallet can buy at most one ticket per round;
- the buyer must sign their own ticket transaction;
- the recorded pot must match the Lovelace actually locked by the contract;
- each ticket must increase the pot by the configured ticket price;
- draw transactions can only happen after the round end time;
- draw randomness must come from the configured oracle public keys;
- when there are fewer than three participants, the pot and participants roll
  over to the next round.

These are strong accounting and transition rules. They make it hard for a
backend or operator to quietly rewrite the round state.

## What Is Not Finished Yet

The current implementation is not production-ready.

The largest missing piece is payout verification. The validator can select three
winners, but it does not yet enforce that the transaction pays those winners or
the maintainer correctly.

Other important gaps:

- the prize split still needs to be defined;
- the maintenance fee still needs final rules;
- tests for bad oracle signatures and unauthorized actions still need to be
  added;
- the participant list can grow, which may become expensive;
- a transaction builder could choose not to submit an unfavorable completed draw;
- the lotto validator blueprint still needs to be generated.

## Why Three Oracles?

A smart contract cannot call the internet or create fresh randomness by itself.
It can only check data included in the transaction or already available on-chain.

This design uses three oracle services. Each oracle signs a random seed for the
current round. The contract verifies all three signatures and combines the seeds
to create the draw result.

Using three oracles is better than trusting one backend-generated random number.
No single oracle directly controls the final seed unless the others collude or
the transaction builder withholds the draw.

This is still not perfect randomness infrastructure. It is a practical v1 design
that can be improved later with stronger commit-reveal or public oracle
publication.

## What A Viewer Can Verify

A technically curious user or auditor should be able to verify:

- the ticket price configured for this validator;
- whether a ticket transaction happened before the deadline;
- whether the buyer signed the transaction;
- whether the pot increased by the ticket price;
- whether a draw happened after the deadline;
- whether the submitted oracle signatures match the configured oracle keys;
- whether a low-participation round rolled over instead of paying out.

Once payout verification is implemented, they should also be able to verify that
the selected winners and maintainer were paid according to the published prize
rules.

## Business Positioning

This contract is best presented as a transparent lottery engine, not as a
finished consumer product yet.

Its current strengths are:

- clear round lifecycle;
- public pot accounting;
- signed multi-oracle randomness;
- explicit rollover behavior;
- simple one-ticket-per-wallet rule;
- readable Plinth implementation for learning and audit.

Its current limitations are also important to present clearly:

- payout enforcement is unfinished;
- scalability of the participant list is not solved;
- oracle and transaction-submission fairness need more work;
- production deployment needs tests, blueprints, and budget measurements.

## Recommended Demo Story

For a demo, describe it like this:

1. "Here is the current lottery round."
2. "Players buy one ticket each, and every valid ticket visibly increases the
   pot."
3. "The contract will not accept late ticket purchases."
4. "After the deadline, three independent oracles sign randomness for this exact
   round."
5. "The contract checks those signatures before selecting winners."
6. "If not enough players joined, the pot rolls into the next round."
7. "The next production milestone is enforcing the actual payout outputs."

That framing is honest: it explains what is already valuable, while making the
unfinished economic safety work impossible to miss.
