{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Lambdabot.Command (
  Command (..),
  cmdNames,
  command,
  runCommand,
  Cmd,
  execCmd,
  getCmdName,
  withMsg,
  readNick,
  showNick,
  getServer,
  getSender,
  getTarget,
  getTags,
  getLambdabotName,
  say,
  lineify,
) where

import Lambdabot.Config (MonadConfig (..))
import Lambdabot.Config.Core (textWidth)
import Lambdabot.Logging (MonadLogging (..))
import qualified Lambdabot.Message as Msg
import Lambdabot.Nick (Nick, fmtNick, parseNick)

import Control.Monad.Base (MonadBase (..))
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.Identity (Identity)
import Control.Monad.Reader (MonadIO (..), MonadReader (ask), MonadTrans (..), ReaderT (..), asks)
import Control.Monad.Trans.Control (ComposeSt, MonadBaseControl (..), MonadTransControl (..), defaultLiftBaseWith, defaultRestoreM)
import Control.Monad.Writer (MonadWriter (tell), WriterT (..), execWriterT)
import Data.Char (isAlphaNum)
import Data.List (inits, tails)

data CmdArgs = forall a.
  Msg.Message a =>
  CmdArgs
  { _message :: a
  , target :: Nick
  , invokedAs :: String
  }

newtype Cmd m a = Cmd {unCmd :: ReaderT CmdArgs (WriterT [String] m) a}
  deriving (MonadCatch, MonadThrow, MonadMask)

instance Functor f => Functor (Cmd f) where
  fmap f (Cmd x) = Cmd (fmap f x)

instance Applicative f => Applicative (Cmd f) where
  pure = Cmd . pure
  Cmd f <*> Cmd x = Cmd (f <*> x)

instance Monad m => Monad (Cmd m) where
  return = Cmd . return
  Cmd x >>= f = Cmd (x >>= (unCmd . f))

instance MonadFail m => MonadFail (Cmd m) where
  fail = lift . fail

instance MonadIO m => MonadIO (Cmd m) where
  liftIO = lift . liftIO

instance MonadBase b m => MonadBase b (Cmd m) where
  liftBase = lift . liftBase

instance MonadTrans Cmd where
  lift = Cmd . lift . lift

instance MonadTransControl Cmd where
  type StT Cmd a = (a, [String])
  liftWith f = do
    r <- Cmd ask
    lift $ f $ \t -> runWriterT (runReaderT (unCmd t) r)
  restoreT = Cmd . lift . WriterT
  {-# INLINE liftWith #-}
  {-# INLINE restoreT #-}

instance MonadBaseControl b m => MonadBaseControl b (Cmd m) where
  type StM (Cmd m) a = ComposeSt Cmd m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM
  {-# INLINE liftBaseWith #-}
  {-# INLINE restoreM #-}

instance MonadConfig m => MonadConfig (Cmd m) where
  getConfig = lift . getConfig

instance MonadLogging m => MonadLogging (Cmd m) where
  getCurrentLogger = do
    parent <- lift getCurrentLogger
    self <- getCmdName
    return (parent ++ ["Command", self])
  logM a b c = lift (logM a b c)

data Command m = Command
  { cmdName :: String
  , aliases :: [String]
  , privileged :: Bool
  , help :: Cmd m ()
  , process :: String -> Cmd m ()
  }

cmdNames :: Command m -> [String]
cmdNames c = cmdName c : aliases c

command :: String -> Command Identity
command name =
  Command
    { cmdName = name
    , aliases = []
    , privileged = False
    , help = bug "they haven't created any help text!"
    , process = const (bug "they haven't implemented this command!")
    }
 where
  bug reason =
    say $
      unwords
        ["You should bug the author of the", show name, "command, because", reason]

runCommand :: (Monad m, Msg.Message a) => Command m -> a -> Nick -> String -> String -> m [String]
runCommand cmd msg tgt arg0 args = execCmd (process cmd args) msg tgt arg0

execCmd :: (Monad m, Msg.Message a) => Cmd m t -> a -> Nick -> String -> m [String]
execCmd cmd msg tgt arg0 = execWriterT (runReaderT (unCmd cmd) (CmdArgs msg tgt arg0))

getTarget :: Monad m => Cmd m Nick
getTarget = Cmd (asks target)

getCmdName :: Monad m => Cmd m String
getCmdName = Cmd (asks invokedAs)

say :: Monad m => String -> Cmd m ()
say [] = return ()
say it = Cmd (tell [it])

-- | wrap long lines.
lineify :: MonadConfig m => [String] -> m String
lineify msg = do
  w <- getConfig textWidth
  return $ unlines $ lines (unlines msg) >>= mbreak w
 where
  mbreak w xs
    | null bs = [as]
    | otherwise = (as ++ cs) : filter (not . null) (mbreak w ds)
   where
    (as, bs) = splitAt (w - n) xs
    breaks =
      filter (not . isAlphaNum . last . fst) $
        drop 1 $
          take n $ zip (inits bs) (tails bs)
    (cs, ds) = last $ splitAt n bs : breaks
    n = 10

withMsg :: Monad m => (forall a. Msg.Message a => a -> Cmd m t) -> Cmd m t
withMsg f = Cmd ask >>= f' where f' (CmdArgs msg _ _) = f msg

readNick :: Monad m => String -> Cmd m Nick
readNick nick = withMsg (\msg -> return (parseNick (Msg.server msg) nick))

showNick :: Monad m => Nick -> Cmd m String
showNick nick = withMsg (\msg -> return (fmtNick (Msg.server msg) nick))

getServer :: Monad m => Cmd m String
getServer = withMsg (return . Msg.server)

getSender :: Monad m => Cmd m Nick
getSender = withMsg (return . Msg.nick)

getTags :: Monad m => Cmd m [(String, String)]
getTags = withMsg (pure . Msg.tags)

getLambdabotName :: Monad m => Cmd m Nick
getLambdabotName = withMsg (return . Msg.lambdabotName)
