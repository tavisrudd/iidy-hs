module Test.DeleteStackTest (deleteStackTests) where

import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Confirm (isConfirmation)

deleteStackTests :: [TestTree]
deleteStackTests =
    [ testCase "isConfirmation: y" $
        isConfirmation "y" @?= True
    , testCase "isConfirmation: Y" $
        isConfirmation "Y" @?= True
    , testCase "isConfirmation: yes" $
        isConfirmation "yes" @?= True
    , testCase "isConfirmation: YES" $
        isConfirmation "YES" @?= True
    , testCase "isConfirmation: Yes" $
        isConfirmation "Yes" @?= True
    , testCase "isConfirmation: n" $
        isConfirmation "n" @?= False
    , testCase "isConfirmation: no" $
        isConfirmation "no" @?= False
    , testCase "isConfirmation: empty" $
        isConfirmation "" @?= False
    , testCase "isConfirmation: yep" $
        isConfirmation "yep" @?= False
    , testCase "isConfirmation: random text" $
        isConfirmation "delete it" @?= False
    ]
