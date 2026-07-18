# Lotto Oracle Architecture Overview v1

Date: 2026-07-17  
Code reference: `src/LottoValidator.hs`

## Purpose

The lottery validator needs randomness at draw time. A Cardano validator cannot call an API, read the internet, or create fresh random numbers by itself. Everything the validator checks must already be inside the transaction or already available on-chain.

This design uses three independent oracle services. Each oracle creates a seed, signs a deterministic message for the current lottery state, and the draw transaction submits those seeds and signatures in the redeemer. The validator verifies the signatures, combines the seeds, and derives winner indexes from the combined seed.

The goal of v1 is simple and auditable:

- each seed is bound to the current on-chain datum state;
- one oracle alone cannot choose the final draw seed;
- the validator can verify signatures fully on-chain;
- the backend has a concrete byte-level message format to implement and test.

## High-Level Flow

1. A round is open until `ldRoundEndTime`.
2. Users buy tickets before `ldRoundEndTime`.
3. At or after `ldRoundEndTime`, the backend asks three oracle services for seeds.
4. Each oracle signs the exact message bytes for the current lottery state and its own seed.
5. The draw transaction submits:
   - `OracleSeed seed1 signature1`
   - `OracleSeed seed2 signature2`
   - `OracleSeed seed3 signature3`
6. The validator checks all three signatures against public keys stored in `LotteryParams`.
7. The validator hashes the three seeds together.
8. The validator derives three winner indexes from the combined seed.
9. If there are fewer than three participants, the round rolls over instead of paying winners.

## On-Chain Data Model

### `LotteryParams`

`LotteryParams` is fixed when the validator is parameterized. It contains configuration that should not change round by round:

```haskell
data LotteryParams = LotteryParams
  { lpMaintainer :: PubKeyHash
  , lpTicketPrice :: Lovelace
  , lpOracle1PublicKey :: BuiltinByteString
  , lpOracle2PublicKey :: BuiltinByteString
  , lpOracle3PublicKey :: BuiltinByteString
  }
```

The oracle public keys are raw Ed25519 verification keys. In normal backend or wallet code, a public key is often wrapped in a JSON type, a bech32 string, a CBOR structure, or a library-specific key object. The validator does not receive that wrapper. It receives the raw bytes that the Plutus builtin expects.

Those bytes are passed to:

```haskell
verifyEd25519Signature
```

Conceptually, `verifyEd25519Signature` answers this question:

```text
Did the private key that matches this public key sign exactly these message bytes?
```

In this design:

- `lpOracle1PublicKey` identifies oracle 1;
- `lpOracle2PublicKey` identifies oracle 2;
- `lpOracle3PublicKey` identifies oracle 3;
- each submitted signature must match the exact oracle position.

This matters because the transaction builder is not trusted to invent randomness. The transaction builder can submit seeds, but the validator only accepts those seeds if the configured oracle keys signed the exact lottery message. If oracle 1's seed is signed by oracle 2, or if the signature was made for a different round end time, different pot, or different seed, the check should fail.

The private keys never go on-chain. They stay with the oracle services. The validator only needs the public keys, because public keys are enough to verify signatures but not enough to create them.

### `LotteryDatum`

The datum is the current on-chain lottery state:

```haskell
data LotteryDatum = LotteryDatum
  { ldRoundEndTime :: POSIXTime
  , ldParticipants :: [PubKeyHash]
  , ldPot :: Lovelace
  }
```

There is no `ldRoundId`. The oracle message is instead bound to existing current state:

- `ldRoundEndTime`
- `ldPot`
- oracle-provided seed

This means the backend must construct the exact same oracle signing message bytes as the validator. It does not mean the backend must construct the datum differently. The datum is still the normal lottery state carried by the script UTXO. The extra responsibility is specifically in the draw/oracle path: when the backend asks an oracle to sign a seed, it must encode `ldRoundEndTime`, `ldPot`, and the seed exactly the same way `oracleMessage` does on-chain.

If the backend signs a text string like `"1725235200000"` but the validator checks binary bytes for `1725235200000`, the signature will not verify. This is why the byte-level example exists in this document.

### `OracleSeed`

Each oracle seed has two fields:

```haskell
data OracleSeed = OracleSeed
  { osSeed :: BuiltinByteString
  , osSignature :: BuiltinByteString
  }
```

`osSeed` is the random material contributed by one oracle. It is not trusted by itself. Anyone can put bytes into a redeemer, so the validator treats the seed as attacker-controlled until the signature check passes.

`osSignature` is the oracle's Ed25519 signature over the full oracle message:

```text
lotto-v1 | current datum round end | current datum pot | this oracle seed
```

When the validator runs `verifyEd25519Signature`, it rebuilds that message from the current on-chain datum and the submitted `osSeed`. If the signature verifies, the validator learns several things at once:

- the seed came from the holder of the configured oracle private key;
- the oracle signed this exact seed, not some other seed;
- the oracle signed for this lottery message version, `lotto-v1`;
- the oracle signed for the current datum's `ldRoundEndTime`;
- the oracle signed for the current datum's `ldPot`.

That last part is important. It helps prevent replaying an old valid `(seed, signature)` pair in a later lottery state. If the round end time or pot changes, the validator rebuilds a different message, so the old signature should no longer match.

The signature does not prove the seed is magically fair. It proves authorization and message binding. Fairness comes from the architecture around it: using multiple independent oracles, combining their seeds, and later improving the protocol if withholding or collusion becomes a concern.

### `LotteryRedeemer`

The draw redeemer carries three oracle seeds:

```haskell
data LotteryRedeemer
  = BuyTicket PubKeyHash
  | Draw OracleSeed OracleSeed OracleSeed
```

The position matters. Oracle 1 is checked against `lpOracle1PublicKey`, oracle 2 against `lpOracle2PublicKey`, and oracle 3 against `lpOracle3PublicKey`.

## Oracle Message Scheme

The validator builds the message inside:

```haskell
oracleMessage :: BuiltinByteString -> BuiltinByteString
```

The exact message format is:

```text
"lotto-v1|round-end:"
<> big-endian base-256 bytes of current ldRoundEndTime
<> "|pot:"
<> big-endian base-256 bytes of current ldPot
<> "|seed:"
<> oracle seed bytes
```

In these examples, `<>` means concatenate bytes: put the bytes on the left directly before the bytes on the right. It is not a separator stored by itself. It is the Haskell operator used in the validator code to join `BuiltinByteString` values into one longer `BuiltinByteString`.

For example:

```text
"abc" <> "def" = "abcdef"
```

For the oracle message, we need concatenation because Ed25519 signs one message byte array. The validator therefore builds one continuous byte string from fixed labels, current datum fields, and the oracle seed.

The same structure with mock variable names:

```text
"lotto-v1|round-end:"
<> **roundEndBytes**
<> "|pot:"
<> **potBytes**
<> "|seed:"
<> **oracleSeedBytes**
```

Example with concrete mock values:

```text
"lotto-v1|round-end:"
<> **0x0191b0080000**
<> "|pot:"
<> **0x989680**
<> "|seed:"
<> **"oracle-1-seed"**
```

Those pieces become one continuous message before signing:

```text
lotto-v1|round-end:<roundEndBytes>|pot:<potBytes>|seed:oracle-1-seed
```

The labels are important. They separate binary integer fields from each other and from the seed. Without labels or lengths, raw concatenation can be ambiguous.

### Copyable Example

Example inputs:

```text
roundEnd = POSIXTime 1725235200000
pot      = Lovelace 10000000
seed     = "oracle-1-seed"
```

The full message as hex is:

```text
6c6f74746f2d76317c726f756e642d656e643a0191b00800007c706f743a9896807c736565643a6f7261636c652d312d73656564
```

The same message as byte values:

```text
[108,111,116,116,111,45,118,49,124,114,111,117,110,100,45,101,110,100,58,1,145,176,8,0,0,124,112,111,116,58,152,150,128,124,115,101,101,100,58,111,114,97,99,108,101,45,49,45,115,101,101,100]
```

Backend rule: the backend and oracle must sign the bytes, not a pretty printed Haskell value.

## Signature Verification

The validator checks each oracle independently:

```haskell
oracleSeedSigned publicKey oracleSeed =
  verifyEd25519Signature
    publicKey
    (oracleMessage (osSeed oracleSeed))
    (osSignature oracleSeed)
```

Breakdown:

- `publicKey` is the configured public key for one oracle. For oracle 1, this is `lpOracle1PublicKey params`.
- `oracleSeed` is the redeemer value submitted for that oracle. It contains both `osSeed` and `osSignature`.
- `osSeed oracleSeed` extracts the raw seed bytes from the redeemer.
- `oracleMessage (osSeed oracleSeed)` rebuilds the exact bytes the oracle was supposed to sign, using the current datum plus that seed.
- `osSignature oracleSeed` extracts the submitted signature bytes.
- `verifyEd25519Signature publicKey message signature` returns `True` only if the signature was created by the private key matching `publicKey` for exactly `message`.

Algorithm key points:

1. Take the submitted seed.
2. Rebuild the expected message from current datum state and that seed.
3. Take the submitted signature.
4. Check the signature against the expected oracle public key.
5. Accept this oracle's seed only if the check returns `True`.

The important detail is that the validator does not trust the seed because it is present in the redeemer. It trusts the seed only after proving that the configured oracle signed a message containing that seed and the current datum values.

Then it combines all three checks:

```haskell
oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3 =
  oracleSeedSigned (lpOracle1PublicKey params) oracleSeed1
    && oracleSeedSigned (lpOracle2PublicKey params) oracleSeed2
    && oracleSeedSigned (lpOracle3PublicKey params) oracleSeed3
```

Breakdown:

- `oracleSeed1` must verify against `lpOracle1PublicKey params`.
- `oracleSeed2` must verify against `lpOracle2PublicKey params`.
- `oracleSeed3` must verify against `lpOracle3PublicKey params`.
- `&&` means all checks must be true. If any oracle signature is missing, malformed, signed by the wrong key, or signed for different message bytes, the draw branch fails.

Algorithm key points:

1. Verify oracle 1's seed with oracle 1's public key.
2. Verify oracle 2's seed with oracle 2's public key.
3. Verify oracle 3's seed with oracle 3's public key.
4. Continue only if all three checks pass.

This gives a clear authorization rule: the draw can only use seeds signed by the configured oracle keys. It also preserves oracle identity. The transaction builder cannot swap oracle 1 and oracle 2 unless the signatures still match the exact public keys expected by the validator.

## Decentralization Model

The design is a 3-oracle commit-by-signature model.

Each oracle contributes one seed. The validator combines the three seeds:

```haskell
combinedSeed =
  blake2b_256 (seed1 <> seed2 <> seed3)
```

This is better than trusting a single backend seed because no single oracle directly controls the final input. If at least one oracle supplies unpredictable seed bytes and does not collude with the transaction builder, the combined seed should remain unpredictable before that honest oracle reveals its seed.

Important limitation: this is not a complete commit-reveal protocol. A transaction builder who sees all three signed seeds before submitting the transaction could choose not to submit an unfavorable draw transaction. That is a liveness/fairness issue, not a signature-verification issue. A later version may need deadlines, penalties, public oracle publication, or a stronger reveal mechanism.

## Winner Selection Algorithm

After the three seeds are combined, the validator derives three separate hashes:

```haskell
seed1 = blake2b_256 (combinedSeed <> "1")
seed2 = blake2b_256 (combinedSeed <> "2")
seed3 = blake2b_256 (combinedSeed <> "3")
```

Each derived hash is converted into an index:

```haskell
entropy =
  byte0 * 16777216
  + byte1 * 65536
  + byte2 * 256
  + byte3

index = entropy `modulo` participantCount
```

The selected winner is removed before the next winner is selected. This prevents the same participant from winning multiple prize slots in the same draw.

Current helper sequence:

1. Select winner 1 from all participants.
2. Remove winner 1.
3. Select winner 2 from remaining participants.
4. Remove winner 2.
5. Select winner 3 from remaining participants.

## Fewer Than Three Participants

The current rule is rollover.

If there are fewer than three participants:

- no winners are selected;
- no payout is checked;
- participants remain in the datum;
- pot remains in the datum;
- round end time advances by one day.

This avoids awkward partial-prize logic and keeps user funds in the next round.

## Draw Validation Order

The draw branch currently checks:

```haskell
Draw oracleSeed1 oracleSeed2 oracleSeed3 ->
  [ validDrawTime
  , currentTxInputValueMatchesDatumPot
  , oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3
  , drawTransitionValid (combinedSeed oracleSeed1 oracleSeed2 oracleSeed3)
  ]
```

The order is readable:

1. Check that this is actually draw time.
2. Check that the current datum honestly describes the current script UTxO value.
3. Check oracle authorization.
4. Check the state transition: payout path or rollover path.

The list is later consumed with `List.and`, so cost-sensitive versions may need direct `&&` structure if short-circuiting and evaluation order become important.

## Backend Responsibilities

The backend must:

1. Read the current script UTxO and datum.
2. Extract `ldRoundEndTime`, `ldPot`, and participants.
3. Ask each oracle for a seed and signature, or run three independent oracle services.
4. Construct the exact message bytes for each seed.
5. Verify signatures off-chain before building the transaction.
6. Build the `Draw` redeemer with three `OracleSeed` values.
7. Build the continuing output:
   - new round state if there are at least three participants;
   - rollover state if there are fewer than three participants.
8. Build payout outputs once `verifyPayouts` is implemented.

## Current Production Gaps

The following are intentionally not complete in v1:

- `verifyPayouts` does not yet verify actual payment outputs.
- `calculateFees` is placeholder logic and currently unused.
- There are no tests yet for invalid oracle signatures.
- There are no tests yet for seed order changes.
- The byte encoding should be mirrored in backend tests.
- The design does not prevent a transaction builder from withholding a completed draw transaction.
- The participant list is stored directly in the datum, which may become expensive if the number of buyers grows.

## Current External Oracle Fit

Existing Cardano oracle providers are mostly feed/statement systems. They are useful for prices or published facts, but this validator currently needs custom signed randomness messages:

```text
lotto-v1 | current round end | current pot | oracle seed
```

This means the current validator fits best with:

1. self-managed oracle services;
2. a custom integration with a provider that agrees to sign this exact message scheme;
3. a future redesign that consumes published on-chain oracle statements by reference input.

## v2 Candidates

Likely next improvements:

- implement real payout verification;
- define the backend byte encoder with tests against the example hex;
- add negative tests for wrong oracle key, wrong pot, wrong round end, wrong seed order;
- decide whether seeds should be published through on-chain oracle UTxOs instead of redeemer fields;
- consider commit-reveal or public publication to reduce withholding risk;
- measure script size and execution budget before optimizing helper structure.
