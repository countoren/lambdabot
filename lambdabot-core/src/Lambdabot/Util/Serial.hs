{-# LANGUAGE FlexibleInstances #-}

{- Copyright (c) 2004-5 Thomas Jaeger, Don Stewart

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License as
published by the Free Software Foundation; either version 2 of
the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
02111-1307, USA. -}

-- | Serialisation
module Lambdabot.Util.Serial (
  Serial (..),
  stdSerial,
  mapSerial,
  mapPackedSerial,
  assocListPackedSerial,
  mapListPackedSerial,
  readM,
  Packable {- instances of Packable -} (..),
  readOnly,
  readPackedEntry,
) where

import Codec.Compression.GZip (compress, decompress)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as P
import Data.ByteString.Lazy (fromChunks, toChunks)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (mapMaybe)

------------------------------------------------------------------------

-- A flexible (moreso than a typeclass) way to define introduction and
-- elimination for persistent state on a per-module basis.
--
data Serial s = Serial
  { serialize :: s -> Maybe ByteString
  , deserialize :: ByteString -> Maybe s
  }

gzip :: ByteString -> ByteString
gzip = P.concat . toChunks . compress . fromChunks . (: [])

gunzip :: ByteString -> ByteString
gunzip = P.concat . toChunks . decompress . fromChunks . (: [])

--
-- read-only serialisation
--
readOnly :: (ByteString -> b) -> Serial b
readOnly f = Serial (const Nothing) (Just . f)

-- | Default `instance' for a Serial
stdSerial :: (Show s, Read s) => Serial s
stdSerial = Serial (Just . P.pack . show) (readM . P.unpack)

{- | Serializes a 'Map' type if both the key and the value are instances
 of Read and Show. The serialization is done by converting the map to
 and from lists. Results are saved line-wise, for better editing and
 revision control.
-}
mapSerial :: (Ord k, Show k, Show v, Read k, Read v) => Serial (Map k v)
mapSerial =
  Serial
    { serialize = Just . P.pack . unlines . map show . M.toList
    , deserialize = Just . M.fromList . mapMaybe (readM . P.unpack) . P.lines
    }

------------------------------------------------------------------------

{- | 'readM' behaves like read, but catches failure in a monad.
 this allocates a 20-30 M on startup...
-}
readM :: (MonadFail m, Read a) => String -> m a
readM s = case [ x | (x, t) <- {-# SCC "Serial.readM.reads" #-} reads s, ("", "") <- lex t -- bad!
               ] of
  [x] -> return x
  [] -> fail "Serial.readM: no parse"
  _ -> fail "Serial.readM: ambiguous parse"

class Packable t where
  readPacked :: ByteString -> t
  showPacked :: t -> ByteString

{- | An instance for Map Packed [Packed]
 uses gzip compression
-}
instance Packable (Map ByteString [ByteString]) where
  readPacked ps = M.fromList (readKV (P.lines . gunzip $ ps))
   where
    readKV :: [ByteString] -> [(ByteString, [ByteString])]
    readKV [] = []
    readKV (k : rest) = let (vs, rest') = break (== P.empty) rest in (k, vs) : readKV (drop 1 rest')

  showPacked m = gzip . P.unlines . concatMap (\(k, vs) -> k : vs ++ [P.empty]) $ M.toList m

-- assumes single line second strings
instance Packable (Map ByteString ByteString) where
  readPacked ps = M.fromList $ readPackedEntry (splitAt 2) (\(k : v : _) -> (k, v)) (P.lines . gunzip $ ps)
  showPacked m = gzip . P.unlines . concatMap (\(k, v) -> [k, v]) $ M.toList m

instance Packable [(ByteString, ByteString)] where
  readPacked ps = readPackedEntry (splitAt 2) (\(k : v : _) -> (k, v)) (P.lines . gunzip $ ps)
  showPacked = gzip . P.unlines . concatMap (\(k, v) -> [k, v])

instance Packable (M.Map ByteString (Bool, [(String, Int)])) where
  readPacked = M.fromList . readPackedEntry (splitAt 2) (\(k : v : _) -> (k, read . P.unpack $ v)) . P.lines
  showPacked m = P.unlines . concatMap (\(k, v) -> [k, P.pack . show $ v]) $ M.toList m

readPackedEntry :: ([ByteString] -> ([ByteString], [ByteString])) -> ([ByteString] -> a) -> [ByteString] -> [a]
readPackedEntry _ _ [] = []
readPackedEntry e f list = f params : readPackedEntry e f rest
 where
  (params, rest) = e list
readPackedEntry _ _ _ = error "Serial.readPacked: parse failed"

-- And for packed string maps
mapPackedSerial :: Serial (Map ByteString ByteString)
mapPackedSerial = Serial (Just . showPacked) (Just . readPacked)

-- And for list of packed string maps
mapListPackedSerial :: Serial (Map ByteString [ByteString])
mapListPackedSerial = Serial (Just . showPacked) (Just . readPacked)

-- And for association list
assocListPackedSerial :: Serial [(ByteString, ByteString)]
assocListPackedSerial = Serial (Just . showPacked) (Just . readPacked)

------------------------------------------------------------------------
