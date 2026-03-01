-- | Convert an existing CloudFormation stack into iidy-compatible YAML files.
--
-- Fetches the stack's template, parameters, tags, and policy from AWS,
-- then generates a directory with stack-args.yaml, cfn-template.yaml,
-- stack-policy.json, and the original template archive.
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Iidy.Cfn.Operations.ConvertStack
  ( convertStackToIidy
  -- * Exported for testing
  , parameterizeEnv
  , parameterizeStackName
  , templateBodyToYaml
  , buildStackArgsYaml
  , emitCfnYaml
  , inlineValue
  , quoteYamlString
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..))
import Data.Char (isDigit)
import Numeric (showHex)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Encode.Pretty as AesonPretty
import qualified Data.ByteString.Lazy as BL
import Data.List (sortBy)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import qualified Data.Scientific as Scientific
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import qualified Data.Yaml as Yaml
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.DescribeStacks as DStacks
import qualified Amazonka.CloudFormation.GetStackPolicy as GSP
import qualified Amazonka.CloudFormation.GetTemplate as GT
import qualified Amazonka.SSM.PutParameter as PP
import qualified Amazonka.SSM.Types.ParameterType as SSMPT

import Iidy.Cfn.Context (CfnContext(..))

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

knownEnvironments :: [Text]
knownEnvironments =
  [ "production", "staging", "development", "integration", "testing" ]

defaultStackPolicy :: Text
defaultStackPolicy = "{\n \"Statement\": [\n  {\n   \"Effect\": \"Allow\",\n   \"Action\": \"Update:*\",\n   \"Principal\": \"*\",\n   \"Resource\": \"*\"\n  }\n ]\n}"

------------------------------------------------------------------------
-- Pure helper functions
------------------------------------------------------------------------

-- | Replace known environment names with {{environment}} template variable.
-- NOTE: Uses sequential T.replace via foldl. If a string contains multiple
-- environment names (e.g. "testing-production"), earlier replacements can
-- cause later ones to match, producing double-replacement. This matches
-- the Rust implementation behavior.
parameterizeEnv :: Text -> Text
parameterizeEnv s = foldl (\acc env -> T.replace env "{{environment}}" acc) s knownEnvironments

-- | Parameterize a stack name by replacing environment, trailing digits,
-- and project name with template variables.
parameterizeStackName :: Text -> Text -> Text
parameterizeStackName name project =
  let envReplaced = parameterizeEnv name
      -- Replace trailing -digits with -{{build_number}}
      digitReplaced = case T.breakOnEnd "-" envReplaced of
        ("", _) -> envReplaced
        (prefix, suffix)
          | not (T.null suffix) && T.all (\c -> c >= '0' && c <= '9') suffix ->
              T.dropEnd 1 prefix <> "-{{build_number}}"
          | otherwise -> envReplaced
      -- Replace project name with {{project}}
  in T.replace project "{{project}}" digitReplaced

------------------------------------------------------------------------
-- CFN key sorting
------------------------------------------------------------------------

defaultSortWeight :: Int
defaultSortWeight = 9999

cfnDocumentWeight :: Text -> Int
cfnDocumentWeight k = case k of
  "AWSTemplateFormatVersion" -> 0
  "Description"              -> 1
  "Metadata"                 -> 2
  "Parameters"               -> 3
  "Mappings"                 -> 4
  "Conditions"               -> 5
  "Transform"                -> 6
  "Resources"                -> 7
  "Outputs"                  -> 8
  _                          -> defaultSortWeight

cfnParameterWeight :: Text -> Int
cfnParameterWeight k = case k of
  "Description" -> 0
  "Type"        -> 1
  "MinValue"    -> 2
  "MaxValue"    -> 3
  "MinLength"   -> 4
  "MaxLength"   -> 5
  _             -> defaultSortWeight

cfnResourceWeight :: Text -> Int
cfnResourceWeight k = case k of
  "Type"       -> 0
  "Properties" -> defaultSortWeight + 1
  _            -> defaultSortWeight

cfnOutputWeight :: Text -> Int
cfnOutputWeight k = case k of
  "Description" -> 0
  "Value"       -> 1
  "Export"      -> 2
  _             -> defaultSortWeight

cfnTagWeight :: Text -> Int
cfnTagWeight k = case k of
  "Key"   -> 0
  "Value" -> 1
  _       -> defaultSortWeight

cfnIamStatementWeight :: Text -> Int
cfnIamStatementWeight k = case k of
  "Sid"       -> 0
  "Effect"    -> 1
  "Action"    -> 2
  "Resource"  -> 3
  "Condition" -> 4
  _           -> defaultSortWeight

cfnPolicyDocWeight :: Text -> Int
cfnPolicyDocWeight k = case k of
  "Version"   -> 0
  "Statement" -> 1
  _           -> defaultSortWeight

cfnPolicyWeight :: Text -> Int
cfnPolicyWeight k = case k of
  "PolicyName"     -> 0
  "PolicyDocument" -> 1
  _                -> defaultSortWeight

-- | Sort an aeson Object using a weight function, returning ordered pairs.
sortObjectPairs :: (Text -> Int) -> KM.KeyMap Value -> [(Key.Key, Value)]
sortObjectPairs weightFn km =
  sortBy cmp (KM.toList km)
  where
    cmp (a, _) (b, _) =
      let aKey = Key.toText a
          bKey = Key.toText b
      in compare (weightFn aKey) (weightFn bKey) <> compare aKey bKey

-- | Convert a template body (JSON or YAML) to sorted YAML text.
-- Uses a custom YAML emitter that sorts keys during emission to avoid
-- relying on KeyMap insertion order (which is not guaranteed).
templateBodyToYaml :: Text -> Bool -> Either Text Text
templateBodyToYaml body sortkeys =
  let trimmed = T.stripStart body
      parsed :: Either String Value
      parsed = if T.isPrefixOf "{" trimmed
        then Aeson.eitherDecodeStrict' (TE.encodeUtf8 body)
        else case Yaml.decodeEither' (TE.encodeUtf8 body) of
               Left err -> Left (show err)
               Right v  -> Right v
  in case parsed of
    Left err -> Left (T.pack err)
    Right val -> Right (emitCfnYaml sortkeys val)

-- | Emit YAML for a CFN template Value.
-- When @sortkeys@ is True, keys are sorted using CFN-specific weight functions.
-- When False, keys come out in the order the KeyMap iterates them.
emitCfnYaml :: Bool -> Value -> Text
emitCfnYaml doSort = emitValue doSort 0 "" ""

emitValue :: Bool -> Int -> Text -> Text -> Value -> Text
emitValue doSort indent parentKey currentKey val = case val of
  Object km ->
    let pairs = if doSort
          then sortObjectPairs (chooseWeightFn parentKey currentKey) km
          else KM.toList km
    in if null pairs
       then "{}\n"
       else T.concat $ map (\(k, v) ->
         let kText = Key.toText k
             newParent = if T.null parentKey && T.null currentKey then kText else currentKey
         in emitPair doSort indent newParent kText k v
         ) pairs
  Array arr ->
    if V.null arr
       then "[]\n"
       else T.concat $ map (\v ->
         emitItem doSort indent currentKey v
         ) (V.toList arr)
  _ -> inlineValue val <> "\n"

emitPair :: Bool -> Int -> Text -> Text -> Key.Key -> Value -> Text
emitPair doSort indent parentKey currentKey k v =
  let prefix = T.replicate indent " "
      key = Key.toText k
  in case v of
    Object km | not (KM.null km) ->
      prefix <> key <> ":\n" <> emitValue doSort (indent + 2) parentKey currentKey v
    Array arr | not (V.null arr) ->
      prefix <> key <> ":\n" <> emitValue doSort (indent + 2) parentKey currentKey v
    _ -> prefix <> key <> ": " <> inlineValue v <> "\n"

emitItem :: Bool -> Int -> Text -> Value -> Text
emitItem doSort indent parentKey v =
  let prefix = T.replicate indent " "
  in case v of
    Object km | not (KM.null km) ->
      let pairs = if doSort
            then sortObjectPairs (chooseWeightFn parentKey "") km
            else KM.toList km
      in case pairs of
        [] -> prefix <> "- {}\n"
        ((firstK, firstV):rest) ->
          let fkText = Key.toText firstK
              firstLine = case firstV of
                Object fkm | not (KM.null fkm) ->
                  prefix <> "- " <> fkText <> ":\n"
                  <> emitValue doSort (indent + 4) parentKey fkText firstV
                Array farr | not (V.null farr) ->
                  prefix <> "- " <> fkText <> ":\n"
                  <> emitValue doSort (indent + 4) parentKey fkText firstV
                _ ->
                  prefix <> "- " <> fkText <> ": " <> inlineValue firstV <> "\n"
              restLines = T.concat $ map (\(rk, rv) ->
                emitPair doSort (indent + 2) parentKey (Key.toText rk) rk rv
                ) rest
          in firstLine <> restLines
    _ -> prefix <> "- " <> inlineValue v <> "\n"

chooseWeightFn :: Text -> Text -> Text -> Int
chooseWeightFn parentKey currentKey
  | T.null parentKey && T.null currentKey = cfnDocumentWeight
  | parentKey == "Parameters" = cfnParameterWeight
  | parentKey == "Resources"  = cfnResourceWeight
  | parentKey == "Tags"       = cfnTagWeight
  | parentKey == "Outputs"    = cfnOutputWeight
  | parentKey == "Statement"  = cfnIamStatementWeight
  | currentKey == "PolicyDocument" || currentKey == "AssumeRolePolicyDocument" = cfnPolicyDocWeight
  | parentKey == "Policies"   = cfnPolicyWeight
  | otherwise = const defaultSortWeight

-- | Format a value inline (no newlines).
-- The Object and Array cases only match empty collections; non-empty
-- collections are handled by 'emitPair'/'emitItem' before reaching this
-- function (they render as block YAML, not inline).  The catch-all
-- therefore cannot be reached in practice, but is retained for totality.
inlineValue :: Value -> Text
inlineValue val = case val of
  String s -> quoteYamlString s
  Number n -> case Scientific.floatingOrInteger n of
    Left (d :: Double) -> T.pack (show d)
    Right (i :: Integer) -> T.pack (show i)
  Bool True -> "true"
  Bool False -> "false"
  Null -> "null"
  Object km | KM.null km -> "{}"
  Array arr | V.null arr -> "[]"
  -- Non-empty Object/Array: unreachable — callers render these as block YAML.
  Object _ -> "{...}"
  Array _  -> "[...]"

-- | Quote a YAML string value if needed.
-- Uses double-quoting with escape sequences for strings containing control
-- characters (single-quoted YAML scalars cannot contain literal newlines).
-- Uses single-quoting for all other special cases.
quoteYamlString :: Text -> Text
quoteYamlString s
  | T.null s = "''"
  | hasControlChars s = "\"" <> escapeForDoubleQuote s <> "\""
  | needsQuoting s = "'" <> T.replace "'" "''" s <> "'"
  | otherwise = s
  where
    hasControlChars t = T.any (< ' ') t

    escapeForDoubleQuote = T.concatMap $ \c -> case c of
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      '\\' -> "\\\\"
      '"'  -> "\\\""
      _    | c < ' '   -> "\\x" <> T.pack (padHex (fromEnum c))
           | otherwise -> T.singleton c

    -- | Zero-pad a hex string to at least 2 digits, as required by YAML spec.
    -- E.g. 0x01 => "01", 0x0f => "0f", 0x10 => "10".
    padHex :: Int -> String
    padHex n = let h = showHex n "" in if length h < 2 then '0' : h else h

    needsQuoting t =
      T.any (`elem` (":{}&*?|>!%@`#,[]\"" :: String)) t
      || t == "true" || t == "false" || t == "null"
      || t == "yes" || t == "no"
      || t == "~"  -- YAML null alias
      || T.isPrefixOf " " t || T.isSuffixOf " " t
      || T.isPrefixOf "." t  -- YAML float prefix (.inf, .nan, etc.)
      || T.isPrefixOf "'" t  -- single-quote opens a flow scalar
      || looksLikeNumber t
      || looksLikeDashSeq t

    -- Detect strings that YAML would interpret as numbers:
    -- integers (123, +42, -7), floats (0.5, +1.0, -3.14),
    -- scientific notation (1e3, 2.5E-4), and special YAML floats
    -- like octal (0o17) and hex (0x1f).
    looksLikeNumber :: Text -> Bool
    looksLikeNumber t =
      case T.uncons t of
        Nothing -> False
        Just (c, rest)
          | c == '+' || c == '-' -> not (T.null rest) && startsNumeric rest
          | isDigit c            -> True
          | otherwise            -> False

    startsNumeric :: Text -> Bool
    startsNumeric t =
      case T.uncons t of
        Just (c, _) -> isDigit c || c == '.'  -- covers +.inf, -.inf too
        Nothing     -> False

    -- Detect block sequence indicator: "-" alone or "- " prefix
    looksLikeDashSeq :: Text -> Bool
    looksLikeDashSeq t =
      t == "-" || T.isPrefixOf "- " t

-- | Build the stack-args.yaml content from stack metadata.
buildStackArgsYaml
  :: Text           -- ^ stack name
  -> Text           -- ^ project name
  -> [(Text, Text)] -- ^ parameters (key, value)
  -> [(Text, Text)] -- ^ tags (key, value)
  -> [Text]         -- ^ capabilities
  -> Maybe Int      -- ^ timeout in minutes
  -> Bool           -- ^ enable termination protection
  -> [Text]         -- ^ notification ARNs
  -> Maybe Text     -- ^ role ARN
  -> Bool           -- ^ disable rollback
  -> [Text]         -- ^ SSM-migrated parameter keys
  -> Text
buildStackArgsYaml stackName project params tags caps mTimeout
                   termProtection notifArns mRoleArn disableRollback ssmParamKeys =
  let ls = concat
        [ [ "$defs:"
          , "  project: " <> project
          , ""
          , "$imports:"
          , "  build_number: 'env:build_number:0'"
          ]
        , if not (null ssmParamKeys)
          then [ "  ssmParams: 'ssm-path:/{{environment}}/{{project}}/'" ]
          else []
        , [ ""
          , "Template: ./cfn-template.yaml"
          , "StackName: " <> parameterizeStackName stackName project
          , "StackPolicy: ./stack-policy.json"
          ]
        , if null params then []
          else "" : "Parameters:" : map formatParam params
        , if null tags then []
          else "" : "Tags:" : map formatTag tags
        , if null caps then []
          else "" : "Capabilities:" : map (\c -> "  - " <> c) caps
        , maybe [] (\t -> ["", "TimeoutInMinutes: " <> T.pack (show t)]) mTimeout
        , if termProtection then ["", "EnableTerminationProtection: true"] else []
        , if null notifArns then []
          else "" : "NotificationARNs:" : map (\a -> "  - " <> a) notifArns
        , maybe [] (\r -> ["", "RoleARN: " <> r]) mRoleArn
        , if disableRollback then ["", "DisableRollback: true"] else []
        , [""]
        ]
      yamlText = T.unlines ls
      -- Post-process: replace SSM placeholders with !$ tags
  in foldl (\acc k ->
       T.replace ("__SSM_REF__" <> k) ("!$ ssmParams." <> k) acc
     ) yamlText ssmParamKeys
  where
    formatParam (k, v)
      | k == "Environment" || k == "environment" = "  " <> k <> ": '{{environment}}'"
      | k `elem` ssmParamKeys = "  " <> k <> ": __SSM_REF__" <> k
      | otherwise = "  " <> k <> ": " <> quoteYamlString v

    formatTag (k, v)
      | k == "project" = "  " <> k <> ": '{{project}}'"
      | k == "environment" || k == "Environment" = "  " <> k <> ": '{{environment}}'"
      | otherwise = "  " <> k <> ": " <> quoteYamlString v

------------------------------------------------------------------------
-- AWS operations
------------------------------------------------------------------------

-- | Convert an existing CloudFormation stack into iidy-compatible files.
convertStackToIidy
  :: CfnContext
  -> Text       -- ^ stack name
  -> Text       -- ^ output directory
  -> Bool       -- ^ move params to SSM
  -> Bool       -- ^ sort keys in template
  -> Maybe Text -- ^ project name override
  -> IO (Either Text Int)
convertStackToIidy ctx stackName outputDir moveParamsToSsm sortkeys mProject = do
  -- 1. Fetch original template
  let gtReq = GT.newGetTemplate { GT.stackName = Just stackName }
  gtResult <- try $ runResourceT $ Amazonka.send (cfnEnv ctx) gtReq
  case gtResult of
    Left (e :: SomeException) ->
      pure (Left ("Failed to get template: " <> T.pack (show e)))
    Right gtResp -> do
      let templateBody = fromMaybe "" gtResp.templateBody
          isJson = T.isPrefixOf "{" (T.stripStart templateBody)
          originalExt = if isJson then "json" else "yaml" :: String

      -- 2. Describe stack
      let dsReq = DStacks.newDescribeStacks { DStacks.stackName = Just stackName }
      dsResult <- try $ runResourceT $ Amazonka.send (cfnEnv ctx) dsReq
      case dsResult of
        Left (e :: SomeException) ->
          pure (Left ("Failed to describe stack: " <> T.pack (show e)))
        Right dsResp -> do
          let stacks = fromMaybe [] dsResp.stacks
          case stacks of
            [] -> pure (Left ("Stack " <> stackName <> " not found"))
            (stack:_) -> processStack ctx stack stackName templateBody originalExt
                           outputDir moveParamsToSsm sortkeys mProject

processStack
  :: CfnContext
  -> CF.Stack -> Text -> Text -> String
  -> Text -> Bool -> Bool -> Maybe Text
  -> IO (Either Text Int)
processStack ctx stack stackName templateBody originalExt
             outputDir moveParamsToSsm sortkeys mProject = do
  -- 3. Get stack policy
  let gspReq = GSP.newGetStackPolicy stackName
  policyResult <- try $ runResourceT $ Amazonka.send (cfnEnv ctx) gspReq
  let policyBody = case policyResult of
        Left (_ :: SomeException) -> defaultStackPolicy
        Right gspResp -> fromMaybe defaultStackPolicy gspResp.stackPolicyBody

  -- Pretty-print the policy JSON if valid
  let prettyPolicy = case Aeson.eitherDecodeStrict' (TE.encodeUtf8 policyBody) :: Either String Value of
        Right v -> TE.decodeUtf8 (BL.toStrict (AesonPretty.encodePretty v))
        Left _  -> policyBody

  let dir = T.unpack outputDir

  -- 4. Create output directory
  createDirectoryIfMissing True dir

  -- 5. Write stack-policy.json
  let policyPath = dir </> "stack-policy.json"
  TIO.writeFile policyPath prettyPolicy
  hPutStrLn stderr $ "Wrote " <> policyPath

  -- 6. Write _original-template
  let originalPath = dir </> "_original-template." <> originalExt
  TIO.writeFile originalPath templateBody
  hPutStrLn stderr $ "Wrote " <> originalPath

  -- 7. Write cfn-template.yaml
  case templateBodyToYaml templateBody sortkeys of
    Left err -> pure (Left ("Failed to convert template: " <> err))
    Right yamlTemplate -> do
      let cfnTemplatePath = dir </> "cfn-template.yaml"
      TIO.writeFile cfnTemplatePath yamlTemplate
      hPutStrLn stderr $ "Wrote " <> cfnTemplatePath

      -- 8. Extract metadata from stack
      let stackTags = extractTags stack
          project = fromMaybe
            (fromMaybe "" (lookup "project" stackTags))
            mProject
          currentEnv = fromMaybe "development" $
            listToMaybe [ v | (k, v) <- stackTags, T.toLower k == "environment" ]
          stackParams = extractParams stack

      -- 9. Optionally migrate params to SSM
      ssmKeys <- if moveParamsToSsm
        then if T.null project
          then do
            hPutStrLn stderr "Error: --move-params-to-ssm requires a project name"
            pure []
          else moveParamsToSSM ctx stackParams currentEnv project
        else pure []

      -- 10. Build and write stack-args.yaml
      let argsContent = buildStackArgsYaml
            stackName project stackParams stackTags
            (extractCapabilities stack) (extractTimeout stack)
            (extractTerminationProtection stack)
            (extractNotificationArns stack) (extractRoleArn stack)
            (extractDisableRollback stack) ssmKeys
          argsPath = dir </> "stack-args.yaml"
      TIO.writeFile argsPath argsContent
      hPutStrLn stderr $ "Wrote " <> argsPath
      pure (Right 0)

------------------------------------------------------------------------
-- Stack field extraction
------------------------------------------------------------------------

extractParams :: CF.Stack -> [(Text, Text)]
extractParams stack = case stack.parameters of
  Nothing -> []
  Just ps -> [ (fromMaybe "" p.parameterKey, fromMaybe "" p.parameterValue) | p <- ps ]

extractTags :: CF.Stack -> [(Text, Text)]
extractTags stack = case stack.tags of
  Nothing   -> []
  Just tags -> [ (t.key, t.value) | t <- tags ]

extractCapabilities :: CF.Stack -> [Text]
extractCapabilities stack = case stack.capabilities of
  Nothing   -> []
  Just caps -> map CF.fromCapability caps

extractNotificationArns :: CF.Stack -> [Text]
extractNotificationArns stack = fromMaybe [] stack.notificationARNs

extractRoleArn :: CF.Stack -> Maybe Text
extractRoleArn stack = stack.roleARN

extractTimeout :: CF.Stack -> Maybe Int
extractTimeout stack = fmap fromIntegral stack.timeoutInMinutes

extractTerminationProtection :: CF.Stack -> Bool
extractTerminationProtection stack = fromMaybe False stack.enableTerminationProtection

extractDisableRollback :: CF.Stack -> Bool
extractDisableRollback stack = fromMaybe False stack.disableRollback

------------------------------------------------------------------------
-- SSM migration
------------------------------------------------------------------------

-- | Migrate non-environment parameters to SSM as SecureString.
-- Returns only the keys that were successfully written.
-- Prints a warning to stderr for any parameters that fail.
moveParamsToSSM :: CfnContext -> [(Text, Text)] -> Text -> Text -> IO [Text]
moveParamsToSSM ctx params currentEnv project = do
  let ssmPrefix = "/" <> currentEnv <> "/" <> project <> "/"
      eligible = filter (\(k, _) -> k /= "Environment" && k /= "environment") params
  results <- mapM (\(k, v) -> do
    let name = ssmPrefix <> k
    hPutStrLn stderr $ "Writing SSM parameter: " <> T.unpack name
    let req = (PP.newPutParameter name v)
                { PP.overwrite = Just True
                , PP.type' = Just SSMPT.ParameterType_SecureString
                }
    result <- try (runResourceT $ Amazonka.send (cfnEnv ctx) req) :: IO (Either SomeException PP.PutParameterResponse)
    case result of
      Left e -> do
        hPutStrLn stderr $ "WARNING: Failed to write SSM parameter "
          <> T.unpack name <> ": " <> show e
        pure Nothing
      Right _ -> pure (Just k)
    ) eligible
  pure (catMaybes results)
