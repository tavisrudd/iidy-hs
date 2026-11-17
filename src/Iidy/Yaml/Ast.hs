module Iidy.Yaml.Ast (
    -- * Core AST
    SrcMeta (..),
    YamlAst (..),
    astMeta,

    -- * CloudFormation tags
    CloudFormationTag (..),

    -- * Preprocessing tags
    PreprocessingTag (..),
    VarLookupTag (..),
    IfTag (..),
    MapTag (..),
    MergeTag (..),
    ConcatTag (..),
    LetTag (..),
    EqTag (..),
    NotTag (..),
    SplitTag (..),
    JoinTag (..),
    ConcatMapTag (..),
    MergeMapTag (..),
    MapListToHashTag (..),
    MapValuesTag (..),
    GroupByTag (..),
    FromPairsTag (..),
    ToYamlStringTag (..),
    ParseYamlTag (..),
    ToJsonStringTag (..),
    ParseJsonTag (..),
    EscapeTag (..),
    ExpandTag (..),
    preprocessingTagParts,

    -- * Other node types
    UnknownTag (..),
    ImportedDocumentNode (..),
    ImportMetadata (..),
) where

import Data.Bifunctor (first)
import Data.Maybe (maybeToList)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Time (UTCTime)
import Iidy.Yaml.Location (Position)

-- | Source metadata for an AST node (input file + span)
data SrcMeta = SrcMeta
    { smInputUri :: !Text
    , smStart :: !Position
    , smEnd :: !Position
    }
    deriving stock (Show, Eq)

-- | The main YAML AST type
data YamlAst
    = AstNull !SrcMeta
    | AstBool !Bool !SrcMeta
    | AstNumber !Scientific !SrcMeta
    | AstPlainString !Text !SrcMeta
    | AstTemplatedString !Text !SrcMeta
    | AstSequence ![YamlAst] !SrcMeta
    | AstMapping ![(YamlAst, YamlAst)] !SrcMeta
    | AstPreprocessingTag !PreprocessingTag !SrcMeta
    | AstCloudFormationTag !CloudFormationTag !SrcMeta
    | AstUnknownTag !UnknownTag !SrcMeta
    | AstImportedDocument !ImportedDocumentNode !SrcMeta
    deriving stock (Show, Eq)

-- | Extract the source metadata from any AST node
astMeta :: YamlAst -> SrcMeta
astMeta = \case
    AstNull m -> m
    AstBool _ m -> m
    AstNumber _ m -> m
    AstPlainString _ m -> m
    AstTemplatedString _ m -> m
    AstSequence _ m -> m
    AstMapping _ m -> m
    AstPreprocessingTag _ m -> m
    AstCloudFormationTag _ m -> m
    AstUnknownTag _ m -> m
    AstImportedDocument _ m -> m

------------------------------------------------------------------------
-- CloudFormation intrinsic function tags
------------------------------------------------------------------------

data CloudFormationTag
    = CfnRef !YamlAst
    | CfnSub !YamlAst
    | CfnGetAtt !YamlAst
    | CfnJoin !YamlAst
    | CfnSelect !YamlAst
    | CfnSplit !YamlAst
    | CfnBase64 !YamlAst
    | CfnGetAZs !YamlAst
    | CfnImportValue !YamlAst
    | CfnFindInMap !YamlAst
    | CfnCidr !YamlAst
    | CfnLength !YamlAst
    | CfnToJsonString !YamlAst
    | CfnTransform !YamlAst
    | CfnForEach !YamlAst
    | CfnIf !YamlAst
    | CfnEquals !YamlAst
    | CfnAnd !YamlAst
    | CfnOr !YamlAst
    | CfnNot !YamlAst
    deriving stock (Show, Eq)

------------------------------------------------------------------------
-- iidy preprocessing tags
------------------------------------------------------------------------

data PreprocessingTag
    = PpVarLookup !VarLookupTag
    | PpIf !IfTag
    | PpMap !MapTag
    | PpMerge !MergeTag
    | PpConcat !ConcatTag
    | PpLet !LetTag
    | PpEq !EqTag
    | PpNot !NotTag
    | PpSplit !SplitTag
    | PpJoin !JoinTag
    | PpConcatMap !ConcatMapTag
    | PpMergeMap !MergeMapTag
    | PpMapListToHash !MapListToHashTag
    | PpMapValues !MapValuesTag
    | PpGroupBy !GroupByTag
    | PpFromPairs !FromPairsTag
    | PpToYamlString !ToYamlStringTag
    | PpParseYaml !ParseYamlTag
    | PpToJsonString !ToJsonStringTag
    | PpParseJson !ParseJsonTag
    | PpEscape !EscapeTag
    | PpExpand !ExpandTag
    deriving stock (Show, Eq)

data VarLookupTag = VarLookupTag
    { vlPath :: !Text
    , vlQuery :: !(Maybe Text)
    , vlJmesPath :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

data IfTag = IfTag
    { ifTest :: !YamlAst
    , ifThenValue :: !YamlAst
    , ifElseValue :: !(Maybe YamlAst)
    }
    deriving stock (Show, Eq)

data MapTag = MapTag
    { mapItems :: !YamlAst
    , mapTemplate :: !YamlAst
    , mapVar :: !(Maybe Text)
    , mapFilter :: !(Maybe YamlAst)
    }
    deriving stock (Show, Eq)

newtype MergeTag = MergeTag
    { mergeSources :: [YamlAst]
    }
    deriving stock (Show, Eq)

newtype ConcatTag = ConcatTag
    { concatSources :: [YamlAst]
    }
    deriving stock (Show, Eq)

data LetTag = LetTag
    { letBindings :: ![(Text, YamlAst)]
    , letExpression :: !YamlAst
    }
    deriving stock (Show, Eq)

data EqTag = EqTag
    { eqLeft :: !YamlAst
    , eqRight :: !YamlAst
    }
    deriving stock (Show, Eq)

newtype NotTag = NotTag
    { notExpression :: YamlAst
    }
    deriving stock (Show, Eq)

data SplitTag = SplitTag
    { splitDelimiter :: !YamlAst
    , splitString :: !YamlAst
    }
    deriving stock (Show, Eq)

data JoinTag = JoinTag
    { joinDelimiter :: !YamlAst
    , joinArray :: !YamlAst
    }
    deriving stock (Show, Eq)

data ConcatMapTag = ConcatMapTag
    { cmapItems :: !YamlAst
    , cmapTemplate :: !YamlAst
    , cmapVar :: !(Maybe Text)
    , cmapFilter :: !(Maybe YamlAst)
    }
    deriving stock (Show, Eq)

data MergeMapTag = MergeMapTag
    { mmapItems :: !YamlAst
    , mmapTemplate :: !YamlAst
    , mmapVar :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

data MapListToHashTag = MapListToHashTag
    { mlthItems :: !YamlAst
    , mlthTemplate :: !YamlAst
    , mlthVar :: !(Maybe Text)
    , mlthFilter :: !(Maybe YamlAst)
    }
    deriving stock (Show, Eq)

data MapValuesTag = MapValuesTag
    { mvItems :: !YamlAst
    , mvTemplate :: !YamlAst
    , mvVar :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

data GroupByTag = GroupByTag
    { gbItems :: !YamlAst
    , gbKey :: !YamlAst
    , gbVar :: !(Maybe Text)
    , gbTemplate :: !(Maybe YamlAst)
    }
    deriving stock (Show, Eq)

newtype FromPairsTag = FromPairsTag
    { fpSource :: YamlAst
    }
    deriving stock (Show, Eq)

newtype ToYamlStringTag = ToYamlStringTag {toYamlData :: YamlAst}
    deriving stock (Show, Eq)

newtype ParseYamlTag = ParseYamlTag {parseYamlString :: YamlAst}
    deriving stock (Show, Eq)

newtype ToJsonStringTag = ToJsonStringTag {toJsonData :: YamlAst}
    deriving stock (Show, Eq)

newtype ParseJsonTag = ParseJsonTag {parseJsonString :: YamlAst}
    deriving stock (Show, Eq)

newtype EscapeTag = EscapeTag {escapeContent :: YamlAst}
    deriving stock (Show, Eq)

data ExpandTag = ExpandTag
    { expandTemplate :: !YamlAst
    , expandParams :: !YamlAst
    }
    deriving stock (Show, Eq)

{- | The tag name and argument a 'PreprocessingTag' was parsed from, with the
argument rebuilt in the shape the parser accepts (a scalar, a sequence or a
mapping with the tag's field names). The parser normalises some spellings, so
the result is the canonical form: aliases (@!$include@, @!$string@) give the
canonical name, and a one-element sequence argument to a single-argument tag
is given without the sequence. Every node of the result carries the tag's own
'SrcMeta'.
-}
preprocessingTagParts :: SrcMeta -> PreprocessingTag -> (Text, YamlAst)
preprocessingTagParts meta = \case
    PpVarLookup (VarLookupTag path query jmes) -> case jmes of
        Just j -> ("!$", fields [("path", Just (str path)), ("jmespath", Just (str j))])
        Nothing -> ("!$", str (maybe path (\q -> path <> "?" <> q) query))
    PpIf (IfTag test thenV elseV) ->
        ("!$if", fields [("test", Just test), ("then", Just thenV), ("else", elseV)])
    PpMap (MapTag items templ var filt) -> ("!$map", mapLike items templ var filt)
    PpMerge (MergeTag srcs) -> ("!$merge", AstSequence srcs meta)
    PpConcat (ConcatTag srcs) -> ("!$concat", AstSequence srcs meta)
    PpLet (LetTag bindings expr) ->
        ("!$let", AstMapping (map (first str) bindings ++ [(str "in", expr)]) meta)
    PpEq (EqTag a b) -> ("!$eq", AstSequence [a, b] meta)
    PpNot (NotTag e) -> ("!$not", e)
    PpSplit (SplitTag d s) -> ("!$split", AstSequence [d, s] meta)
    PpJoin (JoinTag d a) -> ("!$join", AstSequence [d, a] meta)
    PpConcatMap (ConcatMapTag items templ var filt) -> ("!$concatMap", mapLike items templ var filt)
    PpMergeMap (MergeMapTag items templ var) -> ("!$mergeMap", mapLike items templ var Nothing)
    PpMapListToHash (MapListToHashTag items templ var filt) -> ("!$mapListToHash", mapLike items templ var filt)
    PpMapValues (MapValuesTag items templ var) -> ("!$mapValues", mapLike items templ var Nothing)
    PpGroupBy (GroupByTag items key var templ) ->
        ("!$groupBy", fields [("items", Just items), ("key", Just key), ("var", str <$> var), ("template", templ)])
    PpFromPairs (FromPairsTag e) -> ("!$fromPairs", e)
    PpToYamlString (ToYamlStringTag e) -> ("!$toYamlString", e)
    PpParseYaml (ParseYamlTag e) -> ("!$parseYaml", e)
    PpToJsonString (ToJsonStringTag e) -> ("!$toJsonString", e)
    PpParseJson (ParseJsonTag e) -> ("!$parseJson", e)
    PpEscape (EscapeTag e) -> ("!$escape", e)
    PpExpand (ExpandTag templ params) ->
        ("!$expand", fields [("template", Just templ), ("params", Just params)])
  where
    str t = AstPlainString t meta
    fields kvs = AstMapping [(str k, v) | (k, mv) <- kvs, v <- maybeToList mv] meta
    mapLike items templ var filt =
        fields [("items", Just items), ("template", Just templ), ("var", str <$> var), ("filter", filt)]

------------------------------------------------------------------------
-- Other AST node types
------------------------------------------------------------------------

data UnknownTag = UnknownTag
    { utTag :: !Text
    , utValue :: !YamlAst
    }
    deriving stock (Show, Eq)

data ImportedDocumentNode = ImportedDocumentNode
    { idnSourceUri :: !Text
    , idnImportKey :: !Text
    , idnContent :: !YamlAst
    , idnMetadata :: !ImportMetadata
    }
    deriving stock (Show, Eq)

data ImportMetadata = ImportMetadata
    { imContentHash :: !(Maybe Text)
    , imImportedAt :: !(Maybe UTCTime)
    , imImportType :: !(Maybe Text)
    }
    deriving stock (Show, Eq)
