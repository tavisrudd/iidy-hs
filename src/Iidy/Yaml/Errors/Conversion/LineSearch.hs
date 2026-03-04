-- | Pure text search utilities for YAML error location.
-- These functions search source lines for tags, keywords, and patterns.
module Iidy.Yaml.Errors.Conversion.LineSearch
  ( findAnyTagOnLine
  , findFieldColumn
  , findFlowColumn
  , findSecondBracketArg
  , findUnquotedComma
  , findVariableColumn
  , findAfterKeyword
  , findTagInLine
  , findAnyTagInLine
  , safeLine
  , findSubstring
  , findAllSubstring
  , findSecondTag
  , findTagOnSourceLine
  , findTagExampleForUnexpectedField
  , findTagInNearbyLines
  , tagExample
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Yaml.Location (SourceLocation(..))

-- | Find a !$ tag on a line, returning (lineNum, 0-based col, tag text).
findAnyTagOnLine :: [Text] -> Int -> Maybe (Int, Int, Text)
findAnyTagOnLine allLines lineNum = do
  line <- safeLine allLines lineNum
  col0 <- findSubstring "!$" line
  let rest = T.drop col0 line
      tag = T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t' && c /= '{' && c /= '[' && c /= ':') rest
  if T.length tag > 2 then Just (lineNum, col0, tag) else Nothing

-- | Search subsequent lines after a tag for field keywords.
-- Returns (lineNum, column) matching Rust's find_after_keyword logic.
findFieldColumn :: [Text] -> Int -> Text -> Maybe (Int, Int)
findFieldColumn allLines tagLn tagText
  | tagLower == "!$groupby" = searchField "items:"
  | tagLower == "!$maplisttohash" = searchField "items:"
  | tagLower == "!$mapvalues" = searchField "items:"
  | tagLower == "!$frompairs" = searchField "source:"
  | otherwise = Nothing
  where
    tagLower = T.toLower tagText
    searchField keyword =
      -- Search lines after the tag for the keyword
      let nextLines = drop tagLn (zip [1..] (map Just allLines))
      in case [(n, findAfterKeyword line keyword) | (n, Just line) <- take 3 nextLines
              , keyword `T.isInfixOf` line] of
        ((n, Just col):_) -> Just (n, col)
        _ -> Nothing

-- | Find the column for flow-style tag arguments on the same line.
-- Handles !$join [delim, array] and !$split [delim, string] patterns.
findFlowColumn :: Text -> Text -> Text -> Maybe Int
findFlowColumn tagLine tagText msg
  | tagLower == "!$join" =
      if "[delimiter]" `T.isSuffixOf` msg
      then -- Delimiter (first arg): find '[' + 1
           fmap (+ 1) (findSubstring "[" tagLine)
      else if "expected sequence" `T.isPrefixOf` msg
      then -- Sequence (second arg): find after first comma
           findSecondBracketArg tagLine
      else -- Item error: use tag fallback (returns Nothing)
           Nothing
  | otherwise = Nothing
  where
    tagLower = T.toLower tagText

-- | Find the second argument in a bracket expression [first, second].
-- Returns 1-based column of the second argument.
findSecondBracketArg :: Text -> Maybe Int
findSecondBracketArg line = do
  bracketPos <- findSubstring "[" line
  let after = T.drop (bracketPos + 1) line
      commaIdx = findUnquotedComma after
  case commaIdx of
    Just ci ->
      let afterComma = T.drop (ci + 1) after
          ws = T.length (T.takeWhile (== ' ') afterComma)
      in Just (bracketPos + 1 + ci + 1 + ws + 1)  -- 1-based
    Nothing -> Nothing

-- | Find unquoted comma position in text.
findUnquotedComma :: Text -> Maybe Int
findUnquotedComma = go 0 False
  where
    go i inQ t = case T.uncons t of
      Nothing -> Nothing
      Just (c, rest)
        | inQ       -> go (i+1) (c /= '"') rest
        | c == ','  -> Just i
        | c == '"'  -> go (i+1) True rest
        | otherwise -> go (i+1) False rest

-- | Find the position of a variable reference in source lines.
-- Searches for patterns like "!$ variable", "!$variable", "{{variable}}".
-- Returns (lineNum, column) matching Rust's find_variable_column.
findVariableColumn :: [Text] -> Int -> Text -> Maybe (Int, Int)
findVariableColumn allLines lineNum varPath = do
  line <- safeLine allLines lineNum
  case findSubstring ("!$ " <> varPath) line of
    Just col -> Just (lineNum, col + 4)  -- skip "!$ " + 1 for Rust compat
    Nothing -> case findSubstring ("!$" <> varPath) line of
      Just col -> Just (lineNum, col + 3)
      Nothing -> case findSubstring ("{{" <> varPath <> "}}") line of
        Just col -> Just (lineNum, col + 2)
        Nothing -> Nothing

-- | Find the column after a keyword and whitespace (Rust-compatible).
findAfterKeyword :: Text -> Text -> Maybe Int
findAfterKeyword line keyword =
  case findSubstring keyword line of
    Just pos ->
      let afterKw = T.drop (pos + T.length keyword) line
          ws = T.length (T.takeWhile (== ' ') afterKw)
      in Just (pos + T.length keyword + ws + 1)  -- +1 matches Rust
    Nothing -> Nothing

-- | Find a tag in a specific source line. Returns (lineNum, 1-based column).
findTagInLine :: [Text] -> Int -> Text -> Maybe (Int, Int)
findTagInLine allLines lineNum tag = do
  line <- safeLine allLines lineNum
  col <- findSubstring tag line
  Just (lineNum, col + 1)  -- 1-based

-- | Find any !$ tag on a source line. Returns (lineNum, 1-based column).
findAnyTagInLine :: [Text] -> Int -> Maybe (Int, Int)
findAnyTagInLine allLines lineNum = do
  line <- safeLine allLines lineNum
  col <- findSubstring "!$" line
  Just (lineNum, col + 1)  -- 1-based

-- | Safe 1-based line access into a list of lines.
safeLine :: [Text] -> Int -> Maybe Text
safeLine lns n
  | n >= 1 = case drop (n - 1) lns of
      (x:_) -> Just x
      _     -> Nothing
  | otherwise = Nothing

-- | Find a substring in a text, return 0-based column position.
findSubstring :: Text -> Text -> Maybe Int
findSubstring needle haystack
  | T.null needle = Nothing
  | needle `T.isInfixOf` haystack =
      let (before, _) = T.breakOn needle haystack
      in Just (T.length before)
  | otherwise = Nothing

-- | Find all occurrences of a substring, returning 0-based positions.
findAllSubstring :: Text -> Text -> [Int]
findAllSubstring needle haystack = go 0 haystack
  where
    nLen = T.length needle
    go _ t | T.null t = []
    go offset t = case findSubstring needle t of
      Nothing -> []
      Just pos -> (offset + pos) : go (offset + pos + nLen) (T.drop (pos + nLen) t)

-- | Find the second !$ tag on a line, returning its 0-based column position.
findSecondTag :: Text -> Maybe Int
findSecondTag line =
  case findAllSubstring "!$" line of
    (_:second:_) -> Just second
    _ -> Nothing

-- | Find the full tag name (e.g., "!$mapListToHash") on the source line at the given location.
findTagOnSourceLine :: [Text] -> SourceLocation -> Maybe Text
findTagOnSourceLine allLines loc = do
  line <- safeLine allLines (srcLocLine loc)
  col <- findSubstring "!$" line
  let rest = T.drop col line
      tag = T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t' && c /= '{' && c /= '[' && c /= ':') rest
  if T.length tag > 2 then Just tag else Nothing

-- | Find a tag example for unexpected field errors by looking at the source line.
findTagExampleForUnexpectedField :: [Text] -> SourceLocation -> Maybe Text
findTagExampleForUnexpectedField allLines loc =
  let lineNum = srcLocLine loc
  in case findTagOnSourceLine allLines (loc { srcLocLine = max 1 (lineNum - 3) }) of
    Just t  -> let ex = tagExample t in if T.null ex then Nothing else Just ex
    Nothing -> findTagInNearbyLines allLines lineNum

-- | Search nearby lines (before the error position) for a tag.
findTagInNearbyLines :: [Text] -> Int -> Maybe Text
findTagInNearbyLines allLines lineNum =
  let searchRange = [max 1 (lineNum - 5) .. lineNum]
      findTag ln = do
        line <- safeLine allLines ln
        col <- findSubstring "!$" line
        let rest = T.drop col line
            tag = T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t' && c /= '{' && c /= '[' && c /= ':') rest
        if T.length tag > 2 then Just tag else Nothing
  in case concatMap (maybe [] (:[]) . findTag) searchRange of
    (t:_) -> let ex = tagExample t in if T.null ex then Nothing else Just ex
    [] -> Nothing

-- | Generate example text for a tag.
tagExample :: Text -> Text
tagExample tag = case T.toLower tag of
  "!$map"  -> "!$map\n     items: [1, 2, 3]\n     template: \"{{item}}\""
  "!$if"   -> "!$if\n     test: !$eq [\"prod\", \"{{env}}\"]\n     then: \"production\"\n     else: \"development\""
  "!$let"  -> "!$let\n     var1: value1\n     var2: value2\n     in: \"{{var1}}-{{var2}}\""
  "!$maplisttohash" -> "!$mapListToHash\n     items: [{\"key\": \"a\", \"value\": 1}, {\"key\": \"b\", \"value\": 2}]\n     keyPath: key\n     valuePath: value"
  "!$mergemap" -> "!$mergeMap\n     items: [1, 2, 3]\n     template: \"{key: {{item}}}\""
  "!$mapvalues" -> "!$mapValues\n     <check documentation for proper syntax>"
  "!$groupby" -> "!$groupBy\n     items: [{name: \"a\", type: \"x\"}, {name: \"b\", type: \"x\"}]\n     key: type\n     var: group\n     template: \"{{group.key}}: {{#each group.items}}{{name}}{{/each}}\""
  "!$expand" -> "!$expand\n     template: my-template\n     params: {key: value}"
  "!$eq" -> "!$eq [\"{{env}}\", \"production\"]"
  _ -> ""
