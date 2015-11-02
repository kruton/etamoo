
{-# LANGUAGE OverloadedStrings #-}

module MOO.Database (
    Database
  , ServerOptions(..)
  , serverOptions
  , initDatabase
  , dbObjectRef
  , dbObject
  , maxObject
  , resetMaxObject
  , renumber
  , setObjects
  , addObject
  , deleteObject
  , modifyObject
  , allPlayers
  , setPlayer
  , getServerOption
  , getServerOption'
  , loadServerOptions
  , getServerMessage
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent.STM (STM, TVar, newTVarIO, newTVar,
                               readTVar, writeTVar)
import Control.Monad (forM, forM_, when, (>=>))
import Data.IntSet (IntSet)
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Vector (Vector)

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import qualified Data.IntSet as IS
import qualified Data.Vector as V

import {-# SOURCE #-} MOO.Builtins (builtinFunctions)
import MOO.Object
import MOO.Task
import MOO.Types

import qualified MOO.List as Lst
import qualified MOO.String as Str

data Database = Database {
    objects       :: Vector (TVar (Maybe Object))
  , players       :: IntSet
  , serverOptions :: ServerOptions
}

initDatabase = Database {
    objects       = V.empty
  , players       = IS.empty
  , serverOptions = undefined
}

dbObjectRef :: ObjId -> Database -> Maybe (TVar (Maybe Object))
dbObjectRef oid = (V.!? oid) . objects

dbObject :: ObjId -> Database -> STM (Maybe Object)
dbObject oid = maybe (return Nothing) readTVar . dbObjectRef oid

maxObject :: Database -> ObjId
maxObject = pred . V.length . objects

resetMaxObject :: Database -> STM Database
resetMaxObject db = do
  newMaxObject <- findLastValid (maxObject db)
  return db { objects = V.take (succ newMaxObject) $ objects db }

  where findLastValid :: ObjId -> STM ObjId
        findLastValid oid
          | oid >= 0  = dbObject oid db >>=
                        maybe (findLastValid $ pred oid) (return . const oid)
          | otherwise = return nothing

-- | Renumber an object in the database to be the least nonnegative object
-- number not currently in use pursuant to the renumber() built-in function.
renumber :: ObjId -> Database -> STM (ObjId, Database)
renumber old db = do
  maybeNew <- findLeastUnused 0
  case maybeNew of
    Nothing  -> return (old, db)
    Just new -> do
      -- renumber database slot references
      let Just oldRef = dbObjectRef old db
          Just newRef = dbObjectRef new db
      Just obj <- readTVar oldRef
      writeTVar oldRef Nothing
      writeTVar newRef (Just obj)

      -- ask the object to fix up parent/children and location/contents
      renumberObject obj old new db

      -- fix up ownerships throughout entire database
      forM_ [0..maxObject db] $ \oid -> case dbObjectRef oid db of
        Just ref -> do
          maybeObj <- readTVar ref
          case maybeObj of
            Just obj -> do
              maybeNew <- renumberOwnership old new obj
              when (isJust maybeNew) $ writeTVar ref maybeNew
            Nothing  -> return ()
        Nothing  -> return ()

      -- renumber player references (if any)
      let db' = setPlayer (objectIsPlayer obj) new $ setPlayer False old db

      return (new, db')

  where findLeastUnused :: ObjId -> STM (Maybe ObjId)
        findLeastUnused new
          | new < old = dbObject new db >>= maybe (return $ Just new)
                        (const $ findLeastUnused $ succ new)
          | otherwise = return Nothing

setObjects :: [Maybe Object] -> Database -> IO Database
setObjects objs db = do
  refs <- mapM newTVarIO objs
  return db { objects = V.fromList refs }

addObject :: Object -> Database -> STM Database
addObject obj db = do
  ref <- newTVar (Just obj)
  return db { objects = V.snoc (objects db) ref }

deleteObject :: ObjId -> Database -> STM ()
deleteObject oid db =
  case dbObjectRef oid db of
    Just ref -> writeTVar ref Nothing
    Nothing  -> return ()

modifyObject :: ObjId -> Database -> (Object -> STM Object) -> STM ()
modifyObject oid db f =
  case dbObjectRef oid db of
    Just ref -> readTVar ref >>= maybe (return ()) (f >=> writeTVar ref . Just)
    Nothing  -> return ()

{-
isPlayer :: ObjId -> Database -> Bool
isPlayer oid db = oid `IS.member` players db
-}

allPlayers :: Database -> [ObjId]
allPlayers = IS.toList . players

setPlayer :: Bool -> ObjId -> Database -> Database
setPlayer isPlayer oid db = db { players = change oid (players db) }
  where change | isPlayer  = IS.insert
               | otherwise = IS.delete

data ServerOptions = Options {
    bgSeconds :: Int
    -- ^ The number of seconds allotted to background tasks

  , bgTicks :: Int
    -- ^ The number of ticks allotted to background tasks

  , connectTimeout :: IntT
    -- ^ The maximum number of seconds to allow an un-logged-in in-bound
    -- connection to remain open

  , defaultFlushCommand :: Text
    -- ^ The initial setting of each new connection’s flush command

  , fgSeconds :: Int
    -- ^ The number of seconds allotted to foreground tasks

  , fgTicks :: Int
    -- ^ The number of ticks allotted to foreground tasks

  , maxStackDepth :: Int
    -- ^ The maximum number of levels of nested verb calls

  , queuedTaskLimit :: Maybe Int
    -- ^ The default maximum number of tasks a player can have

  , nameLookupTimeout :: IntT
    -- ^ The maximum number of seconds to wait for a network hostname/address
    -- lookup

  , outboundConnectTimeout :: IntT
    -- ^ The maximum number of seconds to wait for an outbound network
    -- connection to successfully open

  , protectProperty :: Id -> Bool
    -- ^ Restrict reading of built-in property to wizards

  , protectFunction :: Id -> Bool
    -- ^ Restrict use of built-in function to wizards

  , supportNumericVerbnameStrings :: Bool
    -- ^ Enables use of an obsolete verb-naming mechanism
}

getServerOption :: Id -> MOO (Maybe Value)
getServerOption = getServerOption' systemObject

getServerOption' :: ObjId -> Id -> MOO (Maybe Value)
getServerOption' oid option = getServerOptions oid >>= ($ option)

getServerOptions :: ObjId -> MOO (Id -> MOO (Maybe Value))
getServerOptions oid = do
  serverOptions <- readProperty oid "server_options"
  return $ case serverOptions of
    Just (Obj oid) -> readProperty oid . fromId
    _              -> const (return Nothing)

getProtected :: (Id -> MOO (Maybe Value)) -> [Id] -> MOO (Id -> Bool)
getProtected getOption ids = do
  maybes <- forM ids $ fmap (fmap truthOf) . getOption . ("protect_" <>)
  let protectedSet = HS.fromList [ id | (id, Just True) <- zip ids maybes ]
  return (`HS.member` protectedSet)

loadServerOptions :: MOO ()
loadServerOptions = do
  option <- getServerOptions systemObject

  bgSeconds <- option "bg_seconds"
  bgTicks   <- option "bg_ticks"
  fgSeconds <- option "fg_seconds"
  fgTicks   <- option "fg_ticks"

  maxStackDepth   <- option "max_stack_depth"
  queuedTaskLimit <- option "queued_task_limit"

  connectTimeout         <- option "connect_timeout"
  outboundConnectTimeout <- option "outbound_connect_timeout"
  nameLookupTimeout      <- option "name_lookup_timeout"

  defaultFlushCommand <- option "default_flush_command"

  supportNumericVerbnameStrings <- option "support_numeric_verbname_strings"

  protectProperty <- getProtected option builtinProperties
  protectFunction <- getProtected option (HM.keys builtinFunctions)

  let options = Options {
          bgSeconds = case bgSeconds of
             Just (Int secs) | secs >= 1 -> fromIntegral secs
             _                           -> defaultBgSeconds
        , bgTicks = case bgTicks of
             Just (Int ticks) | ticks >= 100 -> fromIntegral ticks
             _                               -> defaultBgTicks
        , fgSeconds = case fgSeconds of
             Just (Int secs) | secs >= 1 -> fromIntegral secs
             _                           -> defaultFgSeconds
        , fgTicks = case fgTicks of
             Just (Int ticks) | ticks >= 100 -> fromIntegral ticks
             _                               -> defaultFgTicks

        , maxStackDepth = case maxStackDepth of
             Just (Int depth) | depth > 50 -> fromIntegral depth
             _                             -> defaultMaxStackDepth
        , queuedTaskLimit = case queuedTaskLimit of
             Just (Int limit) | limit >= 0 -> Just (fromIntegral limit)
             _                             -> Nothing

        , connectTimeout = case connectTimeout of
             Just (Int secs) | secs > 0 -> secs
             _                          -> 300
        , outboundConnectTimeout = case outboundConnectTimeout of
             Just (Int secs) | secs > 0 -> secs
             _                          -> 5
        , nameLookupTimeout = case nameLookupTimeout of
             Just (Int secs) | secs >= 0 -> secs
             _                           -> 5

        , defaultFlushCommand = case defaultFlushCommand of
             Just (Str cmd) -> Str.toText cmd
             Just _         -> ""
             Nothing        -> ".flush"

        , supportNumericVerbnameStrings =
             maybe False truthOf supportNumericVerbnameStrings

        , protectProperty = protectProperty
        , protectFunction = protectFunction
        }

  db <- getDatabase
  putDatabase db { serverOptions = options }

getServerMessage :: ObjId -> Id -> MOO [Text] -> MOO [Text]
getServerMessage oid msg def = do
  maybeValue <- getServerOption' oid msg
  case maybeValue of
    Just (Str s) -> return [Str.toText s]
    Just (Lst v) -> maybe (return []) return $ strings (Lst.toList v)
    Just _       -> return []
    Nothing      -> def
  where strings :: [Value] -> Maybe [Text]
        strings (v:vs) = case v of
          Str s -> (Str.toText s :) <$> strings vs
          _     -> Nothing
        strings [] = Just []
