module LottoValidator where

import GHC.Generics (Generic)

import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (Datum (..), Lovelace, OutputDatum (..),
                           POSIXTime (..), PubKeyHash, ScriptContext (..), TxInfo (..),
                           TxOut (..), from, to, ScriptInfo (..), Redeemer (..), getRedeemer)
import PlutusLedgerApi.V3.Contexts (getContinuingOutputs)
import PlutusLedgerApi.V1.Address (toPubKeyHash)
import PlutusLedgerApi.V1.Interval (contains, Interval (..))
import PlutusLedgerApi.V1.Value (lovelaceValueOf)
import PlutusTx
import PlutusTx.AsData qualified as PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude qualified as PlutusTx
import PlutusTx.Show qualified as PlutusTx
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
It contains the day number, list of participants (PubKeyHashes), and accumulated pot (Lovelace).
-}
data LotteryDatum = LotteryDatum
  { ldDayNumber    :: Integer
  -- ^ Day number for this lottery round.
  , ldParticipants :: [PubKeyHash]
  -- ^ List of participants who bought tickets.
  , ldPot          :: Lovelace
  -- ^ Accumulated pot in Lovelace.
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
    lotteryDatum :: LotteryDatum
    lotteryDatum = case scriptInfo of
      SpendingScript _ (Just (Datum datum)) ->
        case PlutusTx.fromBuiltinData datum of
          Just d  -> d
          Nothing -> PlutusTx.traceError "Failed to parse LotteryDatum"
      _ -> PlutusTx.traceError "Expected SpendingScript with datum"

    conditions :: [Bool]
    conditions = case redeemer of
      BuyTicket buyer ->
        [ validBuyingTime
        , buyerNotInList buyer
        , exactlyOneADA
        , correctDatumUpdate buyer
        ]
      Draw oracleSeed ->
        [ validDrawTime
        , verifyPayouts oracleSeed
        ]
    validBuyingTime :: Bool
    {-# INLINEABLE validBuyingTime #-}
    validBuyingTime = True

    buyerNotInList :: PubKeyHash -> Bool
    {-# INLINEABLE buyerNotInList #-}
    buyerNotInList _ = True

    exactlyOneADA :: Bool
    {-# INLINEABLE exactlyOneADA #-}
    exactlyOneADA = True

    correctDatumUpdate :: PubKeyHash -> Bool
    {-# INLINEABLE correctDatumUpdate #-}
    correctDatumUpdate _ = True

    validDrawTime :: Bool
    {-# INLINEABLE validDrawTime #-}
    validDrawTime = True

    selectWinners :: PlutusTx.BuiltinByteString -> [PubKeyHash]
    {-# INLINEABLE selectWinners #-}
    selectWinners _ = case ldParticipants lotteryDatum of
      (w1:w2:w3:_) -> [w1, w2, w3]
      _ -> PlutusTx.traceError "Not enough participants for draw"

    calculateFees :: (Lovelace, Lovelace, Lovelace, Lovelace)
    {-# INLINEABLE calculateFees #-}
    calculateFees =
      let pot = ldPot lotteryDatum
       in (pot, pot, pot, pot)

    verifyPayouts :: PlutusTx.BuiltinByteString -> Bool
    {-# INLINEABLE verifyPayouts #-}
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

