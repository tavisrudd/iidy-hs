{-# LANGUAGE OverloadedRecordDot #-}
-- | SSM Parameter Store client operations.
--
-- Implements get, set, get-by-path, and get-history operations against
-- AWS SSM Parameter Store. All operations use an existing amazonka Env
-- and return Either Text results for uniform error handling.
module Iidy.Params.Client
  ( -- * Parameter operations
    paramGet
  , paramSet
  , paramGetByPath
  , paramGetHistory
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Control.Lens ((^.), (^?), _Just)

import qualified Amazonka
import qualified Amazonka.SSM as SSM
import qualified Amazonka.SSM.GetParameter as GP
import qualified Amazonka.SSM.PutParameter as PP
import qualified Amazonka.SSM.GetParametersByPath as GPBP
import qualified Amazonka.SSM.GetParameterHistory as GPH
import qualified Amazonka.SSM.Types.Parameter as SSMP
import qualified Amazonka.SSM.Types.ParameterHistory as SSMPH
import qualified Amazonka.SSM.Types.ParameterType as SSMPT

import Iidy.Cli (ParamGetArgs(..), ParamSetArgs(..), ParamGetByPathArgs(..))

------------------------------------------------------------------------
-- paramGet
------------------------------------------------------------------------

-- | Fetch a single SSM parameter value.
-- Uses withDecryption to support SecureString parameters.
paramGet :: Amazonka.Env -> ParamGetArgs -> IO (Either Text Text)
paramGet awsEnv args = do
  result <- try @SomeException (fetchParam awsEnv args.pgaPath args.pgaDecrypt)
  case result of
    Left ex  -> pure $ Left $ "SSM GetParameter error for " <> args.pgaPath <> ": " <> T.pack (show ex)
    Right val -> pure (Right val)

fetchParam :: Amazonka.Env -> Text -> Bool -> IO Text
fetchParam awsEnv paramName withDecryption = runResourceT $ do
  let req = (GP.newGetParameter paramName)
              { GP.withDecryption = Just withDecryption }
  resp <- Amazonka.send awsEnv req
  pure (resp.parameter ^. SSMP.parameter_value)

------------------------------------------------------------------------
-- paramSet
------------------------------------------------------------------------

-- | Write a value to SSM Parameter Store.
-- Respects the overwrite flag and type from ParamSetArgs.
-- The type field maps to SSM ParameterType (String, SecureString, StringList).
paramSet :: Amazonka.Env -> ParamSetArgs -> IO (Either Text ())
paramSet awsEnv args = do
  result <- try @SomeException (putParam awsEnv args)
  case result of
    Left ex -> pure $ Left $ "SSM PutParameter error for " <> args.psaPath <> ": " <> T.pack (show ex)
    Right _  -> pure (Right ())

putParam :: Amazonka.Env -> ParamSetArgs -> IO ()
putParam awsEnv args = runResourceT $ do
  let paramType = textToParameterType args.psaType
      req = (PP.newPutParameter args.psaPath args.psaValue)
              { PP.overwrite = Just args.psaOverwrite
              , PP.type'     = paramType
              , PP.description = args.psaMessage
              }
  _ <- Amazonka.send awsEnv req
  pure ()

-- | Convert a text type name to an SSM ParameterType.
-- Defaults to String for unknown values.
textToParameterType :: Text -> Maybe SSM.ParameterType
textToParameterType t = case T.toLower t of
  "securestring" -> Just SSMPT.ParameterType_SecureString
  "stringlist"   -> Just SSMPT.ParameterType_StringList
  "string"       -> Just SSMPT.ParameterType_String
  _              -> Just SSMPT.ParameterType_String

------------------------------------------------------------------------
-- paramGetByPath
------------------------------------------------------------------------

-- | Fetch all parameters under a path prefix.
-- Returns a list of formatted "name=value" strings.
-- Supports recursive traversal and optional decryption.
paramGetByPath :: Amazonka.Env -> ParamGetByPathArgs -> IO (Either Text [Text])
paramGetByPath awsEnv args = do
  result <- try @SomeException (fetchByPath awsEnv args)
  case result of
    Left ex  -> pure $ Left $ "SSM GetParametersByPath error for " <> args.gpbPath <> ": " <> T.pack (show ex)
    Right vs -> pure (Right vs)

fetchByPath :: Amazonka.Env -> ParamGetByPathArgs -> IO [Text]
fetchByPath awsEnv args = runResourceT $ do
  let req = (GPBP.newGetParametersByPath args.gpbPath)
              { GPBP.recursive      = Just args.gpbRecursive
              , GPBP.withDecryption = Just args.gpbDecrypt
              }
  resp <- Amazonka.send awsEnv req
  let params = fromMaybe [] resp.parameters
  pure (map formatParam params)

-- | Format a Parameter as "name=value".
formatParam :: SSM.Parameter -> Text
formatParam p =
  let name  = p.name
      value = p ^. SSMP.parameter_value
  in name <> "=" <> value

------------------------------------------------------------------------
-- paramGetHistory
------------------------------------------------------------------------

-- | Fetch the version history of a single SSM parameter.
-- Returns a list of formatted version entries "version: value".
paramGetHistory :: Amazonka.Env -> ParamGetArgs -> IO (Either Text [Text])
paramGetHistory awsEnv args = do
  result <- try @SomeException (fetchHistory awsEnv args.pgaPath args.pgaDecrypt)
  case result of
    Left ex  -> pure $ Left $ "SSM GetParameterHistory error for " <> args.pgaPath <> ": " <> T.pack (show ex)
    Right vs -> pure (Right vs)

fetchHistory :: Amazonka.Env -> Text -> Bool -> IO [Text]
fetchHistory awsEnv paramName withDecryption = runResourceT $ do
  let req = (GPH.newGetParameterHistory paramName)
              { GPH.withDecryption = Just withDecryption }
  resp <- Amazonka.send awsEnv req
  let entries = fromMaybe [] resp.parameters
  pure (mapMaybe formatHistoryEntry entries)

-- | Format a ParameterHistory entry as "version: value".
-- Skips entries where both version and value are absent.
formatHistoryEntry :: SSM.ParameterHistory -> Maybe Text
formatHistoryEntry ph =
  let mValue   = ph ^? SSMPH.parameterHistory_value . _Just
      mVersion = ph ^? SSMPH.parameterHistory_version . _Just
  in case (mVersion, mValue) of
    (Just ver, Just val) -> Just $ "v" <> T.pack (show ver) <> ": " <> val
    (Nothing,  Just val) -> Just val
    _                    -> Nothing
