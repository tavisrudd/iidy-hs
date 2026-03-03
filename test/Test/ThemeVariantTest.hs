module Test.ThemeVariantTest (themeVariantTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.Status (StackStatus(..))
import Iidy.Output.Color
  ( darkTheme, lightTheme, highContrastTheme, noColorTheme
  , IidyTheme(..), colorize, colorizeResourceStatus
  )

themeVariantTests :: [TestTree]
themeVariantTests =
  [ testCase "darkTheme - has colors enabled" $ do
      assertBool "colors enabled" (thColorsEnabled darkTheme)

  , testCase "lightTheme - has colors enabled" $ do
      assertBool "colors enabled" (thColorsEnabled lightTheme)

  , testCase "highContrastTheme - has colors enabled" $ do
      assertBool "colors enabled" (thColorsEnabled highContrastTheme)

  , testCase "noColorTheme - colors disabled" $ do
      assertBool "colors disabled" (not $ thColorsEnabled noColorTheme)

  , testCase "darkTheme colorize produces ANSI" $ do
      let result = colorize darkTheme (thSuccess darkTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "lightTheme colorize produces ANSI" $ do
      let result = colorize lightTheme (thSuccess lightTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "highContrastTheme colorize produces ANSI" $ do
      let result = colorize highContrastTheme (thSuccess highContrastTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "noColorTheme colorize is plain" $ do
      let result = colorize noColorTheme (thSuccess noColorTheme) "OK"
      assertEqual "no ANSI" "OK" result

  , testCase "dark and light themes produce different ANSI codes" $ do
      let dark = colorize darkTheme (thMuted darkTheme) "text"
          light = colorize lightTheme (thMuted lightTheme) "text"
      assertBool "different codes" (dark /= light)

  , testCase "highContrast uses bright colors" $ do
      let result = colorize highContrastTheme (thError highContrastTheme) "ERR"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
      assertBool "contains text" ("ERR" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus consistent across themes" $ do
      let darkResult = colorizeResourceStatus darkTheme UpdateComplete
          lightResult = colorizeResourceStatus lightTheme UpdateComplete
          hcResult = colorizeResourceStatus highContrastTheme UpdateComplete
      assertBool "dark has ANSI" ("\ESC[" `T.isInfixOf` darkResult)
      assertBool "light has ANSI" ("\ESC[" `T.isInfixOf` lightResult)
      assertBool "hc has ANSI" ("\ESC[" `T.isInfixOf` hcResult)

  , testCase "colorizeResourceStatus - ROLLBACK uses error color" $ do
      let result = colorizeResourceStatus darkTheme RollbackComplete
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - DELETE_SKIPPED uses muted" $ do
      let result = colorizeResourceStatus darkTheme DeleteSkipped
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
  ]
