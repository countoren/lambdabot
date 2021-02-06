module Lambdabot.Plugin.Story.Story (storyPlugin) where

import Lambdabot.Config.Story (defaultStories, secondsToWaitBeforeMovingToTheNextWord)
import Lambdabot.IRC (IrcMessage (IrcMessage), MessageDirection (Outbound), ircDirection, ircMsgCommand, ircMsgLBName, ircMsgParams, ircMsgPrefix, ircMsgServer, ircTags)
import Lambdabot.Monad (send)
import Lambdabot.Plugin (
  Cmd,
  LB,
  Module,
  ModuleT,
  MonadConfig (getConfig),
  aliases,
  command,
  contextual,
  help,
  moduleCmds,
  moduleDefState,
  moduleInit,
  moduleSerialize,
  nName,
  nTag,
  newModule,
  privileged,
  process,
  say,
  stdSerial,
  withMS,
  withMsg,
 )
import Lambdabot.Plugin.Story.Configuration (Definition, GameState (..), StoryState (..), Vote, newGameState, newStoryState)
import Lambdabot.Util (io, randomElem)

import Control.Concurrent.Lifted (fork, threadDelay)
import Control.Monad.Reader (MonadTrans (lift), unless, void, when)
import Data.Either (fromLeft, fromRight)
import Data.List (findIndex, isPrefixOf, partition)
import Data.List.Split (splitOn, splitWhen)
import Data.Maybe (fromJust)
import GHC.Int (Int64)
import Lambdabot.Logging (debugM)
import qualified Lambdabot.Message as Msg

type Story = ModuleT StoryState LB

storyPlugin :: Module StoryState
storyPlugin =
  newModule
    { moduleSerialize = Just stdSerial
    , moduleDefState = do
        initialStories <- getConfig defaultStories
        newStoryState initialStories
    , moduleInit = return ()
    , moduleCmds =
        return
          [ (command "story")
              { help = say "story - Start a random story."
              , aliases = ["story-time"]
              , process = commandStartStory
              , privileged = True
              }
          , (command "add-story")
              { help = say "add-story <story> <definition> - Add a new story to the database."
              , process = commandAddStory
              , privileged = True
              }
          , (command "remove-story")
              { aliases = ["rm-story"]
              , help = say "remove-story <story> - Remove a story from the database."
              , process = commandRemoveStory
              , privileged = True
              }
          , (command "reset-story")
              { aliases = ["rst-story"]
              , help = say "reset-story <story> - Reset active stories."
              , process = commandResetStory
              , privileged = True
              }
          ]
    , contextual = commandContextual
    }

-- TODO: Fork a background thread here?
commandContextual :: String -> Cmd Story ()
commandContextual txt =
  let wrds = words txt
      oneWord = length wrds == 1
   in when oneWord $
        withMsg $ \msg ->
          let srvr = Msg.server msg
              chan = head $ Msg.channels msg
              channelName = srvr ++ nTag chan ++ nName chan
           in withMS $ \storyState writer ->
                let (game, other) = extractGame channelName storyState
                 in unless (null game) $
                      writer
                        storyState
                          { games = addVote (head wrds) (head game) : other
                          }

-- check that the word exists in the wordnet database
-- determine the type of the word
-- if the word is the same type as the next word in the story

addVote :: String -> (String, GameState) -> (String, GameState)
addVote word (channelName, gameState) =
  let (same, other) = partition ((==) word . fst) $ votes gameState
      newScore =
        if null same
          then [(word, 1)]
          else [(word, 1 + snd (head same))]
   in (channelName, gameState{votes = newScore ++ other})

extractGame :: String -> StoryState -> ([(String, GameState)], [(String, GameState)])
extractGame channelName = partition ((==) channelName . fst) . games

commandStartStory :: String -> Cmd Story ()
commandStartStory _ = withMsg $ \msg ->
  let srvr = Msg.server msg
      chan = head $ Msg.channels msg
      sndr = Msg.nick msg
      botn = Msg.lambdabotName msg
   in withMS $ \storyState writer ->
        let channelName = srvr ++ nTag chan ++ nName chan
            (game, other) = extractGame channelName storyState
         in when (null game) $ do
              delay <- getConfig secondsToWaitBeforeMovingToTheNextWord
              sts <- io $ randomElem $ stories storyState
              let newGame = newGameState srvr chan botn sts
              writer storyState{games = (channelName, newGame) : other}
              say $ "Let's make a story together, I will title it '" ++ fst sts ++ "'."
              say $ nextNeed $ fromLeft ("", "") $ nextWord newGame
              void $ lift $ fork $ storyLoop delay channelName

nextWord :: GameState -> Either (String, String) String
nextWord gameState =
  let stry = story gameState
      text = snd stry
      wrds = words text
      fillIn = filter ("__" `isPrefixOf`) wrds
   in if null fillIn
        then Right text
        else
          let parts = splitOn ":" $ init $ init $ tail $ tail $ head fillIn
           in if length parts == 1 then Left (head parts, []) else Left (head parts, last parts)

nextNeed :: (String, String) -> String
nextNeed (wordType, wordSubType) =
  let subType = if not $ null wordSubType then ", specifically a " ++ wordSubType else ""
   in "I need a " ++ wordType ++ subType ++ ", type your choice now..."

highestVote :: (String, String) -> (String, Int) -> String
highestVote (wordType, wordSubType) (wrd, num) =
  let subType = if not $ null wordSubType then " (" ++ wordSubType ++ ")" else ""
   in "The most popular " ++ wordType ++ subType ++ " was '" ++ wrd ++ "' with " ++ show num ++ " votes."

storyLoop :: Int -> String -> Story ()
storyLoop delayInSeconds channelName = do
  void $ io $ threadDelay $ delayInSeconds * 1000 * 1000
  withMS $ \storyState writer -> do
    let (game, other) = extractGame channelName storyState
    unless (null game) $
      let gameState = snd $ head game
          title = fst $ story gameState
       in case nextWord gameState of
            Left needed -> do
              let mostVoted = foldr (\l r -> if snd l > snd r then l else r) ("", 0) $ votes gameState
              let updatedGameState = gameState{votes = [], story = replace mostVoted $ story gameState}
              writer $
                storyState
                  { games = (channelName, updatedGameState) : other
                  }
              lift $ sendText gameState $ highestVote needed mostVoted
              case nextWord updatedGameState of
                Left need -> do
                  lift $ sendText gameState $ nextNeed need
                  void $ fork $ storyLoop delayInSeconds channelName
                Right _ -> do
                  lift $ sendText gameState "All done! Sending the story to the publisher! Get ready..."
                  void $ fork $ storyLoop 5 channelName
            Right stry -> do
              lift $ sendText gameState $ "This is the story we made!  Title: '" ++ title ++ "' Story: " ++ stry
              writer $
                storyState
                  { games = other
                  }

replace :: ([Char], Int) -> Definition -> Definition
replace (wrd, _) (ttl, stry) =
  let wrds = words stry
      location = fromJust $ findIndex ("__" `isPrefixOf`) wrds
      (before, after) = splitAt location wrds
      replaced = unwords $ before ++ [wrd] ++ tail after
   in (ttl, replaced)

sendText :: GameState -> String -> LB ()
sendText gameState text = do
  send
    IrcMessage
      { ircMsgServer = server gameState
      , ircMsgLBName = name gameState
      , ircMsgPrefix = botName gameState ++ "!n=" ++ botName gameState ++ "@" ++ botName gameState ++ ".tmi.twitch.tv"
      , ircMsgCommand = "PRIVMSG"
      , ircMsgParams = [channel gameState, ":" ++ text]
      , ircDirection = Outbound
      , ircTags = []
      }

commandAddStory :: String -> Cmd Story ()
commandAddStory msg = say msg

commandRemoveStory :: String -> Cmd Story ()
commandRemoveStory msg = say msg

commandResetStory :: String -> Cmd Story ()
commandResetStory _ = withMS $ \storyState writer -> do
  writer
    storyState
      { games = []
      }

parseStory :: String -> Either (String, String) String
parseStory input = Right input

updateStory :: String -> [Vote] -> String
updateStory input votes = input