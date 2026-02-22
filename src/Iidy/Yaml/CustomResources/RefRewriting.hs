module Iidy.Yaml.CustomResources.RefRewriting
  ( rewriteRefs
  , collectGlobalRefs
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

rewriteRefs :: Text -> Set Text -> Value -> Value
rewriteRefs prefix globals = rewrite
  where
    rewrite val = case val of
      Object obj -> Object (rewriteObject prefix globals obj)
      Array arr  -> Array (V.map rewrite arr)
      _          -> val

collectGlobalRefs :: Value -> Set Text
collectGlobalRefs val = case val of
  Object obj ->
    let resources = maybe KM.empty extractMapping (KM.lookup "Resources" obj)
        params = maybe KM.empty extractMapping (KM.lookup "Parameters" obj)
    in Set.union (globalFromSection resources) (globalFromSection params)
  _ -> Set.empty
  where
    extractMapping (Object o) = o
    extractMapping _ = KM.empty

    globalFromSection section =
      Set.fromList
        [ Key.toText k
        | (k, v) <- KM.toList section
        , isMarkedGlobal v
        ]

    isMarkedGlobal (Object obj) = case KM.lookup "$global" obj of
      Just (Bool True) -> True
      _ -> False
    isMarkedGlobal _ = False

------------------------------------------------------------------------
-- Internal rewriting
------------------------------------------------------------------------

rewriteObject :: Text -> Set Text -> KM.KeyMap Value -> KM.KeyMap Value
rewriteObject prefix globals obj
  -- Standard Fn:: format
  | Just refVal <- KM.lookup "Ref" obj, KM.size obj == 1 =
      KM.singleton "Ref" (rewriteRefValue prefix globals refVal)
  | Just attVal <- KM.lookup "Fn::GetAtt" obj, KM.size obj == 1 =
      KM.singleton "Fn::GetAtt" (rewriteGetAtt prefix globals attVal)
  | Just subVal <- KM.lookup "Fn::Sub" obj, KM.size obj == 1 =
      KM.singleton "Fn::Sub" (rewriteSub prefix globals subVal)
  -- Short tag format (used by our resolver)
  | Just refVal <- KM.lookup "!Ref" obj, KM.size obj == 1 =
      KM.singleton "!Ref" (rewriteRefValue prefix globals refVal)
  | Just attVal <- KM.lookup "!GetAtt" obj, KM.size obj == 1 =
      KM.singleton "!GetAtt" (rewriteGetAtt prefix globals attVal)
  | Just subVal <- KM.lookup "!Sub" obj, KM.size obj == 1 =
      KM.singleton "!Sub" (rewriteSub prefix globals subVal)
  | otherwise =
      KM.mapWithKey (\k v -> rewriteField prefix globals k v) obj

rewriteRefValue :: Text -> Set Text -> Value -> Value
rewriteRefValue prefix globals = \case
  String s
    | shouldRewrite globals s -> String (prefix <> s)
    | otherwise -> String s
  other -> other

rewriteGetAtt :: Text -> Set Text -> Value -> Value
rewriteGetAtt prefix globals = \case
  String s ->
    case T.breakOn "." s of
      (resource, rest)
        | not (T.null rest) && shouldRewrite globals resource ->
            String (prefix <> resource <> rest)
        | otherwise -> String s
  Array arr
    | V.length arr >= 1 ->
        let first = arr V.! 0
            rewritten = case first of
              String s | shouldRewrite globals s -> String (prefix <> s)
              _ -> first
        in Array (arr V.// [(0, rewritten)])
    | otherwise -> Array arr
  other -> other

rewriteSub :: Text -> Set Text -> Value -> Value
rewriteSub prefix globals = \case
  String template -> String (rewriteSubTemplate prefix globals template)
  Array arr
    | V.length arr == 2 ->
        let template = case arr V.! 0 of
              String t -> t
              _ -> ""
            varsObj = arr V.! 1
            varNames = case varsObj of
              Object obj -> Set.fromList (map Key.toText (KM.keys obj))
              _ -> Set.empty
            extendedGlobals = Set.union globals varNames
        in Array (V.fromList
            [ String (rewriteSubTemplate prefix extendedGlobals template)
            , rewriteRefs prefix globals varsObj
            ])
    | otherwise -> Array arr
  other -> other

rewriteSubTemplate :: Text -> Set Text -> Text -> Text
rewriteSubTemplate prefix globals = go
  where
    go t = case T.breakOn "${" t of
      (before, rest)
        | T.null rest -> t
        | otherwise ->
            let after = T.drop 2 rest
            in case T.breakOn "}" after of
              (ref, closing)
                | T.null closing -> t  -- malformed
                | T.isPrefixOf "!" ref ->
                    before <> "${" <> ref <> "}" <> go (T.drop 1 closing)
                | shouldRewrite globals ref ->
                    before <> "${" <> prefix <> ref <> "}" <> go (T.drop 1 closing)
                | otherwise ->
                    before <> "${" <> ref <> "}" <> go (T.drop 1 closing)

rewriteField :: Text -> Set Text -> Key.Key -> Value -> Value
rewriteField prefix globals key val
  | key == "Condition" = case val of
      String s | shouldRewrite globals s -> String (prefix <> s)
      _ -> val
  | key == "DependsOn" = rewriteDependsOn prefix globals val
  | otherwise = rewriteRefs prefix globals val

rewriteDependsOn :: Text -> Set Text -> Value -> Value
rewriteDependsOn prefix globals = \case
  String s
    | shouldRewrite globals s -> String (prefix <> s)
    | otherwise -> String s
  Array arr -> Array (V.map rewriteOne arr)
  other -> other
  where
    rewriteOne (String s)
      | shouldRewrite globals s = String (prefix <> s)
    rewriteOne v = v

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

shouldRewrite :: Set Text -> Text -> Bool
shouldRewrite globals name
  | T.isPrefixOf "AWS::" name = False
  | Set.member name globals   = False
  | otherwise                 = True
