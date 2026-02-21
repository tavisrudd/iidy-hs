module Iidy.Yaml.Detection
  ( YamlSpecDetection(..)
  , detectYamlSpec
  , shouldUseYaml11Compatibility
  ) where

import Data.Text (Text)
import qualified Data.Text as T

data YamlSpecDetection
  = ExplicitV11
  | ExplicitV12
  | DetectedCloudFormation
  | DetectedKubernetes
  | UnknownSpec
  deriving stock (Show, Eq, Ord)

shouldUseYaml11Compatibility :: YamlSpecDetection -> Bool
shouldUseYaml11Compatibility = \case
  ExplicitV11            -> True
  ExplicitV12            -> False
  DetectedCloudFormation -> True
  DetectedKubernetes     -> False
  UnknownSpec            -> False

detectYamlSpec :: Text -> YamlSpecDetection
detectYamlSpec input =
  let allLines = T.lines input
      first5 = take 5 allLines
  in case detectDirective first5 of
    Just d  -> d
    Nothing -> detectByContent allLines

detectDirective :: [Text] -> Maybe YamlSpecDetection
detectDirective = foldr check Nothing
  where
    check line acc
      | "%YAML 1.1" `T.isPrefixOf` T.stripStart line = Just ExplicitV11
      | "%YAML 1.2" `T.isPrefixOf` T.stripStart line = Just ExplicitV12
      | otherwise = acc

detectByContent :: [Text] -> YamlSpecDetection
detectByContent allLines
  | isCloudFormation allLines = DetectedCloudFormation
  | isKubernetes allLines     = DetectedKubernetes
  | otherwise                 = UnknownSpec

isCloudFormation :: [Text] -> Bool
isCloudFormation allLines =
  let first50 = take 50 allLines
      cfnKeys =
        [ "AWSTemplateFormatVersion"
        , "Transform:"
        , "Resources:"
        , "Parameters:"
        , "Outputs:"
        , "Conditions:"
        , "Mappings:"
        , "Metadata:"
        ]
      count = length [() | line <- first50, key <- cfnKeys, key `T.isInfixOf` line]
  in count >= 2

isKubernetes :: [Text] -> Bool
isKubernetes allLines =
  let first20 = take 20 allLines
      hasApiVersion = any ("apiVersion:" `T.isInfixOf`) first20
      hasKind = any ("kind:" `T.isInfixOf`) first20
      knownApis = ["apps/v1", "v1", "batch/v1", "networking.k8s.io/v1",
                   "rbac.authorization.k8s.io/v1", "policy/v1"]
      hasKnownApi = any (\line -> any (`T.isInfixOf` line) knownApis) first20
  in hasApiVersion && hasKind && hasKnownApi
