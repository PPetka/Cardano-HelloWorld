# Lotto Randomness Architecture v1

Date: 2026-07-17  
Code reference: `src/LottoValidator.hs`

## Purpose

The lottery validator needs randomness at draw time. A Cardano validator cannot call an API, read the internet, or create fresh random numbers by itself. Everything the validator checks must already be inside the transaction or already available on-chain.

This design is about producing draw randomness that the validator can verify. Oracles are the source of the random inputs. Each oracle creates a seed, which is a chunk of random bytes. A realistic 32-byte seed could look like this in hex:

```text
8f34c1a9d502be77f015c9ee6a4d2b9081ab44f026973d5c19ef6a8726b013cd
```

The seed is not the winner result by itself. It is one ingredient that gets mixed with the other oracle seeds.

Using three seeds is stronger than using one seed because no single oracle gets to decide the final random value. If only one oracle provided the seed, that oracle could try different seeds until it found one that helped a chosen ticket. That is the contract hack this design is trying to avoid: biased randomness could make the validator accept a draw that sends the lottery pot to an attacker-controlled winner. In practical terms, weak randomness can compromise the script UTxO because the UTxO is where the lottery money is locked.

With three independent seeds, the final value depends on all three inputs. **As long as at least one oracle gives an honest random seed that the others could not predict in advance, the combined seed should be unpredictable.**

Each oracle signs a message that contains:

- the message version, `lotto-v1`;
- the oracle slot, such as `oracle-1`;
- the current round end time from the datum;
- the current pot from the datum;
- that oracle's seed.

This means the seed is only part of the signed message. The oracle is not just signing "here is my random seed". It is signing "here is my random seed for this exact lottery state".

The draw transaction submits three seeds and three signatures in the redeemer. The validator verifies the signatures, combines the seeds, and derives winner indexes from the combined seed.

This is an introductory oracle-randomness design, not a complete production randomness beacon. It is a first step toward bringing randomness from outside the validator and making the submitted values checkable on-chain. Production designs need a fuller threat model around oracle honesty, oracle availability, seed grinding, withholding, public auditability, and block producer influence.

The goal of v1 is simple and auditable:

- each seed is bound to its oracle slot and the current on-chain datum state;
- one oracle alone cannot choose the final draw seed;
- the validator can verify signatures fully on-chain;
- the backend has a concrete byte-level message format to implement and test.

## High-Level Flow

1. A round is open until `ldRoundEndTime`.
2. Users buy tickets before `ldRoundEndTime`.
3. At or after `ldRoundEndTime`, the backend asks three oracle services for seeds.
4. Each oracle signs the exact message bytes for its oracle slot, the current lottery state, and its own seed.
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

This matters because anyone building the transaction can put seed bytes in the redeemer. The validator does not trust those bytes just because they were submitted. It only accepts a seed when the matching oracle signed the exact message for this lottery state.

So oracle 1's seed must be signed by oracle 1's key, oracle 2's seed by oracle 2's key, and oracle 3's seed by oracle 3's key. The signature must also match the current round end time, current pot, and that exact seed. If any of those details are different, the validator rejects the draw.

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

There is no `ldRoundId`. The signed randomness message is instead bound to existing current state:

- `ldRoundEndTime`
- `ldPot`
- oracle slot
- oracle-provided seed

This means the backend must construct the exact same signing message bytes as the validator. It does not mean the backend must construct the datum differently. The datum is still the normal lottery state carried by the script UTXO. The extra responsibility is specifically in the draw/oracle path: when the backend asks an oracle to sign a seed, it must encode the oracle slot, `ldRoundEndTime`, `ldPot`, and the seed exactly the same way `oracleMessage` does on-chain.

This is why the byte-level example exists in this document. If the backend signs different bytes from the bytes rebuilt by the validator, the signature will not verify.

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
lotto-v1 | oracle slot | current datum round end | current datum pot | this oracle seed
```

When the validator runs `verifyEd25519Signature`, it rebuilds that message from the current on-chain datum and the submitted `osSeed`. If the signature verifies, the validator learns several things at once:

- the seed came from the holder of the configured oracle private key;
- the oracle signed this exact seed, not some other seed;
- the oracle signed for this lottery message version, `lotto-v1`;
- the oracle signed for its expected oracle slot;
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

## Signed Randomness Message

The validator builds the message inside:

```haskell
oracleMessage :: BuiltinByteString -> BuiltinByteString -> BuiltinByteString
```

This is the most important backend rule in v1: the oracle signs the exact message bytes built by `oracleMessage`, not only the seed.

`oracleMessage` takes two inputs: the oracle slot label and the oracle seed bytes. The other two values come from the current datum already locked at the script UTxO:

- `oracleName`, the fixed oracle slot label such as `oracle-1`;
- `ldRoundEndTime`, the current round end time;
- `ldPot`, the current pot recorded by the lottery state.

So each oracle signs a message shaped like this:

```text
"lotto-v1|oracle:"
<> oracle slot bytes
<> "|round-end:"
<> big-endian base-256 bytes of current ldRoundEndTime
<> "|pot:"
<> big-endian base-256 bytes of current ldPot
<> "|seed:"
<> oracle seed bytes
```

In this file, `<>` means "put these bytes directly after the previous bytes". Ed25519 signs one byte array, so the validator joins the labels, datum bytes, and seed bytes into one continuous message.

### One Concrete Example

Input values:

```text
roundEnd = POSIXTime 1725235200000
pot      = Lovelace 10000000
oracle   = "oracle-1"
seed     = "oracle-1-seed"
```

Number encoding:

```text
1725235200000 as big-endian bytes = 0x0191b0080000
10000000 as big-endian bytes      = 0x989680
```

The exact message bytes, shown with escapes, are:

```text
lotto-v1|oracle:oracle-1|round-end:\x01\x91\xb0\x08\x00\x00|pot:\x98\x96\x80|seed:oracle-1-seed
```

Those exact bytes, shown as hex, are:

```text
6c6f74746f2d76317c6f7261636c653a6f7261636c652d317c726f756e642d656e643a0191b00800007c706f743a9896807c736565643a6f7261636c652d312d73656564
```

The same message as byte values:

```text
[108,111,116,116,111,45,118,49,124,111,114,97,99,108,101,58,111,114,97,99,108,101,45,49,124,114,111,117,110,100,45,101,110,100,58,1,145,176,8,0,0,124,112,111,116,58,152,150,128,124,115,101,101,100,58,111,114,97,99,108,101,45,49,45,115,101,101,100]
```

All three blocks above are the same message shown in different forms. For signing, the backend/oracle must use the bytes. The hex form is the safest copyable test value.

The escaped form is useful only if the backend language treats it as a real byte literal, where `\x01` means one byte with value `1`. Conceptually:

```text
escaped byte literal:
lotto-v1|oracle:oracle-1|round-end:\x01\x91\xb0\x08\x00\x00|pot:\x98\x96\x80|seed:oracle-1-seed

to hex:
6c6f74746f2d76317c6f7261636c653a6f7261636c652d317c726f756e642d656e643a0191b00800007c706f743a9896807c736565643a6f7261636c652d312d73656564
```

Read that as a byte-literal example, not as a rule for every programming language. Different languages handle string escapes differently. Backend tests should compare the produced message bytes to the hex value above.

The seed is only the last part of the message. In this example, the oracle contributes `oracle-1-seed`, but it signs the full message:

```text
context bytes from the validator <> oracle seed bytes
```

That is like signing:

```text
my_context_string_in_bytes <> random_seed_bytes_from_oracle
```

This lets the validator verify two things at the same time:

- the seed came from the oracle that owns the matching private key;
- the seed was meant for this exact oracle slot and lottery state, not for a different oracle, round, or pot.

The oracle can create the seed itself and return both values to the backend:

```text
seed
signature over the full signed randomness message
```

The backend includes both values in the draw redeemer. The validator rebuilds the same message from the oracle slot, current datum, and submitted seed, then checks the signature with the oracle's public key.

The labels are important. They separate the binary integer fields from each other and from the seed. Without labels or lengths, raw concatenation can be ambiguous.

### Domain Separation and Deterministic Random Expansion

This design uses a technique commonly called **domain separation**. The idea is
to put an explicit label, prefix, or context string into the bytes before hashing
or signing them. Here, labels such as `lotto-v1`, `oracle:`, `round-end:`, `pot:`, and
`seed:` tell both the backend and the validator what each part of the byte string
means.

That matters because hashes and signatures only see bytes. They do not know that
one byte sequence is supposed to be a round end time and another byte sequence is
supposed to be a seed. Domain labels make accidental overlap much less likely:
a seed signed for `lotto-v1|oracle:oracle-1|round-end:...|pot:...|seed:...` is not just a free
floating random value that can be reused in some unrelated protocol or message
shape.

The winner-selection step uses the related technique of **deterministic random
expansion**. After the three oracle seeds are combined into one `combinedSeed`,
the validator derives separate random-looking values by hashing the combined
seed with different labels:

```haskell
seed1 = blake2b_256 (combinedSeed <> "1")
seed2 = blake2b_256 (combinedSeed <> "2")
seed3 = blake2b_256 (combinedSeed <> "3")
```

This does not create new independent randomness from nowhere. Instead, it
expands one accepted random input into several deterministic outputs that every
validator can recompute exactly. The labels `"1"`, `"2"`, and `"3"` separate the
uses: winner slot 1, winner slot 2, and winner slot 3 each get a different hash
input, so they do not all read the same bytes from `combinedSeed`.

In this lottery, domain separation is used for message meaning and replay
resistance, while deterministic random expansion is used to turn one combined
draw seed into multiple winner-selection inputs. Both techniques fit Cardano
validators because they are deterministic: the backend can build the bytes, and
the on-chain code can rebuild the same bytes and check the result.

## Signature Verification

The validator checks each oracle independently:

```haskell
oracleSeedSigned oracleName publicKey oracleSeed =
  verifyEd25519Signature
    publicKey
    (oracleMessage oracleName (osSeed oracleSeed))
    (osSignature oracleSeed)
```

Breakdown:

- `oracleName` is the configured oracle slot label, such as `oracle-1`.
- `publicKey` is the configured public key for one oracle. For oracle 1, this is `lpOracle1PublicKey params`.
- `oracleSeed` is the redeemer value submitted for that oracle. It contains both `osSeed` and `osSignature`.
- `osSeed oracleSeed` extracts the raw seed bytes from the redeemer.
- `oracleMessage oracleName (osSeed oracleSeed)` rebuilds the exact bytes the oracle was supposed to sign, using the oracle slot, current datum, and that seed.
- `osSignature oracleSeed` extracts the submitted signature bytes.
- `verifyEd25519Signature publicKey message signature` returns `True` only if the signature was created by the private key matching `publicKey` for exactly `message`.

Algorithm key points:

1. Take the submitted seed.
2. Rebuild the expected message from oracle slot, current datum state, and that seed.
3. Take the submitted signature.
4. Check the signature against the expected oracle public key.
5. Accept this oracle's seed only if the check returns `True`.

The important detail is that the validator does not trust the seed because it is present in the redeemer. It trusts the seed only after proving that the configured oracle signed a message containing that seed and the current datum values.

Then it combines all three checks:

```haskell
oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3 =
  oracleSeedSigned "oracle-1" (lpOracle1PublicKey params) oracleSeed1
    && oracleSeedSigned "oracle-2" (lpOracle2PublicKey params) oracleSeed2
    && oracleSeedSigned "oracle-3" (lpOracle3PublicKey params) oracleSeed3
```

Breakdown:

- `oracleSeed1` must verify against `lpOracle1PublicKey params` and the `oracle-1` slot label.
- `oracleSeed2` must verify against `lpOracle2PublicKey params` and the `oracle-2` slot label.
- `oracleSeed3` must verify against `lpOracle3PublicKey params` and the `oracle-3` slot label.
- `&&` means all checks must be true. If any oracle signature is missing, malformed, signed by the wrong key, or signed for different message bytes, the draw branch fails.

Algorithm key points:

1. Verify oracle 1's seed with oracle 1's public key.
2. Verify oracle 2's seed with oracle 2's public key.
3. Verify oracle 3's seed with oracle 3's public key.
4. Continue only if all three checks pass.

This gives a clear authorization rule: the draw can only use seeds signed by the configured oracle keys for their configured oracle slots. It also preserves oracle identity. The transaction builder cannot swap oracle 1 and oracle 2 unless the signatures still match both the exact public keys and slot labels expected by the validator.

Known limitation for this intro contract: the design assumes each configured
oracle actually provides a seed and signature when the draw is due. It does not
yet handle the operational problem where an oracle withholds its response or
goes offline. Future production designs would need a policy for that case, such
as replacement oracles, timeouts, fallback rules, deposits, or other incentives.

## Randomness Trust Model

The design is a 3-oracle commit-by-signature model.

Each oracle contributes one seed. The validator combines the three seeds:

```haskell
combinedSeed =
  blake2b_256
    ( "lotto-v1|combined|oracle-1:"
        <> seed1
        <> "|oracle-2:"
        <> seed2
        <> "|oracle-3:"
        <> seed3
    )
```

This is better than trusting a single backend seed because no single oracle directly controls the final input. A party that controls the only seed could search for a seed that makes its own ticket win, then submit a draw transaction that passes validation and drains the pot through the "winner" payout path. If at least one oracle supplies unpredictable seed bytes and does not collude with the transaction builder, the combined seed should remain unpredictable before that honest oracle reveals its seed.

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
Draw caller oracleSeed1 oracleSeed2 oracleSeed3 ->
  [ validDrawTime
  , currentTxInputValueCoversDatumPot
  , callerSigned caller
  , callerRewardBoundsValid
  , oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3
  , drawTransitionValid caller (combinedSeed oracleSeed1 oracleSeed2 oracleSeed3)
  ]
```

The order is readable:

1. Check that this is actually draw time.
2. Check that the current script UTxO covers the recorded prize pot.
3. Check that the explicit caller signed the transaction.
4. Check oracle authorization.
5. Check the state transition: payout path or rollover path.

The list is later consumed with `List.and`, so cost-sensitive versions may need direct `&&` structure if short-circuiting and evaluation order become important.

## Backend Responsibilities

The backend must:

1. Read the current script UTxO and datum.
2. Extract `ldRoundEndTime`, `ldPot`, and participants.
3. Ask each oracle for a seed and signature, or run three independent oracle services.
4. Construct the exact message bytes for each seed.
5. Verify signatures off-chain before building the transaction.
6. Build the `Draw` redeemer with the caller public key hash and three
   `OracleSeed` values.
7. Build the continuing output:
   - new round state if there are at least three participants;
   - rollover state if there are fewer than three participants.
8. Build payout outputs for the maintainer, caller, and three winners when
   there are at least three participants.

## Current Production Gaps

The following are intentionally not complete in v1:

- Payout output tests are still needed for missing and underpaid recipients.
- There are no tests yet for invalid oracle signatures.
- There are no tests yet for seed order changes.
- The byte encoding should be mirrored in backend tests.
- The design does not prevent a transaction builder from withholding a completed draw transaction.
- The participant list is stored directly in the datum, which may become expensive if the number of buyers grows.

## Production Randomness Research Notes

Good lottery randomness needs several properties at once:

- **Unpredictability before the draw.** No player, backend, oracle, or block producer should know the result while they can still act on it.
- **Verifiability after the draw.** Anyone should be able to check that the published random value follows from the agreed protocol.
- **Grinding resistance.** A party that can influence an input should not be able to retry many candidate inputs and keep only the one it likes.
- **Liveness.** One offline or malicious participant should not be able to freeze the whole draw without a defined timeout, penalty, or fallback.
- **Correct range mapping.** Turning random bytes into winner indexes must avoid avoidable bias.

The current v1 design covers only part of this. It verifies that each submitted
seed was signed by the configured oracle key and binds each signature to the
current lottery state. That is useful, but an Ed25519 signature over a seed is
not the same as a VRF proof, and it does not prove that the oracle generated the
seed in an unbiased way.

Threat vectors and common mitigations:

- **Single oracle chooses the winner.** If one oracle controls the only seed, it
  can try many seeds and sign the favorable one. Mitigation: combine multiple
  independent sources, use a VRF with a public proof, or use commit-reveal with
  accountable participants.
- **Oracle seed grinding.** Even with signatures, a malicious oracle can sample
  many seeds locally before signing. Multiple oracles reduce this if at least
  one honest seed stays unpredictable until the final value is fixed. A VRF
  helps because the oracle output is tied to a key and input with a proof, rather
  than being an arbitrary chosen seed.
- **Oracle withholding or downtime.** An oracle can refuse to answer after it
  learns the likely outcome, or simply go offline. Mitigation: timeouts,
  replacement oracles, fallback rules, deposits, slashing, or a quorum design
  such as "any 3 of 5" instead of "exactly 3 of 3".
- **Last revealer problem.** In commit-reveal, the last participant to reveal
  has already seen the other revealed values and may refuse to reveal if the
  result is bad for them. Mitigation: reveal deadlines and deposits large enough
  that withholding costs more than the expected benefit.
- **Backend or transaction-builder withholding.** Even after collecting valid
  oracle seeds, the party building the draw transaction may choose not to submit
  it if the result is unfavorable. Mitigation: allow anyone to submit the draw
  once valid randomness is available, publish oracle statements on-chain, or use
  penalties and monitoring for privileged operators.
- **Block producer influence.** Cardano block VRF output is useful randomness
  after a future block exists, but validators cannot directly read block headers
  or VRF outputs from the script context. An oracle must bring that value on
  chain, and the block producer for the target slot may still be able to
  withhold a block to avoid an unfavorable value. Mitigation is partly
  application-level and partly consensus-level.
- **Modulo and extraction bias.** Random bytes must be mapped to participant
  indexes carefully. Using string digits, taking small byte slices, or naive
  modulo in the wrong place can skew results. Mitigation: hash the full seed
  material, use enough entropy, and use rejection sampling or a carefully
  reviewed modulo strategy when fairness requires it.
- **Replay and cross-round reuse.** A seed signed for one round should not be
  reusable in another round. The current design addresses this partly by signing
  the round end time and pot. Stronger versions may add a round id, script hash,
  network id, or protocol domain tag.
- **Oracle key lifecycle.** Production systems need key rotation, compromised-key
  handling, and a governance process for replacing oracles. This v1 script fixes
  oracle public keys in `LotteryParams`, so changing them means deploying or
  parameterizing a new script.

Possible production directions:

- **Commit-reveal.** This can be enforced fully by validators because commits
  and reveals are ordinary on-chain data. It reduces trust in external oracle
  seed generation, but introduces a multi-phase protocol and the last-revealer
  problem.
- **VRF oracle.** A VRF gives a random-looking output plus a proof tied to a
  public key and input. This improves verifiability and limits arbitrary seed
  choice, but the contract must either verify the VRF proof on-chain or trust an
  oracle statement that did the verification off-chain.
- **Future block VRF via oracle.** A future Cardano block's VRF output is
  unknown before the block exists and public afterward. It still needs an oracle
  to bring the value into the validator's view, and it does not fully remove
  block-producer grinding or withholding risk.
- **Threshold or quorum oracle set.** Instead of exactly three fixed oracles,
  use a larger set and accept a threshold. This improves liveness but requires
  more complex validator checks and governance.
- **VDF or consensus-level hardening.** Verifiable delay functions and proposals
  such as Ouroboros Phalanx address grinding at the protocol layer. This is far
  outside the scope of the intro lottery contract, but it is relevant for
  understanding why production randomness is not just an application problem.
- **On-chain oracle publication.** Oracles can publish signed randomness
  statements to reference UTxOs. Then anyone can build the draw transaction from
  public statements, reducing reliance on one backend submitter.

Useful research references:

- Cardano Developer Portal, [On-chain Randomness](https://developers.cardano.org/docs/developers/curriculum/dapps/oracles/randomness/)
- Chainlink, [Verifiable Random Function](https://chain.link/education-hub/verifiable-random-function-vrf)
- Cardano CIP-0161, [Ouroboros Phalanx - Breaking Grinding Incentives](https://cips.cardano.org/cip/CIP-0161)

## Current External Oracle Fit

Existing Cardano oracle providers are mostly feed/statement systems. They are useful for prices or published facts, but this validator currently needs custom signed randomness messages:

```text
lotto-v1 | oracle slot | current round end | current pot | oracle seed
```

This means the current validator fits best with:

1. self-managed oracle services;
2. a custom integration with a provider that agrees to sign this exact message scheme;
3. a future redesign that consumes published on-chain oracle statements by reference input.

## v2 Candidates

Likely next improvements:

- define the backend byte encoder with tests against the example hex;
- add negative tests for wrong oracle key, wrong pot, wrong round end, wrong seed order;
- decide whether seeds should be published through on-chain oracle UTxOs instead of redeemer fields;
- consider commit-reveal or public publication to reduce withholding risk;
- measure script size and execution budget before optimizing helper structure.
