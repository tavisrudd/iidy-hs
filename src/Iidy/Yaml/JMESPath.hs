-- | JMESPath query engine for iidy template processing.
--
-- Specification: JMESPath (https://jmespath.org/specification.html)
-- This is a partial implementation covering the subset used by iidy templates:
-- field access, nested/index/slice expressions, projections, filters,
-- multi-select lists/hashes, pipe expressions, and literal values.
module Iidy.Yaml.JMESPath
  ( applyJmesPath
  , JMESPathError(..)
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isAlphaNum, isDigit)
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

newtype JMESPathError = JMESPathError Text
  deriving stock (Show, Eq)

data JExpr
  = JField !Text
  | JIndex !Int
  | JSubExpr !JExpr !JExpr
  | JWildcard
  | JProjection !JExpr !JExpr
  | JFlatten !JExpr
  | JFilter !JExpr !JExpr
  | JMultiSelectHash ![(Text, JExpr)]
  | JMultiSelectList ![JExpr]
  | JLiteral !Value
  | JPipe !JExpr !JExpr
  | JIdentity
  | JComparison !CompOp !JExpr !JExpr
  | JNot !JExpr
  deriving stock (Show)

data CompOp = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe
  deriving stock (Show)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

applyJmesPath :: Text -> Value -> Either JMESPathError Value
applyJmesPath expr val = do
  parsed <- parseJMESPath expr
  Right (evalJExpr parsed val)

------------------------------------------------------------------------
-- Parser
------------------------------------------------------------------------

parseJMESPath :: Text -> Either JMESPathError JExpr
parseJMESPath input = do
  let trimmed = T.strip input
      exprLen = T.length trimmed
  (expr, rest) <- addPosition exprLen (parseExpr trimmed)
  let rest' = T.stripStart rest
  if T.null rest'
    then Right expr
    else Left (JMESPathError $ "Unexpected trailing input: " <> rest')
  where
    -- | Add position info to parse errors, matching Rust jmespath crate format
    addPosition :: Int -> Either JMESPathError a -> Either JMESPathError a
    addPosition len (Left (JMESPathError msg))
      | "Parse error:" `T.isPrefixOf` msg =
          Left (JMESPathError $ msg <> " (line 0, column " <> T.pack (show len) <> ")")
      | otherwise = Left (JMESPathError msg)
    addPosition _ r = r

parseExpr :: Text -> Either JMESPathError (JExpr, Text)
parseExpr input = do
  (lhs, rest) <- parseAtom input
  parsePostfix lhs rest

parseAtom :: Text -> Either JMESPathError (JExpr, Text)
parseAtom input
  | T.null input = Left (JMESPathError "Unexpected end of expression")
  | T.isPrefixOf "*" input =
      Right (JWildcard, T.drop 1 input)
  | T.isPrefixOf "@" input =
      Right (JIdentity, T.drop 1 input)
  | T.isPrefixOf "!" input = do
      (expr, rest) <- parseAtom (T.drop 1 input)
      Right (JNot expr, rest)
  | T.isPrefixOf "{" input = do
      parseMultiSelectHash (T.drop 1 input)
  | T.isPrefixOf "[?" input = do
      parseFilterExpr (T.drop 2 input)
  | T.isPrefixOf "[]" input =
      Right (JFlatten JIdentity, T.drop 2 input)
  | T.isPrefixOf "[*]" input =
      Right (JProjection JIdentity JIdentity, T.drop 3 input)
  | T.isPrefixOf "[" input = do
      parseIndexOrMultiSelect (T.drop 1 input)
  | T.isPrefixOf "'" input = do
      parseLiteralString (T.drop 1 input)
  | T.isPrefixOf "`" input = do
      parseJsonLiteral (T.drop 1 input)
  | Just (c, _) <- T.uncons input, isIdentStart c = do
      let (ident, rest) = T.span isIdentChar input
      Right (JField ident, rest)
  | otherwise =
      Left (JMESPathError $ "Unexpected character: " <> T.take 1 input)

parsePostfix :: JExpr -> Text -> Either JMESPathError (JExpr, Text)
parsePostfix lhs input
  | T.null input = Right (lhs, input)
  | isProjecting lhs, not (T.isPrefixOf "|" input) =
      -- Inside a projection: parse the RHS as the projected expression
      parseProjectedPostfix lhs input
  | T.isPrefixOf "." input = do
      let after = T.drop 1 input
      if T.isPrefixOf "*" after
        then do
          let rest = T.drop 1 after
          parsePostfix (JProjection lhs JIdentity) rest
        else do
          (rhs, rest) <- parseAtom after
          parsePostfix (JSubExpr lhs rhs) rest
  | T.isPrefixOf "[?" input = do
      (filterExpr, rest) <- parseFilterExpr (T.drop 2 input)
      parsePostfix (JProjection lhs filterExpr) rest
  | T.isPrefixOf "[]" input = do
      parsePostfix (JFlatten lhs) (T.drop 2 input)
  | T.isPrefixOf "[*]" input = do
      parsePostfix (JProjection lhs JIdentity) (T.drop 3 input)
  | T.isPrefixOf "[" input = do
      (indexExpr, rest) <- parseIndexOrMultiSelect (T.drop 1 input)
      parsePostfix (JSubExpr lhs indexExpr) rest
  | T.isPrefixOf "|" input = do
      (rhs, rest) <- parseExpr (T.drop 1 input)
      Right (JPipe lhs rhs, rest)
  | T.isPrefixOf "==" input = parseBinOp OpEq lhs (T.drop 2 input)
  | T.isPrefixOf "!=" input = parseBinOp OpNe lhs (T.drop 2 input)
  | T.isPrefixOf "<=" input = parseBinOp OpLe lhs (T.drop 2 input)
  | T.isPrefixOf ">=" input = parseBinOp OpGe lhs (T.drop 2 input)
  | T.isPrefixOf "<" input = parseBinOp OpLt lhs (T.drop 1 input)
  | T.isPrefixOf ">" input = parseBinOp OpGt lhs (T.drop 1 input)
  -- Detect function call syntax: identifier followed by '('
  | T.isPrefixOf "(" input =
      Left (JMESPathError $ "JMESPath functions are not supported in iidy (e.g., 'length(@)'). See notes/jmespath-subset.md")
  | otherwise = Right (lhs, input)

-- | Check if an expression is a projection that needs its RHS filled in
isProjecting :: JExpr -> Bool
isProjecting (JProjection _ JIdentity) = True
isProjecting (JFilter _ JIdentity) = True
isProjecting _ = False

-- | Parse postfix expressions inside a projection, threading them into the
-- projection's RHS rather than wrapping the projection in a JSubExpr
parseProjectedPostfix :: JExpr -> Text -> Either JMESPathError (JExpr, Text)
parseProjectedPostfix lhs input
  | T.null input = Right (lhs, input)
  | T.isPrefixOf "." input = do
      let after = T.drop 1 input
      if T.isPrefixOf "*" after
        then do
          let rest = T.drop 1 after
          -- Nested projection: [*].*  becomes JProjection(source, JProjection(JIdentity, JIdentity))
          parsePostfix (setProjectionRHS lhs (JProjection JIdentity JIdentity)) rest
        else if T.isPrefixOf "{" after
          then do
            (rhs, rest) <- parseAtom after
            parsePostfix (setProjectionRHS lhs rhs) rest
          else do
            (rhs, rest) <- parseAtom after
            (fullRhs, rest') <- parsePostfix rhs rest
            Right (setProjectionRHS lhs fullRhs, rest')
  | T.isPrefixOf "[" input = do
      -- [*][0] or [*][?filter] — parse the bracket expression as projected
      if T.isPrefixOf "[?" input
        then do
          (filterExpr, rest) <- parseFilterExpr (T.drop 2 input)
          parsePostfix (setProjectionRHS lhs (JProjection JIdentity filterExpr)) rest
        else if T.isPrefixOf "[]" input
          then do
            parsePostfix (setProjectionRHS lhs (JFlatten JIdentity)) (T.drop 2 input)
          else if T.isPrefixOf "[*]" input
            then do
              parsePostfix (setProjectionRHS lhs (JProjection JIdentity JIdentity)) (T.drop 3 input)
            else do
              (indexExpr, rest) <- parseIndexOrMultiSelect (T.drop 1 input)
              parsePostfix (setProjectionRHS lhs (JSubExpr JIdentity indexExpr)) rest
  | otherwise = Right (lhs, input)

-- | Set the RHS of a projection or filter expression
setProjectionRHS :: JExpr -> JExpr -> JExpr
setProjectionRHS (JProjection src _) rhs = JProjection src rhs
setProjectionRHS (JFilter cond _) rhs = JFilter cond rhs
setProjectionRHS other _ = other  -- shouldn't happen

parseBinOp :: CompOp -> JExpr -> Text -> Either JMESPathError (JExpr, Text)
parseBinOp op lhs input = do
  let trimmed = T.stripStart input
  (rhs, rest) <- parseAtom trimmed
  Right (JComparison op lhs rhs, rest)

parseFilterExpr :: Text -> Either JMESPathError (JExpr, Text)
parseFilterExpr input = do
  let trimmed = T.stripStart input
  (condExpr, rest) <- parseExpr trimmed
  let rest' = T.stripStart rest
  case T.stripPrefix "]" rest' of
    Just remaining -> Right (JFilter condExpr JIdentity, remaining)
    Nothing -> Left (JMESPathError "Unclosed filter expression")

parseMultiSelectHash :: Text -> Either JMESPathError (JExpr, Text)
parseMultiSelectHash = go []
  where
    go acc input = do
      let trimmed = T.stripStart input
      -- Parse key: expr pair
      let (key, afterKey) = T.span isIdentChar trimmed
      when (T.null key) $ Left (JMESPathError "Expected key in multi-select hash")
      let afterKey' = T.stripStart afterKey
      case T.stripPrefix ":" afterKey' of
        Nothing -> Left (JMESPathError "Expected ':' after key")
        Just afterColon -> do
          let afterColon' = T.stripStart afterColon
          (expr, rest) <- parseExpr afterColon'
          let rest' = T.stripStart rest
              pair = (key, expr)
          case T.uncons rest' of
            Just (',', remaining) -> go (pair : acc) remaining
            Just ('}', remaining) -> Right (JMultiSelectHash (reverse (pair : acc)), remaining)
            _ -> Left (JMESPathError "Expected ',' or '}' in multi-select hash")

parseIndexOrMultiSelect :: Text -> Either JMESPathError (JExpr, Text)
parseIndexOrMultiSelect input
  | T.null input = Left (JMESPathError "Parse error: Expected number, ':', or '*' -- found Eof")
  | Just (c, _) <- T.uncons input, isDigitOrMinus c = do
      let (numStr, afterNum) = T.span (\c' -> isDigit c' || c' == '-') input
      case reads (T.unpack numStr) :: [(Int, String)] of
        [(n, "")] ->
          case T.stripPrefix "]" afterNum of
            Just rest -> Right (JIndex n, rest)
            Nothing
              | T.isPrefixOf ":" afterNum ->
                  Left (JMESPathError $ "JMESPath slice expressions are not supported in iidy (e.g., '[0:5]'). See notes/jmespath-subset.md")
              | otherwise -> Left (JMESPathError "Expected ']' after index")
        _ -> Left (JMESPathError $ "Invalid index: " <> numStr)
  | Just (':', _) <- T.uncons input =
      Left (JMESPathError $ "JMESPath slice expressions are not supported in iidy (e.g., '[0:5]'). See notes/jmespath-subset.md")
  | otherwise = do
      -- Multi-select list
      parseMultiSelectList input
  where
    isDigitOrMinus c = isDigit c || c == '-'

parseMultiSelectList :: Text -> Either JMESPathError (JExpr, Text)
parseMultiSelectList = go []
  where
    go acc input = do
      let trimmed = T.stripStart input
      (expr, rest) <- parseExpr trimmed
      let rest' = T.stripStart rest
      case T.uncons rest' of
        Just (',', remaining) -> go (expr : acc) remaining
        Just (']', remaining) -> Right (JMultiSelectList (reverse (expr : acc)), remaining)
        _ -> Left (JMESPathError "Expected ',' or ']' in multi-select list")

parseLiteralString :: Text -> Either JMESPathError (JExpr, Text)
parseLiteralString input =
  case T.breakOn "'" input of
    (str, rest)
      | T.null rest -> Left (JMESPathError "Unclosed string literal")
      | otherwise -> Right (JLiteral (String str), T.drop 1 rest)

parseJsonLiteral :: Text -> Either JMESPathError (JExpr, Text)
parseJsonLiteral input =
  case T.breakOn "`" input of
    (content, rest)
      | T.null rest -> Left (JMESPathError "Unclosed JSON literal")
      | otherwise -> Right (JLiteral (String content), T.drop 1 rest)

isIdentStart :: Char -> Bool
isIdentStart c = isAlphaNum c || c == '_'

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_'

when :: Bool -> Either e () -> Either e ()
when True e  = e
when False _ = Right ()

------------------------------------------------------------------------
-- Evaluator
------------------------------------------------------------------------

evalJExpr :: JExpr -> Value -> Value
evalJExpr expr val = case expr of
  JField name -> case val of
    Object obj -> maybe Null id (KM.lookup (Key.fromText name) obj)
    _ -> Null

  JIndex i -> case val of
    Array arr
      | i >= 0 && i < V.length arr -> arr V.! i
      | i < 0 && abs i <= V.length arr -> arr V.! (V.length arr + i)
    _ -> Null

  JSubExpr left right ->
    evalJExpr right (evalJExpr left val)

  JWildcard -> case val of
    Object obj -> Array (V.fromList (map snd (KM.toList obj)))
    Array arr -> arr `seq` Array arr
    _ -> Null

  JProjection source proj -> case evalJExpr source val of
    Array arr -> Array (V.map (evalJExpr proj) arr)
    _ -> Null

  JFlatten source -> case evalJExpr source val of
    Array arr -> Array (V.concatMap flattenOne arr)
    _ -> Null
    where
      flattenOne (Array inner) = inner
      flattenOne other = V.singleton other

  JFilter cond proj -> case val of
    Array arr ->
      let filtered = V.filter (\item -> isTruthy (evalJExpr cond item)) arr
      in Array (V.map (evalJExpr proj) filtered)
    _ -> Null

  JMultiSelectHash pairs ->
    Object $ KM.fromList [(Key.fromText k, evalJExpr e val) | (k, e) <- pairs]

  JMultiSelectList exprs ->
    Array (V.fromList [evalJExpr e val | e <- exprs])

  JLiteral v -> v

  JPipe left right ->
    evalJExpr right (evalJExpr left val)

  JIdentity -> val

  JComparison op left right ->
    let l = evalJExpr left val
        r = evalJExpr right val
    in Bool (compareValues op l r)

  JNot e ->
    Bool (not (isTruthy (evalJExpr e val)))

compareValues :: CompOp -> Value -> Value -> Bool
compareValues op l r = case op of
  OpEq -> l == r
  OpNe -> l /= r
  OpLt -> numCompare (<) l r
  OpLe -> numCompare (<=) l r
  OpGt -> numCompare (>) l r
  OpGe -> numCompare (>=) l r

numCompare :: (Scientific -> Scientific -> Bool) -> Value -> Value -> Bool
numCompare f (Number a) (Number b) = f a b
numCompare _ _ _ = False

-- | JMESPath truthiness per the JMESPath spec: all numbers are truthy.
-- This differs from OValue.oIsTruthy where zero is falsy (iidy semantics).
-- See also: Handlebars.Engine.isTruthy (same as this, per Handlebars spec).
isTruthy :: Value -> Bool
isTruthy = \case
  Null     -> False
  Bool b   -> b
  String s -> not (T.null s)
  Number _ -> True
  Array a  -> not (V.null a)
  Object o -> not (KM.null o)

