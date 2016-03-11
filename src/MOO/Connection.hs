
{-# LANGUAGE OverloadedStrings #-}

module MOO.Connection (
    Connection
  , ConnectionHandler
  , Disconnect(..)
  , connectionHandler
  , connectionListener
  , doDisconnected

  , firstConnectionId

  , withConnections
  , withConnection
  , withMaybeConnection

  , connectionName
  , connectionConnectedTime
  , connectionActivityTime
  , connectionOutputDelimiters

  , sendToConnection
  , closeConnection

  , readFromConnection

  , notify
  , notify'

  , bufferedOutputLength
  , forceInput
  , flushInput

  , bootPlayer
  , bootPlayer'

  , setConnectionOption
  , getConnectionOptions

  , proxyConnection
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, newEmptyMVar, takeMVar, putMVar)
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (STM, TVar, TMVar, atomically, newTVar, newTVarIO,
                               newEmptyTMVar, newEmptyTMVarIO, takeTMVar,
                               putTMVar, tryPutTMVar, tryTakeTMVar,
                               readTVar, writeTVar, modifyTVar, swapTVar,
                               readTVarIO, check)
import Control.Concurrent.STM.TBMQueue (TBMQueue, newTBMQueue, newTBMQueueIO,
                                        readTBMQueue, writeTBMQueue,
                                        tryReadTBMQueue, tryWriteTBMQueue,
                                        unGetTBMQueue, isEmptyTBMQueue,
                                        freeSlotsTBMQueue, closeTBMQueue)
import Control.Exception (SomeException, try, bracket, catch)
import Control.Monad ((<=<), join, when, unless, foldM, forever, void)
import Control.Monad.Cont (callCC)
import Control.Monad.Reader (asks)
import Control.Monad.State (get, modify)
import Control.Monad.Trans (lift)
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.Map (Map)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Text.Encoding (Decoding(Some), encodeUtf8, streamDecodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Database.VCache (runVTx)
import Pipes (Producer, Consumer, Pipe, await, yield, runEffect,
              for, cat, (>->))
import Pipes.Concurrent (send, spawn, unbounded, fromInput, toOutput)

import qualified Data.ByteString as BS
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Database.VCache as DV

import MOO.Command
import MOO.Database
import MOO.Object
import MOO.Task
import MOO.Types

import qualified MOO.List as Lst
import qualified MOO.String as Str

data Connection = Connection {
    connectionListener         :: ObjId
  , connectionPlayer           :: TVar ObjId
  , connectionPrintMessages    :: Bool

  , connectionInput            :: TBMQueue StrT
  , connectionOutput           :: TBMQueue ConnectionMessage

  , connectionName             :: ConnectionName
  , connectionConnectedTime    :: TVar (Maybe UTCTime)
  , connectionActivityTime     :: TVar UTCTime
  , connectionTimeout          :: Async ()

  , connectionOutputDelimiters :: TVar (Text, Text)
  , connectionOptions          :: TVar ConnectionOptions

  , connectionReader           :: TMVar Wake
  , connectionDisconnect       :: TMVar Disconnect
  }

data ConnectionMessage = Line Text | Binary ByteString

data ConnectionOptions = ConnectionOptions {
    optionBinaryMode        :: Bool
  , optionHoldInput         :: Bool
  , optionDisableOOB        :: Bool
  , optionClientEcho        :: Bool
  , optionFlushCommand      :: Text
  , optionIntrinsicCommands :: Map Text IntrinsicCommand
  }

initConnectionOptions = ConnectionOptions {
    optionBinaryMode        = False
  , optionHoldInput         = False
  , optionDisableOOB        = False
  , optionClientEcho        = True
  , optionFlushCommand      = ".flush"
  , optionIntrinsicCommands = allIntrinsicCommands
  }

data ConnectionOption = Option {
    optionName :: Id
  , optionGet  :: ConnectionOptions -> Value
  , optionSet  :: Connection -> Value ->
                  ConnectionOptions -> MOO ConnectionOptions
  }

coBinary = Option "binary" get set
  where get = truthValue . optionBinaryMode
        set _ v options = return options { optionBinaryMode = truthOf v }

coHoldInput = Option "hold-input" get set
  where get = truthValue . optionHoldInput
        set _ v options = return options { optionHoldInput = truthOf v }

coDisableOOB = Option "disable-oob" get set
  where get = truthValue . optionDisableOOB
        set _ v options = return options { optionDisableOOB = truthOf v }

coClientEcho = Option "client-echo" get set
  where get = truthValue . optionClientEcho
        set conn v options = do
          let clientEcho = truthOf v
              telnetCommand = BS.pack [telnetIAC, telnetOption, telnetECHO]
              telnetOption  = if clientEcho then telnetWON'T else telnetWILL
          liftSTM $ enqueueOutput False conn (Binary telnetCommand)
          return options { optionClientEcho = clientEcho }

          where telnetIAC   = 255
                telnetWILL  = 251
                telnetWON'T = 252
                telnetECHO  = 1

coFlushCommand = Option "flush-command" get set
  where get = Str . Str.fromText . optionFlushCommand
        set _ v options = do
          let flushCommand = case v of
                Str flush -> Str.toText flush
                _         -> T.empty
          return options { optionFlushCommand = flushCommand }

coIntrinsicCommands = Option "intrinsic-commands" get set
  where get = fromListBy (Str . Str.fromText) . M.keys . optionIntrinsicCommands
        set _ v options = do
          commands <- case v of
            Lst vs -> foldM addCommand M.empty (Lst.toList vs)
            Int 0  -> return M.empty
            Int _  -> return allIntrinsicCommands
            _      -> raise E_INVARG

          return options { optionIntrinsicCommands = commands }

        addCommand :: Map Text IntrinsicCommand -> Value
                   -> MOO (Map Text IntrinsicCommand)
        addCommand cmds value = case value of
          Str cmd -> do
            ic <- maybe (raise E_INVARG) return $
                  M.lookup (Str.toText cmd) allIntrinsicCommands
            return $ M.insert (intrinsicCommand ic) ic cmds
          _ -> raise E_INVARG

allConnectionOptions :: Map Id ConnectionOption
allConnectionOptions = M.fromList $ map assoc connectionOptions
  where assoc co = (optionName co, co)
        connectionOptions = [
            coBinary
          , coHoldInput
          , coDisableOOB
          , coClientEcho
          , coFlushCommand
          , coIntrinsicCommands
          ]

data IntrinsicCommand = Intrinsic {
    intrinsicCommand       :: Text
  , intrinsicFunction      :: Connection -> Text -> IO ()
  }

modifyOutputDelimiters :: Connection -> ((Text, Text) -> (Text, Text)) -> IO ()
modifyOutputDelimiters conn =
  atomically . modifyTVar (connectionOutputDelimiters conn)

icPREFIX = Intrinsic "PREFIX" $ \conn prefix ->
  modifyOutputDelimiters conn $ \(_, suffix) -> (prefix, suffix)

icSUFFIX = Intrinsic "SUFFIX" $ \conn suffix ->
  modifyOutputDelimiters conn $ \(prefix, _) -> (prefix, suffix)

icOUTPUTPREFIX = icPREFIX { intrinsicCommand = "OUTPUTPREFIX" }
icOUTPUTSUFFIX = icSUFFIX { intrinsicCommand = "OUTPUTSUFFIX" }

icProgram = Intrinsic ".program" $ \conn argstr ->
  -- XXX verify programmer
  atomically $ sendToConnection conn ".program: Not yet implemented"  -- XXX

allIntrinsicCommands :: Map Text IntrinsicCommand
allIntrinsicCommands = M.fromList $ map assoc intrinsicCommands
  where assoc ic = (intrinsicCommand ic, ic)
        intrinsicCommands = [
            icPREFIX
          , icSUFFIX
          , icOUTPUTPREFIX
          , icOUTPUTSUFFIX
          , icProgram
          ]

maxQueueLength :: Int
maxQueueLength = 512

outOfBandQuotePrefix :: Text
outOfBandQuotePrefix = "#$\""

outOfBandPrefix :: Text
outOfBandPrefix = "#$#"

isOOBQuoted :: Text -> Bool
isOOBQuoted = (outOfBandQuotePrefix `T.isPrefixOf`)

isOOB :: Text -> Bool
isOOB = (outOfBandPrefix `T.isPrefixOf`)

type ConnectionName = STM String
type ConnectionHandler = ConnectionName -> (Producer ByteString IO (),
                                            Consumer ByteString IO ()) -> IO ()

data Disconnect = Disconnected | ClientDisconnected

connectionHandler :: TVar World -> ObjId -> Bool -> ConnectionHandler
connectionHandler world' listener printMessages connectionName (input, output) =
  bracket newConnection deleteConnection $ \conn -> do
    forkIO $ runConnection world' conn

    forkIO $ do
      try (runEffect $ input >-> connectionRead conn) >>=
        either (\err -> let _ = err :: SomeException in return ()) return
      atomically $ do
        tryPutTMVar (connectionDisconnect conn) ClientDisconnected
        closeTBMQueue (connectionOutput conn)

    runEffect $ connectionWrite conn >-> output
    atomically $ do
      tryPutTMVar (connectionDisconnect conn) Disconnected
      closeTBMQueue (connectionInput conn)

  where newConnection :: IO Connection
        newConnection = do
          now <- getCurrentTime
          vspace <- persistenceVSpace . persistence <$> readTVarIO world'

          timeoutConnection <- newEmptyMVar
          timeoutAsync <- async $ do
            conn <- takeMVar timeoutConnection
            timeout <- runTask =<< newTask world' nothing
              (getConnectTimeout' listener)
            case timeout >>= toMicroseconds of
              Just usecs | usecs > 0 -> do
                delay usecs
                player <- readTVarIO (connectionPlayer conn)
                let comp = do
                      world <- getWorld
                      connName <- liftSTM connectionName
                      liftSTM $ writeLog world $ "TIMEOUT: #" <>
                        T.pack (show player) <> " on " <> T.pack connName
                      printMessage conn timeoutMsg
                      liftSTM $ closeConnection conn
                      liftVTx $ updateConnections world' $ M.delete player
                      return zero
                void $ runTask =<< newTask world' player comp
              _ -> return ()

          connection <- runVTx vspace $ do
            (world, connectionId, nextId,
             connection, inputQueue) <- DV.liftSTM $ do

              world <- readTVar world'
              let connectionId = nextConnectionId world

              name <- connectionName
              writeLog world $ "ACCEPT: " <> toText (Obj connectionId) <>
                " on " <> T.pack name

              playerVar     <- newTVar connectionId

              inputQueue    <- newTBMQueue maxQueueLength
              outputQueue   <- newTBMQueue maxQueueLength

              cTimeVar      <- newTVar Nothing
              aTimeVar      <- newTVar now

              delimsVar     <- newTVar (T.empty, T.empty)
              optionsVar    <- newTVar initConnectionOptions {
                optionFlushCommand = defaultFlushCommand $
                                     serverOptions (database world) }

              readerVar     <- newEmptyTMVar
              disconnectVar <- newEmptyTMVar

              let connection = Connection {
                      connectionListener         = listener
                    , connectionPlayer           = playerVar
                    , connectionPrintMessages    = printMessages

                    , connectionInput            = inputQueue
                    , connectionOutput           = outputQueue

                    , connectionName             = connectionName
                    , connectionConnectedTime    = cTimeVar
                    , connectionActivityTime     = aTimeVar
                    , connectionTimeout          = timeoutAsync

                    , connectionOutputDelimiters = delimsVar
                    , connectionOptions          = optionsVar

                    , connectionReader           = readerVar
                    , connectionDisconnect       = disconnectVar
                    }
                  nextId = succConnectionId
                           (`M.member` connections world) connectionId

              return (world, connectionId, nextId, connection, inputQueue)

            DV.liftSTM $ writeTVar world' world { nextConnectionId = nextId }
            updateConnections world' $ M.insert connectionId connection

            DV.liftSTM $ writeTBMQueue inputQueue Str.empty

            return connection

          putMVar timeoutConnection connection
          return connection

        deleteConnection :: Connection -> IO ()
        deleteConnection conn = do
          how <- atomically $ takeTMVar (connectionDisconnect conn)
          player <- readTVarIO (connectionPlayer conn)
          doDisconnected world' listener player how
          case how of
            ClientDisconnected -> do
              let comp = do
                    world <- getWorld
                    connName <- liftSTM connectionName
                    objectName <- getObjectName player
                    liftSTM $ writeLog world $ "CLIENT DISCONNECTED: " <>
                      Str.toText objectName <> " on " <> T.pack connName
                    return zero
              void $ runTask =<< newTask world' player comp
            _ -> return ()

doDisconnected :: TVar World -> ObjId -> ObjId -> Disconnect -> IO ()
doDisconnected world' listener player how = do
  let systemVerb = case how of
        Disconnected       -> "user_disconnected"
        ClientDisconnected -> "user_client_disconnected"
      comp = do
        liftVTx $ updateConnections world' $ M.delete player
        fromMaybe zero <$>
          callSystemVerb' listener systemVerb [Obj player] Str.empty
  void $ runTask =<< newTask world' player (resetLimits True >> comp)

runConnection :: TVar World -> Connection -> IO ()
runConnection world' conn = loop

  where loop :: IO ()
        loop = do
          (options, band, reader) <- atomically $ do
            options <- readTVar     (connectionOptions conn)
            input   <- readTBMQueue (connectionInput   conn)

            let band = maybe (Right Nothing)
                             (fmap Just . inputBand options) input
            reader <- if isRight band then tryTakeTMVar (connectionReader conn)
                      else return Nothing

            when (isJust input && isRight band && isNothing reader) $
              check (not $ optionHoldInput options)
            return (options, band, reader)

          either processOutOfBand (processInBand options reader) band

        processOutOfBand :: StrT -> IO ()
        processOutOfBand input = doOutOfBandCommand input >> loop

        processInBand :: ConnectionOptions -> Maybe Wake -> Maybe StrT -> IO ()
        processInBand options reader input =
          case (input, reader) of
            (Just input, Nothing         ) -> doCommand options input  >> loop
            (Just input, Just (Wake wake)) -> wake         (Str input) >> loop
            (Nothing   , Just (Wake wake)) -> wake         (Err E_INVARG)
            (Nothing   , Nothing         ) -> return ()

        doOutOfBandCommand :: StrT -> IO ()
        doOutOfBandCommand input = void $
          runServerVerb' "do_out_of_band_command" (cmdWords input) input

        doCommand :: ConnectionOptions -> StrT -> IO ()
        doCommand options line = do
          player <- readTVarIO (connectionPlayer conn)
          if player < 0 then doLoginCommand line
            else do
            let cmd = parseCommand (Str.toText line)
            case M.lookup (Str.toText $ commandVerb cmd)
                 (optionIntrinsicCommands options) of
              Just Intrinsic { intrinsicFunction = runIntrinsic } ->
                runIntrinsic conn (Str.toText $ commandArgStr cmd)
              Nothing -> do
                (prefix, suffix) <- readTVarIO (connectionOutputDelimiters conn)
                let maybeSend delim = unless (T.null delim) $
                                      sendToConnection conn delim
                void $ runServerTask $ do
                  liftSTM $ maybeSend prefix
                  delayIO $ atomically $ maybeSend suffix
                  -- XXX it would be better to send the suffix as part of the
                  -- atomic command, but we don't currently have a way of
                  -- ensuring anything is run after an uncaught exception
                  result <- callSystemVerb "do_command" (cmdWords line) line
                  case result of
                    Just value | truthOf value -> return zero
                    _                          -> runCommand cmd

        doLoginCommand :: StrT -> IO ()
        doLoginCommand line = do
          result <- runServerTask $ do
            maxObject <- maxObject <$> getDatabase
            player <- fromMaybe zero <$>
                      callSystemVerb "do_login_command" (cmdWords line) line
            return $ fromList [Obj maxObject, player]
          case result of
            Just (Lst v) -> case Lst.toList v of
              [Obj maxObject, Obj player] -> connectPlayer player maxObject
              _                           -> return ()
            _            -> return ()

        connectPlayer :: ObjId -> ObjId -> IO ()
        connectPlayer player maxObject = do
          cancel (connectionTimeout conn)
          now <- getCurrentTime

          oldPlayer <- atomically $ swapTVar (connectionPlayer conn) player

          void $ runServerTask $ do
            liftSTM $ writeTVar (connectionConnectedTime conn) (Just now)

            playerName <- getObjectName player
            connName   <- liftSTM $ connectionName conn

            world <- getWorld
            let maybeOldConn = M.lookup player (connections world)
            case maybeOldConn of
              Just oldConn -> do
                liftSTM $ writeTVar (connectionPlayer oldConn) oldPlayer
                printMessage oldConn redirectFromMsg
                liftSTM $ closeConnection oldConn

                oldConnName <- liftSTM $ connectionName oldConn
                liftSTM $ writeLog world $ "REDIRECTED: " <>
                  Str.toText playerName <> ", was " <> T.pack oldConnName <>
                  ", now " <> T.pack connName

              Nothing -> liftSTM $ writeLog world $ "CONNECTED: " <>
                         Str.toText playerName <> " on " <> T.pack connName

            liftVTx $ updateConnections world' $
              M.insert player conn . M.delete oldPlayer

            let (verb, msg)
                  | player > maxObject     = ("user_created",     createMsg)
                  | isNothing maybeOldConn = ("user_connected",   connectMsg)
                  | otherwise              = ("user_reconnected", redirectToMsg)

            printMessage conn msg
            callSystemVerb verb [Obj player] Str.empty

            return zero

        callSystemVerb :: StrT -> [Value] -> StrT -> MOO (Maybe Value)
        callSystemVerb = callSystemVerb' (connectionListener conn)

        runServerVerb' :: StrT -> [Value] -> StrT -> IO (Maybe Value)
        runServerVerb' vname args argstr = runServerTask $
          fromMaybe zero <$> callSystemVerb' listener vname args argstr
          where listener = connectionListener conn

        runServerTask :: MOO Value -> IO (Maybe Value)
        runServerTask comp = do
          player <- readTVarIO (connectionPlayer conn)
          let run = runTask =<< newTask world' player (resetLimits True >> comp)
          run `catch` \except -> do
            atomically $ sendToConnection conn $
              T.pack $ "*** Runtime error: " <> show (except :: SomeException)
            return Nothing

        cmdWords :: StrT -> [Value]
        cmdWords = map Str . parseWords . Str.toText

-- | Classify input as out-of-band (Left) or in-band (Right).
inputBand :: ConnectionOptions -> StrT -> Either StrT StrT
inputBand options input
  | optionDisableOOB options = Right          input
  | isOOB       input'       = Left           input
  | isOOBQuoted input'       = Right (unquote input)
  | otherwise                = Right          input
  where input'  = Str.toText input
        unquote = Str.drop (T.length outOfBandQuotePrefix)

-- | Connection reading thread: deliver messages from the network to our input
-- 'TBMQueue' until EOF, handling binary mode and the flush command, if any.
connectionRead :: Connection -> Consumer ByteString IO ()
connectionRead conn = do
  (outputLines,    inputLines)    <- lift $ spawn unbounded
  (outputMessages, inputMessages) <- lift $ spawn unbounded

  lift $ forkIO $ runEffect $
    fromInput inputLines >->
    readUtf8 >-> readLines >-> sanitize >-> lineMessage >->
    toOutput outputMessages

  lift $ forkIO $ runEffect $ fromInput inputMessages >-> deliverMessages

  forever $ do
    bytes <- await

    lift $ getCurrentTime >>=
      atomically . writeTVar (connectionActivityTime conn)

    options <- lift $ readTVarIO (connectionOptions conn)
    lift $ atomically $
      if optionBinaryMode options
      then send outputMessages (Binary bytes)
      else send outputLines bytes

  where readUtf8 :: Monad m => Pipe ByteString Text m ()
        readUtf8 = await >>= readUtf8' . streamDecodeUtf8With lenientDecode
          where readUtf8' (Some text _ continue) = do
                  unless (T.null text) $ yield text
                  await >>= readUtf8' . continue

        readLines :: Monad m => Pipe Text Text m ()
        readLines = readLines' TL.empty
          where readLines' prev = await >>= yieldLines prev >>= readLines'

                yieldLines :: Monad m => TL.Text -> Text
                           -> Pipe Text Text m TL.Text
                yieldLines prev text
                  | T.null rest = return (concatenate text)
                  | otherwise   = yield line' >>
                                  yieldLines TL.empty (T.tail rest)
                  where (end, rest) = T.break (== '\n') text
                        concatenate = TL.append prev . TL.fromStrict
                        line  = TL.toStrict (concatenate end)
                        line' = if not (T.null line) && T.last line == '\r'
                                then T.init line else line

        sanitize :: Monad m => Pipe Text Text m ()
        sanitize = for cat (yield . T.filter Str.validChar)

        lineMessage :: Monad m => Pipe Text ConnectionMessage m ()
        lineMessage = for cat (yield . Line)

        deliverMessages :: Consumer ConnectionMessage IO ()
        deliverMessages = forever $ do
          message <- await
          lift $ case message of
            Line line -> do
              flushCmd <- optionFlushCommand <$>
                          readTVarIO (connectionOptions conn)
              if not (T.null flushCmd) && line == flushCmd
                     then flushQueue else enqueue message
            Binary _ -> enqueue message

        enqueue :: ConnectionMessage -> IO ()
        enqueue = atomically . writeTBMQueue (connectionInput conn) . stringize

        stringize :: ConnectionMessage -> StrT
        stringize message = case message of
          Line   text  -> Str.fromText   text
          Binary bytes -> Str.fromBinary bytes

        flushQueue :: IO ()
        flushQueue = atomically $ flushInput True conn

-- | Connection writing thread: deliver messages from our output 'TBMQueue' to
-- the network until the queue is closed, which is our signal to close the
-- connection.
connectionWrite :: Connection -> Producer ByteString IO ()
connectionWrite conn = loop
  where loop = do
          message <- lift $ atomically $ readTBMQueue (connectionOutput conn)
          case message of
            Just (Line text)    -> yield (encodeUtf8 text) >> yield crlf >> loop
            Just (Binary bytes) -> yield bytes                           >> loop
            Nothing             -> return ()

        crlf :: ByteString
        crlf = encodeUtf8 "\r\n"

-- | The first un-logged-in connection ID. Avoid conflicts with #-1
-- ($nothing), #-2 ($ambiguous_match), and #-3 ($failed_match).
firstConnectionId :: ObjId
firstConnectionId = -4

-- | Determine the next valid un-logged-in connection ID, making sure it
-- remains negative and doesn't pass the predicate.
succConnectionId :: (ObjId -> Bool) -> ObjId -> ObjId
succConnectionId invalid = findNext
  where findNext connId
          | nextId >= 0    = findNext firstConnectionId
          | invalid nextId = findNext nextId
          | otherwise      = nextId
          where nextId = connId - 1

-- | Do something with the 'Map' of all active connections.
withConnections :: (Map ObjId Connection -> MOO a) -> MOO a
withConnections f = f . connections =<< getWorld

-- | Do something with the connection for the given object, if any.
withMaybeConnection :: ObjId -> (Maybe Connection -> MOO a) -> MOO a
withMaybeConnection oid f = withConnections $ f . M.lookup oid

-- | Do something with the connection for the given object, raising 'E_INVARG'
-- if no such connection exists.
withConnection :: ObjId -> (Connection -> MOO a) -> MOO a
withConnection oid = withMaybeConnection oid . maybe (raise E_INVARG)

enqueueOutput :: Bool -> Connection -> ConnectionMessage -> STM Bool
enqueueOutput noFlush conn message = do
  let queue = connectionOutput conn
  result <- tryWriteTBMQueue queue message
  case result of
    Just False -> if noFlush then return False
                  else do readTBMQueue queue  -- XXX count flushed lines
                          enqueueOutput noFlush conn message
    _          -> return True

sendToConnection :: Connection -> Text -> STM ()
sendToConnection conn = void . enqueueOutput False conn . Line

printMessage :: Connection -> ServerMessage -> MOO ()
printMessage conn msg
  | connectionPrintMessages conn = liftSTM =<< serverMessage conn msg
  | otherwise                    = return ()

serverMessage :: Connection -> ServerMessage -> MOO (STM ())
serverMessage conn msg =
  mapM_ (sendToConnection conn) <$> msg (connectionListener conn)

readFromConnection :: ObjId -> Bool -> MOO Value
readFromConnection oid nonBlocking = withConnection oid $ \conn -> do
  let queue  = connectionInput conn
      unRead = liftSTM . unGetTBMQueue queue

  input   <- liftSTM $ tryReadTBMQueue queue
  options <- liftSTM $ readTVar (connectionOptions conn)

  case input of
    Just (Just input) -> case inputBand options input of
      Right input     -> return (Str input)
      _ | nonBlocking -> unRead input >> return zero
      _               -> unRead input >> suspend conn
    Just Nothing
      | nonBlocking   -> return zero
      | otherwise     -> suspend conn
    Nothing           -> raise E_INVARG

  where suspend :: Connection -> MOO Value
        suspend conn = do
          checkQueuedTaskLimit

          resumeTVar <- liftSTM newEmptyTMVar
          let wake value = do
                now <- getCurrentTime
                atomically $ putTMVar resumeTVar (now, value)

          success <- liftSTM $ tryPutTMVar (connectionReader conn) (Wake wake)
          unless success $ raise E_INVARG

          task <- asks task
          state <- get
          putTask task { taskStatus = Reading
                       , taskState  = state {
                         startTime = posixSecondsToUTCTime (-1) }
                       }

          callCC $ interrupt . Suspend . Resume
          (now, value) <- liftSTM $ takeTMVar resumeTVar

          putTask task

          resetLimits False
          modify $ \state -> state { startTime = now }

          case value of
            Err error -> raise error
            _         -> return value

-- | Send data to a connection, flushing if necessary.
notify :: ObjId -> StrT -> MOO Bool
notify = notify' False

-- | Send data to a connection, optionally without flushing.
notify' :: Bool -> ObjId -> StrT -> MOO Bool
notify' noFlush who what =
  withMaybeConnection who . maybe (return True) $ \conn -> do
    options <- liftSTM $ readTVar (connectionOptions conn)
    message <- if optionBinaryMode options
               then Binary <$> binaryString what
               else return (Line $ Str.toText what)
    liftSTM $ enqueueOutput noFlush conn message

-- | Return the number of items currently buffered for output to a connection,
-- or the maximum number of items that will be buffered up for output on any
-- connection.
bufferedOutputLength :: Maybe Connection -> STM Int
bufferedOutputLength Nothing     = return maxQueueLength
bufferedOutputLength (Just conn) =
  (maxQueueLength -) <$> freeSlotsTBMQueue (connectionOutput conn)

-- | Force a line of input for a connection.
forceInput :: Bool -> ObjId -> StrT -> MOO ()
forceInput atFront oid line =
  withConnection oid $ \conn -> do
    let queue = connectionInput conn
    success <- liftSTM $
      if atFront then unGetTBMQueue queue line >> return True
      else fromMaybe True <$> tryWriteTBMQueue queue line
    unless success $ raise E_QUOTA

-- | Flush a connection's input queue, optionally showing what was flushed.
flushInput :: Bool -> Connection -> STM ()
flushInput showMessages conn = do
  let queue  = connectionInput conn
      notify = when showMessages . sendToConnection conn
  empty <- isEmptyTBMQueue queue
  if empty then notify ">> No pending input to flush..."
    else do notify ">> Flushing the following pending input:"
            flushQueue queue notify
            notify ">> (Done flushing)"

  where flushQueue queue notify = loop
          where loop = do
                  item <- join <$> tryReadTBMQueue queue
                  case item of
                    Just line -> notify (">>     " <> Str.toText line) >> loop
                    Nothing   -> return ()

-- | Initiate the closing of a connection by closing its output queue.
closeConnection :: Connection -> STM ()
closeConnection = closeTBMQueue . connectionOutput

-- | Close the connection associated with an object.
bootPlayer :: ObjId -> MOO ()
bootPlayer = bootPlayer' False

-- | Close the connection associated with an object, with message varying on
-- whether the object is being recycled.
bootPlayer' :: Bool -> ObjId -> MOO ()
bootPlayer' recycled oid =
  withMaybeConnection oid . maybe (return ()) $ \conn -> do
    connName <- liftSTM $ connectionName conn
    writeLog <- writeLog <$> getWorld
    if recycled then do
      liftSTM $ writeLog $ "RECYCLED: #" <> T.pack (show oid) <>
        " on " <> T.pack connName
      printMessage conn recycleMsg
      else do
      objectName <- getObjectName oid
      liftSTM $ writeLog $ "DISCONNECTED: " <> Str.toText objectName <>
        " on " <> T.pack connName
      printMessage conn bootMsg

    liftSTM $ closeConnection conn

    world' <- getWorld'
    liftVTx $ updateConnections world' $ M.delete oid

withConnectionOptions :: ObjId -> (ConnectionOptions -> MOO a) -> MOO a
withConnectionOptions oid f =
  withConnection oid $ f <=< liftSTM . readTVar . connectionOptions

modifyConnectionOptions :: ObjId -> (Connection -> ConnectionOptions ->
                                     MOO ConnectionOptions) -> MOO ()
modifyConnectionOptions oid f =
  withConnection oid $ \conn -> do
    let optionsVar = connectionOptions conn
    options <- liftSTM (readTVar optionsVar)
    liftSTM . writeTVar optionsVar =<< f conn options

-- | Set a connection option for an active connection.
setConnectionOption :: ObjId -> Id -> Value -> MOO ()
setConnectionOption oid option value =
  modifyConnectionOptions oid $ \conn options -> do
    option <- maybe (raise E_INVARG) return $
              M.lookup option allConnectionOptions
    optionSet option conn value options

-- | Return a 'Map' of all currently set connection options for a connection.
getConnectionOptions :: ObjId -> MOO (Map Id Value)
getConnectionOptions oid =
  withConnectionOptions oid $ \options ->
    let optionValue option = optionGet option options
    in return $ M.map optionValue allConnectionOptions

type ServerMessage = ObjId -> MOO [Text]

msgFor :: Id -> [Text] -> ServerMessage
msgFor msg def oid
  | oid == systemObject = systemMessage
  | otherwise           = getServerMessage oid msg systemMessage
  where systemMessage = getServerMessage systemObject msg (return def)

bootMsg         = msgFor "boot_msg"    ["*** Disconnected ***"]
connectMsg      = msgFor "connect_msg" ["*** Connected ***"]
createMsg       = msgFor "create_msg"  ["*** Created ***"]
recycleMsg      = msgFor "recycle_msg" ["*** Recycled ***"]
redirectFromMsg = msgFor "redirect_from_msg"
                  ["*** Redirecting connection to new port ***"]
redirectToMsg   = msgFor "redirect_to_msg"
                  ["*** Redirecting old connection to this port ***"]
serverFullMsg   = msgFor "server_full_msg"
  [ "*** Sorry, but the server cannot accept any more connections right now."
  , "*** Please try again later." ]
timeoutMsg      = msgFor "timeout_msg" ["*** Timed-out waiting for login. ***"]

-- | Create a proxy connection for console output (used by Emergency Wizard
-- Mode).
proxyConnection :: ObjId -> IO Connection
proxyConnection player = do
  player' <- newTVarIO player

  input  <- newTBMQueueIO maxQueueLength
  output <- newTBMQueueIO maxQueueLength

  now <- getCurrentTime
  connectedTime <- newTVarIO (Just now)
  activityTime  <- newTVarIO now

  timeout <- async $ return ()

  outputDelimiters <- newTVarIO (T.empty, T.empty)
  options <- newTVarIO initConnectionOptions

  reader     <- newEmptyTMVarIO
  disconnect <- newEmptyTMVarIO

  let conn = Connection {
          connectionListener         = systemObject
        , connectionPlayer           = player'
        , connectionPrintMessages    = True

        , connectionInput            = input
        , connectionOutput           = output

        , connectionName             = return "console"
        , connectionConnectedTime    = connectedTime
        , connectionActivityTime     = activityTime
        , connectionTimeout          = timeout

        , connectionOutputDelimiters = outputDelimiters
        , connectionOptions          = options

        , connectionReader           = reader
        , connectionDisconnect       = disconnect
        }

  forkIO $ runEffect $ connectionWrite conn >-> for cat (lift . BS.putStr)

  return conn
