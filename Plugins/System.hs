--
-- | System module : IRC control functions
--
module Plugins.System (theModule) where

import Lambdabot
import LBState
import qualified IRC
import Util                     (breakOnGlue,showClean)
import AltTime
import qualified Map as M       (Map,keys,fromList,lookup,union)

import Data.Maybe               (fromMaybe)
import Data.List                ((\\))
import Control.Monad.State      (MonadState(get), gets)
import Control.Monad.Trans      (liftIO)

------------------------------------------------------------------------

newtype SystemModule = SystemModule ()

theModule :: MODULE
theModule = MODULE $ SystemModule ()

instance Module SystemModule ClockTime where
    moduleCmds   _   = M.keys syscmds
    modulePrivs  _   = M.keys privcmds
    moduleHelp _ s   = fromMaybe defaultHelp (M.lookup s $ syscmds `M.union` privcmds)
    moduleDefState _ = liftIO getClockTime
    process      _   = doSystem

------------------------------------------------------------------------

syscmds :: M.Map String String
syscmds = M.fromList
       [("listchans",   "show channels bot has joined")
       ,("listmodules", "show available plugins")
       ,("listcommands","listcommands [module|command]\n"++
                        "show all commands or command for [module]")
       ,("echo",        "echo irc protocol string")
       ,("uptime",      "show uptime")]

privcmds :: M.Map String String
privcmds = M.fromList [
        ("join",        "join <channel>")
       ,("leave",       "leave <channel>")
       ,("part",        "part <channel>")
       ,("msg",         "msg someone")
       ,("quit",        "quit [msg], have the bot exit with msg")
       ,("reconnect",   "reconnect to channel")]

------------------------------------------------------------------------

defaultHelp :: String
defaultHelp = "system : irc management"

doSystem :: IRC.Message -> String -> [Char] -> [Char] -> ModuleT ClockTime LB (Maybe [String])
doSystem msg target cmd rest = get >>= \s -> case cmd of

  "listchans"   -> return $ Just  [pprKeys (ircChannels s)]
  "listmodules" -> return $ Just [pprKeys (ircModules s) ]

  "listcommands" 
        | null rest -> case target of
              ('#':_) -> return $ Just ["use listcommands [module|command]. " ++ 
                                        "Modules are:\n" ++ pprKeys (ircModules s)]
              _       -> listAll >>= return . Just
        | otherwise -> listModule rest >>= return . Just . (:[])

  ------------------------------------------------------------------------

  "join"  -> send (IRC.join rest) >> return Nothing   -- system commands
  "leave" -> send (IRC.part rest) >> return Nothing
  "part"  -> send (IRC.part rest) >> return Nothing

   -- writes to another location:
  "msg"   -> ircPrivmsg tgt txt' >> return Nothing
                  where (tgt, txt) = breakOnGlue " " rest
                        txt'       = dropWhile (== ' ') txt

  "quit" -> do ircQuit $ if null rest then "requested" else rest
               return Nothing

  "reconnect" -> do ircReconnect $ if null rest then "request" else rest
                    return Nothing
  "echo" -> return $ Just [concat ["echo; msg:", show msg, " rest:", show rest]]

  "uptime" -> do
          loaded <- readMS
          now    <- liftIO getClockTime
          let diff = timeDiffPretty $ now `diffClockTimes` loaded
          return $ Just ["uptime: " ++ diff]

------------------------------------------------------------------------

listAll :: LB [String]
listAll = get >>= mapM listModule . M.keys . ircModules

listModule :: String -> LB String
listModule query = withModule ircModules query fromCommand printProvides
  where
    fromCommand = withModule ircCommands query
        (return $ "No module \""++query++"\" loaded")
        printProvides
    
    printProvides m = do
        let cmds = moduleCmds m
        privs <- gets ircPrivCommands
        return $ concat [?name, " provides: ", showClean $ cmds\\privs]

pprKeys :: (Show k) => M.Map k a -> String
pprKeys m = showClean (M.keys m)
