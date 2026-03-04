{- | Handlebars template engine for iidy template processing.

Specification: Handlebars Language Guide (https://handlebarsjs.com/guide/)
This is a custom implementation covering the subset used by iidy templates:
variable interpolation ({{var}}), helpers with arguments, sub-expressions,
block helpers ({{#if}}/{{#each}}/{{#with}}), and {{else}} clauses.
Does not implement partials, decorators, or inline partials.
-}
module Iidy.Yaml.Handlebars.Engine (
    interpolate,
    isTruthy,
    InterpolateError (..),
    HelperFn,
    defaultHelpers,
) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAlphaNum, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Iidy.Yaml.Handlebars.Helpers (HelperFn, defaultHelpers)

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

newtype InterpolateError = InterpolateError Text
    deriving stock (Show, Eq)

newtype Template = Template [TemplatePart]
    deriving stock (Show)

data TemplatePart
    = Literal !Text
    | Output !Expr
    | Block !Text !Expr [TemplatePart] !(Maybe [TemplatePart])
    | Comment
    deriving stock (Show)

data Expr
    = PathExpr ![Text]
    | LitStr !Text
    | LitNum !Scientific
    | LitBool !Bool
    | HelperExpr !Text ![Expr]
    | SubExpr !Text ![Expr]
    deriving stock (Show)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

interpolate :: Map Text HelperFn -> Value -> Text -> Either InterpolateError Text
interpolate helpers ctx template
    | not (T.isInfixOf "{{" template) = Right template
    | otherwise = do
        parts <- parseTemplate template
        renderParts helpers ctx parts

------------------------------------------------------------------------
-- Template parser
------------------------------------------------------------------------

parseTemplate :: Text -> Either InterpolateError [TemplatePart]
parseTemplate = go []
  where
    go acc rest
        | T.null rest = Right (reverse acc)
        | otherwise = case T.breakOn "{{" rest of
            (before, after)
                | T.null after ->
                    Right (reverse (addLiteral before acc))
                | otherwise -> do
                    let acc' = addLiteral before acc
                    (part, remaining) <- parseMustache (T.drop 2 after)
                    go (part : acc') remaining

    addLiteral t acc
        | T.null t = acc
        | otherwise = Literal t : acc

parseMustache :: Text -> Either InterpolateError (TemplatePart, Text)
parseMustache input
    | T.isPrefixOf "!" input =
        -- Comment: {{! ... }}
        case T.breakOn "}}" input of
            (_, rest)
                | T.null rest -> Left (InterpolateError "Unclosed comment")
                | otherwise -> Right (Comment, T.drop 2 rest)
    | T.isPrefixOf "#" input = do
        -- Block helper: {{#name expr}}...{{/name}}
        let content = T.drop 1 input
        (blockName, expr, rest) <- parseBlockOpen content
        (body, elseBody, remaining) <- parseBlockBody blockName rest
        Right (Block blockName expr body elseBody, remaining)
    | T.isPrefixOf "/" input =
        Left (InterpolateError "Unexpected closing block")
    | otherwise = do
        -- Regular output: {{expr}}
        (expr, rest) <- parseOutputExpr input
        Right (Output expr, rest)

parseBlockOpen :: Text -> Either InterpolateError (Text, Expr, Text)
parseBlockOpen input = do
    let trimmed = T.stripStart input
    let (name, afterName) = T.span isIdentChar trimmed
    when (T.null name) $ Left (InterpolateError "Empty block helper name")
    let afterName' = T.stripStart afterName
    (expr, rest) <-
        if T.isPrefixOf "}}" afterName'
            then Right (LitBool True, T.drop 2 afterName')
            else do
                (e, r) <- parseExpr afterName'
                case T.stripPrefix "}}" (T.stripStart r) of
                    Nothing -> Left (InterpolateError $ "Unclosed block: " <> name)
                    Just remaining -> Right (e, remaining)
    Right (name, expr, rest)

parseBlockBody :: Text -> Text -> Either InterpolateError ([TemplatePart], Maybe [TemplatePart], Text)
parseBlockBody name = goBody []
  where
    closeTag = "{{/" <> name <> "}}"
    elseTag = "{{else}}"

    goBody acc rest
        | T.null rest = Left (InterpolateError $ "Unclosed block: " <> name)
        | T.isPrefixOf closeTag rest =
            Right (reverse acc, Nothing, T.drop (T.length closeTag) rest)
        | T.isPrefixOf elseTag rest = do
            let afterElse = T.drop (T.length elseTag) rest
            (elseParts, remaining) <- goElse [] afterElse
            Right (reverse acc, Just elseParts, remaining)
        | otherwise = case T.breakOn "{{" rest of
            (before, after)
                | T.null after ->
                    Left (InterpolateError $ "Unclosed block: " <> name)
                | otherwise ->
                    if T.isPrefixOf closeTag after || T.isPrefixOf elseTag after
                        then goBody (addLit before acc) after
                        else do
                            let acc' = addLit before acc
                            (part, remaining) <- parseMustache (T.drop 2 after)
                            goBody (part : acc') remaining

    goElse acc rest
        | T.null rest = Left (InterpolateError $ "Unclosed block: " <> name)
        | T.isPrefixOf closeTag rest =
            Right (reverse acc, T.drop (T.length closeTag) rest)
        | otherwise = case T.breakOn "{{" rest of
            (before, after)
                | T.null after ->
                    Left (InterpolateError $ "Unclosed block: " <> name)
                | otherwise ->
                    if T.isPrefixOf closeTag after
                        then goElse (addLit before acc) after
                        else do
                            let acc' = addLit before acc
                            (part, remaining) <- parseMustache (T.drop 2 after)
                            goElse (part : acc') remaining

    addLit t xs
        | T.null t = xs
        | otherwise = Literal t : xs

parseOutputExpr :: Text -> Either InterpolateError (Expr, Text)
parseOutputExpr input = do
    let trimmed = T.stripStart input
    (expr, rest) <- parseExpr trimmed
    let rest' = T.stripStart rest
    case T.stripPrefix "}}" rest' of
        Just remaining -> Right (expr, remaining)
        Nothing -> Left (InterpolateError $ "Unclosed expression, remaining: " <> T.take 20 rest')

parseExpr :: Text -> Either InterpolateError (Expr, Text)
parseExpr input
    | T.null input = Left (InterpolateError "Empty expression")
    | T.isPrefixOf "(" input = do
        -- Sub-expression
        let inner = T.drop 1 input
            trimmed = T.stripStart inner
        let (name, afterName) = T.span isIdentChar trimmed
        when (T.null name) $ Left (InterpolateError "Empty sub-expression")
        (args, rest) <- parseArgs (T.stripStart afterName) ")"
        case T.stripPrefix ")" (T.stripStart rest) of
            Nothing -> Left (InterpolateError "Unclosed sub-expression")
            Just remaining -> Right (SubExpr name args, remaining)
    | Just (quote, after) <- T.uncons input
    , quote == '"' || quote == '\'' = do
        case T.breakOn (T.singleton quote) after of
            (str, rest)
                | T.null rest -> Left (InterpolateError "Unclosed string literal")
                | otherwise -> Right (LitStr str, T.drop 1 rest)
    | startsWithDigit input = do
        let (numStr, rest) = T.span (\c -> isDigit c || c == '.' || c == '-') input
        case reads (T.unpack numStr) :: [(Scientific, String)] of
            [(n, "")] -> Right (LitNum n, rest)
            _badRead -> Left (InterpolateError $ "Invalid number: " <> numStr)
    | T.isPrefixOf "true" input && not (isContinued (T.drop 4 input)) =
        Right (LitBool True, T.drop 4 input)
    | T.isPrefixOf "false" input && not (isContinued (T.drop 5 input)) =
        Right (LitBool False, T.drop 5 input)
    | otherwise = do
        -- Identifier or helper call
        let (ident, afterIdent) = T.span isPathChar input
        when (T.null ident) $ Left (InterpolateError $ "Unexpected character: " <> T.take 1 input)
        let afterIdent' = T.stripStart afterIdent
        -- Check if this is a helper call (next non-space is not }} or ))
        if isArgStart afterIdent'
            then do
                (args, rest) <- parseArgs afterIdent' "}}"
                Right (HelperExpr ident args, rest)
            else Right (toPathExpr ident, afterIdent)
  where
    startsWithDigit t = case T.uncons t of
        Just (c, rest) -> isDigit c || (c == '-' && maybe False (isDigit . fst) (T.uncons rest))
        Nothing -> False
    isContinued t = case T.uncons t of
        Just (c, _) -> isIdentChar c
        Nothing -> False
    isArgStart t = case T.uncons t of
        Nothing -> False
        Just (c, _) ->
            not (T.isPrefixOf "}}" t)
                && not (T.isPrefixOf ")" t)
                && c /= '}'

toPathExpr :: Text -> Expr
toPathExpr t = PathExpr (T.splitOn "." t)

parseArgs :: Text -> Text -> Either InterpolateError ([Expr], Text)
parseArgs input terminator = go [] input
  where
    go acc rest
        | T.null rest = Right (reverse acc, rest)
        | T.isPrefixOf terminator rest = Right (reverse acc, rest)
        | T.isPrefixOf ")" rest = Right (reverse acc, rest)
        | otherwise = do
            let rest' = T.stripStart rest
            if T.null rest' || T.isPrefixOf terminator rest' || T.isPrefixOf ")" rest'
                then Right (reverse acc, rest')
                else do
                    (expr, remaining) <- parseExpr rest'
                    go (expr : acc) (T.stripStart remaining)

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_' || c == '-'

isPathChar :: Char -> Bool
isPathChar c = isIdentChar c || c == '.' || c == '@' || c == '[' || c == ']'

when :: Bool -> Either e () -> Either e ()
when True e = e
when False _action = Right ()

------------------------------------------------------------------------
-- Renderer
------------------------------------------------------------------------

renderParts :: Map Text HelperFn -> Value -> [TemplatePart] -> Either InterpolateError Text
renderParts helpers ctx parts = do
    texts <- traverse (renderPart helpers ctx) parts
    Right (T.concat texts)

renderPart :: Map Text HelperFn -> Value -> TemplatePart -> Either InterpolateError Text
renderPart helpers ctx = \case
    Literal t -> Right t
    Comment -> Right ""
    Output expr -> do
        val <- evalExpr helpers ctx expr
        Right (valueToString val)
    Block name condExpr body elseBody -> do
        renderBlock helpers ctx name condExpr body elseBody

renderBlock :: Map Text HelperFn -> Value -> Text -> Expr -> [TemplatePart] -> Maybe [TemplatePart] -> Either InterpolateError Text
renderBlock helpers ctx name condExpr body elseBody = case name of
    "if" -> do
        val <- evalExpr helpers ctx condExpr
        if isTruthy val
            then renderParts helpers ctx body
            else maybe (Right "") (renderParts helpers ctx) elseBody
    "unless" -> do
        val <- evalExpr helpers ctx condExpr
        if not (isTruthy val)
            then renderParts helpers ctx body
            else maybe (Right "") (renderParts helpers ctx) elseBody
    "each" -> do
        val <- evalExpr helpers ctx condExpr
        case val of
            Array arr -> do
                texts <- V.iforM arr $ \i item -> do
                    let itemCtx =
                            mergeContext ctx $
                                Object $
                                    KM.fromList
                                        [ ("this", item)
                                        , ("@index", Number (fromIntegral i))
                                        , ("@first", Bool (i == 0))
                                        , ("@last", Bool (i == V.length arr - 1))
                                        ]
                    renderParts helpers itemCtx body
                Right (T.concat (V.toList texts))
            Object obj -> do
                let entries = KM.toList obj
                texts <-
                    traverse
                        ( \(k, v) -> do
                            let itemCtx =
                                    mergeContext ctx $
                                        Object $
                                            KM.fromList
                                                [ ("this", v)
                                                , ("@key", String (Key.toText k))
                                                ]
                            renderParts helpers itemCtx body
                        )
                        entries
                Right (T.concat texts)
            _notIterable -> maybe (Right "") (renderParts helpers ctx) elseBody
    "with" -> do
        val <- evalExpr helpers ctx condExpr
        if isTruthy val
            then renderParts helpers (mergeContext ctx val) body
            else maybe (Right "") (renderParts helpers ctx) elseBody
    _unknownHelper -> Left (InterpolateError $ "Unknown block helper: " <> name)

evalExpr :: Map Text HelperFn -> Value -> Expr -> Either InterpolateError Value
evalExpr helpers ctx = \case
    PathExpr segments -> Right (lookupPath segments ctx)
    LitStr s -> Right (String s)
    LitNum n -> Right (Number n)
    LitBool b -> Right (Bool b)
    HelperExpr name args -> do
        argVals <- traverse (evalExpr helpers ctx) args
        callHelper helpers name argVals
    SubExpr name args -> do
        argVals <- traverse (evalExpr helpers ctx) args
        callHelper helpers name argVals

callHelper :: Map Text HelperFn -> Text -> [Value] -> Either InterpolateError Value
callHelper helpers name args =
    case Map.lookup name helpers of
        Just fn -> case fn args of
            Right val -> Right val
            Left err -> Left (InterpolateError $ name <> ": " <> err)
        Nothing ->
            -- Unknown helper: treat first arg as the result if it's just a path with helper syntax
            Left (InterpolateError $ "Unknown helper: " <> name)

lookupPath :: [Text] -> Value -> Value
lookupPath [] val = val
lookupPath ("this" : rest) val = lookupPath rest val
lookupPath (seg : rest) val = case val of
    Object obj -> case KM.lookup (Key.fromText seg) obj of
        Just v -> lookupPath rest v
        Nothing -> Null
    Array arr
        | Just i <- readInt seg
        , i >= 0
        , i < V.length arr ->
            lookupPath rest (arr V.! i)
    _nonTraversable -> Null

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
    [(i, "")] -> Just i
    _notInt -> Nothing

mergeContext :: Value -> Value -> Value
mergeContext (Object base) (Object overlay) = Object (KM.union overlay base)
mergeContext _ v = v

valueToString :: Value -> Text
valueToString = \case
    String s -> s
    Number n -> case Sci.floatingOrInteger n of
        Left (d :: Double) -> T.pack (show d)
        Right (i :: Integer) -> T.pack (show i)
    Bool True -> "true"
    Bool False -> "false"
    Null -> ""
    other -> T.pack (show other)

{- | Handlebars truthiness per the Handlebars spec: all numbers are truthy.
This differs from OValue.oIsTruthy where zero is falsy (iidy semantics).
See also: JMESPath.isTruthy (same as this, per JMESPath spec).
-}
isTruthy :: Value -> Bool
isTruthy = \case
    Null -> False
    Bool b -> b
    String s -> not (T.null s)
    Number _ -> True
    Array a -> not (V.null a)
    Object o -> not (KM.null o)
