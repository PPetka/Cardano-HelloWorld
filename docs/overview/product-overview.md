# Lotto Product Overview v1

Date: 2026-07-18  
Code reference: `src/LottoValidator.hs`

## One-Sentence Summary

This is a transparent on-chain lottery where ticket buying, pot tracking, draw
timing, and winner selection are checked by public rules instead of being handled
only by a central operator.

## What It Does

The lotto application runs repeated lottery rounds.

During a round, players can buy tickets. Each accepted ticket adds that player to
the round and increases the prize pool by the fixed ticket price.

When the round ends, the application starts the draw process. Winner selection is
based on randomness from independent sources, and the contract checks that the
draw follows the expected rules before accepting it.

The main idea is simple:

```text
buy tickets -> build prize pool -> close round -> pick winners -> start next round
```

## Why Put This On-Chain?

A normal online lottery asks users to trust the operator:

- trust that ticket sales are recorded correctly;
- trust that the prize pool is not overstated;
- trust that the draw happens after the advertised deadline;
- trust that randomness is not manipulated;
- trust that winners are paid correctly.

This application moves the core lottery rules into a public rule-checking layer.
Anyone can inspect accepted lottery actions and verify that they followed the
same rules.

The design does not remove every trust assumption, especially around randomness
providers and transaction submission, but it makes the core accounting and round
transitions public and enforceable.

## Who Is Involved?

- **Players** buy tickets.
- **The smart contract** checks whether proposed lottery updates follow the
  rules.
- **Randomness providers** contribute signed randomness for the draw.
- **The backend** builds transactions and gives users a normal app experience.
- **The maintainer** operates and improves the system, and is intended to receive
  a maintenance fee once payout rules are finished.

The backend can prepare actions, but it cannot make the contract accept an action
that breaks the validator's rules.

## User Journey

1. A player opens the lotto app and sees the current round.
2. The app shows ticket price, prize pool, participant count, and round end time.
3. The player buys a ticket by approving a transaction.
4. The contract checks that buying is still open and that the pot increases
   correctly.
5. After the round closes, the backend collects randomness from independent
   sources.
6. A draw transaction is submitted.
7. The contract checks the draw inputs and computes the winners.
8. The next round starts.

## What The Contract Guarantees Today

The current validator is designed to enforce these rules:

- tickets can only be bought before the round end time;
- one wallet can buy at most one ticket per round;
- the buyer must approve their own ticket transaction;
- the recorded prize pool must match the funds controlled by the lottery;
- each ticket must increase the prize pool by the configured ticket price;
- draw transactions can only happen after the round end time;
- draw randomness must come from the configured randomness providers.

These are strong accounting and transition rules. They make it hard for a
backend or operator to quietly rewrite the round state.

## How Randomness Works At A High Level

Randomness is not an ordinary built-in feature of a smart contract.

A smart contract is designed to check facts that are already available to it. It
cannot secretly call an outside service, browse the internet, or privately roll
dice. If it could do hidden random work, different machines checking the same
transaction might disagree about the result.

So randomness has to be designed one level above the contract itself. It becomes
part of the protocol around the contract.

In this lotto design:

1. Independent randomness providers create random inputs for the current round.
2. Each provider signs its input so the contract can recognize where it came
   from.
3. The draw transaction submits those signed inputs.
4. The contract checks the signatures.
5. The contract combines the accepted inputs into one draw result.

These randomness providers are often called oracles. An oracle is simply an
outside source that provides information a smart contract cannot create by
itself. Here, the information is draw randomness.

Using several providers is better than trusting one private server. No single
provider is supposed to control the final draw by itself. This is still a v1
randomness design, not the final answer to every fairness problem, but it is a
clear protocol-level improvement over one hidden backend random number.

## What A Viewer Can Verify

A technically curious user or auditor should be able to verify:

- the configured ticket price;
- whether a ticket happened before the deadline;
- whether the buyer approved the ticket;
- whether the prize pool increased by the ticket price;
- whether a draw happened after the deadline;
- whether the draw used inputs from the expected randomness providers.

Once payout verification is implemented, they should also be able to verify that
the selected winners and maintainer were paid according to the published prize
rules.

## What Is Not Finished Yet

The current implementation is not production-ready.

The largest missing piece is payout verification. The validator can select
winners, but it does not yet enforce that the transaction pays those winners or
the maintainer correctly.

Other important gaps:

- the prize split still needs to be defined;
- the maintenance fee still needs final rules;
- tests for bad randomness inputs and unauthorized actions still need to be
  added;
- the participant list can grow, which may become expensive;
- a transaction builder could choose not to submit an unfavorable completed draw;
- deployment artifacts and production monitoring still need work.

## Business Positioning

This contract is best presented as a transparent lottery engine, not as a
finished consumer product yet.

Its current strengths are:

- clear round lifecycle;
- public prize-pool accounting;
- randomness from independent signed sources;
- simple one-ticket-per-wallet rule;
- readable implementation for learning and audit.

Its current limitations are also important to present clearly:

- payout enforcement is unfinished;
- scalability of the participant list is not solved;
- randomness and transaction-submission fairness need more work;
- production deployment needs tests, artifacts, and budget measurements.

## Recommended Demo Story

For a demo, describe it like this:

1. "Here is the current lottery round."
2. "Players buy one ticket each, and every valid ticket visibly increases the
   prize pool."
3. "The contract will not accept late ticket purchases."
4. "After the deadline, independent sources provide signed randomness for the
   draw."
5. "The contract checks those inputs before selecting winners."
6. "The next production milestone is enforcing the actual payout outputs."

That framing is honest: it explains what is already valuable, while making the
unfinished economic safety work impossible to miss.
