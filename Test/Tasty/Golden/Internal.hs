{-# LANGUAGE RankNTypes, ExistentialQuantification, DeriveDataTypeable,
    MultiParamTypeClasses, GeneralizedNewtypeDeriving #-}
module Test.Tasty.Golden.Internal where

import Control.DeepSeq
import Control.Exception
import Data.Typeable (Typeable)
import Options.Applicative
import Data.Monoid
import Data.Tagged
import Data.Proxy
import System.IO.Error (isDoesNotExistError)
import Test.Tasty.Providers
import Test.Tasty.Options

-- | See 'goldenTest' for explanation of the fields
data Golden =
  forall a .
    Golden
      (IO a)
      (IO a)
      (a -> a -> IO (Maybe String))
      (a -> IO ())
  deriving Typeable

-- | This option, when set to 'True', specifies that we should run in the
-- «accept tests» mode
newtype AcceptTests = AcceptTests Bool
  deriving (Eq, Ord, Typeable)
instance IsOption AcceptTests where
  defaultValue = AcceptTests False
  parseValue = fmap AcceptTests . safeReadBool
  optionName = return "accept"
  optionHelp = return "Accept current results of golden tests"
  optionCLParser = flagCLParser Nothing (AcceptTests True)

-- | This option, when set to 'True', specifies to error when a file does
-- not exist, instead of creating a new file.
newtype NoCreateFile = NoCreateFile Bool
  deriving (Eq, Ord, Typeable)
instance IsOption NoCreateFile where
  defaultValue = NoCreateFile False
  parseValue = fmap NoCreateFile . safeReadBool
  optionName = return "no-create"
  optionHelp = return "Error when golden file does not exist"
  optionCLParser = flagCLParser Nothing (NoCreateFile True)

instance IsTest Golden where
  run opts golden _ = runGolden golden opts
  testOptions =
    return
      [ Option (Proxy :: Proxy AcceptTests)
      , Option (Proxy :: Proxy NoCreateFile)
      ]

runGolden :: Golden -> OptionSet -> IO Result
runGolden (Golden getGolden getTested cmp update) opts = do
  do
    mbNew <- try getTested

    case mbNew of
      Left e -> do
        return $ testFailed $ show (e :: SomeException)
      Right new -> do

        mbRef <- try getGolden

        case mbRef of
          Left e | isDoesNotExistError e ->
            if noCreate
              then return $ testFailed "Golden file does not exist; --no-create flag specified"
              else do
                update new
                return $ testPassed "Golden file did not exist; created"

            | otherwise -> throwIO e

          Right ref -> do

            result <- cmp ref new

            case result of
              Just _reason | accept -> do
                -- test failed; accept the new version
                update new
                return $ testPassed "Accepted the new version"

              Just reason -> do
                -- Make sure that the result is fully evaluated and doesn't depend
                -- on yet un-read lazy input
                evaluate . rnf $ reason
                return $ testFailed reason

              Nothing ->
                return $ testPassed ""
  where
    AcceptTests accept = lookupOption opts
    NoCreateFile noCreate = lookupOption opts
