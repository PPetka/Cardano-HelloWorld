# Lotto Backend Transaction Overview v1

Date: 2026-07-20  
Code reference: `src/LottoValidator.hs`  
Related documents:

- `docs/overview/business-overview.md`
- `docs/overview/product-overview.md`
- `docs/technical/protocol-architecture.md`
- `docs/technical/plutus-architecutre.md`
- `docs/oracle/randomness-architecture.md`

## Purpose

This document is for the backend developer who needs to turn the lottery idea
into real Cardano transactions.

The smart contract is the rule-checker. The backend is the transaction builder,
state reader, user-facing API, and scheduled draw operator. The backend cannot
force the contract to accept an invalid action. Its job is to collect the right
information, build the right transaction shape, ask the right wallet or oracle
to sign, submit the transaction, and keep the website in sync with chain state.

Read the overview documents first to understand the product. Then use this file
as the high-level technical map for backend work.

## Mental Model

Think about the system as four layers:

```text
Website
  shows state and asks users to approve actions

Backend API
  reads chain state, prepares transactions, tracks pending actions

Scheduled workers
  run background jobs such as the draw after the round deadline

Cardano / validator
  stores the real lottery UTxO and rejects transactions that break the rules
```

The backend should always treat the chain as the source of truth. A database is
useful for caching, indexing, job status, logs, and user experience, but it must
not become the real lottery state. The real state is the script UTxO carrying
the current `LotteryDatum`.

## What The Backend Owns

The backend usually owns these responsibilities:

- Serve the current round to the website.
- Build a buy-ticket transaction for a player's wallet to sign.
- Submit signed transactions or help the frontend submit them.
- Watch the chain for accepted lottery transactions.
- Keep an indexed view of participants, pot, deadline, and draw status.
- Run a scheduled draw worker after the round deadline.
- Contact the randomness providers and collect signed oracle seeds.
- Build and submit the draw transaction.
- Record failures so operators can retry safely.

The backend does not own these responsibilities:

- It does not decide whether a transaction is valid. The validator does that.
- It does not secretly change the participant list. The next datum is checked by
  the validator.
- It does not invent draw randomness. The draw must use signed randomness from
  the configured providers.
- It should not treat its database as proof that a ticket was bought. A ticket
  counts only after the transaction is confirmed on-chain.

## Main On-Chain Objects

The backend has to understand a few Plutus terms.

`LotteryDatum` is the state stored at the lottery script UTxO. It contains:

- `ldRoundEndTime`: when ticket buying closes;
- `ldParticipants`: wallet public key hashes that bought tickets this round;
- `ldPot`: the recorded Lovelace pot.

`LotteryRedeemer` is the action submitted when spending the script UTxO. It is
either:

- `BuyTicket buyer`;
- `Draw oracleSeed1 oracleSeed2 oracleSeed3`.

The script UTxO is the current lottery box. To change the lottery, a transaction
spends the current script UTxO and creates a next script UTxO with the next
datum. In Plutus language, an output locked by the same script is often called a
continuing output. For this project, use `current...` names for the state being
spent and `next...` names for the state being produced.

## Suggested Backend Components

A clean backend can be split like this:

```text
Chain indexer
  Finds the active lottery script UTxO and decodes its datum.

Round service
  Gives the website a friendly current-round response.

Transaction builder
  Builds unsigned or partially signed Cardano transactions.

Submission service
  Submits signed transactions and tracks confirmation status.

Oracle client
  Requests signed seeds from each randomness provider.

Draw worker
  Runs after the deadline and tries to submit a valid draw.

Database
  Stores cached state, job status, transaction ids, logs, and retry metadata.
```

These can be separate modules before they are separate processes. The important
part is that each module has one job and that transaction-building code reads
fresh chain state before building a transaction.

## State The Website Needs

The website probably wants an API response shaped like this:

```json
{
  "roundEndTime": "2026-07-21T00:00:00Z",
  "ticketPriceLovelace": 10000000,
  "potLovelace": 50000000,
  "participantCount": 5,
  "currentUserHasTicket": false,
  "status": "open",
  "lastKnownTxId": "..."
}
```

Most of this comes from the active script UTxO datum and validator parameters.
`currentUserHasTicket` is derived by checking whether the user's `PubKeyHash` is
inside `ldParticipants`. `status` is derived from the current time, round end
time, pending transaction state, and whether a draw has already been confirmed.

Do not show a ticket as final just because the user clicked the button. Use a
pending state until the buy-ticket transaction is confirmed.

## Buy Ticket Flow

The buy-ticket path is the normal user action.

```text
1. User opens the app.
2. Backend reads the current lottery script UTxO.
3. Backend checks that the round is still open.
4. Backend checks whether this wallet is already in ldParticipants.
5. Backend builds a transaction with redeemer BuyTicket buyer.
6. User signs the transaction in their wallet.
7. Transaction is submitted.
8. Backend waits for confirmation and refreshes the current round from chain.
```

The transaction must spend the current script UTxO and create the next script
UTxO. The next datum should:

- keep the same `ldRoundEndTime`;
- add the buyer to `ldParticipants`;
- increase `ldPot` by exactly `lpTicketPrice`.

The next script output must also contain the increased Lovelace value. It is not
enough to update the datum. The validator checks that the actual locked funds
match the pot rule.

The user must sign because the validator checks buyer authorization. This stops
the backend from buying a ticket for someone else without that wallet's
approval.

## Buy Ticket Race Conditions

Two users can try to buy a ticket at the same time. Both transactions may be
built from the same current script UTxO, but only one can spend it first. The
other one will fail because the script UTxO it tried to spend is already gone.

Handle this as a normal retry case:

```text
Build from current UTxO A.
Another transaction spends UTxO A first.
Your transaction fails or never confirms.
Read the new current UTxO B.
Build again from UTxO B if the round is still open.
```

This is not a backend bug. It is how the EUTXO model works. A stateful contract
has one current state UTxO, and only one transaction can consume that exact UTxO.

There are protocol designs that can reduce this contention, such as batching
several ticket purchases into one transaction, collecting separate purchase
order UTxOs, or splitting the round across multiple state UTxOs. These are not
backend-only optimizations. The smart contract must be designed to validate that
shape safely, including buyer authorization, ticket payment, state updates, and
the later draw accounting.

## Draw Worker Flow

The draw worker is the scheduled backend job. It can run after midnight if the
product defines rounds that close at midnight. More precisely, it should run
when the active round's `ldRoundEndTime` has passed.

```text
1. Scheduler wakes up.
2. Worker reads the active lottery script UTxO.
3. Worker checks that current time is at or after ldRoundEndTime.
4. Worker checks whether a draw is already pending or confirmed.
5. Worker requests one signed seed from each configured oracle.
6. Worker builds a Draw redeemer with the three oracle responses in order.
7. Worker builds the next lottery state.
8. Worker submits the transaction.
9. Worker records the transaction id and watches for confirmation.
```

The worker should be idempotent. If it runs twice, it should not blindly submit
two draw attempts. Store job status such as:

```text
round end time
current script UTxO reference
oracle response status
submitted transaction id
confirmation status
failure reason
retry count
```

Before every retry, read the current chain state again. If another valid draw
already happened, stop retrying.

## Oracle Request Flow

The draw transaction needs three signed `OracleSeed` values. The detailed byte
format is in `docs/oracle/randomness-architecture.md`.

At a high level:

```text
Backend sends current round state to oracle.
Oracle creates random seed bytes.
Oracle signs the exact lotto-v1 message bytes.
Backend receives seed + signature.
Backend places seed + signature in the Draw redeemer.
Validator verifies the signatures on-chain.
```

The backend must be very careful here. The oracle must sign the exact bytes that
the validator rebuilds:

```text
lotto-v1 | oracle slot | current round end | current pot | oracle seed
```

If the backend sends the wrong oracle slot, pot, round end time, number
encoding, seed bytes, or provider order, the signature check will fail and the
draw transaction will be rejected.

Provider order matters:

```text
Draw oracleSeed1 oracleSeed2 oracleSeed3
```

`oracleSeed1` must match oracle public key 1, `oracleSeed2` must match oracle
public key 2, and `oracleSeed3` must match oracle public key 3.

## Draw State Transition

The backend must build one of two next-state shapes.

When there are enough participants for a normal draw, the intended next state is
a fresh round:

```text
next round end time = current round end time + 1 day
next participants   = empty list
next pot            = value locked at the next script UTxO
```

The current implementation can select winners, but payout enforcement is not
complete yet. Before production, the backend and validator need the final payout
rules. The backend will then need to include outputs that pay winners and the
maintainer exactly as the validator expects.

When there are fewer than three participants, the low-participation path rolls
the round forward:

```text
next round end time = current round end time + 1 day
next participants   = current participants
next pot            = current pot
```

This keeps the existing pot and participants in the lottery instead of drawing
with too few players.

## What To Store In The Database

The database should help the app run smoothly, but it should not replace chain
validation.

Useful tables or collections:

- `round_snapshots`: decoded datum, script UTxO reference, pot, participant
  count, observed slot/time;
- `participants`: round identifier or round end time, wallet public key hash,
  buy transaction id, confirmation status;
- `transactions`: transaction id, type, status, submitted time, confirmed time,
  failure reason;
- `draw_jobs`: current script UTxO reference, oracle response status, submitted
  transaction id, retry count;
- `oracle_responses`: provider id, seed bytes hash, signature, message hash,
  round end time, pot;
- `app_events`: operator-readable logs for debugging and audit.

Store raw seeds carefully. They are not private after the draw transaction is
submitted, because they appear in the redeemer, but logs should still avoid
unnecessary sensitive or confusing data. Storing hashes is often enough for
debugging.

## Backend API Shape

Possible API endpoints:

```text
GET  /round/current
POST /transactions/buy-ticket/build
POST /transactions/submit
GET  /transactions/:txId
GET  /round/current/participants
GET  /draw/status
POST /admin/draw/retry
```

The build endpoint should return a transaction for the user's wallet to sign,
not silently spend the user's funds. The submit endpoint should return a clear
pending status because Cardano confirmation is not instant.

Admin endpoints need authentication. A public user should not be able to force
draw retries, change oracle configuration, or mutate backend job state.

## Validation Before Submitting

The backend should check obvious mistakes before submitting a transaction:

- current script UTxO still exists;
- datum decoded successfully;
- transaction time range matches the action;
- next datum follows the expected transition;
- next script output value matches the expected pot;
- buyer has not already joined;
- buyer signature is included for buy-ticket transactions;
- all three oracle responses exist for draw transactions;
- oracle responses are for the current round end time and current pot;
- provider order is correct;
- transaction balances and fees are valid.

These checks are not a replacement for the validator. They make failures easier
to catch before paying fees or confusing the user.

## Monitoring And Operations

At minimum, operators should be able to answer:

- What is the active script UTxO?
- What datum is stored there?
- How many buy-ticket transactions are pending?
- Did the latest draw worker run?
- Did all three oracles respond?
- Was a draw transaction submitted?
- Did it confirm, fail, or time out?
- If it failed, was the cause a stale UTxO, bad oracle signature, timing range,
  balancing issue, or network submission issue?

For scheduled draws, alert if:

- the round deadline passed but no draw job started;
- one or more oracles did not respond;
- a draw transaction failed repeatedly;
- the indexer is behind chain tip;
- the website is showing stale state.

## Common Beginner Mistakes

- Treating the database as final state. The chain is final; the database is a
  cache and operational record.
- Building a transaction from stale script UTxO data.
- Updating the datum pot but forgetting to lock the matching Lovelace value.
- Forgetting that the user wallet must sign a buy-ticket transaction.
- Letting the buy transaction be valid after the round deadline.
- Asking oracles to sign only the seed instead of the full lottery message.
- Mixing up oracle provider order in the `Draw` redeemer.
- Retrying a draw job without first checking whether another draw already
  confirmed.
- Showing a ticket purchase as complete before on-chain confirmation.

## Suggested Implementation Order

1. Build the chain indexer for the active lottery script UTxO.
2. Decode and expose the current `LotteryDatum`.
3. Implement `GET /round/current`.
4. Build buy-ticket transactions.
5. Add transaction submission and confirmation tracking.
6. Add retry handling for stale UTxO buy-ticket failures.
7. Implement oracle clients and byte-level oracle message tests.
8. Implement the draw worker without payout assumptions beyond the current
   validator behavior.
9. Add monitoring and admin retry tools.
10. After payout rules are finalized, update draw transaction outputs and tests.

Do not start with the midnight bot. The bot depends on state indexing,
transaction building, oracle clients, submission, and retries. Build those pieces
first, then the scheduled worker becomes mostly orchestration.

## Production Gaps To Keep Visible

This backend can support demos and development, but the protocol is not finished
for production until these are resolved:

- winner payout enforcement;
- exact prize split and maintainer fee;
- negative tests for unauthorized and malformed transactions;
- participant-list scaling;
- stronger handling of oracle withholding and transaction withholding;
- blueprint generation and validator budget checks;
- operational monitoring for draw failures.

The backend developer should keep these gaps visible in tickets, dashboards, and
release notes. Hiding them in code comments is not enough.
