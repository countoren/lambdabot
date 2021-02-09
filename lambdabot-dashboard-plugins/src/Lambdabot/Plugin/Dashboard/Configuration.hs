module Lambdabot.Plugin.Dashboard.Configuration (
  DashboardState (..),
  WatcherUniqueIdentifier,
  WatcherSystemIdentifier,
  MessageUniqueIdentifier,
  ChannelName,
  WatcherName,
  EmoteUniqueIdentifier,
  EmoteStartPosition,
  EmoteEndPosition,
  MessageText,
  BadgeName,
  BadgeVersion,
  Watcher,
  EmotePosition,
  Message,
  Badge,
  Watching,
  Channel,
  Spoken,
) where

-- Currently Twitch centric

type WatcherSystemIdentifier = Maybe Int
type WatcherUniqueIdentifier = String
type MessageUniqueIdentifier = String
type ChannelName = String
type WatcherName = String
type EmoteUniqueIdentifier = Int
type EmoteStartPosition = Int
type EmoteEndPosition = Int
type MessageText = String
type BadgeName = String
type BadgeVersion = Int

type Watcher = (WatcherUniqueIdentifier, WatcherName, WatcherSystemIdentifier)
type Badge = (BadgeName, BadgeVersion)
type Watching = (WatcherName, [Badge])
type Channel = (ChannelName, [Watching])

type EmotePosition = (EmoteUniqueIdentifier, EmoteStartPosition, EmoteEndPosition)
type Message = (MessageUniqueIdentifier, WatcherName, MessageText, [EmotePosition])
type Spoken = (ChannelName, [MessageUniqueIdentifier])

data DashboardState = MkDashboardState
  { focusedChannel :: ChannelName
  , shutdown :: Bool
  , watchers :: [Watcher]
  , watching :: [Channel]
  , messages :: [Message]
  , speaking :: [Spoken]
  }
  deriving (Read, Show)
