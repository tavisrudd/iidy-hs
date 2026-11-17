module Iidy.Yaml.Parser (
    parseYaml,
    parseYamlStrict,
    parseYamlFile,
    ParseError (..),
) where

import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Functor.Identity (Identity (..))
import Data.List qualified as List
import Data.Maybe (isNothing)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Unsafe (lengthWord8)
import Data.YAML qualified as Y
import Data.YAML.Event (ScalarStyle (..), Tag, tagToText)
import Iidy.Constants (yamlMaxAliasNodes, yamlMaxExpandedBytes)
import Iidy.Yaml.Ast
import Iidy.Yaml.DuplicateKeys (KeyId, firstDuplicate, mappingKeyId, scalarKeyId, sequenceKeyId)
import Iidy.Yaml.Location (Position (..), zeroPosition)
import Iidy.Yaml.Parser.Tags (Parse, ParseError (..), classifyLocalTag)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Parse text that was already checked by 'parseYamlStrict' (a re-parse of an
imported document). A repeated mapping key is accepted and the last value
wins, as in Rust's template parser; also used for a template fetched from AWS.
-}
parseYaml :: BL.ByteString -> Text -> Parse YamlAst
parseYaml = parseYamlWith False

{- | Parse a user document: a template, stack-args file, demo script, imported
document or @!$parseYaml@ string. A repeated mapping key at any depth is an
error, as TypeScript (js-yaml) and Rust's serde_yaml imports report it (@a@ and
@"a"@ are the same key; @1@ and @"1"@ are not).
-}
parseYamlStrict :: BL.ByteString -> Text -> Parse YamlAst
parseYamlStrict = parseYamlWith True

parseYamlWith :: Bool -> BL.ByteString -> Text -> Parse YamlAst
parseYamlWith rejectDuplicates input uri =
    let
        -- Ensure trailing newline for HsYAML compatibility
        input' =
            if BL.null input || BL.last input /= 0x0a
                then input <> "\n"
                else input
     in
        case runIdentity (Y.decodeLoader (yamlLoader rejectDuplicates uri) input') of
            Left (pos, msg) -> Left (ParseError (convertPos pos) (T.pack msg))
            Right [] -> Right (AstNull (emptyMeta uri))
            Right (node : _) -> Right (nodeAst node)

parseYamlFile :: FilePath -> IO (Parse YamlAst)
parseYamlFile path = do
    input <- BL.readFile path
    pure (parseYaml input (T.pack path))

------------------------------------------------------------------------
-- Loader (preserves document key order)
------------------------------------------------------------------------

{- | A loaded node and, for a mapping key, its identity (lazy: lenient
parsing never forces it).
-}
data Node = Node
    { nodeAst :: YamlAst
    , nodeKey :: Maybe KeyId
    , nodeCount :: !Int
    {- ^ nodes in this subtree with every alias expanded (shared subtrees
    are measured once and reused, so this is cheap to compute)
    -}
    , nodeBytes :: !Int
    -- ^ UTF-8 bytes of scalar text in this subtree with every alias expanded
    }

yamlLoader :: Bool -> Text -> Y.Loader Identity Node
yamlLoader rejectDuplicates uri =
    Y.Loader
        { Y.yScalar = \tag style text pos ->
            let bytes = lengthWord8 text
             in pure $
                    checkExpansion uri pos 1 bytes
                        *> ( (\ast -> Node ast (Just (scalarKeyId (isResolved tag style) text)) 1 bytes)
                                <$> resolveScalar uri pos tag style text
                           )
        , Y.ySequence = \tag nodes pos ->
            pure $
                let items = map nodeAst nodes
                    startP = convertPos pos
                    endP = childrenEndPos startP (map astMeta items)
                    meta = SrcMeta uri startP endP
                    (count, bytes) = totals nodes
                 in checkExpansion uri pos count bytes
                        *> ((\n -> Node n (sequenceKeyId (map nodeKey nodes)) count bytes) <$> applyTag meta tag (AstSequence items meta))
        , Y.yMapping = \tag nodes pos ->
            pure $
                let kvs = [(nodeAst k, nodeAst v) | (k, v) <- nodes]
                    startP = convertPos pos
                    endP = childrenEndPos startP (map (astMeta . snd) kvs)
                    meta = SrcMeta uri startP endP
                    (count, bytes) = totals (concat [[k, v] | (k, v) <- nodes])
                 in checkExpansion uri pos count bytes
                        *> case firstDuplicate [(nodeAst k, nodeKey k) | (k, _) <- nodes] of
                            Just (dup, msg)
                                | rejectDuplicates -> Left (unconvertPos (smStart (astMeta dup)), msg)
                            _noDuplicate -> (\n -> Node n (mappingKeyId [(nodeKey k, nodeKey v) | (k, v) <- nodes]) count bytes) <$> applyTag meta tag (AstMapping kvs meta)
        , Y.yAlias = \_ _ node _ -> pure $ Right node
        , Y.yAnchor = \_ node _ -> pure $ Right node
        }
  where
    -- An untagged plain scalar resolves to a number, boolean or null.
    isResolved tag style = style == Plain && isNothing (tagToText tag)

-- | The node count (this node included) and scalar bytes of children.
totals :: [Node] -> (Int, Int)
totals nodes = (1 + sum (map nodeCount nodes), sum (map nodeBytes nodes))

{- | Reject a document whose alias-expanded size passes 'yamlMaxAliasNodes'
or 'yamlMaxExpandedBytes'. Every child has already passed this check, so the
sums stay far below overflow, and an alias bomb is refused at the first
level that crosses a limit, before anything is expanded.
-}
checkExpansion :: Text -> Y.Pos -> Int -> Int -> Either (Y.Pos, String) ()
checkExpansion uri pos count bytes
    | count > yamlMaxAliasNodes =
        Left (pos, "YAML alias expansion exceeds " <> show yamlMaxAliasNodes <> " nodes in " <> T.unpack uri)
    | bytes > yamlMaxExpandedBytes =
        Left (pos, "YAML alias expansion exceeds " <> show yamlMaxExpandedBytes <> " bytes of text in " <> T.unpack uri)
    | otherwise = Right ()

------------------------------------------------------------------------
-- Scalar resolution (Core schema)
------------------------------------------------------------------------

resolveScalar :: Text -> Y.Pos -> Tag -> ScalarStyle -> Text -> Either (Y.Pos, String) YamlAst
resolveScalar uri pos tag style text =
    let meta = makeScalarMeta uri pos tag text
     in case tagToText tag of
            Just t
                | "!" `T.isPrefixOf` t ->
                    -- Local tag on scalar: resolve the scalar type first, then apply tag
                    let baseNode = case style of
                            Plain -> resolvePlainScalar meta text
                            _quotedStyle -> classifyString meta text
                     in mapLeft (\(ParseError p m) -> (unconvertPos p, T.unpack m)) $
                            classifyLocalTag meta t baseNode
            _untagged ->
                -- Untagged or global-tagged: resolve type
                Right $ case style of
                    Plain -> resolvePlainScalar meta text
                    _quotedStyle -> classifyString meta text

resolvePlainScalar :: SrcMeta -> Text -> YamlAst
resolvePlainScalar meta text
    | isNullLiteral text = AstNull meta
    | text == "true" || text == "True" || text == "TRUE" = AstBool True meta
    | text == "false" || text == "False" || text == "FALSE" = AstBool False meta
    | Just n <- parseInteger text = AstNumber (fromInteger n) meta
    | Just n <- parseFloat text = AstNumber n meta
    | otherwise = classifyString meta text

isNullLiteral :: Text -> Bool
isNullLiteral t = t == "null" || t == "Null" || t == "NULL" || t == "~" || T.null t

parseInteger :: Text -> Maybe Integer
parseInteger t
    | T.null t = Nothing
    | T.isPrefixOf "0x" t || T.isPrefixOf "0X" t =
        readMaybe (T.unpack t)
    | T.isPrefixOf "0o" t || T.isPrefixOf "0O" t =
        readMaybe (T.unpack t)
    | T.isPrefixOf "-" t || T.isPrefixOf "+" t =
        let rest = T.drop 1 t
         in if not (T.null rest) && T.all isDigit rest
                then readMaybe (T.unpack t)
                else Nothing
    | T.all isDigit t = readMaybe (T.unpack t)
    | otherwise = Nothing

parseFloat :: Text -> Maybe Scientific
parseFloat t
    | t == ".inf" || t == ".Inf" || t == ".INF" = Just (Sci.fromFloatDigits (1 / 0 :: Double))
    | t == "-.inf" || t == "-.Inf" || t == "-.INF" = Just (Sci.fromFloatDigits ((-1) / 0 :: Double))
    | t == ".nan" || t == ".NaN" || t == ".NAN" = Just (Sci.fromFloatDigits (0 / 0 :: Double))
    | hasFloatChars t = case reads (T.unpack t) :: [(Double, String)] of
        [(d, "")] -> Just (Sci.fromFloatDigits d)
        _badRead -> Nothing
    | otherwise = Nothing
  where
    hasFloatChars s = T.any (== '.') s || T.any (== 'e') s || T.any (== 'E') s

readMaybe :: (Read a) => String -> Maybe a
readMaybe s = case reads s of
    [(a, "")] -> Just a
    _badRead -> Nothing

------------------------------------------------------------------------
-- Tag handling
------------------------------------------------------------------------

applyTag :: SrcMeta -> Tag -> YamlAst -> Either (Y.Pos, String) YamlAst
applyTag meta tag node = case tagToText tag of
    Just t
        | "!" `T.isPrefixOf` t ->
            mapLeft (\(ParseError p m) -> (unconvertPos p, T.unpack m)) $
                classifyLocalTag meta t node
    _untagged -> Right node

classifyString :: SrcMeta -> Text -> YamlAst
classifyString meta text
    | "{{" `T.isInfixOf` text = AstTemplatedString text meta
    | otherwise = AstPlainString text meta

------------------------------------------------------------------------
-- Position helpers
------------------------------------------------------------------------

convertPos :: Y.Pos -> Position
convertPos p =
    Position
        { posLine = Y.posLine p
        , posColumn = Y.posColumn p
        , posOffset = Y.posByteOffset p
        }

unconvertPos :: Position -> Y.Pos
unconvertPos p =
    Y.Pos
        { Y.posLine = posLine p
        , Y.posColumn = posColumn p
        , Y.posByteOffset = posOffset p
        , Y.posCharOffset = posOffset p
        }

emptyMeta :: Text -> SrcMeta
emptyMeta uri = SrcMeta uri zeroPosition zeroPosition

{- | Create SrcMeta for a scalar value with end position computed from text length.
The end position accounts for the tag prefix (e.g., "!Ref ") if present.
-}
makeScalarMeta :: Text -> Y.Pos -> Tag -> Text -> SrcMeta
makeScalarMeta uri pos tag text =
    let startP = convertPos pos
        tagLen = case tagToText tag of
            Just t | "!" `T.isPrefixOf` t -> T.length t + 1 -- tag + space
            _untagged -> 0
        textLen = T.length text
        endP =
            startP
                { posColumn = posColumn startP + tagLen + textLen
                , posOffset = posOffset startP + tagLen + textLen
                }
     in SrcMeta uri startP endP

{- | Compute end position from a list of child node metadata.
Uses the end position of the last child, or falls back to the start position.
-}
childrenEndPos :: Position -> [SrcMeta] -> Position
childrenEndPos startP metas = List.foldl' (\_acc x -> smEnd x) startP metas

------------------------------------------------------------------------
-- Error mapping
------------------------------------------------------------------------

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f (Left a) = Left (f a)
mapLeft _ (Right c) = Right c
