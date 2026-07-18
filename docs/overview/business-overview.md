# Decentralized Lotto Business Overview v1

Date: 2026-07-17

## Simple Summary

This application is a decentralized lottery.

People buy tickets for a lottery round. The ticket money builds a public prize
pool. When the round ends, winners are selected using a public process that does
not depend on one company secretly choosing the result.

The goal is to make the lottery feel familiar to normal users, while making the
important parts transparent:

- who joined;
- how big the prize pool is;
- when the round closes;
- how the winner selection is triggered;
- what happens if too few people join.

## The Problem With A Normal Online Lottery

In a normal online lottery, users usually have to trust the operator.

They trust that:

- every ticket is recorded honestly;
- the prize pool is calculated correctly;
- the draw happens at the right time;
- the winner is selected fairly;
- the operator does not change the rules after people join;
- winners are paid correctly.

Even if the operator is honest, users often cannot verify these things directly.
They mostly see the website's promise.

## What Makes This Different

In this decentralized lotto, the core rules are enforced by a smart contract.

That means the important lottery state lives publicly on-chain instead of only
inside a private company database. The application can still have a normal
website or mobile interface, but the rule enforcement happens in a public system.

A user does not need to understand the technical details to understand the value:

```text
The app can show the lottery.
The blockchain can prove the lottery state.
The contract can reject rule-breaking actions.
```

## What A User Sees

A normal user should see a simple lottery screen:

- current prize pool;
- ticket price;
- number of participants;
- time left in the round;
- button to buy a ticket;
- status of the draw after the round closes;
- winner information after the draw is complete.

The user experience should feel close to a regular lottery app. The difference is
that the important numbers are not just claims from the operator. They come from
the public on-chain state.

## Basic User Flow

1. A round is open.
2. A user buys a ticket.
3. The prize pool increases.
4. More users can join until the round closes.
5. After the deadline, the draw can happen.
6. The system uses signed randomness from independent services.
7. Winners are selected.
8. A new round starts.

If too few people joined, the round does not pay out. Instead, the prize pool and
participants roll into the next round.

## Why The Prize Pool Is More Trustworthy

The prize pool is not just a number shown on a website.

In this design, the lottery contract tracks the pot and checks that the real
funds locked in the contract match the recorded pot. This helps prevent a fake
or misleading prize pool.

For a normal user, the message is:

```text
The displayed pot can be backed by funds locked in the smart contract.
```

## Why Ticket Buying Is More Trustworthy

A valid ticket purchase must follow the round rules.

The current design says:

- tickets can only be bought before the round closes;
- one wallet can buy one ticket in a round;
- the buyer must approve their own ticket purchase;
- the ticket price must be added to the pot.

This gives users a clearer rule set than a private backend where the operator can
change database entries without public visibility.

## Why The Draw Is More Trustworthy

A lottery needs randomness. Randomness is hard in decentralized systems because a
smart contract cannot privately roll dice.

This design uses three independent randomness providers, called oracles. Each one
signs its contribution to the draw. The contract checks those signatures before
using the randomness.

For a normal user, the simplified explanation is:

```text
The draw result is based on signed inputs from multiple independent sources,
not on one private server choosing a number.
```

This is stronger than trusting one operator-controlled random number, although it
is not the final version of a perfect randomness system.

## What Happens If Not Enough People Join?

The current rule is simple: if fewer than three people join, the round rolls
over.

That means:

- no winner is selected;
- the prize pool stays in the contract;
- the same participants remain in the next round;
- the next round gets a later deadline.

This avoids awkward small-round payout rules and keeps the experience simple.

## Business Value

This lotto can be positioned as a transparent lottery engine.

The value proposition is:

- users can see the pot;
- users can see the round timing;
- users can verify participation;
- the operator cannot freely rewrite accepted lottery state;
- randomness uses multiple independent signed sources;
- the protocol can be audited publicly.

This is especially useful for communities, crypto-native campaigns, gaming
experiences, prize draws, and promotional lotteries where transparency matters.

## What This Is Not Yet

This is not yet a finished production lottery.

The biggest missing business feature is payout enforcement. The current
validator can identify winners, but the payout rules still need to be completed
so the contract checks that winners actually receive the right amounts.

Before launch, the project still needs:

- final prize split;
- final maintainer fee rule;
- payout enforcement;
- tests for bad or dishonest transactions;
- a better plan for very large numbers of participants;
- stronger protection against someone withholding an unfavorable draw;
- production deployment and monitoring work.

## How To Explain It In One Minute

This is a lottery where the important rules are enforced publicly instead of
privately.

Players buy tickets into a round. Their ticket money builds a pot locked by a
smart contract. When the round ends, the draw uses signed randomness from three
independent sources. The contract checks the rules before accepting the result.
If too few people join, the pot rolls into the next round.

The aim is not just to run a lottery online. The aim is to make the lottery
auditable, harder to manipulate, and easier for users to trust.
