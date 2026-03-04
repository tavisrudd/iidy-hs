module Iidy.Yaml.CustomResources.RefRewriting (
    rewriteRefs,
    collectGlobalRefs,
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Yaml.OValue

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

rewriteRefs :: Text -> Set Text -> OValue -> OValue
rewriteRefs prefix globals = rewrite
  where
    rewrite val = case val of
        OObject kvs -> OObject (rewriteObject prefix globals kvs)
        OArray items -> OArray (map rewrite items)
        _ -> val

collectGlobalRefs :: OValue -> Set Text
collectGlobalRefs val = case val of
    OObject kvs ->
        let resources = maybe [] extractKvs (lookupO "Resources" kvs)
            params = maybe [] extractKvs (lookupO "Parameters" kvs)
         in Set.union (globalFromSection resources) (globalFromSection params)
    _ -> Set.empty
  where
    extractKvs (OObject o) = o
    extractKvs _ = []

    globalFromSection section =
        Set.fromList
            [ k
            | (k, v) <- section
            , isMarkedGlobal v
            ]

    isMarkedGlobal (OObject kvs) = case lookupO "$global" kvs of
        Just (OBool True) -> True
        _ -> False
    isMarkedGlobal _ = False

------------------------------------------------------------------------
-- Internal rewriting
------------------------------------------------------------------------

rewriteObject :: Text -> Set Text -> [(Text, OValue)] -> [(Text, OValue)]
rewriteObject prefix globals kvs
    -- Standard Fn:: format
    | length kvs == 1
    , Just refVal <- lookupO "Ref" kvs =
        [("Ref", rewriteRefValue prefix globals refVal)]
    | length kvs == 1
    , Just attVal <- lookupO "Fn::GetAtt" kvs =
        [("Fn::GetAtt", rewriteGetAtt prefix globals attVal)]
    | length kvs == 1
    , Just subVal <- lookupO "Fn::Sub" kvs =
        [("Fn::Sub", rewriteSub prefix globals subVal)]
    -- Short tag format (used by our resolver)
    | length kvs == 1
    , Just refVal <- lookupO "!Ref" kvs =
        [("!Ref", rewriteRefValue prefix globals refVal)]
    | length kvs == 1
    , Just attVal <- lookupO "!GetAtt" kvs =
        [("!GetAtt", rewriteGetAtt prefix globals attVal)]
    | length kvs == 1
    , Just subVal <- lookupO "!Sub" kvs =
        [("!Sub", rewriteSub prefix globals subVal)]
    | otherwise =
        map (\(k, v) -> (k, rewriteField prefix globals k v)) kvs

rewriteRefValue :: Text -> Set Text -> OValue -> OValue
rewriteRefValue prefix globals = \case
    OString s
        | shouldRewrite globals s -> OString (prefix <> s)
        | otherwise -> OString s
    other -> other

rewriteGetAtt :: Text -> Set Text -> OValue -> OValue
rewriteGetAtt prefix globals = \case
    OString s ->
        case T.breakOn "." s of
            (resource, rest)
                | not (T.null rest) && shouldRewrite globals resource ->
                    OString (prefix <> resource <> rest)
                | otherwise -> OString s
    OArray items
        | (first : rest) <- items ->
            let rewritten = case first of
                    OString s | shouldRewrite globals s -> OString (prefix <> s)
                    _ -> first
             in OArray (rewritten : rest)
        | otherwise -> OArray items
    other -> other

rewriteSub :: Text -> Set Text -> OValue -> OValue
rewriteSub prefix globals = \case
    OString template -> OString (rewriteSubTemplate prefix globals template)
    OArray [OString template, varsObj] ->
        let varNames = case varsObj of
                OObject kvs -> Set.fromList (map fst kvs)
                _ -> Set.empty
            extendedGlobals = Set.union globals varNames
         in OArray
                [ OString (rewriteSubTemplate prefix extendedGlobals template)
                , rewriteRefs prefix globals varsObj
                ]
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
                            | T.null closing -> t -- malformed
                            | T.isPrefixOf "!" ref ->
                                before <> "${" <> ref <> "}" <> go (T.drop 1 closing)
                            | shouldRewrite globals ref ->
                                before <> "${" <> prefix <> ref <> "}" <> go (T.drop 1 closing)
                            | otherwise ->
                                before <> "${" <> ref <> "}" <> go (T.drop 1 closing)

rewriteField :: Text -> Set Text -> Text -> OValue -> OValue
rewriteField prefix globals key val
    | key == "Condition" = case val of
        OString s | shouldRewrite globals s -> OString (prefix <> s)
        _ -> val
    | key == "DependsOn" = rewriteDependsOn prefix globals val
    | otherwise = rewriteRefs prefix globals val

rewriteDependsOn :: Text -> Set Text -> OValue -> OValue
rewriteDependsOn prefix globals = \case
    OString s
        | shouldRewrite globals s -> OString (prefix <> s)
        | otherwise -> OString s
    OArray items -> OArray (map rewriteOne items)
    other -> other
  where
    rewriteOne (OString s)
        | shouldRewrite globals s = OString (prefix <> s)
    rewriteOne v = v

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

shouldRewrite :: Set Text -> Text -> Bool
shouldRewrite globals name
    | T.isPrefixOf "AWS::" name = False
    | Set.member name globals = False
    | otherwise = True
