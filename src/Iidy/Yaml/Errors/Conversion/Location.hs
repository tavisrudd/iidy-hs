-- | Source location utilities for YAML error positioning.
-- Converts positions to source locations and adjusts them to point at tags.
module Iidy.Yaml.Errors.Conversion.Location
  ( posToSourceLocation
  , adjustLocationForTag
  , isTypeMismatchError
  , adjustForTypeMismatch
  , tagFallbackOffset
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Yaml.Errors.Conversion.Guidance
  ( extractTagName
  , isCfnValidationMessage
  , isParseStyleError
  )
import Iidy.Yaml.Errors.Conversion.LineSearch
  ( findAnyTagInLine
  , findAnyTagOnLine
  , findFieldColumn
  , findFlowColumn
  , findTagInLine
  , findVariableColumn
  , safeLine
  )
import Iidy.Yaml.Location (Position(..), SourceLocation(..))

-- | Convert Position to SourceLocation.
posToSourceLocation :: Text -> Position -> SourceLocation
posToSourceLocation filePath pos = SourceLocation
  { srcLocFile     = filePath
  , srcLocLine     = posLine pos
  , srcLocColumn   = posColumn pos
  , srcLocYamlPath = ""
  }

-- | Adjust the source location to point at the tag rather than the value.
-- HsYAML reports the position of the value (mapping content or scalar),
-- but Rust reports the position of the tag (e.g., !$map).
-- This function searches nearby source lines for the tag and adjusts.
adjustLocationForTag :: Text -> SourceLocation -> Text -> SourceLocation
adjustLocationForTag source loc msg =
  let allLines = T.lines source
      lineNum = srcLocLine loc  -- 1-based
      tagName = extractTagName msg
  in case tagName of
    Just tag ->
      -- Search current line, then previous line for the specific tag
      case findTagInLine allLines lineNum tag of
        Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
        Nothing ->
          case findTagInLine allLines (lineNum - 1) tag of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing ->
              case findTagInLine allLines (lineNum - 2) tag of
                Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
                Nothing -> loc
    Nothing
      -- Parse errors (must be/must have): Rust points at the tag
      | isParseStyleError msg ->
          case findAnyTagInLine allLines lineNum of
            Just (ln, col) | col < srcLocColumn loc ->
              loc { srcLocLine = ln, srcLocColumn = col }
            _ -> case findAnyTagInLine allLines (lineNum - 1) of
              Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
              Nothing -> loc
      -- Type mismatch errors: use Rust-style find_tag_column logic
      | isTypeMismatchError msg ->
          adjustForTypeMismatch allLines loc msg
      -- Variable not found: search for variable reference pattern
      | "Variable not found: " `T.isPrefixOf` msg ->
          let rest = fromMaybe msg (T.stripPrefix "Variable not found: " msg)
              varPath = fst (T.breakOn ". Available: " rest)
          in case findVariableColumn allLines lineNum varPath of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing -> loc
      -- Unknown tag: "'!$mapp' is not a valid iidy tag"
      | "' is not a valid iidy tag" `T.isSuffixOf` msg ->
          let unknownTag = T.takeWhile (/= '\'') (T.drop 1 msg)
          in case findTagInLine allLines lineNum unknownTag of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing -> case findTagInLine allLines (lineNum - 1) unknownTag of
              Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
              Nothing -> loc
      -- Unexpected field: position needs +1 for 1-based column
      | "unexpected field '" `T.isPrefixOf` msg ->
          loc { srcLocColumn = srcLocColumn loc + 1 }
      -- Query/jmespath mutual exclusivity: search for !$ tag
      | "'query' and 'jmespath'" `T.isPrefixOf` msg ->
          case findAnyTagInLine allLines lineNum of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            _ -> case findAnyTagInLine allLines (lineNum - 1) of
              Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
              Nothing -> loc
      -- CFN validation: +1 for 1-based column
      | isCfnValidationMessage msg ->
          loc { srcLocColumn = srcLocColumn loc + 1 }
      -- Property not found in query: column 0 suppresses caret (matching Rust)
      | "property '" `T.isPrefixOf` msg ->
          loc { srcLocColumn = 0 }
      | otherwise -> loc

-- | Check if message is a type mismatch error
isTypeMismatchError :: Text -> Bool
isTypeMismatchError msg = "expected " `T.isPrefixOf` msg && ", found " `T.isInfixOf` msg

-- | Adjust location for type mismatch errors.
-- Searches for the tag on the source line, then uses tag-specific logic
-- to find the correct column (matching Rust's find_tag_column behavior).
adjustForTypeMismatch :: [Text] -> SourceLocation -> Text -> SourceLocation
adjustForTypeMismatch allLines loc msg =
  let lineNum = srcLocLine loc
      -- First: find which line has the tag
      tagInfo = findAnyTagOnLine allLines lineNum
            <|> findAnyTagOnLine allLines (lineNum - 1)
  in case tagInfo of
    Just (tagLn, tagCol0, tagText) ->
      -- Try searching for field keyword on subsequent lines (block-style)
      -- Skip field search for template-result errors (they should use tag fallback)
      let isItemsError = "expected sequence" `T.isPrefixOf` msg
                       || "expected object" `T.isPrefixOf` msg
          fieldResult = if isItemsError
                        then findFieldColumn allLines tagLn tagText
                        else Nothing
          fallback = loc { srcLocLine = tagLn, srcLocColumn = tagCol0 + tagFallbackOffset tagText }
      in case fieldResult of
        Just (fieldLn, fieldCol) -> loc { srcLocLine = fieldLn, srcLocColumn = fieldCol }
        Nothing ->
          -- Try flow-style position adjustment on the tag line
          case safeLine allLines tagLn of
            Just tagLine -> case findFlowColumn tagLine tagText msg of
              Just flowCol -> loc { srcLocLine = tagLn, srcLocColumn = flowCol }
              Nothing -> fallback
            Nothing -> fallback
    Nothing -> loc

-- | Get the fallback offset for a tag, matching Rust's tag_fallback patterns.
-- Rust matches tag families in order: !$split, !$join, !$groupBy, !$mapListToHash,
-- !$fromPairs, !$merge, !$map. Each uses find(short_tag) + offset.
-- The offset = short_tag_length + 1.
tagFallbackOffset :: Text -> Int
tagFallbackOffset tagText
  | "!$split" `T.isPrefixOf` tt     = 8    -- !$split (7) + 1
  | "!$join" `T.isPrefixOf` tt      = 7    -- !$join (6) + 1
  | "!$groupBy" `T.isPrefixOf` tt   = 9    -- !$groupBy (9) + 0
  | "!$mapListToHash" `T.isPrefixOf` tt = 15 -- !$mapListToHash (15) + 0
  | "!$fromPairs" `T.isPrefixOf` tt = 12   -- !$fromPairs (11) + 1
  | "!$merge" `T.isPrefixOf` tt     = 8    -- !$merge (7) + 1 (matches !$mergeMap)
  | "!$map" `T.isPrefixOf` tt       = 6    -- !$map (5) + 1 (matches !$mapValues)
  | otherwise = T.length tagText + 1
  where tt = tagText
