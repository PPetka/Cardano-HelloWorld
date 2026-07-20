module LottoValidator where

import GHC.Generics (Generic)

import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (Datum (..), Lovelace (..), OutputDatum (..),
                           POSIXTime (..), PubKeyHash, Redeemer (..), ScriptContext (..),
                           ScriptInfo (..), TxInInfo (..), TxInfo (..), TxOut (..), from,
                           getRedeemer, to)
import PlutusLedgerApi.V3.Contexts (findOwnInput, getContinuingOutputs)
import PlutusLedgerApi.V1.Interval (Interval (..), contains, strictUpperBound)
import PlutusLedgerApi.V1.Value (lovelaceValueOf)
import PlutusTx
import PlutusTx.Builtins qualified as Builtins
import PlutusTx.Blueprint
import PlutusTx.Prelude qualified as PlutusTx
import PlutusTx.List qualified as List

data LotteryParams = LotteryParams
  { lpMaintainer :: PubKeyHash
  -- ^ Maintainer's public key hash who receives the maintenance fee.
  , lpTicketPrice :: Lovelace
  -- ^ Price per lottery ticket in Lovelace (1 ADA = 1,000,000 Lovelace).
  , lpOracle1PublicKey :: PlutusTx.BuiltinByteString
  -- ^ Raw Ed25519 public key for the first randomness oracle.
  , lpOracle2PublicKey :: PlutusTx.BuiltinByteString
  -- ^ Raw Ed25519 public key for the second randomness oracle.
  , lpOracle3PublicKey :: PlutusTx.BuiltinByteString
  -- ^ Raw Ed25519 public key for the third randomness oracle.
  }
  deriving stock (Generic)
  deriving anyclass (HasBlueprintDefinition)

PlutusTx.makeLift ''LotteryParams
PlutusTx.makeIsDataSchemaIndexed ''LotteryParams [('LotteryParams, 0)]

{- | Datum represents the state of a daily lottery.
It contains the current round end time, list of participants (PubKeyHashes),
and the total Lovelace locked in the script UTXO.
-}
data LotteryDatum = LotteryDatum
  { ldRoundEndTime :: POSIXTime
  -- ^ POSIX time when the current lottery round ends.
  , ldParticipants :: [PubKeyHash]
  -- ^ List of participants who bought tickets.
  , ldPot          :: Lovelace
  -- ^ Total Lovelace locked in the lottery script UTXO.
  }
  deriving stock (Generic)
  deriving anyclass (HasBlueprintDefinition)

PlutusTx.makeIsDataSchemaIndexed ''LotteryDatum [('LotteryDatum, 0)]

data OracleSeed = OracleSeed
  { osSeed      :: PlutusTx.BuiltinByteString
  -- ^ Random bytes supplied by the oracle for the current round.
  , osSignature :: PlutusTx.BuiltinByteString
  -- ^ Ed25519 signature over the oracle message for this round and seed.
  }
  deriving stock (Generic)
  deriving anyclass (HasBlueprintDefinition)

PlutusTx.makeIsDataSchemaIndexed ''OracleSeed [('OracleSeed, 0)]

{- | Redeemer is the input that changes the state of a smart contract.
In this case it is either a BuyTicket action or a Draw action.
-}
data LotteryRedeemer = BuyTicket PubKeyHash | Draw OracleSeed OracleSeed OracleSeed
  deriving stock (Generic)
  deriving anyclass (HasBlueprintDefinition)

PlutusTx.makeIsDataSchemaIndexed ''LotteryRedeemer [('BuyTicket, 0), ('Draw, 1)]

{-# INLINEABLE lottoTypedValidator #-}

{- | Given the lottery parameters, determines whether the transaction is allowed to
spend the UTXO. V3 validator extracts datum and redeemer from ScriptContext.
-}
lottoTypedValidator ::
  LotteryParams ->
  ScriptContext ->
  Bool
lottoTypedValidator params ctx@(ScriptContext txInfo scriptRedeemer scriptInfo) =
  List.and conditions
  where
    -- Extract redeemer from script context
    redeemer :: LotteryRedeemer
    redeemer = case PlutusTx.fromBuiltinData (getRedeemer scriptRedeemer) of
      Nothing -> PlutusTx.traceError "Failed to parse LotteryRedeemer"
      Just r  -> r

    -- Extract datum from script context
    currentDatum :: LotteryDatum
    currentDatum = case scriptInfo of
      SpendingScript _ (Just (Datum datum)) ->
        case PlutusTx.fromBuiltinData datum of
          Just d  -> d
          Nothing -> PlutusTx.traceError "Failed to parse LotteryDatum"
      _ -> PlutusTx.traceError "Expected SpendingScript with datum"

    conditions :: [Bool]
    conditions = case redeemer of
      BuyTicket buyer ->
        [ -- Tickets can only be bought before the draw window starts.
          validBuyTime
        , -- Before trusting currentDatum.ldPot, compare it with the Lovelace being spent.
          currentTxInputValueMatchesDatumPot
        , -- One wallet should not be able to buy twice in the same round.
          PlutusTx.not (buyerInList buyer)
        , -- The participant being added must approve the transaction.
          -- Without this, someone can add another wallet to the participant list.
          buyerSigned buyer
        , -- The next datum must increase the total script Lovelace by exactly one ticket.
          nextDatumPotIncreasesByTicketPrice
        , -- The next script txOutput must actually lock the next datum's Lovelace.
          nextTxOutputHasExpectedPot
        , -- The next datum must preserve round timing and add current buyer.
          nextDatumAddsBuyer buyer
        ]
      Draw oracleSeed1 oracleSeed2 oracleSeed3 ->
        [ -- Draw can only happen once the round has ended.
          validDrawTime
        , -- Before paying/resetting the round, confirm currentDatum.ldPot matches the spent UTXO.
          currentTxInputValueMatchesDatumPot
        , -- Each oracle seed must be signed for this lottery version and current state.
          oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3
        , -- With fewer than 3 participants, no payout happens; the round rolls over.
          drawTransitionValid (combinedSeed oracleSeed1 oracleSeed2 oracleSeed3)
        ]

    buyerInList :: PubKeyHash -> Bool
    {-# INLINEABLE buyerInList #-}
    buyerInList buyer = case List.find (PlutusTx.== buyer) (ldParticipants currentDatum) of
      Nothing -> False
      Just _  -> True

    buyerSigned :: PubKeyHash -> Bool
    {-# INLINEABLE buyerSigned #-}
    buyerSigned buyer = case List.find (PlutusTx.== buyer) (txInfoSignatories txInfo) of
      Nothing -> False
      Just _  -> True

    currentRoundEndTime :: POSIXTime
    {-# INLINEABLE currentRoundEndTime #-}
    currentRoundEndTime = ldRoundEndTime currentDatum

    validBuyTime :: Bool
    {-# INLINEABLE validBuyTime #-}
    ~validBuyTime =
      -- Buy transactions must be valid strictly before the round end time.
      let buyInterval = to currentRoundEndTime
       in Interval (ivFrom buyInterval) (strictUpperBound currentRoundEndTime)
            `contains` txInfoValidRange txInfo

    validDrawTime :: Bool
    {-# INLINEABLE validDrawTime #-}
    ~validDrawTime =
      -- Draw transactions must be valid no earlier than the round end time.
      from currentRoundEndTime `contains` txInfoValidRange txInfo

    nextTxOutputWithDatum :: (TxOut, LotteryDatum)
    {-# INLINEABLE nextTxOutputWithDatum #-}
    -- Plutus calls this a continuing output: the next UTXO locked by this same script.
    -- It carries the next lottery datum so the following transaction can continue the round.
    nextTxOutputWithDatum = case getContinuingOutputs ctx of
      [txOutput] -> case txOutDatum txOutput of
        OutputDatum (Datum nextDatumData) -> case PlutusTx.fromBuiltinData nextDatumData of
          Just nextDatum -> (txOutput, nextDatum)
          Nothing -> PlutusTx.traceError "Failed to parse output LotteryDatum"
        _ -> PlutusTx.traceError "Expected inline output datum"
      _ -> PlutusTx.traceError "Expected exactly one continuing output"

    -- The current txInput is the script UTXO being spent; resolving it gives its txOutput.
    currentTxInputResolvedTxOutput :: TxOut
    {-# INLINEABLE currentTxInputResolvedTxOutput #-}
    currentTxInputResolvedTxOutput = case findOwnInput ctx of
      Just txInput -> txInInfoResolved txInput
      Nothing      -> PlutusTx.traceError "Expected own input"

    -- Lovelace locked in the current script UTXO before this transaction.
    currentTxInputValue :: Lovelace
    {-# INLINEABLE currentTxInputValue #-}
    currentTxInputValue = lovelaceValueOf (txOutValue currentTxInputResolvedTxOutput)

    -- currentDatum.ldPot is our datum copy of the script's total Lovelace.
    -- Check it against the real current txInput value before using it later.
    currentTxInputValueMatchesDatumPot :: Bool
    {-# INLINEABLE currentTxInputValueMatchesDatumPot #-}
    currentTxInputValueMatchesDatumPot = currentTxInputValue PlutusTx.== ldPot currentDatum

    nextDatumPotIncreasesByTicketPrice :: Bool
    {-# INLINEABLE nextDatumPotIncreasesByTicketPrice #-}
    ~nextDatumPotIncreasesByTicketPrice =
      let (_, nextDatum) = nextTxOutputWithDatum
          potIncrease = ldPot nextDatum PlutusTx.- ldPot currentDatum
       in potIncrease PlutusTx.== lpTicketPrice params

    nextTxOutputHasExpectedPot :: Bool
    {-# INLINEABLE nextTxOutputHasExpectedPot #-}
    ~nextTxOutputHasExpectedPot =
      let (txOutput, _) = nextTxOutputWithDatum
          expectedPot = currentTxInputValue PlutusTx.+ lpTicketPrice params
       in lovelaceValueOf (txOutValue txOutput) PlutusTx.== expectedPot

    nextDatumAddsBuyer :: PubKeyHash -> Bool
    {-# INLINEABLE nextDatumAddsBuyer #-}
    nextDatumAddsBuyer buyer =
      let (_, nextDatum) = nextTxOutputWithDatum
       in (ldRoundEndTime nextDatum PlutusTx.== currentRoundEndTime)
            PlutusTx.&& (ldParticipants nextDatum PlutusTx.== buyer : ldParticipants currentDatum)

    oneDay :: POSIXTime
    {-# INLINEABLE oneDay #-}
    oneDay = POSIXTime 86_400_000

    addPOSIXTime :: POSIXTime -> POSIXTime -> POSIXTime
    {-# INLINEABLE addPOSIXTime #-}
    addPOSIXTime (POSIXTime a) (POSIXTime b) = POSIXTime (a PlutusTx.+ b)

    nextTxOutputStartsNewRound :: Bool
    {-# INLINEABLE nextTxOutputStartsNewRound #-}
    ~nextTxOutputStartsNewRound =
      -- This only checks the next lottery state. Payout correctness belongs in verifyPayouts.
      let (txOutput, nextDatum) = nextTxOutputWithDatum
       in (ldRoundEndTime nextDatum PlutusTx.== addPOSIXTime currentRoundEndTime oneDay)
            PlutusTx.&& (ldParticipants nextDatum PlutusTx.== [])
            PlutusTx.&& (ldPot nextDatum PlutusTx.== lovelaceValueOf (txOutValue txOutput))

    nextTxOutputRollsOverRound :: Bool
    {-# INLINEABLE nextTxOutputRollsOverRound #-}
    ~nextTxOutputRollsOverRound =
      -- Not enough participants: keep participants/pot and advance the round end time.
      let (txOutput, nextDatum) = nextTxOutputWithDatum
       in (ldRoundEndTime nextDatum PlutusTx.== addPOSIXTime currentRoundEndTime oneDay)
            PlutusTx.&& (ldParticipants nextDatum PlutusTx.== ldParticipants currentDatum)
            PlutusTx.&& (ldPot nextDatum PlutusTx.== ldPot currentDatum)
            PlutusTx.&& (ldPot nextDatum PlutusTx.== lovelaceValueOf (txOutValue txOutput))

    drawTransitionValid :: PlutusTx.BuiltinByteString -> Bool
    {-# INLINEABLE drawTransitionValid #-}
    drawTransitionValid seed =
      if enoughParticipants
        then
          nextTxOutputStartsNewRound
            PlutusTx.&& verifyPayouts seed
        else nextTxOutputRollsOverRound

    enoughParticipants :: Bool
    {-# INLINEABLE enoughParticipants #-}
    enoughParticipants = List.length (ldParticipants currentDatum) PlutusTx.>= 3

    integerToByteString :: Integer -> PlutusTx.BuiltinByteString
    {-# INLINEABLE integerToByteString #-}
    integerToByteString n =
      if n PlutusTx.<= 0
        then ""
        else integerToByteString (n `PlutusTx.quotient` 256) PlutusTx.<> Builtins.consByteString (n `PlutusTx.modulo` 256) ""

    oracleMessage :: PlutusTx.BuiltinByteString -> PlutusTx.BuiltinByteString -> PlutusTx.BuiltinByteString
    {-# INLINEABLE oracleMessage #-}
    {- Off-chain oracles must sign these exact bytes:
       "lotto-v1|oracle:" <> oracleName <> "|round-end:" <> roundEndBytes <> "|pot:" <> potBytes <> "|seed:" <> seedBytes

       Example for the backend/oracle:
         oracle   = "oracle-1"
         roundEnd = POSIXTime 1725235200000
         pot      = Lovelace 10000000
         seed     = "oracle-1-seed"

       The labels separate the binary integer fields from each other and from the seed.
       The oracle label binds a signature to its configured oracle slot.
       Current state bytes prevent replaying a valid seed/signature in another round/state.
    -}
    oracleMessage oracleName seed =
      let POSIXTime roundEnd = currentRoundEndTime
          Lovelace pot = ldPot currentDatum
       in "lotto-v1|oracle:"
            PlutusTx.<> oracleName
            PlutusTx.<> "|round-end:"
            PlutusTx.<> integerToByteString roundEnd
            PlutusTx.<> "|pot:"
            PlutusTx.<> integerToByteString pot
            PlutusTx.<> "|seed:"
            PlutusTx.<> seed

    oracleSeedSigned :: PlutusTx.BuiltinByteString -> PlutusTx.BuiltinByteString -> OracleSeed -> Bool
    {-# INLINEABLE oracleSeedSigned #-}
    oracleSeedSigned oracleName publicKey oracleSeed =
      Builtins.verifyEd25519Signature publicKey (oracleMessage oracleName (osSeed oracleSeed)) (osSignature oracleSeed)

    oracleSeedsSigned :: OracleSeed -> OracleSeed -> OracleSeed -> Bool
    {-# INLINEABLE oracleSeedsSigned #-}
    oracleSeedsSigned oracleSeed1 oracleSeed2 oracleSeed3 =
      oracleSeedSigned "oracle-1" (lpOracle1PublicKey params) oracleSeed1
        PlutusTx.&& oracleSeedSigned "oracle-2" (lpOracle2PublicKey params) oracleSeed2
        PlutusTx.&& oracleSeedSigned "oracle-3" (lpOracle3PublicKey params) oracleSeed3

    combinedSeed :: OracleSeed -> OracleSeed -> OracleSeed -> PlutusTx.BuiltinByteString
    {-# INLINEABLE combinedSeed #-}
    -- Fixed oracle order matters: each seed is tagged before hashing into the draw seed.
    -- The tags make the combined hash depend on the oracle slot, not just raw byte order.
    combinedSeed oracleSeed1 oracleSeed2 oracleSeed3 =
      Builtins.blake2b_256
        ( "lotto-v1|combined|oracle-1:"
            PlutusTx.<> osSeed oracleSeed1
            PlutusTx.<> "|oracle-2:"
            PlutusTx.<> osSeed oracleSeed2
            PlutusTx.<> "|oracle-3:"
            PlutusTx.<> osSeed oracleSeed3
        )

    winnerIndex :: PlutusTx.BuiltinByteString -> Integer -> Integer
    {-# INLINEABLE winnerIndex #-}
    -- Use the first four bytes of a derived hash as an integer, then fit it into the list length.
    winnerIndex seed participantCount =
      let entropy =
            (Builtins.indexByteString seed 0 PlutusTx.* 16_777_216)
              PlutusTx.+ (Builtins.indexByteString seed 1 PlutusTx.* 65_536)
              PlutusTx.+ (Builtins.indexByteString seed 2 PlutusTx.* 256)
              PlutusTx.+ Builtins.indexByteString seed 3
       in entropy `PlutusTx.modulo` participantCount

    selectAt :: Integer -> [PubKeyHash] -> PubKeyHash
    {-# INLINEABLE selectAt #-}
    selectAt index participants = case participants of
      [] -> PlutusTx.traceError "No participants"
      participant : rest ->
        if index PlutusTx.== 0
          then participant
          else selectAt (index PlutusTx.- 1) rest

    removeWinner :: PubKeyHash -> [PubKeyHash] -> [PubKeyHash]
    {-# INLINEABLE removeWinner #-}
    removeWinner winner participants = case participants of
      [] -> []
      participant : rest ->
        if participant PlutusTx.== winner
          then rest
          else participant : removeWinner winner rest

    selectWinners :: PlutusTx.BuiltinByteString -> [PubKeyHash]
    {-# INLINEABLE selectWinners #-}
    selectWinners seed =
      let participants = ldParticipants currentDatum
          seed1 = Builtins.blake2b_256 (seed PlutusTx.<> "1")
          seed2 = Builtins.blake2b_256 (seed PlutusTx.<> "2")
          seed3 = Builtins.blake2b_256 (seed PlutusTx.<> "3")
          winner1 = selectAt (winnerIndex seed1 (List.length participants)) participants
          remaining1 = removeWinner winner1 participants
          winner2 = selectAt (winnerIndex seed2 (List.length remaining1)) remaining1
          remaining2 = removeWinner winner2 remaining1
          winner3 = selectAt (winnerIndex seed3 (List.length remaining2)) remaining2
       in if enoughParticipants
            then [winner1, winner2, winner3]
            else PlutusTx.traceError "Not enough participants for draw"

    verifyPayouts :: PlutusTx.BuiltinByteString -> Bool
    {-# INLINEABLE verifyPayouts #-}
    -- TODO: implement winner/maintainer payouts before this validator is production-ready.
    verifyPayouts seed = case selectWinners seed of
      [_winner1, _winner2, _winner3] -> True
      _ -> PlutusTx.traceError "Expected exactly three winners"

{-# INLINEABLE lottoUntypedValidator #-}
lottoUntypedValidator ::
  LotteryParams ->
  BuiltinData ->
  PlutusTx.BuiltinUnit
lottoUntypedValidator params ctx =
  PlutusTx.check
    ( lottoTypedValidator
        params
        (PlutusTx.unsafeFromBuiltinData ctx)
    )

lottoValidatorScript ::
  LotteryParams ->
  CompiledCode (BuiltinData -> PlutusTx.BuiltinUnit)
lottoValidatorScript params =
  $$(PlutusTx.compile [||lottoUntypedValidator||])
    `PlutusTx.unsafeApplyCode` PlutusTx.liftCode plcVersion110 params
