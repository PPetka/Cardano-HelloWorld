# Smart Contract Testing Guide

Last checked: 2026-07-21.

This guide explains how tests are set up in this repository, how to run them,
and how to add new tests for `LottoValidator`.

The goal is beginner-friendly Plutus testing: tests should read like business
rules, while noisy ledger details live in fixtures and helper modules.

## Current Test Stack

The test suite is a Cabal test target named `plinth-template-test`.

Relevant Cabal stanza:

```cabal
test-suite plinth-template-test
  import:         ghc-only-options, plutus-deps
  type:           exitcode-stdio-1.0
  hs-source-dirs: test
  main-is:        Main.hs
  other-modules:
    Lotto.Fixtures
    Lotto.ValidatorSpec
    TestHelpers.Ledger
  build-depends:
    , base
    , plinth-validators
    , tasty
    , tasty-hunit
```

Tools used:

- `cabal test`: builds and runs the test suite.
- `tasty`: organizes tests into named groups and runs them.
- `tasty-hunit`: provides simple unit-test assertions like `assertBool`.
- `plutus-ledger-api`: provides Cardano ledger types like `ScriptContext`,
  `TxInfo`, `TxOut`, `Datum`, `Redeemer`, `Lovelace`, and `POSIXTime`.
- `plutus-tx`: provides data encoding helpers like `toBuiltinData`.

Useful references:

- Cabal test suites: <https://cabal.readthedocs.io/en/stable/cabal-package-description-file.html#test-suites>
- Tasty: <https://hackage.haskell.org/package/tasty>
- Tasty HUnit: <https://hackage.haskell.org/package/tasty-hunit>
- Plutus V3 ledger API: <https://plutus.cardano.intersectmbo.org/haddock/latest/plutus-ledger-api/PlutusLedgerApi-V3.html>
- Plutus V3 context types: <https://plutus.cardano.intersectmbo.org/haddock/latest/plutus-ledger-api/PlutusLedgerApi-V3-Contexts.html>
- Plutus ledger language versions: <https://plutus.cardano.intersectmbo.org/docs/working-with-scripts/ledger-language-version>
- Evaluating Plinth locally: <https://plutus.cardano.intersectmbo.org/docs/using-plinth/evaluating-plinth>

## How To Run Tests

From the repository root:

```bash
cabal test plinth-template-test
```

If using the Nix shell:

```bash
nix develop
cabal test plinth-template-test
```

Expected current output:

```text
plinth-template
  lotto validator
    BuyTicket
      rejects a ticket purchase whose validity range starts after the round end time: OK

All 1 tests passed
```

To run only matching Tasty tests, pass a pattern after `--test-options`:

```bash
cabal test plinth-template-test --test-options='-p BuyTicket'
```

Tasty patterns match test group names and test names. This is useful once the
suite has separate `BuyTicket` and `Draw` groups.

## File Layout

Current files:

```text
test/
  Main.hs
  TestHelpers/
    Ledger.hs
  Lotto/
    Fixtures.hs
    ValidatorSpec.hs
```

Intended meaning:

- `test/Main.hs` is only the test entrypoint. It should import spec modules and
  combine them with `testGroup`.
- `test/TestHelpers/Ledger.hs` contains generic Plutus ledger helpers that are
  not specific to the lotto contract.
- `test/Lotto/Fixtures.hs` contains reusable lotto-specific defaults and
  override functions.
- `test/Lotto/ValidatorSpec.hs` contains tests grouped by business behavior.

Do not put large `ScriptContext` construction directly in a test case. Put it in
`Fixtures.hs`, then override only the field that matters for the test.

## What A Validator Test Is Actually Testing

In this repository, the lotto validator has this typed entrypoint:

```haskell
lottoTypedValidator :: LotteryParams -> ScriptContext -> Bool
```

That is what the first unit test calls.

At runtime on-chain, the validator is compiled into a Plutus V3 script with this
shape:

```haskell
BuiltinData -> BuiltinUnit
```

In Plutus V3, the `BuiltinData` argument is decoded into `ScriptContext`. The
datum and redeemer are inside that context:

- `scriptContextTxInfo`: the transaction being validated.
- `scriptContextRedeemer`: the redeemer for the current script.
- `scriptContextScriptInfo`: the purpose of the script, such as
  `SpendingScript`.

For this validator, `lottoTypedValidator` extracts:

- the redeemer from `scriptContextRedeemer`
- the current datum from `SpendingScript _ (Just datum)`
- transaction fields from `TxInfo`

So tests need to create a realistic enough `ScriptContext` for the branch being
tested.

## Important Plutus Test Terms

`ScriptContext` is the full ledger view available to the validator. It contains
the transaction inputs, outputs, signers, valid time range, minting field,
redeemers, datums, and the current script purpose.

`TxInfo` is the transaction body seen by the script. The lotto validator reads
fields such as `txInfoValidRange`, `txInfoSignatories`, and `txInfoOutputs`.

`Datum` is the state attached to the script UTxO. For lotto, the datum is
`LotteryDatum`, encoded as `BuiltinData`.

`Redeemer` is the action being attempted. For lotto, it is either:

```haskell
BuyTicket PubKeyHash
Draw PubKeyHash OracleSeed OracleSeed OracleSeed
```

`BuiltinData` is the generic on-chain data representation. Domain values like
`LotteryDatum` and `LotteryRedeemer` are converted to it with
`PlutusTx.toBuiltinData`.

`TxOut` is a transaction output. In stateful contracts, one output is usually
locked by the same script again and carries the next datum.

`getContinuingOutputs` is a Plutus helper used by the validator. It returns
outputs locked by the same script address as the input currently being spent.
For lotto, this is the next state UTxO.

`findOwnInput` finds the script input currently being validated. The lotto
validator uses it to inspect the value currently locked at the script.

## Current Fixture Shape

`Lotto.Fixtures` defines a valid default `BuyTicket` transaction context.

Important defaults:

```haskell
defaultLottoParams :: LotteryParams
defaultLottoContext :: ScriptContext
```

The default context is built so that the `BuyTicket` branch should pass:

- redeemer is `BuyTicket buyerPkh`
- current datum has no participants
- buyer signed the transaction
- transaction is valid before `roundEndTime`
- current script value covers the current datum pot
- next datum adds the buyer
- next datum increases pot by exactly one ticket price
- next script output value increases by exactly one ticket price
- there is exactly one continuing script output

The current test overrides only the time range:

```haskell
lateBuyTicketContext :: ScriptContext
lateBuyTicketContext = withValidRange (Interval.from lateBuyTicketTime)
```

This keeps the test focused on this business rule:

```haskell
validBuyTime =
  to currentRoundEndTime `contains` txInfoValidRange txInfo
```

## Why Fixtures Matter

Validator branches usually check many things at once. For example, `BuyTicket`
currently checks:

- buy time
- current input value covers datum pot
- buyer is not already in participant list
- buyer signed
- next datum pot increased by ticket price
- next output value increased by ticket price
- next datum adds buyer correctly

If every test builds a `ScriptContext` by hand, tests become long and fragile.
Worse, a test intended to check time validity might accidentally fail because
the output datum is wrong.

The fixture approach solves that:

1. Make the default context valid for the branch.
2. In each test, change one thing.
3. Assert that the validator result changes for the expected reason.

This is similar to a builder or fixture pattern in Kotlin tests.

## Testing A Whole Branch vs One Helper

Default rule: test validator branches, not local helper functions.

For this repo, that means most tests should call:

```haskell
lottoTypedValidator defaultLottoParams someContext
```

and use a real redeemer:

```haskell
BuyTicket buyerPkh
Draw caller oracleSeed1 oracleSeed2 oracleSeed3
```

Reason: most helpers inside `lottoTypedValidator` are local `where` functions.
They are not exported and they depend on the same `params`, `ctx`, `txInfo`, and
`currentDatum`. Testing the whole branch gives more confidence that the actual
on-chain path works.

When should helper-level tests exist?

- If a pure helper is exported intentionally.
- If the helper is complex enough to deserve independent examples.
- If the helper has no ledger-context dependency.
- If testing through the branch would require too much unrelated setup.

Examples that could become exported helper tests later:

- selecting winners from a seed
- calculating payout percentages
- converting integer fields into oracle message bytes

But do this carefully. Exporting helpers just for tests can make the production
module API noisy. Prefer branch tests first.

## How To Avoid Unrelated Failures

When testing one rule, keep every other rule valid.

Example: to test that a late ticket fails, do not also make the buyer unsigned.
That would make the test ambiguous. The validator would reject the transaction,
but the test would not prove the deadline check works.

Good pattern:

```haskell
testCase "rejects ticket purchase after round end" $
  assertBool
    "late ticket purchase should fail"
    (not (lottoTypedValidator defaultLottoParams lateBuyTicketContext))
```

Where:

```haskell
lateBuyTicketContext =
  withValidRange (Interval.from lateBuyTicketTime)
```

Bad pattern:

```haskell
lateAndUnsignedContext =
  defaultLottoContext
    { scriptContextTxInfo =
        (scriptContextTxInfo defaultLottoContext)
          { txInfoValidRange = Interval.from lateBuyTicketTime
          , txInfoSignatories = []
          }
    }
```

That tests two failures at once and makes the result less useful.

## How To Add A New BuyTicket Test

1. Decide which rule you want to test.

Example:

```text
rejects duplicate buyer
```

2. Add a focused override helper in `Lotto.Fixtures` if needed.

For duplicate buyer, the moving piece is the current datum participants. A helper
could look like:

```haskell
withCurrentDatum :: LotteryDatum -> ScriptContext
withCurrentDatum currentDatum =
  defaultLottoContext
    { scriptContextScriptInfo =
        SpendingScript lottoInputRef (Just (datum currentDatum))
    }
```

But that alone may not be enough. Because `BuyTicket` also checks the next datum,
the next datum must still be coherent with the changed current datum.

For state transitions, prefer helpers that update current and next state
together:

```haskell
buyTicketContext ::
  LotteryDatum ->
  LotteryDatum ->
  ScriptContext
```

This keeps the EUTXO transition explicit: current state is being spent, next
state is being produced.

3. Add the test under the `BuyTicket` group in `Lotto.ValidatorSpec`.

Example shape:

```haskell
testCase "rejects duplicate buyer" $
  assertBool
    "buyer already in participants should fail"
    (not (lottoTypedValidator defaultLottoParams duplicateBuyerContext))
```

4. Run:

```bash
cabal test plinth-template-test --test-options='-p BuyTicket'
```

## How To Add A Draw Test

`Draw` is more complex than `BuyTicket`.

The `Draw` branch checks:

- transaction is valid after the round end
- current input value covers the datum pot
- caller signed
- caller reward bounds are valid
- all three oracle seeds have valid signatures
- if there are fewer than 3 participants, the round rolls over
- if there are at least 3 participants, payouts and next round state are valid

Start with the simplest `Draw` tests:

1. Draw too early fails.
2. Draw without caller signature fails.
3. Invalid caller reward bounds fail.

These can fail before payout details become the focus.

Oracle signature tests need more setup because the validator uses:

```haskell
verifyEd25519Signature
```

That means a passing draw test needs real Ed25519 public keys and signatures over
the exact oracle message bytes. Do not fake passing oracle signatures unless the
validator has a test-only parameter path, and do not add test-only behavior to
on-chain code. Instead, fixtures should generate or store deterministic test
keys and signatures off-chain.

For failing draw tests that should not depend on oracle signatures, make the
targeted failing check happen before oracle checks. For example:

- "draw too early" can use dummy oracle seeds because `validDrawTime` fails
  first in the current condition order.
- "caller did not sign" can use dummy oracle seeds because the caller signature
  check fails before oracle checks.

This is useful, but be careful: relying on check order is acceptable for simple
negative tests, but it should be documented in the test name or fixture name if
the order matters.

For positive draw tests, build the full valid path.

## Current Test Naming Convention

Use business-language test names:

```text
rejects a ticket purchase whose validity range starts after the round end time
```

Prefer:

- `accepts ...`
- `rejects ...`
- `requires ...`
- `preserves ...`

Avoid names that only repeat implementation details:

```text
validBuyTime false
```

The test reader should learn the contract rule before looking at the code.

## Suggested Future Test File Split

Keep the current structure while the suite is small:

```text
test/
  Lotto/
    Fixtures.hs
    ValidatorSpec.hs
```

When the file gets large, split by redeemer branch:

```text
test/
  Lotto/
    Fixtures.hs
    BuyTicketSpec.hs
    DrawSpec.hs
    ValidatorSpec.hs
```

Then `Lotto.ValidatorSpec` becomes only:

```haskell
tests =
  testGroup
    "lotto validator"
    [ BuyTicket.tests
    , Draw.tests
    ]
```

Do not split too early. A split is useful when it improves navigation, not just
because more files look organized.

## Direct Constructors vs ScriptContextBuilder

The current tests build `ScriptContext` directly with ledger constructors.

This is explicit and good for learning:

- you see every field the validator can inspect
- it works without introducing another testing abstraction
- it makes the EUTXO shape concrete

There is also an official `ScriptContextBuilder` module in the Plutus ledger API
test utilities. It provides functions such as:

- `buildScriptContext`
- `withRedeemer`
- `withSigner`
- `withSigners`
- `withSpendingScript`
- `withOutput`
- `withInput`
- `withScriptInput`
- `withValue`
- `withValidRange`
- `withInlineDatum`

Reference:
<https://plutus.cardano.intersectmbo.org/haddock/latest/plutus-ledger-api/PlutusLedgerApi-Test-ScriptContextBuilder-Builder.html>

That builder can reduce boilerplate later. For now, direct constructors are fine
because this project is a first-time learning repo and the current fixture keeps
the constructor noise away from the specs.

Possible future migration:

```haskell
defaultLottoContext =
  buildScriptContext $
    withSpendingScript ...
      <> withRedeemer ...
      <> withSigner buyerPkh
      <> withValidRange ...
```

Only switch if it makes fixtures clearer. Do not switch just to hide the ledger
model before it is understood.

## Typed, Untyped, And Compiled Tests

There are three useful levels of validator tests.

### 1. Typed Unit Tests

Current level:

```haskell
lottoTypedValidator :: LotteryParams -> ScriptContext -> Bool
```

Pros:

- fastest to write
- easiest failure messages
- good for business rules
- no compiled script evaluation setup

Cons:

- does not prove the `BuiltinData` wrapper works
- does not measure execution budget

Use this for most business-rule tests.

### 2. Untyped Boundary Tests

The on-chain wrapper is:

```haskell
lottoUntypedValidator ::
  LotteryParams ->
  BuiltinData ->
  BuiltinUnit
```

This path decodes `BuiltinData` with `unsafeFromBuiltinData` and then calls the
typed validator.

Use this when testing:

- datum/redeemer encoding
- missing datum behavior
- wrong redeemer shape
- boundary behavior closer to the ledger

### 3. Compiled Script Evaluation Tests

Plutus can evaluate compiled code locally without starting a Cardano node. The
Plutus docs describe this as running Plinth code with the CEK machine to get the
result, traces, and consumed execution budget.

Use this later for:

- execution budget checks
- trace output checks
- confirming the compiled script behaves like the typed tests
- regression tests for expensive paths like draw payout calculation

Do not start here. Start with typed tests, then add boundary and budget tests
once business coverage exists.

## What To Test First

Recommended order for `BuyTicket`:

1. accepts valid ticket purchase before round end
2. rejects ticket purchase after round end
3. rejects duplicate buyer
4. rejects unsigned buyer
5. rejects next datum that does not add the buyer
6. rejects next datum that does not increase pot by ticket price
7. rejects next output value that does not increase by ticket price
8. rejects current input value that does not cover datum pot
9. rejects missing continuing output
10. rejects multiple continuing outputs

Recommended order for `Draw`:

1. rejects draw before round end
2. rejects unsigned caller
3. rejects invalid caller reward bounds
4. rejects invalid oracle signatures
5. accepts rollover with fewer than 3 participants
6. rejects bad rollover next datum
7. rejects bad rollover next output value
8. accepts successful draw with 3 or more participants
9. rejects missing maintainer payout
10. rejects missing caller payout
11. rejects missing winner payout
12. handles overlapping roles correctly, for example caller is also a winner

## Fixture Design Rules

Keep these rules when adding fixtures:

1. Defaults should describe one valid branch path.
2. Override helpers should change one concept, not many unrelated fields.
3. Current state and next state should be named clearly.
4. If changing current datum requires changing next datum, make that coupling
   explicit in a helper.
5. Do not add test-only logic to on-chain validator modules.
6. Do not export production helpers only because one test would be easier.
7. Keep ledger constructors in fixtures, not in specs.
8. Keep test names written as contract behavior.

## Current And Next Naming

Stateful Cardano contracts consume one UTxO and create another UTxO.

Use:

- `currentDatum`: datum on the script UTxO being spent
- `currentScriptValue`: value on the script UTxO being spent
- `nextDatum`: datum on the new script UTxO
- `nextScriptValue`: value on the new script UTxO

This matches the validator's EUTXO transition and avoids vague names like
`old`, `new`, or `continuingDatum`.

The phrase "continuing output" should be reserved for the Plutus concept:
an output locked by the same script as the input being validated.

## Common Failure Modes

If a test unexpectedly fails, check these first:

- Is `scriptContextRedeemer` encoded with the expected redeemer?
- Is `scriptContextScriptInfo` a `SpendingScript` with `Just datum`?
- Does the current script input exist in `txInfoInputs`?
- Does the input address match the continuing output address?
- Is there exactly one continuing output when the validator expects one?
- Does the next output use `OutputDatum`, not `NoOutputDatum`?
- Did the required signer appear in `txInfoSignatories`?
- Does `txInfoValidRange` match the intended time rule?
- Does the Lovelace in `txOutValue` match the datum pot rule?
- Are dummy oracle signatures causing failure before the rule under test?

## Adding Dependencies

If a new test module imports a package not already listed in the Cabal
`test-suite`, add that package to `build-depends`.

If a new test file is added under `test/`, add it to `other-modules` unless it
is the `main-is` module.

Example:

```cabal
other-modules:
  Lotto.Fixtures
  Lotto.ValidatorSpec
  TestHelpers.Ledger
```

If adding QuickCheck later:

```cabal
build-depends:
  , tasty-quickcheck
```

Then group property tests separately from example-based tests.

## What This Guide Does Not Cover Yet

Future docs should add:

- untyped wrapper tests for `lottoUntypedValidator`
- compiled script evaluation tests and budget checks
- deterministic oracle key/signature test fixture generation
- local testnet integration tests
- blueprint regeneration checks after interface changes

Keep this document updated when the test structure changes.
