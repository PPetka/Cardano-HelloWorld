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
