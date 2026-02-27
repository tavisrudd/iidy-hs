module Test.FilehashTest (filehashTests) where

import Data.Aeson (Value(..))
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import Iidy.Yaml.Imports.Loaders.File (loadFilehashImport, dispatchLocalImport)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportType(..), ImportError(..))

filehashTests :: [TestTree]
filehashTests =
  [ testGroup "loadFilehashImport"
    [ testFileHash
    , testFileHashBase64
    , testMissingAllowed
    , testMissingNotAllowed
    , testInvalidFormat
    , testDirectoryHash
    , testDirectoryDeterministic
    , testKnownHash
    ]
  , testGroup "dispatchLocalImport"
    [ testDispatchFilehash
    , testDispatchFilehashBase64
    , testDispatchFile
    ]
  ]

testFileHash :: TestTree
testFileHash = testCase "file hash returns 64-char hex" $
  withSystemTempDirectory "filehash" $ \dir -> do
    let fp = dir </> "test.txt"
    BS.writeFile fp "hello world"
    let location = "filehash:" <> T.pack fp
    result <- loadFilehashImport location "." False
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat -> do
        idType dat @?= ImportFilehash
        T.length (idRawData dat) @?= 64
        assertBool "all hex chars" (T.all isHexDigit (idRawData dat))
        -- doc should be a String with the hash
        idDoc dat @?= String (idRawData dat)

testFileHashBase64 :: TestTree
testFileHashBase64 = testCase "base64 variant returns different encoding" $
  withSystemTempDirectory "filehash-b64" $ \dir -> do
    let fp = dir </> "test.txt"
    BS.writeFile fp "hello world"
    let location = "filehash-base64:" <> T.pack fp
    result <- loadFilehashImport location "." True
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat -> do
        idType dat @?= ImportFilehashBase64
        -- base64 of 32 bytes = 44 chars (with padding)
        T.length (idRawData dat) @?= 44
        -- should NOT be the same as hex
        assertBool "not hex" (T.length (idRawData dat) /= 64)

testMissingAllowed :: TestTree
testMissingAllowed = testCase "? prefix allows missing files" $ do
  let location = "filehash:?/nonexistent/file.txt"
  result <- loadFilehashImport location "." False
  case result of
    Left (ImportError e) -> fail (T.unpack e)
    Right dat -> do
      idType dat @?= ImportFilehash
      idRawData dat @?= "FILE_MISSING"
      idDoc dat @?= String "FILE_MISSING"

testMissingNotAllowed :: TestTree
testMissingNotAllowed = testCase "missing file without ? returns error" $ do
  let location = "filehash:/nonexistent/file.txt"
  result <- loadFilehashImport location "." False
  case result of
    Left (ImportError e) ->
      assertBool "mentions location" ("Invalid location" `T.isInfixOf` e)
    Right _ -> fail "Expected error for missing file"

testInvalidFormat :: TestTree
testInvalidFormat = testCase "invalid format returns error" $ do
  let location = "filehash"  -- no colon
  result <- loadFilehashImport location "." False
  case result of
    Left (ImportError e) ->
      assertBool "mentions format" ("Invalid filehash" `T.isInfixOf` e)
    Right _ -> fail "Expected error for invalid format"

testDirectoryHash :: TestTree
testDirectoryHash = testCase "directory hash returns 64-char hex" $
  withSystemTempDirectory "filehash-dir" $ \dir -> do
    let subdir = dir </> "sub"
    createDirectory subdir
    BS.writeFile (subdir </> "a.txt") "content_a"
    BS.writeFile (subdir </> "b.txt") "content_b"
    let location = "filehash:" <> T.pack subdir
    result <- loadFilehashImport location "." False
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat -> do
        idType dat @?= ImportFilehash
        T.length (idRawData dat) @?= 64
        assertBool "all hex chars" (T.all isHexDigit (idRawData dat))

testDirectoryDeterministic :: TestTree
testDirectoryDeterministic = testCase "directory hash is deterministic" $
  withSystemTempDirectory "filehash-det" $ \dir -> do
    let subdir = dir </> "sub"
    createDirectory subdir
    BS.writeFile (subdir </> "a.txt") "content_a"
    BS.writeFile (subdir </> "b.txt") "content_b"
    let location = "filehash:" <> T.pack subdir
    result1 <- loadFilehashImport location "." False
    result2 <- loadFilehashImport location "." False
    case (result1, result2) of
      (Right d1, Right d2) -> idRawData d1 @?= idRawData d2
      _ -> fail "Expected both to succeed"

-- Cross-check: SHA256("hello world") is a well-known value
testKnownHash :: TestTree
testKnownHash = testCase "hash matches known SHA256 value" $
  withSystemTempDirectory "filehash-known" $ \dir -> do
    let fp = dir </> "test.txt"
    -- Write raw bytes, no trailing newline
    BS.writeFile fp (TE.encodeUtf8 "hello world")
    let location = "filehash:" <> T.pack fp
    result <- loadFilehashImport location "." False
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat ->
        -- SHA256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
        idRawData dat @?= "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

testDispatchFilehash :: TestTree
testDispatchFilehash = testCase "dispatches filehash: to filehash loader" $
  withSystemTempDirectory "dispatch-fh" $ \dir -> do
    let fp = dir </> "test.txt"
    BS.writeFile fp "dispatch test"
    let location = "filehash:" <> T.pack fp
    result <- dispatchLocalImport location "."
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat -> do
        idType dat @?= ImportFilehash
        T.length (idRawData dat) @?= 64

testDispatchFilehashBase64 :: TestTree
testDispatchFilehashBase64 = testCase "dispatches filehash-base64: to filehash loader" $
  withSystemTempDirectory "dispatch-fhb64" $ \dir -> do
    let fp = dir </> "test.txt"
    BS.writeFile fp "dispatch test"
    let location = "filehash-base64:" <> T.pack fp
    result <- dispatchLocalImport location "."
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat ->
        idType dat @?= ImportFilehashBase64

testDispatchFile :: TestTree
testDispatchFile = testCase "dispatches bare paths to file loader" $
  withSystemTempDirectory "dispatch-file" $ \dir -> do
    let fp = dir </> "test.yaml"
    BS.writeFile fp "key: value"
    let location = T.pack fp
    result <- dispatchLocalImport location "."
    case result of
      Left (ImportError e) -> fail (T.unpack e)
      Right dat ->
        idType dat @?= ImportFile

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

isHexDigit :: Char -> Bool
isHexDigit c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
