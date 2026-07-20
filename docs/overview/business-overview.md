# Decentralized Lotto Business Overview v1

Date: 2026-07-18

## Simple Summary

This application is a decentralized lottery.

People buy tickets for a lottery round. The ticket money builds a public prize
pool. A smart contract acts as the public rule-checker. When the round ends,
winners are selected through a process that is meant to be visible, auditable,
and harder for one operator to manipulate.

The goal is to make the lottery feel familiar to normal users, while making the
important parts more transparent:

- how big the prize pool is;
- when the round closes;
- whether ticket purchases follow the rules;
- whether the winner-selection process used the expected randomness process.

## The Problem With A Normal Online Lottery

In a normal online lottery, users must trust the operator.

They trust that:

- every ticket is recorded honestly;
- the prize pool is calculated correctly;
- the draw happens at the right time;
- the winner is selected fairly;
- the operator does not quietly change the rules after people join;
- winners are paid correctly.

Even if the operator is honest, users often cannot verify these things directly.
They mostly see the website's promise.

## What Makes This Different

In this decentralized lotto, the most important rules are checked by a smart
contract.

Think of the smart contract as a public rule-checker running in a decentralized
cloud. It does not run the website. It does not choose favorites. It receives a
proposed lottery update and answers one simple question:

```text
Does this update follow the lottery rules?
```

If the update follows the rules, it can be accepted. If it breaks the rules, it
is rejected.

For a normal user, the important idea is:

```text
The app shows the lottery.
The public network stores the important lottery state.
The smart contract checks whether changes are allowed.
```

## What A User Sees

A user should see a simple lottery screen:

- current prize pool;
- ticket price;
- number of participants;
- time left in the round;
- button to buy a ticket;
- draw status after the round closes;
- winner information after the draw is complete.

The experience should feel close to a regular lottery app. The difference is
that the important numbers are not only claims from the operator. They are meant
to be backed by public state and contract rules.

## Basic User Flow

1. A round is open.
2. A user buys a ticket.
3. The prize pool increases.
4. More users can join until the round closes.
5. After the deadline, the draw process starts.
6. Winners are selected.
7. A new round starts.

## Why The Prize Pool Is More Trustworthy

The prize pool is not just a number shown on a website.

The contract records the pot and checks that the funds controlled by the lottery
match the recorded pot. This helps prevent a fake or misleading prize pool.

For a normal user, the message is:

```text
The displayed pot can be backed by funds locked for the lottery.
```

## Why Ticket Buying Is More Trustworthy

A valid ticket purchase must follow the round rules.

The current design says:

- tickets can only be bought before the round closes;
- one wallet can buy one ticket in a round;
- the buyer must approve their own ticket purchase;
- the ticket price must be added to the prize pool.

This gives users a clearer rule set than a private backend where the operator can
quietly change database entries.

## Why The Draw Is More Trustworthy

A lottery needs a fair way to pick winners.

In a centralized lottery, the draw can depend on one private system. In this
design, the draw is based on randomness supplied by independent sources. The
contract checks that the expected sources participated before accepting the draw.

For a normal user, the simplified explanation is:

```text
The winner selection is not supposed to come from one private server.
It is based on randomness contributed by multiple independent sources.
```

This does not magically make the system perfect, but it is a stronger starting
point than asking users to trust one operator-controlled random number.

## Business Value

This lotto can be positioned as a transparent lottery engine.

The value proposition is:

- users can see the prize pool;
- users can see the round timing;
- users can verify that the lottery follows public rules;
- the operator cannot freely rewrite accepted lottery state;
- winner selection uses independent randomness sources;
- the protocol can be audited publicly.

This is useful for communities, crypto-native campaigns, gaming experiences,
prize draws, and promotional lotteries where transparency matters.

## What This Is Not Yet

This is not yet a finished production lottery.

The validator now checks payout outputs for successful draws. It requires the
maintainer, the signed draw caller, and the three selected winners to receive at
least the published amounts.

Before launch, the project still needs:

- tests for bad or dishonest transactions;
- a better plan for very large numbers of participants;
- stronger protection against someone refusing to submit an unfavorable draw;
- production deployment and monitoring work.

## How To Explain It In One Minute

This is a lottery where the important rules are checked publicly instead of
privately.

Players buy tickets. Ticket money builds the prize pool. When the round ends,
the system uses randomness from independent sources to pick winners. The smart
contract acts like a public rule-checker: it accepts lottery updates that follow
the rules and rejects updates that break them.

The aim is to make online lottery more transparent, harder to manipulate, and
easier for users to trust.
