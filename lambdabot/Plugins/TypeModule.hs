--
-- |   The Type Module - another progressive plugin for lambdabot
--
-- pesco hamburg 2003-04-05
--
--     Greetings reader,
--
--     whether you're a regular follower of the series or dropping in for
--     the first time, let me present for your pleasure the Type Module:
--
--     One thing we enjoy on #haskell is throwing function types at each
--     other instead of spelling out tiresome monologue about arguments
--     or return values. Unfortunately such a toss often involves a local
--     lookup of the type signature in question because one is seldom
--     sure about the actual argument order.
--
--     Well, what do you know, this plugin enables lambdabot to automate
--     that lookup for you and your fellow lambda hackers.
--
module Plugins.TypeModule (theModule) where

import IRC
import Util                 (expandTab)
import PosixCompat          (popen)
import Maybe (mapMaybe)
import Control.Monad.Trans (liftIO)
import Text.Regex          (Regex, mkRegexWithOpts, matchRegex)

--     In accordance with the KISS principle, the plan is to delegate all
--     the hard work! To get the type of foo, pipe

command :: [Char] -> [Char] -> [Char]
command cmd foo = cmd ++ " " ++ foo

--     into hugs and send any line matching

signature_regex :: Regex
signature_regex
    = mkRegexWithOpts
      "^(\\*?[A-Z][_a-zA-Z0-9]*(\\*?[A-Z][_a-zA-Z0-9]*)*>)? *(.*[	-=:].*)"
      True True

--     through IRC.

{-
result_regex :: Regex
result_regex
    = mkRegexWithOpts
      "^\\*?[A-Z][_a-zA-Z0-9]*(\\*?[A-Z][_a-zA-Z0-9]*)*> (.*)" True True
-}

--
--     To get any signature line from the hugs output, split it into lines,
--     match each against the regex, and take the last substring match from
--     each successfull match.
--
extract_signatures :: String -> [String]
extract_signatures output
        = map expandTab $ map last.mapMaybe (matchRegex signature_regex) $
                 (reverse $ tail $ reverse $ drop 7 $ lines output)

{-
extract_result :: String -> [String]
extract_result output
        = head (map last.mapMaybe (matchRegex result_regex) $ (lines output)) : []
-}

--
--     With this the command handler can be easily defined using popen:
--
query_ghci :: String -> String -> String -> IRC ()
query_ghci src cmd expr =
       do
       (output, _, _) <- liftIO $ popen "ghci-6.4" ["-fglasgow-exts"]
			                  (Just (command cmd expr))
       mapM_ (ircPrivmsg src) $
                let ls = extract_signatures output
                in if null ls then ["bzzt"] else ls

{-
--
--     With this the command handler can be easily defined using popen:
--
run_ghci :: String -> String -> IRC ()
run_ghci src expr =
       do
       (output, _, _) <- liftIO $ popen "ghci" [] (Just expr)
       mapM_ (ircPrivmsg src) (extract_result output)
-}

--
--     And thus the plugin:
--
newtype TypeModule = TypeModule ()

theModule :: MODULE
theModule = MODULE $ TypeModule ()

instance Module TypeModule () where
     moduleHelp _ "type" = return "@type: return the type of a value"
     moduleHelp _ "kind" = return "@kind: return the kind of a type (GHC)"
     moduleHelp _ _      = return "@type,@kind: interact with the typechecker"
     moduleCmds        _ = return ["type", "kind"]
     process _ _ src "type" expr = query_ghci src ":t" expr
     process _ _ src "kind" expr = query_ghci src ":k" expr
--   process _ _ src "info" expr = query_ghci src ":info" expr
     process _ _ _ _ _ = error "TypeModule: invalid cmd"
