--
-- | IRC protocol binding
-- TODO : refactor this. Especially the MODULE stuff which has nothing
-- to do with the IRC protocol.
--
module IRC (
        MODULE(..), Module(..),
        ModuleT,

        IRCMessage(..), 
        IRCRState(..), IRCRWState(..), IRCError(..), 
        IRC(..),

        LB(..), MonadLB(..),

        withModule, getDictKeys,

        -- ** Functions to access the module's state
        readMS, writeMS, modifyMS,

        -- ** Utility functions for modules that need state for each target.
        GlobalPrivate(global), mkGlobalPrivate, writePS, readPS, writeGS, readGS,

        ircPrivmsg,
        ircJoin, ircPart, ircQuit, ircReconnect,
        ircTopic, ircGetTopic, ircGetChannels,
        ircSignalConnect, Callback, ircInstallOutputFilter, OutputFilter,
        ircInstallModule, ircUnloadModule,
        ircNick, ircChans, ircNames,
        ircSignOn,
        ircRead,

        ircLoad, ircUnload,

        clean, checkPrivs, mkCN, handleIrc, runIrc,
  ) where

import qualified Config (config, name, admins, host, port, textwidth)
import DeepSeq          (($!!), DeepSeq(..))
import ErrorUtils
import ExceptionError   (ExceptionError(..), ExceptionErrorT(..))
import MonadException   (MonadException(throwM))
import Util             (split,clean,breakOnGlue, Serializer(..), lowerCaseString)
import qualified Util   (join)

import Map (Map)
import qualified Map as M hiding (Map)
import qualified Shared as S

import Prelude hiding   (mod, catch)

import Network          (withSocketsDo, connectTo, PortID(PortNumber))

import System.IO        (Handle, hGetLine, hPutStr, hClose,
                         hSetBuffering, BufferMode(NoBuffering),
                         openFile, hGetContents, IOMode(..))

#if __GLASGOW_HASKELL__ >= 600
import System.IO.Error  (isEOFError, ioeGetHandle)

# ifndef mingw32_HOST_OS
import System.Posix.Signals
import System.IO.Unsafe         (unsafePerformIO)
# endif

#else
import Posix
import System.IO.Error
#endif

import Data.Char                (toLower, isAlphaNum, isSpace)
import Data.List                (isSuffixOf)
import Data.Dynamic             (Typeable, toDyn, fromDynamic)
import Data.IORef               (newIORef, IORef, readIORef, writeIORef)

import Control.Exception
import Control.Concurrent
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Error (MonadError (..))
import Control.Arrow       (first)

------------------------------------------------------------------------

#ifdef mingw32_HOST_OS
type Signal = ()
type Handler = ()
type SignalSet = ()
#endif

-- | Global read-only state.
data IRCRState
  = IRCRState {
        ircServer      :: String,
        ircReadChan    :: Chan IRCMessage,
        ircReadThread  :: ThreadId,
        ircWriteChan   :: Chan IRCMessage,
        ircWriteThread :: ThreadId
  }

type Callback = IRCMessage -> IRC ()
-- | target, message
type OutputFilter = String -> [String] -> IRC [String]
-- type OutputFilter = String -> [String] -> ContT [String] IRC [String]

-- | Global read\/write state.
data IRCRWState
  = IRCRWState {
        ircPrivilegedUsers :: Map String Bool,
        ircChannels        :: Map ChanName String, 
            -- ^ maps channel names to topics
        ircModules         :: Map String ModuleRef,
        ircCallbacks       :: Map String [(String,Callback)],
        ircOutputFilters   :: [(String,OutputFilter)], 
            -- ^ Output filters, invoked from right to left
        ircCommands        :: Map String ModuleRef,
        ircStayConnected   :: Bool,
        ircDynLoad         :: S.DynLoad
  }

newtype ChanName = ChanName { getCN :: String } -- should be abstract, always lowercase
  deriving (Eq, Ord)

instance Show ChanName where
  show (ChanName x) = show x

-- only use the "smart constructor":
mkCN :: String -> ChanName
mkCN = ChanName . map toLower

-- does the deriving Typeable do the right thing?
newtype SignalException = SignalException Signal
  deriving Typeable

withHandler :: (MonadIO m,MonadError e m)
            => Signal 
            -> Handler 
            -> Maybe SignalSet 
            -> m () 
            -> m ()
#ifdef mingw32_HOST_OS
withHandler s h ss m = return ()
#else
withHandler s h ss m 
  = bracketError (liftIO $ installHandler s h ss)
                 (\oldh -> liftIO $ installHandler s oldh Nothing)
                 (\_ -> m)
#endif

withHandlerList :: (MonadError e m,MonadIO m)
                => [Signal]
                -> (Signal -> Handler) 
                -> Maybe SignalSet 
                -> m () 
                -> m ()
withHandlerList sl h ss m = foldr (\s -> withHandler s (h s) ss) m sl

-- be careful adding signals, some signals can't be caught and installHandler
-- just raises an exception if you try
ircSignalsToCatch :: [Signal]
ircSignalsToCatch = [
#ifndef mingw32_HOST_OS
#if __GLASGOW_HASKELL__ >= 600
                     busError,
#endif
                     segmentationViolation,
                     keyboardSignal,softwareTermination,
                     keyboardTermination,lostConnection
#endif                     
                     ]

ircSignalMessage :: Signal -> [Char]
ircSignalMessage s
#ifndef mingw32_HOST_OS
#if __GLASGOW_HASKELL__ >= 600
                   | s==busError = "killed by SIGBUS"
#endif
                   | s==segmentationViolation = "killed by SIGSEGV"
                   | s==keyboardSignal = "killed by SIGINT"
                   | s==softwareTermination = "killed by SIGTERM"
                   | s==keyboardTermination = "killed by SIGQUIT"
                   | s==lostConnection = "killed by SIGHUP"
#endif
 -- this case shouldn't happen if the list of messages is kept up to date
 -- with the list of signals caught
                   | otherwise = "killed by unknown signal"

ircSignalHandler :: ThreadId -> Signal -> Handler
ircSignalHandler threadid s
#ifdef mingw32_HOST_OS
  = ()
#else  
  = Catch $ do
      putMVar catchLock ()
      throwTo threadid $ DynException $ toDyn $ SignalException s
                                
-- This is clearly a hack, but I have no idea how to accomplish the same
-- thing correctly. The main problem is that signals are often thrown multiple
-- times, and the threads start killing each other if we allow the
-- SignalException to be thrown more than once.
{-# NOINLINE catchLock #-}      
catchLock :: MVar ()            
catchLock = unsafePerformIO $ newEmptyMVar
#endif  

withIrcSignalCatch :: (MonadError e m,MonadIO m) => m () -> m ()
withIrcSignalCatch m 
  = do threadid <- liftIO $ myThreadId
       withHandlerList ircSignalsToCatch (ircSignalHandler threadid) Nothing m

data IRCError = IRCRaised Exception 
              | SignalCaught Signal 
  deriving Show

{-
ircErrorMsg :: IRCError -> String
ircErrorMsg (IRCRaised e) = show e
ircErrorMsg (SignalCaught s) = "caught signal "++show s
-}

instance ExceptionError IRCError where
  fromException e 
    = case e of
        DynException d ->
          case fromDynamic d of
             Just (SignalException s) -> SignalCaught s
             Nothing -> IRCRaised e
        _ -> IRCRaised e


type IRCErrorT m a = ExceptionErrorT IRCError m a

handleIRCErrorT :: (MonadIO m,MonadException m) => IRCErrorT m () -> m ()
handleIRCErrorT m 
  = do res <- runExceptionErrorT m
       case res of
         Left (IRCRaised e) -> throwM e
#ifndef mingw32_HOST_OS         
         Left (SignalCaught s) -> liftIO $ raiseSignal s
#endif         
-- overlapped for now, but won't be if IRCError gets extended
--       Left e -> throwM $ ErrorCall (ircErrorMsg e)
         Right v -> return v


data IRCMessage
  = IRCMessage {
        msgPrefix   :: String,
        msgCommand  :: String,
        msgParams   :: [String]
  }
  deriving (Show)

instance DeepSeq IRCMessage where
  deepSeq m
    = deepSeq (msgPrefix m) . deepSeq (msgCommand m) . deepSeq (msgParams m)

ircNick     :: IRCMessage -> String
ircNick msg = fst $ breakOnGlue "!" (msgPrefix msg)

-- | 'ircChans' converts an IRCMessage to a list of channels.
ircChans :: IRCMessage -> [String]
ircChans msg
  = let cstr = head $ msgParams msg
    in map (\(x:xs) -> if x == ':' then xs else x:xs) (split "," cstr)
           -- solves what seems to be an inconsistency in the parser

{-
ircuser     :: IRCMessage -> String
ircuser msg = head $ split "@" $ (split "!" (msgPrefix msg)) !! 1

irchost     :: IRCMessage -> String
irchost msg = (split "@" (msgPrefix msg)) !! 1
-}

-- | Lambdabot's basic monad. Doesn't assume that there is a connection to a
--   server.
newtype LB a = LB { runLB :: IRCErrorT (StateT IRCRWState IO) a }
#if __GLASGOW_HASKELL__ >= 600
#ifndef __HADDOCK__
   deriving (Functor,Monad,MonadState IRCRWState,MonadError IRCError,MonadIO)
#endif
#else
instance Monad LB where
  return a = LB $ return a
  LB m >>= f = LB $ do v <- m
                       runLB (f v)

instance MonadState IRCRWState LB where
  get = LB get
  put s = LB $ put s

instance MonadError IRCError LB where
  throwError e = LB $ throwError e
  catchError (LB m) f = LB $ catchError m (runLB . f)

instance MonadIO LB where
  liftIO m = LB $ liftIO m

#endif

evalLB :: LB () -> IRCRWState -> IO ()
evalLB lb rws = evalStateT (handleIRCErrorT (runLB lb)) rws

class (Monad m,MonadState IRCRWState m,MonadError IRCError m,MonadIO m) 
   => MonadLB m 
   where
  liftLB :: LB a -> m a

-- | This \"transformer\" encodes the additional information a module might 
--   need to access its name or its state.
type ModuleT s m a = (?ref :: IORef s, ?name :: String) => m a

-- | The IRC Monad. The reader transformer holds information about the
--   connection to the IRC server.
newtype IRC a 
  = IRC { runIRC :: IRCErrorT (ReaderT IRCRState (StateT IRCRWState IO)) a }
#if __GLASGOW_HASKELL__ >= 600
#ifndef __HADDOCK__
    deriving (Monad,Functor,MonadReader IRCRState,MonadState IRCRWState,
              MonadError IRCError,MonadIO)
#endif
#else
instance Monad IRC where
  return a = IRC $ return a
  IRC m >>= f = IRC $ do v <- m
                         runIRC (f v)

instance MonadReader IRCRState IRC where
  ask = IRC ask
  local f (IRC m) = IRC $ local f m

instance MonadState IRCRWState IRC where
  get = IRC get
  put s = IRC $ put s
  
instance MonadError IRCError IRC where
  throwError e = IRC $ throwError e
  catchError (IRC m) f = IRC $ catchError m (runIRC . f)

instance MonadIO IRC where
  liftIO m = IRC $ liftIO m

#endif

instance MonadLB LB where
  liftLB m = m

instance MonadLB IRC where
  liftLB (LB (ExceptionErrorT m)) 
   = IRC $ ExceptionErrorT $ lift m

mkIrcMessage :: String -> [String] -> IRCMessage
mkIrcMessage cmd params
  = IRCMessage { msgPrefix = "", msgCommand = cmd, msgParams = params }

ircSignOn :: String -> String -> IRC ()
ircSignOn nick ircname = do 
    server <- asks ircServer
    ircWrite (mkIrcMessage "USER" [nick, "localhost", server, ircname])
    ircWrite (mkIrcMessage "NICK" [nick])

ircGetChannels :: MonadLB m => m [String]
ircGetChannels = do 
    chans <- gets ircChannels
    return $ map getCN (M.keys chans)

lineify, checkRecip, cleanOutput :: OutputFilter
lineify _ msg = return $ mlines $ unlines msg

checkRecip who msg
  | who == Config.name Config.config = return []
  | "bot" `isSuffixOf` lowerCaseString who = return []
  | otherwise = return msg

-- For now, this just checks for duplicate empty lines.
cleanOutput _ msg = return $ drop 1 $ concat $ zipWith cl ("":msg') (cycle msg') where 
  cl "" "" = []
  cl x  _  = [x]

  msg' = map (reverse . dropWhile isSpace . reverse) msg

-- | Send a message to a channel\/user. If the message is too long, the rest
--   of it is saved in the (global) more-state.
ircPrivmsg :: String -- ^ The channel\/user.
   -> String         -- ^ The message.
   -> IRC ()
ircPrivmsg who msg = do 
  filters <- gets ircOutputFilters
  sendlines <- foldr (\f -> (=<<) (f who)) (return $ lines msg) $ map snd filters
  -- Hardcoded defaults: maximal ten lines, maximal 80 chars/line
  mapM_ (ircPrivmsg' who . take 80) $ take 10 sendlines

-- ---------------------------------------------------------------------
-- | output filter (should consider a fmt(1)-like algorithm
--
mlines		:: String -> [String]
mlines ""	=  []
mlines s	=  let (l, s') = mbreak 0 (== '\n') s in l: mlines s'
  where
    mbreak :: Int -> (Char -> Bool) -> [Char] -> ([Char], [Char])
    mbreak _ _ xs@[] = (xs, xs)
    mbreak n p xs@(x:xs')
      | n == w                           = ([],dropWhile isSpace xs)
      | n > (w-10) && not (isAlphaNum x) = ([x], dropWhile isSpace xs')
      | p x	                             = ([],xs')
      | otherwise                        = first (x:) $ mbreak (n+1) p xs'

    w = Config.textwidth Config.config

-- ---------------------------------------------------------------------

ircPrivmsg' :: String -> String -> IRC ()
ircPrivmsg' who "" = ircPrivmsg' who " "
ircPrivmsg' who msg
  = ircWrite (mkIrcMessage "PRIVMSG" [who, ':' : clean_msg])
    -- merry christmas det
    where clean_msg = case concatMap clean msg of
              str@('@':_) -> ' ':str
              str         -> str


ircTopic :: String -> String -> IRC ()
ircTopic chan topic
  = ircWrite (mkIrcMessage "TOPIC" [chan, ':' : topic])

ircGetTopic :: String -> IRC ()
ircGetTopic chan
  = ircWrite (mkIrcMessage "TOPIC" [chan])

-- quit and reconnect wait 1s after sending a QUIT to give the connection
-- a chance to close gracefully (and interrupt the wait with an exception)
-- after that they return and the connection will probably be forcibly
-- closed by the finallyError in runIrc'

ircQuit :: String -> IRC ()
ircQuit msg = do 
    state <- get
    put (state { ircStayConnected = False })
    ircWrite (mkIrcMessage "QUIT" [':' : msg])
    liftIO $ threadDelay 1000

ircReconnect :: String -> IRC ()
ircReconnect msg = do ircWrite (mkIrcMessage "QUIT" [':' : msg])
                      liftIO $ threadDelay 1000

ircJoin :: String -> IRC ()
ircJoin loc
  = ircWrite (mkIrcMessage "JOIN" [loc])

ircPart :: String -> IRC ()
ircPart loc
  = ircWrite (mkIrcMessage "PART" [loc])

ircNames :: [String] -> IRC ()
ircNames chans = ircWrite (mkIrcMessage "NAMES" [Util.join "," chans])

ircRead :: IRC IRCMessage
ircRead = do 
    chanr <- asks ircReadChan
    liftIO (readChan chanr)

ircWrite :: IRCMessage -> IRC ()
ircWrite line = do  
    chanw <- asks ircWriteChan
    -- use DeepSeq's $!! to ensure that any Haskell errors in line
    -- are caught now, rather than later on in the other thread
    liftIO (writeChan chanw $!! line)


--
-- May wish to add more things to the things caught, or restructure things 
-- a bit. Can't just catch everything - in particular EOFs from the socket
-- loops get thrown to this thread and we musn't just ignore them.
--
handleIrc :: (MonadError IRCError m) => (String -> m ()) -> m () -> m ()
handleIrc handler m = catchError m $ \e -> case e of
        IRCRaised (ErrorCall s)        -> handler s
        IRCRaised (PatternMatchFail s) -> handler s
        _                              -> throwError e

--
-- | run the IRC monad
--
runIrc :: LB a -> IRC () -> S.DynLoad -> IO ()
runIrc initialise m ld = withSocketsDo $ do
        ex <- try $ evalLB
                 (initialise >> withIrcSignalCatch (runIrc' m))
                 (initState (Config.admins Config.config))
        either (\e->putStrLn ("runIRC: caught exception: "++show e)) (return) ex
      where
        initState as = IRCRWState {
                ircPrivilegedUsers = M.fromList [(a,True)|a <- as],
                ircChannels        = M.empty,
                ircModules         = M.empty,
                ircCallbacks       = M.empty,
                ircOutputFilters   = [("",cleanOutput),
                                      ("",lineify),
                                      ("",checkRecip)],
                ircCommands        = M.empty,
                ircStayConnected   = True,
                ircDynLoad         = ld
            }

{-
traceError :: (MonadIO m,MonadError e m,Show e) => m a -> m a
traceError = handleError (\e -> liftIO (print e) >> throwError e)

traceException :: (MonadIO m,MonadException m) => m a -> m a
traceException = handleM (\e -> liftIO (print e) >> throwM e)
-}

runIrc' :: IRC () -> LB ()
runIrc' m = do  
        let portnum  = PortNumber $ fromIntegral (Config.port Config.config)

        s <- liftIO $ connectTo (Config.host Config.config) portnum

        tryErrorJust (isEOFon s) $ do 
            liftIO $ hSetBuffering s NoBuffering
            threadmain <- liftIO $ myThreadId
            chanr      <- liftIO $ newChan
            chanw      <- liftIO $ newChan
            threadr    <- liftIO $ forkIO $ readerLoop threadmain chanr chanw s
            threadw    <- liftIO $ forkIO $ writerLoop threadmain chanw s

            let chans = IRCRState {
                            ircServer      = Config.host Config.config,
                            ircReadChan    = chanr,
                            ircReadThread  = threadr,
                            ircWriteChan   = chanw,
                            ircWriteThread = threadw }

            finallyError 
               (LB $ ExceptionErrorT $
                     runReaderT (runExceptionErrorT $ runIRC $ catchSignals $
                                       m >> ircQuit "terminated")
                                chans)
               (do exitModules
                   liftIO $ killThread threadr
                   liftIO $ killThread threadw
                   liftIO $ hClose s)

        reconn <- gets ircStayConnected
        when reconn $ runIrc' m

  where
#if __GLASGOW_HASKELL__ >= 600
        isEOFon s (IRCRaised (IOException e)) 
            = if isEOFError e && ioeGetHandle e == Just s
              then Just () else Nothing
#else
        isEOFon s (IRCRaised e) 
            = if isEOFError e && ioeGetHandle e == Just s
              then Just () else Nothing
#endif        
        isEOFon _ _ = Nothing
        isSignal (SignalCaught s) = Just s
        isSignal _ = Nothing
        catchSignals n = catchErrorJust isSignal n
                             (\s -> do tryError $ ircQuit (ircSignalMessage s)
                                       throwError (SignalCaught s))

        exitModules = do
          mods <- gets $ M.elems . ircModules
          (`mapM_` mods) $ \(ModuleRef mod ref name) -> do
            -- Call ircUnloadModule?
            let ?ref = ref; ?name = name 
            moduleExit mod
            writeGlobalState mod name


readerLoop :: ThreadId -> Chan IRCMessage -> Chan IRCMessage -> Handle -> IO ()
readerLoop threadmain chanr chanw h
  = do  liftIO (putStrLn "Running reader loop...")
        exc <- try readerLoop'
        case exc of
           Left (AsyncException ThreadKilled) -> return ()
           Left err -> throwTo threadmain err
           Right _ -> return ()
  where
    readerLoop'
      = do line <- hGetLine h
           let  line' = [ c | c <- line, c /= '\n', c /= '\r' ]
           case line' of
                ('P':'I':'N':'G':' ':rest)
                    -> writeChan chanw (mkIrcMessage "PONG" [rest])
                _   -> writeChan chanr (decodeMessage line')
           readerLoop'
{-# INLINE readerLoop #-}

writerLoop :: ThreadId -> Chan IRCMessage -> Handle -> IO ()
writerLoop threadmain chanw h
  = do exc <- try writerLoop'
       case exc of
           Left (AsyncException ThreadKilled) 
             -> try (hPutStr h "QUIT :died unexpectedly\r") >> return ()
           Left e  -> throwTo threadmain e
           Right _ -> return ()
  where
    writerLoop'
      = do msg <- readChan chanw
           hPutStr h (encodeMessage msg "\r")
           writerLoop'
{-# INLINE writerLoop #-}

encodeMessage :: IRCMessage -> String -> String
encodeMessage msg
  = encodePrefix (msgPrefix msg) . encodeCommand (msgCommand msg)
          . encodeParams (msgParams msg)
  where
    encodePrefix [] = id
    encodePrefix prefix = showChar ':' . showString prefix . showChar ' '

    encodeCommand cmd = showString cmd

    encodeParams [] = id
    encodeParams (p:ps) = showChar ' ' . showString p . encodeParams ps


decodeMessage :: String -> IRCMessage
decodeMessage line
  = let (prefix, rest1) = decodePrefix (,) line in
    let (cmd, rest2)    = decodeCmd (,) rest1 in
    let params          = decodeParams rest2 in
    IRCMessage { msgPrefix = prefix, msgCommand = cmd, msgParams = params }
  where
    decodePrefix k (':':cs)
      = decodePrefix' k cs
      where
        decodePrefix' j ""       = j "" ""
        decodePrefix' j (' ':ds) = j "" ds
        decodePrefix' j (c:ds)   = decodePrefix' (\xs ys -> j (c:xs) ys) ds

    decodePrefix k cs
      = k "" cs

    decodeCmd k []
      = k "" ""
    decodeCmd k (' ':cs)
      = k "" cs
    decodeCmd k (c:cs)
      = decodeCmd (\xs ys -> k (c:xs) ys) cs

    decodeParams :: String -> [String]
    decodeParams xs
      = decodeParams' [] [] xs
      where
        decodeParams' param params []
          | null param = reverse params
          | otherwise  = reverse (reverse param : params)
        decodeParams' param params (' ' : cs)
          | null param = decodeParams' [] params cs
          | otherwise  = decodeParams' [] (reverse param : params) cs
        decodeParams' param params rest@(c@':' : cs)
          | null param = reverse (rest : params)
          | otherwise  = decodeParams' (c:param) params cs
        decodeParams' param params (c:cs)
          = decodeParams' (c:param) params cs

{-
getFirstWord :: String -> String
getFirstWord line = takeWhile (/=' ') line
-}

{-
lowQuote :: String -> String
lowQuote [] = []
lowQuote ('\0':cs)   = '\020':'0'    : lowQuote cs
lowQuote ('\n':cs)   = '\020':'n'    : lowQuote cs
lowQuote ('\r':cs)   = '\020':'r'    : lowQuote cs
lowQuote ('\020':cs) = '\020':'\020' : lowQuote cs
lowQuote (c:cs)      = c : lowQuote cs

lowDequote :: String -> String
lowDequote [] = []
lowDequote ('\020':'0'   :cs) = '\0'   : lowDequote cs
lowDequote ('\020':'n'   :cs) = '\n'   : lowDequote cs
lowDequote ('\020':'r'   :cs) = '\r'   : lowDequote cs
lowDequote ('\020':'\020':cs) = '\020' : lowDequote cs
lowDequote ('\020'       :cs) = lowDequote cs
lowDequote (c:cs)             = c : lowDequote cs

ctcpQuote :: String -> String
ctcpQuote [] = []
ctcpQuote ('\001':cs) = '\134':'a'    : ctcpQuote cs
ctcpQuote ('\134':cs) = '\134':'\134' : ctcpQuote cs
ctcpQuote (c:cs)      = c : ctcpQuote cs

ctcpDequote :: String -> String
ctcpDequote [] = []
ctcpDequote ('\134':'a'   :cs) = '\001' : ctcpDequote cs
ctcpDequote ('\134':'\134':cs) = '\134' : ctcpDequote cs
ctcpDequote ('\134':cs)        = ctcpDequote cs
ctcpDequote (c:cs)             = c : ctcpDequote cs
-}

------------------------------------------------------------------------

-- | The Module type class.
-- Minimal complete definition: @moduleHelp@, @moduleCmds@, @process@.
class Module m s | m -> s where
    -- | If the module wants its state to be saved, this function should
    --   return a Serializer.
    --
    --   The default implementation returns Nothing.
    moduleSerialize :: m -> Maybe (Serializer s)
    -- | If the module maintains state, this method specifies the default state
    --   (for example in case the state can't be read from a state).
    --
    --   The default implementation returns an error and assumes the state is 
    --   never accessed.
    moduleDefState  :: m -> LB s
    -- | This method should return a help string for every command it defines.
    moduleHelp      :: m -> String -> ModuleT s LB String
    -- | Is the module sticky? Sticky modules (as well as static ones) can't be
    --   unloaded. By default, modules are not sticky.
    moduleSticky    :: m -> Bool
    -- | The commands the module listenes to.
    moduleCmds      :: m -> ModuleT s LB [String]
    -- | Initialize the module. The default implementation does nothing.
    moduleInit      :: m -> ModuleT s LB ()
    -- | Initialize the module. Only called when dynloading, i.e. when we
    --   we have a connection to an IRC server.
    moduleDynInit   :: m -> ModuleT s IRC ()
    -- | Finalize the module. The default implementation does nothing.
    moduleExit      :: m -> ModuleT s LB ()
    -- | Process a command a user sent.
    process         :: m -- ^ phantom
        -> IRCMessage    -- ^ the message
        -> String        -- ^ target
        -> String        -- ^ command
        -> String        -- ^ the arguments to the command
        -> ModuleT s IRC () 

    moduleExit _      = return ()
    moduleInit _      = return ()
    moduleDynInit _   = return ()
    moduleSticky _    = False
    moduleSerialize _ = Nothing
    moduleDefState  _ = return $ error "state not initalized"

-- | An existential type holding a module.
data MODULE = forall m s. (Module m s) => MODULE m

data ModuleRef = forall m s. (Module m s) => ModuleRef m (IORef s) String

toFilename :: String -> String
toFilename = ("State/"++)

writeGlobalState :: Module m s => m -> String -> ModuleT s LB ()
writeGlobalState mod name = case moduleSerialize mod of
  Nothing  -> return ()
  Just ser -> do
    state <- readMS
    case serialize ser state of
      Nothing  -> return ()
      Just out -> liftIO $ writeFile (toFilename name) out

-- Read the whole file so it'll be closed
readFile' :: String -> IO String
readFile' file = do
  h <- openFile file ReadMode
  cont <- hGetContents h
  cont `deepSeq` hClose h
  return cont

readGlobalState :: Module m s => m -> String -> IO (Maybe s)
readGlobalState mod name = case moduleSerialize mod of
  Nothing  -> return Nothing
  Just ser -> do
    state <- Just `fmap` readFile' (toFilename name) `catch` \_ -> return Nothing
    return $ deSerialize ser =<< state

------------------------------------------------------------------------
--
-- | Register a module in the irc state
--
ircInstallModule :: MODULE -> String -> LB ()
ircInstallModule (MODULE mod) modname = do  
    savedState <- liftIO $ readGlobalState mod modname
    state      <- maybe (moduleDefState mod) return savedState
    ref        <- liftIO $ newIORef state

    let modref = ModuleRef mod ref modname
    let ?ref = ref; ?name = modname
    moduleInit mod
    cmds <- moduleCmds mod

    s <- get
    let modmap = ircModules s
    let cmdmap = ircCommands s
    put $ s {
      ircModules = M.insert modname modref modmap,
      ircCommands = M.addList [ (cmd,modref) | cmd <- cmds ] cmdmap                
    }

--
-- | Unregister a module's entry in the irc state
--
ircUnloadModule :: String -> LB ()
ircUnloadModule modname = withModule ircModules modname (error "module not loaded") (\m -> do
    when (moduleSticky m) $ error "module is sticky"
    moduleExit m
    writeGlobalState m modname
    cmds  <- moduleCmds m
    s <- get
    let modmap = ircModules s
        cmdmap = ircCommands s
        cbs    = ircCallbacks s
        ofs    = ircOutputFilters s
    put $ s { ircCommands = foldl (flip M.delete) cmdmap cmds }
            { ircModules = M.delete modname modmap }
            { ircCallbacks = filter ((/=modname) . fst) `fmap` cbs }
            { ircOutputFilters = filter ((/=modname) . fst) ofs }
  )

--
-- | Binding to dynamic loader functions (stored as a bundle in state)
-- passed from Boot. DynamicModule goes through here to get at them.
--
ircLoad :: FilePath -> S.Symbol -> LB (S.Module, a)
ircLoad mod sym = do
    s <- get
    let fn  = S.dynload (ircDynLoad s)
    liftIO $ (fn mod sym)

--
-- | Dynamically unload a module
--
ircUnload :: FilePath -> LB ()
ircUnload mod = do
    s <- get
    liftIO $ (S.unload (ircDynLoad s)) (S.Module mod)

------------------------------------------------------------------------

ircSignalConnect :: MonadLB m => String -> Callback -> ModuleT s m ()
ircSignalConnect str f 
    = do s <- get
         let cbs = ircCallbacks s
         case M.lookup str cbs of 
              Nothing -> put (s { ircCallbacks = M.insert str [(?name,f)]    cbs}) 
              Just fs -> put (s { ircCallbacks = M.insert str ((?name,f):fs) cbs}) 

ircInstallOutputFilter :: MonadLB m => OutputFilter -> ModuleT s m ()
ircInstallOutputFilter f = modify $ \s -> 
  s { ircOutputFilters = (?name, f): ircOutputFilters s }

-- | Checks if the given user has admin permissions and excecute the action
--   only in this case.
checkPrivs :: IRCMessage -> String -> IRC () -> IRC ()
checkPrivs msg target f = do
    maybepriv <- gets (\s -> M.lookup (ircNick msg) (ircPrivilegedUsers s) )
    case maybepriv of
       Just _  -> f
       Nothing -> ircPrivmsg target "not enough privileges"

-- | Update the module's private state.
writeMS :: MonadIO m => s -> ModuleT s m ()
writeMS s = liftIO $ writeIORef ?ref $! s

-- | Read the module's private state.
readMS :: MonadIO m => ModuleT s m s
readMS = liftIO $ readIORef ?ref

-- | Modify the module's private state.
modifyMS :: MonadIO m => (s -> s) -> ModuleT s m ()
modifyMS f = liftIO $ do
  s <- readIORef ?ref
  writeIORef ?ref $! f s -- It's a shame there's no modifyIORef'

-- | This datatype allows modules to conviently maintain both global 
--   (i.e. for all clients they're interacting with) and private state.
--   It is implemented on top of readMS\/writeMS.
-- 
-- This simple implementation is linear in the number of private states used.
data GlobalPrivate g p = GP {
  global :: !g,
  private :: ![(String,p)]
}

-- | Creates a @GlobalPrivate@ given the value of the global state. No private
--   state for clients will be created.
mkGlobalPrivate :: g -> GlobalPrivate g p
mkGlobalPrivate g = GP {
  global = g,
  private = []
}

-- | Writes private state.
writePS :: MonadIO m 
  => Int     -- ^ Maximal number of private states to keep
  -> String  -- ^ The target
  -> Maybe p -- ^ @Just x@ writes x in the user's private state, @Nothing@ removes it.
  -> ModuleT (GlobalPrivate g p) m ()
writePS maxSize who mp = do
  state <- readMS
  let newPrivate = take maxSize . maybe id (\x -> ((who,x):)) mp . 
        filter ((/=who) . fst) $ private state
  length newPrivate `seq` writeMS $ state { private = newPrivate }

-- | Reads private state.
readPS :: MonadIO m => String -> ModuleT (GlobalPrivate g p) m (Maybe p)
readPS who = do
  state <- readMS
  let answer = lookup who (private state)
  writePS maxBound who answer
  return answer

-- | Writes global state.
writeGS :: MonadIO m => g -> ModuleT (GlobalPrivate g p) m ()
writeGS g = do
  state <- readMS
  writeMS $ state { global = g }

-- | Reads global state.
readGS :: MonadIO m => ModuleT (GlobalPrivate g p) m g
readGS = global `liftM` readMS


-- | Interpret an expression in the context of a module.
-- Arguments are which map to use (@ircModules@ and @ircCommands@ are
-- the only sensible arguments here), the name of the module\/command,
-- action for the case that the lookup fails, action if the lookup
-- succeeds.
--
withModule :: (Ord k, MonadLB m)
  => (IRCRWState -> Map k ModuleRef)
  -> k
  -> m a 
  -> (forall mod s. Module mod s => mod -> ModuleT s m a)
  -> m a

withModule dict modname def f = do
    maybemod <- gets (M.lookup modname . dict)
    case maybemod of
      Just (ModuleRef m ref name) -> let ?ref = ref; ?name = name in f m
      _                      -> def


getDictKeys :: (MonadState s m) => (s -> Map k a) -> m [k]
getDictKeys dict = gets (M.keys . dict)