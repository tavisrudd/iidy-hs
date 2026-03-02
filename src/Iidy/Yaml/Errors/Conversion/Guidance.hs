-- | Error guidance utilities for YAML error display.
-- Extracts tag names, generates guidance text, and produces help for CFN errors.
module Iidy.Yaml.Errors.Conversion.Guidance
  ( isParseStyleError
  , extractTagName
  , extractMustBeGuidance
  , guessExampleFromMustBe
  , extractExpected
  , extractFound
  , generateTypeConversionHelp
  , isCfnValidationMessage
  , parseCfnValidationMessage
  , cfnHelpText
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Yaml.Errors.Conversion.LineSearch (tagExample)

-- | Check if this is a parse-time error (not a resolve-time type mismatch).
-- Parse errors need the position adjusted to point at the tag, not the value.
isParseStyleError :: Text -> Bool
isParseStyleError msg =
  "must be " `T.isPrefixOf` msg ||
  "must have " `T.isPrefixOf` msg ||
  "invalid format" `T.isPrefixOf` msg

-- | Extract the tag name from an error message.
-- Looks for patterns like "!$map", "!$join", "!$if", etc.
extractTagName :: Text -> Maybe Text
extractTagName msg
  -- "'field' missing in !$tag tag"
  | "' missing in " `T.isInfixOf` msg =
      let (_, rest) = T.breakOn "' missing in " msg
          afterMissing = fromMaybe rest (T.stripPrefix "' missing in " rest)
          tag = T.takeWhile (\c -> c /= ' ' && c /= '\n') afterMissing
      in if T.null tag then Nothing else Just tag
  -- "missing required 'in' field" — it's !$let
  | "missing required 'in' field" == msg = Just "!$let"
  -- "must be a mapping/sequence" patterns — no tag info directly
  -- Try to find !$ in the message
  | "must be " `T.isPrefixOf` msg = Nothing
  | "must have " `T.isPrefixOf` msg = Nothing
  -- "expected X, found Y" — type mismatch, search for tag in context
  | "expected " `T.isPrefixOf` msg = Nothing
  -- Messages starting with "!$tag ..."
  | "!$" `T.isPrefixOf` msg =
      let tag = "!" <> T.takeWhile (\c -> c /= ' ' && c /= ':' && c /= '\n') (T.drop 1 msg)
      in Just tag
  | otherwise = Nothing

-- | Generate guidance text from "must be" error messages.
extractMustBeGuidance :: Text -> Text
extractMustBeGuidance msg
  | "must be a mapping with required 'test' and 'then' fields" `T.isInfixOf` msg =
      "use format: {test: condition, then: value, else: alternative}"
  | "must be a mapping with variable bindings" `T.isInfixOf` msg =
      "use format: {var1: value1, var2: value2, in: expression}"
  | "must be a mapping with 'items' and 'template'" `T.isInfixOf` msg =
      "use format: {items: array, template: mapping_template}"
  | "must be a mapping with 'items' and 'key'" `T.isInfixOf` msg =
      "use format: {items: array, key: grouping_key, var: item_name, template: result_template}"
  | "must be a mapping with 'template' and 'params'" `T.isInfixOf` msg =
      "use format: {template: name, params: {key: value}}"
  | "must be a sequence with format [delimiter, array]" `T.isInfixOf` msg =
      "use format: [delimiter, array]"
  | "must be a sequence with format [delimiter, string]" `T.isInfixOf` msg =
      "use format: [delimiter, string]"
  | "must be a sequence with format [value1, value2]" `T.isInfixOf` msg =
      "use format: [value1, value2]"
  | "must be a sequence with exactly 2 elements" `T.isInfixOf` msg =
      "use format: [value1, value2]"
  | "must be a sequence of objects to merge" `T.isInfixOf` msg =
      "use format: [object1, object2, ...]"
  | "must be a sequence of arrays to concatenate" `T.isInfixOf` msg =
      "use format: [array1, array2, ...]"
  | otherwise = "check tag format"

-- | Guess an example block from a "must be" message by looking for tag-specific keywords.
guessExampleFromMustBe :: Text -> Maybe Text
guessExampleFromMustBe msg
  | "'test' and 'then'" `T.isInfixOf` msg = Just $ tagExample "!$if"
  | "variable bindings" `T.isInfixOf` msg = Just $ tagExample "!$let"
  | "'items' and 'template'" `T.isInfixOf` msg = Just $ tagExample "!$map"
  | "'items' and 'key'" `T.isInfixOf` msg = Just $ tagExample "!$groupBy"
  | "'template' and 'params'" `T.isInfixOf` msg = Just $ tagExample "!$expand"
  | "[delimiter, array]" `T.isInfixOf` msg = Just "!$join [\",\", [\"a\", \"b\", \"c\"]]"
  | "[delimiter, string]" `T.isInfixOf` msg = Just "!$split [\",\", \"a,b,c\"]"
  | "[value1, value2]" `T.isInfixOf` msg = Just "!$eq [\"{{env}}\", \"production\"]"
  | "exactly 2 elements" `T.isInfixOf` msg = Just "!$eq [\"{{env}}\", \"production\"]"
  | "objects to merge" `T.isInfixOf` msg = Just "!$merge\n     - {key1: value1}\n     - {key2: value2}\n     - {key3: value3}"
  | "arrays to concatenate" `T.isInfixOf` msg = Just "!$concat\n     - [item1, item2]\n     - [item3, item4]\n     - [item5]"
  | otherwise = Nothing

-- | Extract expected type from error message (best effort).
extractExpected :: Text -> Text
extractExpected msg
  | "items must be a sequence" `T.isInfixOf` msg = "sequence"
  | "must be a mapping" `T.isInfixOf` msg || "must be mappings" `T.isInfixOf` msg = "object"
  | "requires string" `T.isInfixOf` msg = "string"
  | "requires [string, sequence]" `T.isInfixOf` msg = "string and sequence"
  | "requires a sequence" `T.isInfixOf` msg = "sequence"
  | otherwise = "correct type"

-- | Extract found type from error message (best effort).
extractFound :: Text -> Text
extractFound msg
  | "found a string" `T.isInfixOf` msg = "string"
  | "found a sequence" `T.isInfixOf` msg = "sequence"
  | "found a mapping" `T.isInfixOf` msg || "found an object" `T.isInfixOf` msg = "object"
  | "found a number" `T.isInfixOf` msg = "number"
  | "found a boolean" `T.isInfixOf` msg = "boolean"
  | "found null" `T.isInfixOf` msg = "null"
  | otherwise = "wrong type"

-- | Generate type conversion help text matching Rust's output.
-- Rust only provides hints for object/string conversions.
generateTypeConversionHelp :: Text -> Text -> Maybe Text
generateTypeConversionHelp expected found
  | expected == "object" && found == "string" =
      Just "try using !$parseJson or !$parseYaml to parse the string"
  | expected == "string" && found == "object" =
      Just "try using !$toJsonString or !$toYamlString to serialize the object"
  | otherwise = Nothing

-- | Check if a message is a CloudFormation validation error.
isCfnValidationMessage :: Text -> Bool
isCfnValidationMessage msg = any (\p -> p `T.isPrefixOf` msg) cfnValidationPrefixes
  where
    cfnValidationPrefixes :: [Text]
    cfnValidationPrefixes =
      [ "!Ref ", "!Sub ", "!GetAtt ", "!Join ", "!Select ", "!Split "
      , "!FindInMap ", "!Base64 ", "!GetAZs ", "!ImportValue "
      , "!Cidr ", "!Length ", "!ToJsonString ", "!Transform ", "!ForEach "
      , "!If ", "!Equals ", "!And ", "!Or ", "!Not "
      ]

-- | Extract CFN tag name from validation message.
parseCfnValidationMessage :: Text -> (Text, Text)
parseCfnValidationMessage msg =
  let tag = "!" <> T.takeWhile (/= ' ') (T.drop 1 msg)
  in (tag, msg)

-- | Generate help text for CloudFormation validation errors.
cfnHelpText :: Text -> Text -> Text
cfnHelpText tag _msg
  | tag == "!Ref" =
      "!Ref expects a string (resource or parameter name)\n" <>
      "   example: BucketName: !Ref MyBucket\n" <>
      "   example: Environment: !Ref EnvironmentParam"
  | tag == "!Base64" =
      "!Base64 expects a non-null string value\n" <>
      "   example: UserData: !Base64 'echo Hello'\n" <>
      "   example: Script: !Base64 !Sub 'echo ${Parameter}'"
  | tag == "!Join" =
      "!Join expects [delimiter, array] with exactly 2 elements\n" <>
      "   example: Name: !Join ['-', [!Ref 'AWS::StackName', 'suffix']]"
  | tag == "!Select" =
      "!Select expects [index, array] with exactly 2 elements\n" <>
      "   example: AZ: !Select [0, !GetAZs '']"
  | tag == "!FindInMap" =
      "!FindInMap expects [map, key1, key2] with exactly 3 elements\n" <>
      "   example: AMI: !FindInMap [RegionMap, !Ref 'AWS::Region', AMI]"
  | tag == "!Sub" =
      "!Sub expects a string or [string, variables_map]\n" <>
      "   example: Name: !Sub '${AWS::StackName}-resource'\n" <>
      "   example: Name: !Sub ['${Param}-suffix', {Param: !Ref MyParam}]"
  | tag == "!GetAtt" =
      "!GetAtt expects 'Resource.Attribute' or [resource, attribute]\n" <>
      "   example: Arn: !GetAtt MyBucket.Arn\n" <>
      "   example: Arn: !GetAtt [MyBucket, Arn]"
  | tag == "!Split" =
      "!Split expects [delimiter, string] with exactly 2 elements\n" <>
      "   example: Parts: !Split [',', 'a,b,c']"
  | tag == "!If" =
      "!If expects [condition, true_value, false_value] with exactly 3 elements\n" <>
      "   example: Value: !If [IsProduction, 'prod', 'dev']"
  | tag == "!Equals" =
      "!Equals expects [value1, value2] with exactly 2 elements\n" <>
      "   example: !Equals [!Ref EnvParam, 'production']"
  | tag == "!Not" =
      "!Not expects a 1-element array containing a condition\n" <>
      "   example: !Not [!Equals [!Ref EnvParam, 'production']]"
  | otherwise = tag <> " usage error"
