module Iidy.Yaml.Ast
  ( -- * Core AST
    SrcMeta(..)
  , YamlAst(..)
  , astMeta
    -- * CloudFormation tags
  , CloudFormationTag(..)
    -- * Preprocessing tags
  , PreprocessingTag(..)
  , VarLookupTag(..)
  , IfTag(..)
  , MapTag(..)
  , MergeTag(..)
  , ConcatTag(..)
  , LetTag(..)
  , EqTag(..)
  , NotTag(..)
  , SplitTag(..)
  , JoinTag(..)
  , ConcatMapTag(..)
  , MergeMapTag(..)
  , MapListToHashTag(..)
  , MapValuesTag(..)
  , GroupByTag(..)
  , FromPairsTag(..)
  , ToYamlStringTag(..)
  , ParseYamlTag(..)
  , ToJsonStringTag(..)
  , ParseJsonTag(..)
  , EscapeTag(..)
  , ExpandTag(..)
    -- * Other node types
  , UnknownTag(..)
  , ImportedDocumentNode(..)
  , ImportMetadata(..)
  ) where

import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Time (UTCTime)
import Iidy.Yaml.Location (Position)

-- | Source metadata for an AST node (input file + span)
data SrcMeta = SrcMeta
  { smInputUri :: !Text
  , smStart    :: !Position
  , smEnd      :: !Position
  } deriving stock (Show, Eq)

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
  AstNull m               -> m
  AstBool _ m             -> m
  AstNumber _ m           -> m
  AstPlainString _ m      -> m
  AstTemplatedString _ m  -> m
  AstSequence _ m         -> m
  AstMapping _ m          -> m
  AstPreprocessingTag _ m -> m
  AstCloudFormationTag _ m -> m
  AstUnknownTag _ m       -> m
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
  { vlPath     :: !Text
  , vlQuery    :: !(Maybe Text)
  , vlJmesPath :: !(Maybe Text)
  } deriving stock (Show, Eq)

data IfTag = IfTag
  { ifTest      :: !YamlAst
  , ifThenValue :: !YamlAst
  , ifElseValue :: !(Maybe YamlAst)
  } deriving stock (Show, Eq)

data MapTag = MapTag
  { mapItems    :: !YamlAst
  , mapTemplate :: !YamlAst
  , mapVar      :: !(Maybe Text)
  , mapFilter   :: !(Maybe YamlAst)
  } deriving stock (Show, Eq)

newtype MergeTag = MergeTag
  { mergeSources :: [YamlAst]
  } deriving stock (Show, Eq)

newtype ConcatTag = ConcatTag
  { concatSources :: [YamlAst]
  } deriving stock (Show, Eq)

data LetTag = LetTag
  { letBindings   :: ![(Text, YamlAst)]
  , letExpression :: !YamlAst
  } deriving stock (Show, Eq)

data EqTag = EqTag
  { eqLeft  :: !YamlAst
  , eqRight :: !YamlAst
  } deriving stock (Show, Eq)

newtype NotTag = NotTag
  { notExpression :: YamlAst
  } deriving stock (Show, Eq)

data SplitTag = SplitTag
  { splitDelimiter :: !YamlAst
  , splitString    :: !YamlAst
  } deriving stock (Show, Eq)

data JoinTag = JoinTag
  { joinDelimiter :: !YamlAst
  , joinArray     :: !YamlAst
  } deriving stock (Show, Eq)

data ConcatMapTag = ConcatMapTag
  { cmapItems    :: !YamlAst
  , cmapTemplate :: !YamlAst
  , cmapVar      :: !(Maybe Text)
  , cmapFilter   :: !(Maybe YamlAst)
  } deriving stock (Show, Eq)

data MergeMapTag = MergeMapTag
  { mmapItems    :: !YamlAst
  , mmapTemplate :: !YamlAst
  , mmapVar      :: !(Maybe Text)
  } deriving stock (Show, Eq)

data MapListToHashTag = MapListToHashTag
  { mlthItems    :: !YamlAst
  , mlthTemplate :: !YamlAst
  , mlthVar      :: !(Maybe Text)
  , mlthFilter   :: !(Maybe YamlAst)
  } deriving stock (Show, Eq)

data MapValuesTag = MapValuesTag
  { mvItems    :: !YamlAst
  , mvTemplate :: !YamlAst
  , mvVar      :: !(Maybe Text)
  } deriving stock (Show, Eq)

data GroupByTag = GroupByTag
  { gbItems    :: !YamlAst
  , gbKey      :: !YamlAst
  , gbVar      :: !(Maybe Text)
  , gbTemplate :: !(Maybe YamlAst)
  } deriving stock (Show, Eq)

newtype FromPairsTag = FromPairsTag
  { fpSource :: YamlAst
  } deriving stock (Show, Eq)

newtype ToYamlStringTag = ToYamlStringTag { toYamlData :: YamlAst }
  deriving stock (Show, Eq)

newtype ParseYamlTag = ParseYamlTag { parseYamlString :: YamlAst }
  deriving stock (Show, Eq)

newtype ToJsonStringTag = ToJsonStringTag { toJsonData :: YamlAst }
  deriving stock (Show, Eq)

newtype ParseJsonTag = ParseJsonTag { parseJsonString :: YamlAst }
  deriving stock (Show, Eq)

newtype EscapeTag = EscapeTag { escapeContent :: YamlAst }
  deriving stock (Show, Eq)

data ExpandTag = ExpandTag
  { expandTemplate :: !YamlAst
  , expandParams   :: !YamlAst
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Other AST node types
------------------------------------------------------------------------

data UnknownTag = UnknownTag
  { utTag   :: !Text
  , utValue :: !YamlAst
  } deriving stock (Show, Eq)

data ImportedDocumentNode = ImportedDocumentNode
  { idnSourceUri :: !Text
  , idnImportKey :: !Text
  , idnContent   :: !YamlAst
  , idnMetadata  :: !ImportMetadata
  } deriving stock (Show, Eq)

data ImportMetadata = ImportMetadata
  { imContentHash :: !(Maybe Text)
  , imImportedAt  :: !(Maybe UTCTime)
  , imImportType  :: !(Maybe Text)
  } deriving stock (Show, Eq)
