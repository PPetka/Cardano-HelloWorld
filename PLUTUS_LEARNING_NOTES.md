# Plutus Learning Notes

This file collects Plutus/Plinth things that look important, but are easy to
skip while building. Add notes here when something is surprising, non-obvious,
or worth learning properly later so it does not get forgotten.

## Lazy Local Bindings Under `Strict`

This project enables the `Strict` language extension through Cabal. That means
local value bindings are strict by default, which can be surprising in validator
code.

For branch-specific checks, use a lazy pattern binding:

```haskell
~validDrawTime = from currentRoundEndTime `contains` txInfoValidRange txInfo
```

`INLINEABLE` does not make this redundant. `INLINEABLE` exposes the helper body
to the Plinth compiler; it does not change strictness or evaluation order.

Why this matters: if a value is only relevant for the `Draw` redeemer branch, we
do not want it evaluated while validating a `BuyTicket` transaction. This keeps
the branch logic closer to the business rule and avoids unnecessary on-chain
work.

This is especially useful for checks that inspect continuing outputs, decode
next datums, scan transaction outputs, or call helpers that can fail with
`traceError`.

## `deriving stock (Generic)` and `deriving anyclass (HasBlueprintDefinition)`

You will see this pattern on validator-facing data types:

```haskell
deriving stock (Generic)
deriving anyclass (HasBlueprintDefinition)
```

`Generic` comes from `GHC.Generics`. It asks GHC to create a generic structural
description of the Haskell type.

`HasBlueprintDefinition` comes from `PlutusTx.Blueprint`. It uses that generic
type structure to describe the type in generated contract blueprints.

In this project, these are mainly for off-chain metadata and blueprint
generation, not for the core validator decision itself. The on-chain data
encoding is controlled separately by `PlutusTx.makeIsDataSchemaIndexed`.

## Buy Ticket Race Conditions and Concurrency

The current lottery design has one state UTxO for the active round. A ticket
purchase spends that current script UTxO and creates the next script UTxO with
an updated datum and pot.

Because of that, two buy-ticket transactions built from the same current UTxO
are racing for the same input. Only one can confirm. The other must read the new
current UTxO and rebuild if the round is still open. This is normal EUTXO
behavior, not a backend bug.

Common ways to reduce contention:

- **Retry from fresh state.** Keep the validator simple and treat stale
  transactions as normal retries. This is easiest, but busy rounds can produce
  more failed submissions.
- **Batch multiple buyers in one state transition.** One transaction adds
  several buyers at once. If the validator requires buyer signatures, every
  included buyer must sign that exact transaction. If one buyer does not sign,
  the backend usually has to rebuild a smaller transaction and collect
  signatures again.
- **Use separate purchase order UTxOs.** Each user creates an independent order
  UTxO with their payment and authorization. A batcher later consumes many
  orders plus the current lottery UTxO. This avoids needing all users online for
  the final batch, but the validator must verify each order.
- **Shard the round into multiple state UTxOs.** Split purchases across buckets,
  for example by hashing the buyer public key. This allows parallel buys in
  different buckets, but makes the draw and accounting more complex.
- **Represent tickets as independent UTxOs or tokens.** Buying a ticket no
  longer spends one shared state UTxO, so concurrency improves. The hard part is
  giving the draw validator a bounded and verifiable way to know which tickets
  are valid.

The important lesson: the backend can retry, batch, and coordinate, but it
cannot solve this alone. The smart contract must explicitly support the
transaction shape and still enforce the business rules: buyer authorization,
ticket payment, correct next state, and fair draw accounting.
