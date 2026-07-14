# Agent Instructions

These instructions apply to the whole repository. Read this file before making
or reviewing Plinth/Plutus smart contract code.

## Reporting Rule

When implementing, changing, or reviewing code using any rule below, explicitly
tell the user which instruction point was applied. Use a short section such as:

```text
Instruction points applied:
- P2: Kept on-chain code simple Plinth and avoided unsupported Haskell features.
- P6: Used INLINEABLE rather than INLINE.
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

- **P22. Optimize only after measuring unless the issue is obvious.** First make
  the contract correct and simple, then measure script size and execution budget.
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
- Plinth subset, strictness, pragmas, flags: P4-P8
- Budget shape and hot-path structure: P9-P16, P22-P23
- Security/protocol checks: P17-P21
- Build, blueprint, and artifact validation: P24-P25
