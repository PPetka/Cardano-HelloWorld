# Agent Instructions

These instructions apply to the whole repository. Read this file before making
or reviewing Plinth/Plutus smart contract code.

## Reporting Rule

When implementing, changing, or reviewing code using any rule below, explicitly
tell the user which instruction point was applied, and explain what that point
means in the context of the actual code touched. Write this for someone who is
new to Plutus: include the practical reason, the relevant code shape, and the
tradeoff if useful.

Use a section near the end of the response such as:

```text
Instruction points applied:
- P4: Kept the on-chain code simple Plinth.
  In this change, I used a plain helper function and normal pattern matching
  instead of advanced Haskell features. This matters because Plinth is only a
  subset of Haskell, and code compiled into a validator cannot use everything
  ordinary Haskell can use.

- P6: Used INLINEABLE rather than INLINE.
  The helper is part of on-chain code, so it needs its unfolding available to the
  Plinth compiler. `INLINEABLE` exposes the function body while still letting
  the Plinth/PIR/UPLC optimizers decide whether inlining is actually good for
  script size and execution budget.

- P8: Preserved short-circuiting behavior.
  The validation condition still uses `PlutusTx.&&` directly. In Plinth, ordinary
  function arguments are strict, so wrapping `&&` in a custom helper could make
  both sides evaluate even when the first side already fails.
```

If a rule is intentionally not followed, explain why.

## Plutus Version Baseline

- **P1. Confirm version-sensitive facts.** Plutus versions, compiler flags,
  ledger-language behavior, and library APIs change. When the user asks for
  latest/current version information, or when a change depends on latest
  behavior, verify against official Plutus/Intersect/Cardano sources before
  relying on memory.
- **P2. Prefer Plutus V3 / Plinth for new scripts unless compatibility requires
  V1/V2.** In V3, validators have a single `BuiltinData -> BuiltinUnit` shape;
  datum and redeemer are part of the script context, and spending datum can be
  absent. Handle the absent-datum case explicitly.
- **P3. Distinguish version meanings.** "Plutus V1/V2/V3" is the ledger
  language version. Plutus Core has its own version, and Plutus Haskell packages
  such as `plutus-ledger-api`, `plutus-tx`, and `plutus-tx-plugin` have separate
  package versions.

## On-Chain Coding Rules

- **P4. Keep on-chain code simple Plinth.** Avoid advanced Haskell features in
  code compiled by the Plinth plugin: type families, GADTs, existentials,
  mutually recursive data types, `IO`, FFI, and arbitrary third-party libraries.
  Use Plutus/Plinth counterparts instead of unsupported `base` functions.
- **P5. Use strictness deliberately.** On-chain modules should normally use
  `{-# LANGUAGE Strict #-}` or equivalent plugin defaults. Use strict bindings
  for reused expensive values. Use lazy bindings only when they avoid unnecessary
  work, and remember they are not memoized by the UPLC evaluator.
- **P6. Use `INLINEABLE`, not `INLINE`, for on-chain helpers.** `INLINE` can
  bloat scripts. Let the Plinth/PIR/UPLC optimizers make most inlining choices.
- **P7. Preserve Plinth-friendly GHC options.** Do not remove project/compiler
  flags that prevent Haskell optimizations from hurting Plinth output, such as
  disabling full laziness, specialization, strictness analysis, and unboxing of
  strict fields, unless there is a measured reason.
- **P8. Use real short-circuiting constructs.** Prefer `PlutusTx.Bool.&&`,
  `PlutusTx.Bool.||`, or explicit `if then else`. Do not wrap these operators in
  custom ordinary functions when short-circuiting matters, because ordinary
  Plinth function arguments are strict.
- **P9. Avoid strict intermediate structures in hot paths.** Do not build lists,
  maps, or other intermediate values only to immediately consume them. Rewrite
  hot paths as direct recursive scans or fused checks when profiling or code
  shape indicates materialization cost.
- **P10. Specialize hot higher-order code.** Higher-order functions are fine for
  clarity, but closures and generic combinators can cost CPU/memory. In measured
  hotspots, replace them with purpose-built recursive helpers.
- **P11. Use partial failure only when whole-script failure is correct.** For
  invalid transactions, `error`, `traceError`, `unsafeFromBuiltinData`, or
  incomplete matches can be appropriate and cheaper. Do not use them where the
  business logic needs recoverable failure.
- **P12. Remove development traces from production scripts.** Traces are useful
  while debugging but cost size and budget. Prefer the `remove-trace` plugin flag
  or equivalent production path before mainnet deployment.
- **P12a. Add comments for non-obvious on-chain logic.** This project is written
  for a Plutus beginner. When adding or changing validator logic, add short
  comments near checks that explain the business rule and the Plutus/EUTXO reason
  for the check. Prefer comments that explain why the check exists, not comments
  that merely restate the code. Keep comments close to the relevant code, and
  avoid long essays inside hot on-chain functions. When Plutus naming is not
  obvious, add a brief hint; for example, explain that a "continuing output" is
  the next UTxO locked by the same script so the contract state can continue.
  When a check appears only in one redeemer branch, comment why that path needs
  it and why the other path does not.
- **P12b. Explain common Plutus helpers during reviews and discussions.** When
  discussing code with the user, briefly explain recurring Plutus/Plinth helpers,
  classes, and data types in context when they are not obvious: examples include
  `liftCode`, `makeIsDataSchemaIndexed`, `BuiltinData`, `Datum`, `Redeemer`,
  `ScriptContext`, `findOwnInput`, `getContinuingOutputs`, `txInInfoResolved`,
  `txOutValue`, and datum decoding/updating helpers. Say whether the thing is a
  type, function, class, field accessor, constructor, or compiler/plugin helper;
  where it comes from; what inputs it takes; what it returns; and how it affects
  the current validator. For functions used often in Plutus code, explain them
  more deeply than a one-line glossary. Prefer explanations tied to the current
  code over generic documentation-style descriptions.
- **P12c. Use current/next naming for state transitions.** In stateful validators,
  call the datum, txInput, txOutput, and values being spent from the blockchain
  `current...`. Call the datum, txOutput, and values produced by the transaction
  `next...`. Reserve "continuing output" for the Plutus ledger/API concept: an
  output locked by the same script, usually carrying the next state. Prefer names
  like `currentDatum`, `currentTxInputValue`, `nextDatum`, and
  `nextTxOutputHasExpectedPot` over mixed words such as `old`, `new`, or
  domain-unclear `continuing...` helper names.

## Data and Script Context

- **P13. Decode at the boundary by default.** For beginner-friendly code, decode
  incoming `BuiltinData` into domain types with `unsafeFromBuiltinData`, then run
  typed validator logic. This is the default for clarity and safety.
- **P14. Consider `asData` / data-backed APIs for measured V3 context costs.**
  Use `PlutusLedgerApi.Data.V3` and data-backed lists/maps when scripts inspect
  only small portions of a large `ScriptContext`. Prefer record patterns that
  extract all needed fields together.
- **P15. Do not mix `asData` casually.** `asData` works best when nested field
  types are also data-backed or cheap builtins. If a field is a large normal ADT,
  conversion at each use site can erase the benefit.
- **P16. Prefer SOP/Plutus Core 1.1.0 for V3 where supported.** Sums-of-products
  encoding is generally smaller and cheaper than older Scott encoding for data
  types, especially pattern matching over many constructors.

## Security and Protocol Design

- **P17. Bound attacker-controlled data.** Avoid protocols that accept arbitrary
  large datums, unbounded lists/maps, or arbitrary token bundles into trusted
  UTxOs. Check sizes or structure where relevant.
- **P18. Check authorization on every path.** Missing signatures, missing minted
  token checks, or permissive witness redeemers are common smart-contract
  failures. Tests should include cases where each actor/action is unauthorized.
- **P19. Validate minting exactly.** For minting policies, check the currency
  symbol, token names, and quantities that are allowed, and reject extra minting
  or burning unless it is intentional.
- **P20. Account for EUTXO state and concurrency.** Shared state UTxOs can become
  bottlenecks or DoS targets. Prefer designs that shard state, use proof tokens,
  or make contention explicit when the protocol needs throughput.
- **P21. Be careful with parameterized scripts.** Do not assume on-chain code can
  cheaply prove that another script is a specific parameterized instantiation.
  If this matters, design an explicit witness/token/proof mechanism.

## Measurement and Validation

- **P22. Make the business rule correct before optimizing.** Do not encode clever
  shortcuts, artificial constants, or performance-motivated assumptions until
  the protocol rule is clear. First make the validator express the intended
  invariant in simple code. For example, if a datum field is defined as "total
  Lovelace locked at the script UTxO", do not reset it to `0` just because that
  is convenient; check it against the real continuing output value. After the
  rule is correct and readable, measure script size and execution budget before
  doing budget-focused optimizations.
- **P23. Use profiling for budget questions.** For CPU/memory issues, compile
  with profiling options and evaluate fully applied scripts with the `uplc`
  tooling where feasible.
- **P24. Validate generated artifacts after script changes.** Build the relevant
  Cabal target and regenerate/check blueprints when validator or minting policy
  interfaces change. If builds cannot run due to environment or network limits,
  report that explicitly.
- **P25. Keep off-chain and on-chain concerns separate.** Heavy helpers,
  constraints builders, JSON, file IO, networking, and broad libraries belong
  off-chain unless explicitly proven suitable for Plinth compilation.

## Preferred Review Checklist

When the user asks to review code against these instructions, report findings
first, grouped by instruction point. Prioritize correctness/security issues,
then budget/performance issues, then style/maintainability.

Use this checklist:

- Version target and script type: P1-P3
- Plinth subset, comments, strictness, pragmas, flags: P4-P8, P12a-P12c
- Budget shape and hot-path structure: P9-P16, P22-P23
- Security/protocol checks: P17-P21
- Build, blueprint, and artifact validation: P24-P25
