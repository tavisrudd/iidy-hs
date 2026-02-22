-- | Template hashing and S3 URL utilities for template approval workflows.
{-# LANGUAGE OverloadedStrings #-}
module Iidy.Cfn.TemplateHash
  ( calculateTemplateHash
  , generateVersionedLocation
  , parseS3Url
  ) where

import Crypto.Hash (SHA256(..), hashWith)
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath (takeExtension)

------------------------------------------------------------------------
-- Hashing
------------------------------------------------------------------------

-- | Compute a SHA256 hash of the template content, returned as hex string.
calculateTemplateHash :: Text -> Text
calculateTemplateHash content =
  let digest = hashWith SHA256 (TE.encodeUtf8 content)
      bytes = BA.convert digest :: BS.ByteString
  in T.pack (concatMap toHex (BS.unpack bytes))
  where
    toHex b = [hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    hexDigit n
      | n < 10    = toEnum (fromEnum '0' + fromIntegral n)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)

------------------------------------------------------------------------
-- S3 URL utilities
------------------------------------------------------------------------

-- | Parse an S3 URL into (bucket, key).
-- Expected format: s3://bucket/key
parseS3Url :: Text -> Either Text (Text, Text)
parseS3Url url
  | not (T.isPrefixOf "s3://" url) =
      Left ("Invalid S3 URL (must start with s3://): " <> url)
  | otherwise =
      let rest = T.drop 5 url  -- remove "s3://"
      in case T.breakOn "/" rest of
        (bucket, keyWithSlash)
          | T.null bucket -> Left ("Invalid S3 URL (no bucket): " <> url)
          | T.null keyWithSlash -> Left ("Invalid S3 URL (no key): " <> url)
          | otherwise -> Right (bucket, T.drop 1 keyWithSlash)

-- | Generate a versioned S3 location for a template.
-- Returns (bucket, versioned_key) where key = basePath/hash.extension
generateVersionedLocation
  :: Text  -- ^ base S3 location (e.g., s3://bucket/templates/)
  -> Text  -- ^ template content (for hashing)
  -> Text  -- ^ template file path (for extension)
  -> Either Text (Text, Text)
generateVersionedLocation baseLocation content templatePath = do
  (bucket, baseKey) <- parseS3Url baseLocation
  let hash = calculateTemplateHash content
      ext = T.pack (takeExtension (T.unpack templatePath))
      -- Ensure trailing slash is handled
      basePath = if T.isSuffixOf "/" baseKey
                 then T.dropEnd 1 baseKey
                 else baseKey
      versionedKey = basePath <> "/" <> hash <> ext
  Right (bucket, versionedKey)
