module Iidy.Yaml.Imports.Loaders.File
  ( loadFileImport
  , loadFilehashImport
  , dispatchLocalImport
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash (SHA256(..), hashWith)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, takeDirectory, (</>))
import Iidy.Yaml.Imports.Types (ImportData(..), ImportType(..), ImportError(..))
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Resolver (astToValueRaw)

------------------------------------------------------------------------
-- Import dispatcher
------------------------------------------------------------------------

-- | Dispatch a local import based on its type prefix.
-- Routes filehash:/filehash-base64: to the filehash loader,
-- everything else to the file loader.
dispatchLocalImport :: Text -> Text -> IO (Either ImportError ImportData)
dispatchLocalImport location baseLocation
  | "filehash-base64:" `T.isPrefixOf` location =
      loadFilehashImport location baseLocation True
  | "filehash:" `T.isPrefixOf` location =
      loadFilehashImport location baseLocation False
  | otherwise =
      loadFileImport location baseLocation

------------------------------------------------------------------------
-- File import
------------------------------------------------------------------------

loadFileImport :: Text -> Text -> IO (Either ImportError ImportData)
loadFileImport location baseLocation = do
  let rawPath = stripFilePrefix location
      basePath = T.unpack (stripFilePrefix baseLocation)
      baseDir = takeDirectory basePath
      fullPath = if isAbsolutePath rawPath
                 then T.unpack rawPath
                 else baseDir </> T.unpack rawPath
  result <- try @IOException (BS.readFile fullPath)
  case result of
    Left err -> pure $ Left $ ImportError $ "Failed to read file: " <> T.pack (show err)
    Right bs -> case TE.decodeUtf8' bs of
      Left err -> pure $ Left $ ImportError $ "Invalid UTF-8 in file: " <> T.pack (show err)
      Right content -> do
        let ext = takeExtension fullPath
            doc = parseByExtension ext content
        pure $ Right $ ImportData
          { idType     = ImportFile
          , idLocation = T.pack fullPath
          , idRawData  = content
          , idDoc      = doc
          }

------------------------------------------------------------------------
-- Filehash import
------------------------------------------------------------------------

-- | Load a filehash import (SHA256 of file/directory content).
-- Matches Rust: raw byte hashing, directory recursive walk, ?allow-missing.
loadFilehashImport :: Text -> Text -> Bool -> IO (Either ImportError ImportData)
loadFilehashImport location baseLocation base64 = do
  case parseFilehashLocation location of
    Left err -> pure $ Left err
    Right (filePath, allowMissing) -> do
      let basePath = T.unpack (stripFilePrefix baseLocation)
          baseDir = takeDirectory basePath
          resolvedPath = if isAbsolutePathStr filePath
                         then filePath
                         else baseDir </> filePath
      fileExists <- doesFileExist resolvedPath
      dirExists <- doesDirectoryExist resolvedPath
      if not fileExists && not dirExists
        then if allowMissing
          then pure $ Right $ mkFilehashData resolvedPath "FILE_MISSING" base64
          else pure $ Left $ ImportError $
            "Invalid location " <> T.pack resolvedPath
            <> " for filehash in " <> baseLocation
        else do
          hashResult <- try @IOException (computePathHash resolvedPath)
          case hashResult of
            Left err -> pure $ Left $ ImportError $
              "Failed to hash " <> T.pack resolvedPath <> ": " <> T.pack (show err)
            Right hexHash -> do
              let hashData = if base64
                    then b64EncodeBytes (hexToBytes hexHash)
                    else hexHash
              pure $ Right $ mkFilehashData resolvedPath hashData base64

-- | Parse filehash location: "filehash:path" or "filehash:?path" (allow missing)
parseFilehashLocation :: Text -> Either ImportError (FilePath, Bool)
parseFilehashLocation location =
  case T.breakOn ":" location of
    (_, rest)
      | T.null rest -> Left $ ImportError $
          "Invalid filehash import format: " <> location
      | otherwise ->
          let afterColon = T.drop 1 rest  -- drop the ':'
              (allowMissing, path) = if T.isPrefixOf "?" afterColon
                then (True, T.strip (T.drop 1 afterColon))
                else (False, afterColon)
          in Right (T.unpack path, allowMissing)

mkFilehashData :: FilePath -> Text -> Bool -> ImportData
mkFilehashData resolvedPath hashData base64 = ImportData
  { idType     = if base64 then ImportFilehashBase64 else ImportFilehash
  , idLocation = T.pack resolvedPath
  , idRawData  = hashData
  , idDoc      = String hashData
  }

------------------------------------------------------------------------
-- SHA256 hashing
------------------------------------------------------------------------

-- | SHA256 hash of raw bytes, returned as lowercase hex string.
sha256Bytes :: BS.ByteString -> Text
sha256Bytes bs =
  let digest = hashWith SHA256 bs
      bytes = BA.convert digest :: BS.ByteString
  in T.pack (concatMap toHexLower (BS.unpack bytes))
  where
    toHexLower b = [hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    hexDigit n
      | n < 10    = toEnum (fromEnum '0' + fromIntegral n)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)

-- | Compute SHA256 hash for a file or directory.
-- Files: hash raw bytes directly.
-- Directories: recursively find all files (sorted), hash each,
-- join hex hashes with commas, then hash that string.
computePathHash :: FilePath -> IO Text
computePathHash path = do
  isDir <- doesDirectoryExist path
  if isDir
    then do
      files <- listFilesRecursive path
      let sortedFiles = sort files
      hashes <- mapM (\f -> sha256Bytes <$> BS.readFile f) sortedFiles
      let combined = T.intercalate "," hashes
      pure $ sha256Bytes (TE.encodeUtf8 combined)
    else sha256Bytes <$> BS.readFile path

-- | Recursively list all files under a directory (not directories themselves).
listFilesRecursive :: FilePath -> IO [FilePath]
listFilesRecursive dir = do
  entries <- listDirectory dir
  let fullPaths = map (dir </>) entries
  concat <$> mapM classify fullPaths
  where
    classify fp = do
      isDir <- doesDirectoryExist fp
      if isDir
        then listFilesRecursive fp
        else pure [fp]

------------------------------------------------------------------------
-- Encoding helpers
------------------------------------------------------------------------

-- | Decode a hex string to raw bytes.
hexToBytes :: Text -> BS.ByteString
hexToBytes hex = BS.pack (go (T.unpack hex))
  where
    go [] = []
    go [_] = []  -- odd length, ignore trailing nibble
    go (h:l:rest) = fromIntegral (hexVal h * 16 + hexVal l) : go rest
    hexVal :: Char -> Int
    hexVal c
      | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
      | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
      | c >= 'A' && c <= 'F' = fromEnum c - fromEnum 'A' + 10
      | otherwise = 0

-- | Base64-encode raw bytes (RFC 4648).
b64EncodeBytes :: BS.ByteString -> Text
b64EncodeBytes bs = TE.decodeUtf8 (b64Encode (BS.unpack bs))
  where
    alphabet :: BS.ByteString
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    enc :: Word8 -> Word8
    enc i = BS.index alphabet (fromIntegral i)

    b64Encode :: [Word8] -> BS.ByteString
    b64Encode = BS.pack . go

    go :: [Word8] -> [Word8]
    go [] = []
    go [a] =
      [ enc (a `shiftR` 2)
      , enc ((a .&. 3) `shiftL` 4)
      , 61, 61  -- ==
      ]
    go [a, b] =
      [ enc (a `shiftR` 2)
      , enc (((a .&. 3) `shiftL` 4) .|. (b `shiftR` 4))
      , enc ((b .&. 15) `shiftL` 2)
      , 61  -- =
      ]
    go (a:b:c:rest) =
      enc (a `shiftR` 2)
      : enc (((a .&. 3) `shiftL` 4) .|. (b `shiftR` 4))
      : enc (((b .&. 15) `shiftL` 2) .|. (c `shiftR` 6))
      : enc (c .&. 63)
      : go rest

------------------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------------------

stripFilePrefix :: Text -> Text
stripFilePrefix loc = maybe loc id (T.stripPrefix "file:" loc)

isAbsolutePath :: Text -> Bool
isAbsolutePath t = T.isPrefixOf "/" t

isAbsolutePathStr :: FilePath -> Bool
isAbsolutePathStr ('/':_) = True
isAbsolutePathStr _ = False

parseByExtension :: String -> Text -> Value
parseByExtension ext content
  | ext `elem` [".yaml", ".yml"] = parseYamlToValue content
  | ext == ".json" = parseJson content
  | otherwise = String content

parseYamlToValue :: Text -> Value
parseYamlToValue content =
  case parseYaml (BL.fromStrict (TE.encodeUtf8 content)) "<import>" of
    Right ast -> astToValueRaw ast
    Left _ -> String content

parseJson :: Text -> Value
parseJson content =
  case Aeson.eitherDecodeStrict' (TE.encodeUtf8 content) of
    Right val -> val
    Left _ -> String content
