module Lambdabot.Logging (
  L.Priority (..),
  L.updateGlobalLogger,
  L.rootLoggerName,
  L.addHandler,
  L.setLevel,
  L.setHandlers,
  L.removeAllHandlers,
  MonadLogging (..),
  GenericHandler (formatter),
  streamHandler,
  simpleLogFormatter,
  debugM,
  infoM,
  noticeM,
  warningM,
  errorM,
  criticalM,
  alertM,
  emergencyM,
) where

import Data.List (intercalate)
import System.Log.Formatter (simpleLogFormatter)
import System.Log.Handler.Simple (GenericHandler (formatter), streamHandler)
import qualified System.Log.Logger as L

class Monad m => MonadLogging m where
  getCurrentLogger :: m [String]
  logM :: String -> L.Priority -> String -> m ()

instance MonadLogging IO where
  getCurrentLogger = return []
  logM = L.logM

getCurrentLoggerName :: MonadLogging m => m String
getCurrentLoggerName =
  fmap (intercalate "." . filter (not . null)) getCurrentLogger

debugM :: MonadLogging m => String -> m ()
debugM msg = do
  logger <- getCurrentLoggerName
  logM logger L.DEBUG msg

infoM :: MonadLogging m => String -> m ()
infoM msg = do
  logger <- getCurrentLoggerName
  logM logger L.INFO msg

noticeM :: MonadLogging m => String -> m ()
noticeM msg = do
  logger <- getCurrentLoggerName
  logM logger L.NOTICE msg

warningM :: MonadLogging m => String -> m ()
warningM msg = do
  logger <- getCurrentLoggerName
  logM logger L.WARNING msg

errorM :: MonadLogging m => String -> m ()
errorM msg = do
  logger <- getCurrentLoggerName
  logM logger L.ERROR msg

criticalM :: MonadLogging m => String -> m ()
criticalM msg = do
  logger <- getCurrentLoggerName
  logM logger L.CRITICAL msg

alertM :: MonadLogging m => String -> m ()
alertM msg = do
  logger <- getCurrentLoggerName
  logM logger L.ALERT msg

emergencyM :: MonadLogging m => String -> m ()
emergencyM msg = do
  logger <- getCurrentLoggerName
  logM logger L.EMERGENCY msg
