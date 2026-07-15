# Plutus Special Cases

This file collects Plutus/Plinth cases that are easy to miss when learning.
Add new entries here when a pattern is surprising, non-obvious, or worth
remembering for future validator work.

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
