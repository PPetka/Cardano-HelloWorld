# Lotto Plutus Architecture

Date: 2026-07-20  
Code reference: `src/LottoValidator.hs`  
Protocol reference: `docs/technical/protocol-architecture.md`  
Randomness reference: `docs/oracle/randomness-architecture.md`

## Purpose

This document explains how the lotto protocol is expressed in Plutus/Plinth
code. It is written for readers who are learning how the validator works, so it
stays close to the names and helper functions in `src/LottoValidator.hs`.

The validator is a state-machine spending script. Each valid transaction spends
the current lottery UTxO and creates exactly one next lottery UTxO locked by the
same validator.

```text
current script UTxO
  -> validator checks one redeemer action
  -> next script UTxO
```

The current implementation supports two redeemer actions:

- `BuyTicket buyer`
- `Draw caller oracleSeed1 oracleSeed2 oracleSeed3`

Winner selection, oracle signature checking, and payout-output checking exist.
`verifyPayouts` checks the outputs that pay the maintainer, the signed draw
caller, and the three selected winners.

## Validator Entry Points

The compiled validator is produced by:

```haskell
lottoValidatorScript ::
  LotteryParams ->
  CompiledCode (BuiltinData -> BuiltinUnit)
```

`LotteryParams` is applied when building the script. The result is a Plutus V3
validator that receives one runtime argument:

```haskell
BuiltinData
```

That `BuiltinData` is the serialized `ScriptContext`. In Plutus V3, a spending
validator does not receive datum and redeemer as separate top-level arguments.
They are inside the context.

The untyped wrapper decodes the raw context and turns the final `Bool` into
script success or failure:

```haskell
lottoUntypedValidator params ctx =
  PlutusTx.check
    (lottoTypedValidator params (PlutusTx.unsafeFromBuiltinData ctx))
```

`unsafeFromBuiltinData` is acceptable at this boundary because malformed script
input should make the whole transaction invalid. After that point, most logic
uses typed values such as `LotteryDatum`, `LotteryRedeemer`, `TxOut`,
`Lovelace`, and `PubKeyHash`.

## On-Chain Data

`LotteryParams` is fixed for one parameterized validator instance:

```haskell
data LotteryParams = LotteryParams
  { lpMaintainer :: PubKeyHash
  , lpTicketPrice :: Lovelace
  , lpOracle1PublicKey :: BuiltinByteString
  , lpOracle2PublicKey :: BuiltinByteString
  , lpOracle3PublicKey :: BuiltinByteString
  }
```

The maintainer and ticket price are protocol configuration. The three oracle
public keys are raw Ed25519 verification keys used by
`verifyEd25519Signature`.

`LotteryDatum` is the state stored on the current lottery UTxO:

```haskell
data LotteryDatum = LotteryDatum
  { ldRoundEndTime :: POSIXTime
  , ldParticipants :: [PubKeyHash]
  , ldPot :: Lovelace
  }
```

The datum records the deadline, the participant list, and the prize pot. The
script UTxO can hold extra non-prize ADA so it can continue after a draw. The
pot is only trusted after the validator checks that the real Lovelace locked in
the script input covers it.

`LotteryRedeemer` selects the action:

```haskell
data LotteryRedeemer
  = BuyTicket PubKeyHash
  | Draw PubKeyHash OracleSeed OracleSeed OracleSeed
```

For `BuyTicket`, the `PubKeyHash` is the buyer being added. For `Draw`, each
`OracleSeed` contains seed bytes and a signature from one configured oracle.
The order matters: the first seed is checked against `lpOracle1PublicKey`, the
second against `lpOracle2PublicKey`, and the third against
`lpOracle3PublicKey`.

The Template Haskell declarations near these types are part of the Plinth
plumbing:

```haskell
PlutusTx.makeLift ''LotteryParams
PlutusTx.makeIsDataSchemaIndexed ''LotteryDatum [('LotteryDatum, 0)]
```

`makeLift` lets parameters be embedded into compiled Plutus code.
`makeIsDataSchemaIndexed` defines the on-chain data encoding used when datums
and redeemers are converted to and from `BuiltinData`.

## Typed Validator Flow

The typed validator starts from the V3 context:

```haskell
lottoTypedValidator params ctx@(ScriptContext txInfo scriptRedeemer scriptInfo) =
  List.and conditions
```

`ScriptContext` is the validator's view of the spending transaction. This code
extracts three pieces from it:

- `txInfo`: transaction inputs, outputs, signatories, and validity range;
- `scriptRedeemer`: the redeemer for this script execution;
- `scriptInfo`: the script-purpose information, including the spending datum.

The redeemer is decoded from `scriptRedeemer`:

```haskell
redeemer = case PlutusTx.fromBuiltinData (getRedeemer scriptRedeemer) of
  Nothing -> PlutusTx.traceError "Failed to parse LotteryRedeemer"
  Just r  -> r
```

`getRedeemer` unwraps the ledger API `Redeemer` newtype. `fromBuiltinData`
attempts to decode it as `LotteryRedeemer`.

The current datum is decoded from `scriptInfo`:

```haskell
currentDatum = case scriptInfo of
  SpendingScript _ (Just (Datum datum)) ->
    case PlutusTx.fromBuiltinData datum of
      Just d  -> d
      Nothing -> PlutusTx.traceError "Failed to parse LotteryDatum"
  _ -> PlutusTx.traceError "Expected SpendingScript with datum"
```

The `Just` case matters. In Plutus V3, the spending datum can be absent from the
context. This validator rejects that case explicitly because every lotto action
needs the current round state.

## Shared State Checks

Both branches need to know the real value locked at the current script UTxO.
That value is not read from the datum. It is read from the transaction input
that is currently spending this validator:

```haskell
currentTxInputResolvedTxOutput = case findOwnInput ctx of
  Just txInput -> txInInfoResolved txInput
  Nothing      -> PlutusTx.traceError "Expected own input"
```

`findOwnInput` locates the input being validated. `txInInfoResolved` gives the
`TxOut` that input spends. From that output, the validator reads the real ADA
locked at the script:

```haskell
currentTxInputValue =
  lovelaceValueOf (txOutValue currentTxInputResolvedTxOutput)
```

The datum pot is checked against that value before it is trusted:

```haskell
currentTxInputValueCoversDatumPot =
  currentTxInputValue >= ldPot currentDatum
```

This is important in EUTXO code. A datum is just data attached to a UTxO; it can
claim a pot amount. `txOutValue` is the ledger value actually locked by that
UTxO. The validator requires the real UTxO value to cover the recorded prize
pot. Extra ADA can remain at the script as non-prize reserve for the continuing
state UTxO.

Both branches also need the next lottery state. Plutus calls the next UTxO
locked by this same script a continuing output:

```haskell
nextTxOutputWithDatum = case getContinuingOutputs ctx of
  [txOutput] -> case txOutDatum txOutput of
    OutputDatum (Datum nextDatumData) ->
      case PlutusTx.fromBuiltinData nextDatumData of
        Just nextDatum -> (txOutput, nextDatum)
        Nothing -> PlutusTx.traceError "Failed to parse output LotteryDatum"
    _ -> PlutusTx.traceError "Expected inline output datum"
  _ -> PlutusTx.traceError "Expected exactly one continuing output"
```

This validator requires exactly one continuing output and requires it to carry
an inline `LotteryDatum`. That keeps the state machine simple:

```text
currentDatum + currentTxInputValue
  -> branch checks
  -> nextDatum + nextTxOutputValue
```

## BuyTicket Branch

The `BuyTicket buyer` branch accepts a transaction only when all of these checks
pass:

```haskell
BuyTicket buyer ->
  [ validBuyTime
  , currentTxInputValueCoversDatumPot
  , PlutusTx.not (buyerInList buyer)
  , buyerSigned buyer
  , nextDatumPotIncreasesByTicketPrice
  , nextTxOutputHasExpectedPot
  , nextDatumAddsBuyer buyer
  ]
```

`validBuyTime` requires the transaction validity interval to be strictly before
`ldRoundEndTime`. This prevents late buys after the draw window opens.

`buyerInList` scans `ldParticipants currentDatum`. The validator rejects a
buyer already in the list, so the v1 rule is one ticket per wallet per round.

`buyerSigned` scans `txInfoSignatories`. This prevents a transaction builder
from adding another wallet to the participant list without that wallet's
approval.

The two pot checks intentionally check different things:

```haskell
ldPot nextDatum - ldPot currentDatum == lpTicketPrice params
lovelaceValueOf (txOutValue nextTxOutput) ==
  currentTxInputValue + lpTicketPrice params
```

The first check says the next datum records exactly one new ticket. The second
check says the next script output actually locks that extra Lovelace. Together
with `currentTxInputValueCoversDatumPot`, this ties the state transition to
the real ADA controlled by the script.

`nextDatumAddsBuyer` preserves the current round end time and prepends the buyer
to the participant list:

```text
next participants = buyer : current participants
```

That ordering is part of the protocol because winner selection later depends on
list positions.

## Draw Branch

The `Draw` branch accepts a transaction only when all of these checks pass:

```haskell
Draw caller oracleSeed1 oracleSeed2 oracleSeed3 ->
  [ traceIfFalse "Draw: too early" validDrawTime
  , traceIfFalse "Draw: current input does not cover datum pot" currentTxInputValueCoversDatumPot
  , traceIfFalse "Draw: caller did not sign" (callerSigned caller)
  , traceIfFalse "Draw: caller reward bounds invalid" callerRewardBoundsValid
  , traceIfFalse "Draw: oracle seed signature invalid" (oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3)
  , traceIfFalse "Draw: state transition or payouts invalid" (drawTransitionValid caller (combinedSeed oracleSeed1 oracleSeed2 oracleSeed3))
  ]
```

`callerSigned` checks `txInfoSignatories`, the list of public key hashes that
signed this transaction. The caller is explicit in the redeemer because a
transaction can have several signers, so the validator should not guess which
signer earns the reward.

`validDrawTime` requires the transaction validity interval to be at or after
`ldRoundEndTime`. This keeps the draw from closing the round early.

`oracleSeedsSigned` verifies each submitted seed against the matching oracle
public key in `LotteryParams`. The validator rebuilds the signed message from:

- the literal message version `lotto-v1`;
- the oracle slot label, such as `oracle-1`;
- `ldRoundEndTime currentDatum`;
- `ldPot currentDatum`;
- the submitted oracle seed bytes.

This binds each signature to its oracle slot and the current lottery state. A
seed signed for a different oracle slot, round end time, or pot should not verify
here.

`combinedSeed` tags the three oracle seed byte strings in fixed oracle order and
hashes them with `blake2b_256`. The fixed order makes the draw deterministic and
auditable, and the labels make the hash input depend on the oracle slot as well
as the raw seed bytes.

`drawTransitionValid` has two paths:

```haskell
if enoughParticipants
  then nextTxOutputStartsNewRound && verifyPayouts caller seed
  else nextTxOutputRollsOverRound
```

With at least three participants, the next datum must start a fresh round:

- round end time increases by one day;
- participant list becomes empty;
- next datum prize pot is reset to zero;
- next script output keeps only the non-prize script reserve.

The code then calls `verifyPayouts`. It inspects `txInfoOutputs` and requires
the maintainer, caller, and winners to receive at least the amounts calculated
from the payout rule. Overpayment is allowed, so extra off-chain inputs can add
more ADA to a recipient without invalidating the draw.

The payout rule is:

- maintainer receives 4% of the prize pot;
- caller receives at least `lpMinCallerReward`, at most `lpMaxCallerReward`,
  and never more than what remains after maintenance;
- winner 1 receives 50% of the remaining prize pool;
- winner 2 receives 30% of the remaining prize pool;
- winner 3 receives the remainder.

With fewer than three participants, the rollover path is used instead:

- round end time increases by one day;
- participant list is preserved;
- prize pot is preserved;
- next script output preserves the full current script value, including any
  non-prize reserve ADA.

The rollover path intentionally does not call `verifyPayouts`, because no
winners are paid when the round has fewer than three participants.

## Winner Selection

Winner selection is deterministic once the three oracle seeds pass signature
verification.

```text
lotto-v1|combined|oracle-1: <> oracle seed 1
  <> |oracle-2: <> oracle seed 2
  <> |oracle-3: <> oracle seed 3
  -> blake2b_256
  -> combined draw seed
```

The validator derives three separate hashes from the combined seed by appending
`"1"`, `"2"`, and `"3"`. For each derived hash, `winnerIndex` reads the first
four bytes as an integer and reduces it modulo the current participant count.

After selecting a winner, `removeWinner` removes that public key from the list
before the next winner is selected. This prevents the same wallet from winning
more than one of the three winner slots in the same draw.

Because participant order matters, off-chain code must construct the next datum
exactly the same way the validator expects during buys.

## Evaluation Shape

The project enables the `Strict` language extension in Cabal, so local bindings
are strict by default. Some branch-specific helpers use lazy pattern bindings:

```haskell
~validBuyTime = ...
~validDrawTime = ...
```

This prevents a helper for one branch from being evaluated before that branch
needs it. That matters for helpers that inspect continuing outputs or fail with
`traceError`.

The top-level branch checks are currently collected in a list and consumed with
`List.and`. This is clear for learning, but it is not the most budget-focused
shape. For production tuning, measure first, then consider rewriting the hot
checks with direct `PlutusTx.&&` chains or explicit `if then else` so expensive
checks short-circuit without allocating an intermediate list.

On-chain helpers use `INLINEABLE`, not `INLINE`. `INLINEABLE` exposes helper
bodies to the Plinth compiler while still leaving final inlining decisions to
the Plinth/PIR/UPLC optimizers.

The Cabal `plinth-options` section also preserves Plinth-friendly compiler
flags, including the Plutus Core 1.1.0 target:

```cabal
PlutusTx.Plugin:target-version=1.1.0
```

Those flags should stay in place unless budget measurements show a specific
reason to change them.

## Current Gaps To Track

- Add negative tests for missing buyer signatures, duplicate buyers, bad oracle
  signatures, wrong oracle order, wrong timing, malformed next datums, and bad
  pot transitions.
- Add negative tests for missing caller signatures and underpaid payout outputs.
- Consider bounding `ldParticipants` or redesigning ticket representation before
  high-volume rounds.
- Build the relevant Cabal target and regenerate/check blueprints after any
  validator interface change.
