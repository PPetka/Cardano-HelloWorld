module LottoValidator where

import GHC.Generics (Generic)

import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (Datum (..), Lovelace, OutputDatum (..),
                           POSIXTime (..), PubKeyHash, Redeemer (..), ScriptContext (..),
                           ScriptInfo (..), TxInInfo (..), TxInfo (..), TxOut (..), from,
                           getRedeemer, to)
import PlutusLedgerApi.V3.Contexts (findOwnInput, getContinuingOutputs)
import PlutusLedgerApi.V1.Interval (Interval (..), contains, strictUpperBound)
import PlutusLedgerApi.V1.Value (lovelaceValueOf)
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude qualified as PlutusTx
import PlutusTx.List qualified as List

data LotteryParams = LotteryParams
  { lpMaintainer :: PubKeyHash
  -- ^ Maintainer's public key hash who receives the maintenance fee.
  , lpTicketPrice :: Lovelace
  -- ^ Price per lottery ticket in Lovelace (1 ADA = 1,000,000 Lovelace).
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

{- | Redeemer is the input that changes the state of a smart contract.
In this case it is either a BuyTicket action or a Draw action.
-}
data LotteryRedeemer = BuyTicket PubKeyHash | Draw PlutusTx.BuiltinByteString
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
      Draw oracleSeed ->
        [ -- Draw can only happen once the round has ended.
          validDrawTime
        , -- Before paying/resetting the round, confirm currentDatum.ldPot matches the spent UTXO.
          currentTxInputValueMatchesDatumPot
        , -- The next script txOutput must reset participants and advance the round end time.
          nextTxOutputStartsNewRound
        , -- TODO: verify winner/maintainer payouts; keep this last because it will scan outputs.
          verifyPayouts oracleSeed
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

    selectWinners :: PlutusTx.BuiltinByteString -> [PubKeyHash]
    {-# INLINEABLE selectWinners #-}
    selectWinners _ = case ldParticipants currentDatum of
      (w1:w2:w3:_) -> [w1, w2, w3]
      _ -> PlutusTx.traceError "Not enough participants for draw"

    calculateFees :: (Lovelace, Lovelace, Lovelace, Lovelace)
    {-# INLINEABLE calculateFees #-}
    calculateFees =
      let pot = ldPot currentDatum
       in (pot, pot, pot, pot)

    verifyPayouts :: PlutusTx.BuiltinByteString -> Bool
    {-# INLINEABLE verifyPayouts #-}
    -- TODO: implement winner/maintainer payouts before this validator is production-ready.
    verifyPayouts _ = True

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
