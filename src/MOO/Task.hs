
{-# LANGUAGE CPP, OverloadedStrings, ExistentialQuantification #-}

module MOO.Task (
  -- * Monad Interface
    MOO
  , Environment(..)
  , initEnvironment
  , liftVTx
  , liftSTM

  -- * World Interface
  , World(..)
  , newWorld
  , getWorld
  , getWorld'
  , putWorld
  , modifyWorld
  , updateConnections
  , getDatabase
  , putDatabase
  , getVSpace
  , serverOption

  -- * Task Interface
  , Task(..)
  , TaskStatus(..)
  , Wake(..)
  , TaskState(..)
  , CallStack(..)
  , DelayedIO(..)
  , TaskDisposition(..)
  , Resume(..)
  , Resource(..)
  , initState
  , newState
  , newTaskId
  , newTask
  , defaultMaxStackDepth
  , defaultFgTicks
  , defaultBgTicks
  , defaultFgSeconds
  , defaultBgSeconds
  , getDelay
  , resetLimits
  , taskOwner
  , taskSize
  , isQueued
  , queuedTasks
  , stepTask
  , runTask
  , forkTask
  , interrupt
  , requestIO
  , delayIO
  , unsafeIOtoMOO
  , catchUnsafeIOtoMOO
  , getTask
  , putTask
  , purgeTask

  -- * Object Interface
  , getPlayer
  , getObject
  , getObjectName
  , getProperty
  , modifyProperty
  , modifyVerb
  , readProperty
  , writeProperty
  , setBuiltinProperty

  -- * Verb Execution Interface
  , getVerb
  , findVerb
  , callSystemVerb
  , callSystemVerb'
  , callCommandVerb
  , callVerb
  , callFromFunc
  , evalFromFunc
  , runVerb
  , runTick

  -- * Verb Frame Interface
  , StackFrame(..)
  , Continuation(..)
  , initFrame
  , formatFrames
  , activeFrame
  , frame
  , caller
  , modifyFrame
  , setLineNumber
  , mkVariables

  -- * Loop and Try/Finally Control Functions
  , pushTryFinallyContext
  , pushLoopContext
  , setLoopContinue
  , popContext
  , breakLoop
  , continueLoop

  -- * Exception Handling
  , Exception(..)
  , Code
  , Message
  , raiseException
  , raise
  , catchException
  , passException
  , handleDebug
  , timeoutException
  , formatTraceback

  -- * Utility Check Functions
  , isWizard
  , checkFloat
  , checkProgrammer
  , checkWizard
  , checkPermission
  , checkValid
  , checkFertile
  , checkProtectedProperty
  , checkRecurrence
  , checkQueuedTaskLimit

  -- * Miscellaneous
  , binaryString
  , random
  , newRandomGen
  , delay

  , shutdown
  , notyet
  ) where

import Control.Applicative ((<$>))
import Control.Arrow ((&&&))
import Control.Concurrent (MVar, ThreadId, myThreadId, forkIO, threadDelay,
                           newEmptyMVar, putMVar, tryPutMVar, takeMVar)
import Control.Concurrent.STM (STM, TVar, atomically, retry, throwSTM,
                               newEmptyTMVar, putTMVar, takeTMVar,
                               newTVarIO, readTVar, readTVarIO, writeTVar,
                               modifyTVar)
import Control.Exception (SomeException, try)
import Control.Monad (when, unless, void, (>=>), forM_)
import Control.Monad.Cont (ContT, runContT, callCC)
import Control.Monad.Reader (ReaderT, runReaderT, local, asks)
import Control.Monad.State.Strict (StateT, runStateT, get, gets, modify)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Writer (Writer, execWriter, tell)
import Data.ByteString (ByteString)
import Data.Function (on)
import Data.HashMap.Lazy (HashMap)
import Data.Int (Int32)
import Data.List (find)
import Data.Map (Map)
import Data.Maybe (isNothing, fromMaybe, fromJust)
import Data.Monoid (Monoid(mempty), (<>))
import Data.Text (Text)
import Data.Text.Lazy.Builder (Builder)
import Data.Time (UTCTime, getCurrentTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Database.VCache (VSpace, VTx, runVTx, getVTxSpace, deref, vref,
                        PVar, readPVarIO, readPVar, writePVar, modifyPVar,
                        pvar_space, VRef)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix (nanosleep)
import System.Random (Random, StdGen, newStdGen, mkStdGen, splitGen,
                      randomR, randomRs)

import qualified Data.HashMap.Lazy as HM
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy.Builder.Int as TLB
import qualified Database.VCache as DV

import MOO.Command
import {-# SOURCE #-} MOO.Compiler
import {-# SOURCE #-} MOO.Connection
import {-# SOURCE #-} MOO.Database
import {-# SOURCE #-} MOO.Network
import MOO.Object
import MOO.Types
import MOO.Verb
# ifdef MOO_WAIF
import {-# SOURCE #-} MOO.WAIF
# endif

import qualified MOO.List as Lst
import qualified MOO.String as Str

-- | This is the basic MOO monad transformer stack. A computation of type
-- @'MOO' a@ is a 'VTx' transaction (layered on 'STM') that returns a value of
-- type @a@ within an environment that supports state, continuations, and
-- local modification.
type MOO = ReaderT Environment
           (ContT TaskDisposition
            (StateT TaskState VTx))

-- | Lift a 'VTx' transaction into the 'MOO' monad.
liftVTx :: VTx a -> MOO a
liftVTx = lift . lift . lift

-- | Lift an 'STM' transaction into the 'MOO' monad.
liftSTM :: STM a -> MOO a
liftSTM = liftVTx . DV.liftSTM

-- | The known universe, as far as the MOO server is concerned
data World = World {
    writeLog           :: Text -> STM ()        -- ^ Logging function

  , persistence        :: Persistence           -- ^ Persistent storage
  , checkpoint         :: STM ()                -- ^ Database checkpoint signal

  , database           :: Database              -- ^ The database of objects
  , tasks              :: Map TaskId Task       -- ^ Queued and running tasks

  , listeners          :: Map Point Listener    -- ^ Network listening points
  , connections        :: Map ObjId Connection  -- ^ Network connections

  , nextConnectionId   :: ObjId
    -- ^ The (negative) object number to be assigned to the next inbound or
    -- outbound connection

  , outboundNetwork    :: Bool
    -- ^ Is @open_network_connection()@ enabled?
  , bindAddress        :: Maybe HostName
    -- ^ Interface address to bind to for incoming connections

  , shutdownMessage    :: MVar Text
    -- ^ Shutdown signal
  }

initWorld :: World
initWorld = World {
    writeLog         = const $ return ()

  , persistence      = undefined
  , checkpoint       = return ()

  , database         = initDatabase
  , tasks            = M.empty

  , listeners        = M.empty
  , connections      = M.empty

  , nextConnectionId = firstConnectionId

  , outboundNetwork  = False
  , bindAddress      = Nothing

  , shutdownMessage  = undefined
  }

newWorld :: (Text -> STM ()) -> Persistence -> Bool -> IO (TVar World)
newWorld writeLog persist outboundNetworkEnabled = do
  shutdownVar <- newEmptyMVar

  db <- readPVarIO (persistenceDatabase persist)
  world' <- newTVarIO initWorld {
      writeLog        = writeLog
    , persistence     = persist
    , database        = db
    , outboundNetwork = outboundNetworkEnabled
    , shutdownMessage = shutdownVar
    }

  runTask =<< newTask world' nothing (loadServerOptions >> return zero)

  return world'

-- | A structure representing a queued or running task
data Task = Task {
    taskId          :: TaskId
  , taskStatus      :: TaskStatus

  , taskThread      :: ThreadId
  , taskWorld       :: TVar World
  , taskPlayer      :: ObjId

  , taskState       :: TaskState
  , taskComputation :: MOO Value
  }

initTask :: Task
initTask = Task {
    taskId          = 0
  , taskStatus      = Pending

  , taskThread      = undefined
  , taskWorld       = undefined
  , taskPlayer      = nothing

  , taskState       = initState
  , taskComputation = return zero
  }

instance Eq Task where
  (==) = (==) `on` taskId

instance Ord Task where
  compare = compare `on` (startTime . taskState)

type TaskId = Int32

-- | Generate a (random) 'TaskId' not currently in use by any existing task.
newTaskId :: World -> StdGen -> TaskId
newTaskId world = fromJust . find unused . randomRs (1, maxBound)
  where unused = (`M.notMember` tasks world)

-- | Create a pending 'Task' for the given computation on behalf of the given
-- player. A new 'TaskId' is reserved for the task and the task is added to
-- the 'World'. (The task will not actually run until passed to 'runTask'.)
newTask :: TVar World -> ObjId -> MOO Value -> IO Task
newTask world' player comp = do
  gen <- newStdGen
  state <- newState

  atomically $ do
    world <- readTVar world'

    let taskId = newTaskId world gen
        task = initTask {
            taskId          = taskId

          , taskWorld       = world'
          , taskPlayer      = player

          , taskState       = state
          , taskComputation = comp
          }

    writeTVar world' world { tasks = M.insert taskId task (tasks world) }
    return task

taskOwner :: Task -> ObjId
taskOwner = permissions . activeFrame

-- | (Grossly) estimate a task's size, in bytes.
taskSize :: Task -> Int
taskSize task = 64 + stateSize (taskState task)

  where stateSize :: TaskState -> Int
        stateSize state = 32 + stackSize (stack state)

        stackSize :: CallStack -> Int
        stackSize (Stack frames) = sum $ map frameSize frames

        frameSize :: StackFrame -> Int
        frameSize frame = 64 + sum (map contextSize $ contextStack frame) +
          HM.foldrWithKey varFold 0 (variables frame) +
          textSize (Str.toText $ verbName     frame) +
          textSize (Str.toText $ verbFullName frame)

          where varFold :: Id -> Value -> Int -> Int
                varFold name value accum = accum +
                  textSize (fromId name) + valueSize value

        contextSize :: Context -> Int
        contextSize Loop { loopName = name } = 16 +
          maybe 0 (textSize . fromId) name
        contextSize TryFinally{} = 8

        textSize :: Text -> Int
        textSize = T.length

        valueSize :: Value -> Int
        valueSize (Int _) = 8
        valueSize (Flt _) = 12
        valueSize (Str x) = Str.length x
        valueSize (Obj _) = 8
        valueSize (Err _) = 4
        valueSize (Lst x) = Lst.foldr' (\v a -> a + valueSize v) 0 x
# ifdef MOO_WAIF
        valueSize (Waf _) = 32
# endif

-- | The running state of a task
data TaskStatus = Pending | Running | Forked | Suspended Wake | Reading

isQueued :: TaskStatus -> Bool
isQueued Pending = False
isQueued Running = False
isQueued _       = True

isRunning :: TaskStatus -> Bool
isRunning Running = True
isRunning _       = False

queuedTasks :: MOO [Task]
queuedTasks = filter (isQueued . taskStatus) . M.elems . tasks <$> getWorld

-- | A function to call in order to wake a suspended task
newtype Wake = Wake (Value -> IO ())

-- | The intermediate or final result of a running task
data TaskDisposition = Complete Value
                     | Suspend                    (Resume ())
                     | forall a. RequestIO (IO a) (Resume a)
                     | Uncaught Exception
                     | Timeout  Resource  CallStack
                     | Suicide

-- | A continuation to resume the execution of a task where it left off
newtype Resume a = Resume (a -> MOO Value)

-- | Task resource limits
data Resource = Ticks | Seconds

showResource :: Resource -> StrT
showResource Ticks   = "ticks"
showResource Seconds = "seconds"

timeoutException :: Resource -> CallStack -> Exception
timeoutException resource stack = except { exceptionCallStack = stack }
  where message = "Task ran out of " <> showResource resource
        except  = newException (Err E_QUOTA) message zero

stepTask :: Task -> IO (TaskDisposition, Task)
stepTask task = do
  let env    = initEnvironment task
      comp   = taskComputation task
      comp'  = callCC $ \k ->
        Complete <$> local (\r -> r { interruptHandler = Interrupt k }) comp
      state  = taskState task
      contM  = runReaderT comp' env
      stateM = runContT contM return
      vtxM   = runStateT stateM state
  vspace <- persistenceVSpace . persistence <$> readTVarIO (taskWorld task)
  (result, state') <- runVTx vspace vtxM
  runDelayed $ delayedIO state'
  return (result, task { taskState = state' { delayedIO = mempty }})

stepTaskWithIO :: Task -> IO (TaskDisposition, Task)
stepTaskWithIO task = do
  (disposition, task') <- stepTask task
  case disposition of
    RequestIO io (Resume resume) -> do
      result <- io
      stepTaskWithIO task' { taskComputation = resume result }
    _ -> return (disposition, task')

-- | Run a task in a new Haskell thread, returning either the value produced
-- by the task, or 'Nothing' if the task suspends or aborts before producing a
-- value. If the task suspends, it may continue running after this function
-- returns. The task is removed from the task queue after it is finished.
runTask :: Task -> IO (Maybe Value)
runTask task = do
  resultMVar <- newEmptyMVar

  forkIO $ do
    threadId <- myThreadId
    let task' = task { taskThread = threadId }

    atomically $ modifyTVar (taskWorld task) $ \world ->
      world { tasks = M.insert (taskId task)
                      task' { taskStatus = Running } $ tasks world }

    runTask' task' $ putMVar resultMVar

    atomically $ modifyTVar (taskWorld task) $ \world ->
      world { tasks = M.delete (taskId task) $ tasks world }

  takeMVar resultMVar

  where noOp = const $ return ()

        runTask' :: Task -> (Maybe Value -> IO ()) -> IO ()
        runTask' task putResult = do
          (disposition, task') <- stepTaskWithIO task
          case disposition of
            Complete value -> putResult (Just value)

            Suspend (Resume resume) -> do
              putResult Nothing

              -- restart this task only when there are none other running
              atomically $ do
                world <- readTVar (taskWorld task')
                when (any (isRunning . taskStatus) $ M.elems $ tasks world)
                  retry

              runTask' task' { taskComputation = resume () } noOp

            Uncaught exception@Exception {
                exceptionCode      = code
              , exceptionMessage   = message
              , exceptionValue     = value
              , exceptionCallStack = Stack frames
              } -> handleAbortedTask task' formatted putResult $
                   callSystemVerb "handle_uncaught_error"
                   [ code, Str message, value, traceback
                   , fromListBy (Str . Str.fromText) formatted ]
              where traceback = formatFrames True frames
                    formatted = formatTraceback exception

            Timeout resource stack@(Stack frames) ->
              handleAbortedTask task' formatted putResult $
                callSystemVerb "handle_task_timeout"
                [ Str $ showResource resource, traceback
                , fromListBy (Str . Str.fromText) formatted ]
              where traceback = formatFrames True frames
                    formatted = formatTraceback $
                                timeoutException resource stack

            Suicide -> putResult Nothing

        handleAbortedTask :: Task -> [Text] -> (Maybe Value -> IO ()) ->
                             MOO (Maybe Value) -> IO ()
        handleAbortedTask task traceback putResult call = do
          state <- newState
          handleAbortedTask' traceback task {
              taskState = state
            , taskComputation = fromMaybe zero <$> call
            }

          where handleAbortedTask' :: [Text] -> Task -> IO ()
                handleAbortedTask' traceback task = do
                  (disposition, task') <- stepTaskWithIO task
                  case disposition of
                    Complete value -> do
                      unless (truthOf value) $ informPlayer traceback
                      putResult Nothing
                    Suspend (Resume resume) -> do
                      -- The aborted task is considered "handled" but continue
                      -- running the suspended handler (which might abort
                      -- again!)
                      putResult Nothing
                      runTask' task' { taskComputation = resume () } noOp
                    Uncaught exception -> do
                      informPlayer traceback
                      informPlayer $ formatTraceback exception
                      putResult Nothing
                    Timeout resource stack -> do
                      informPlayer traceback
                      informPlayer $ formatTraceback $
                        timeoutException resource stack
                      putResult Nothing
                    Suicide -> putResult Nothing

        informPlayer :: [Text] -> IO ()
        informPlayer lines = atomically $ do
          world <- readTVar (taskWorld task)
          forM_ lines $ writeLog world

          case M.lookup (taskPlayer task) (connections world) of
            Just conn -> forM_ lines $ sendToConnection conn
            Nothing   -> return ()

defaultMaxStackDepth :: Num a => a
defaultMaxStackDepth = 50

defaultFgTicks :: Num a => a
defaultFgTicks = 30000

defaultBgTicks :: Num a => a
defaultBgTicks = 15000

defaultFgSeconds :: Num a => a
defaultFgSeconds = 5

defaultBgSeconds :: Num a => a
defaultBgSeconds = 3

getDelay :: Value -> MOO Integer
getDelay v = case toMicroseconds v of
  Just usecs | usecs >= 0 -> return usecs
             | otherwise  -> raise E_INVARG
  Nothing                 -> raise E_TYPE

-- | Create and queue a task to run the given computation after the given
-- microsecond delay. 'E_INVARG' may be raised if the delay is out of
-- acceptable range. (The given 'TaskId' should have been reserved by a call
-- to 'newTaskId'.)
forkTask :: TaskId -> Integer -> MOO Value -> MOO ()
forkTask taskId usecs code = do
  state <- get

  let now = startTime state
      estimatedWakeup = (fromIntegral usecs / 1000000) `addUTCTime` now

  when (estimatedWakeup < now || estimatedWakeup > endOfTime) $ raise E_INVARG

  task <- asks task
  gen <- newRandomGen

  maxDepth <- serverOption maxStackDepth
  let frame = currentFrame (stack state)

      frame' = frame {
          depthLeft    = maxDepth
        , contextStack = contextStack initFrame
        , lineNumber   = lineNumber frame + 1
        }

      state' = initState {
          ticksLeft = defaultBgTicks
        , stack     = Stack [frame']
        , startTime = estimatedWakeup
        , randomGen = gen
        }

      task' = task {
          taskId          = taskId
        , taskStatus      = Forked
        , taskState       = state'
        , taskComputation = resetLimits False >> code
        }

  -- make sure the forked task doesn't start before the current task commits
  startSignal <- liftSTM newEmptyTMVar

  threadId <- requestIO $ forkIO $ do
    delay usecs
    atomically $ takeTMVar startSignal
    now <- getCurrentTime
    void $ runTask task' { taskState = state' { startTime = now } }

  modifyWorld $ \world ->
    world { tasks = M.insert taskId task' { taskThread = threadId } $
                    tasks world }
  liftSTM $ putTMVar startSignal ()

-- | Wait for the given number of microseconds to elapse.
delay :: Integer -> IO ()
delay usecs
  | usecs <= maxInt = threadDelay (fromIntegral usecs)
  | otherwise       = nanosleep (usecs * 1000)
  where maxInt = fromIntegral (maxBound :: Int)

-- | A continuation for returning to the task dispatcher to handle an
-- interrupt request. Note that calling this continuation implies a commit to
-- the current task's transaction.
newtype InterruptHandler = Interrupt (TaskDisposition -> MOO TaskDisposition)

-- | Commit the current task's transaction, and return to the task dispatcher
-- with an interrupt request. The task dispatcher may resume execution of the
-- task later if the request is one which supplies an appropriate
-- continuation.
interrupt :: TaskDisposition -> MOO a
interrupt disp = do
  Interrupt handler <- asks interruptHandler
  handler disp
  error "Returned from interrupt handler"

-- | An 'IO' computation to be performed after the current task commits its
-- 'STM' transaction
newtype DelayedIO = DelayedIO { runDelayed :: IO () }

instance Semigroup DelayedIO where
  DelayedIO a <> DelayedIO b = DelayedIO (a >> b)

instance Monoid DelayedIO where
  mempty = DelayedIO $ return ()

-- | Interrupt the current task to perform the given IO computation, and
-- return the result. Note this implies a commit of the task's 'STM'
-- transaction.
requestIO :: IO a -> MOO a
requestIO io = callCC $ interrupt . RequestIO io . Resume

-- | Perform the given IO computation after the current task commits its 'STM'
-- transaction.
--
-- Since general IO can't be performed within a transaction, this is a simple
-- alternative when the value returned by the IO isn't needed.
delayIO :: IO () -> MOO ()
delayIO io = modify $ \state ->
  state { delayedIO = delayedIO state <> DelayedIO io }

-- | Unsafely perform the given IO action within the current 'STM'
-- transaction, using the supplied exception handler in case the IO throws an
-- exception.
--
-- Since 'STM' transactions may be aborted at any time, the IO is performed in
-- a separate thread in order to guarantee consistency with any finalizers,
-- brackets, and so forth. The IO must be idempotent as it may be run more
-- than once.
--
-- Note that all the hazards of 'unsafePerformIO' apply; in particular, it is
-- incumbent upon the caller to ensure the IO action is executed at least as
-- many times as desired (and not, say, optimized to a single execution).
catchUnsafeIOtoMOO :: IO a -> (SomeException -> MOO a) -> MOO a
catchUnsafeIOtoMOO io catchFunc = either catchFunc return $ unsafePerformIO $ do
  r <- newEmptyMVar
  forkIO $ try io >>= putMVar r
  takeMVar r

-- | A version of 'catchUnsafeIOtoMOO' that simply propagates any thrown
-- exception into the calling thread, most likely aborting its execution.
unsafeIOtoMOO :: IO a -> MOO a
unsafeIOtoMOO io = catchUnsafeIOtoMOO io $ liftSTM . throwSTM

-- | A 'Reader' environment for state that either doesn't change, or can be
-- locally modified for subcomputations
data Environment = Env {
    task             :: Task
  , interruptHandler :: InterruptHandler
  , exceptionHandler :: ExceptionHandler
  , indexLength      :: MOO Value
  }

initEnvironment :: Task -> Environment
initEnvironment task = Env {
    task             = task
  , interruptHandler = error "Undefined interrupt handler"
  , exceptionHandler = Handler $ interrupt . Uncaught
  , indexLength      = error "Invalid index context"
  }

-- | A 'State' structure for data that may normally change during computation
data TaskState = State {
    ticksLeft    :: Int
  , secondsLimit :: Int
  , stack        :: CallStack
  , startTime    :: UTCTime
  , randomGen    :: StdGen
  , delayedIO    :: DelayedIO
  }

initState :: TaskState
initState = State {
    ticksLeft    = defaultFgTicks
  , secondsLimit = defaultFgSeconds
  , stack        = Stack []
  , startTime    = posixSecondsToUTCTime 0
  , randomGen    = mkStdGen 0
  , delayedIO    = mempty
  }

newState :: IO TaskState
newState = do
  startTime <- getCurrentTime
  gen <- newStdGen
  return initState {
      startTime = startTime
    , randomGen = gen
    }

-- | Reset the number of ticks and seconds available for the current task
-- based on the latest values obtained from @$server_options@.
resetLimits :: Bool -> MOO ()
resetLimits foreground = getServerOptions >>= \options -> modify $ \state ->
    state { ticksLeft    = (if foreground then fgTicks   else bgTicks  ) options
          , secondsLimit = (if foreground then fgSeconds else bgSeconds) options
          }

getServerOptions :: MOO ServerOptions
getServerOptions = serverOptions <$> getDatabase

-- | Fetch the current setting of a server option obtained from
-- @$server_options@.
serverOption :: (ServerOptions -> a) -> MOO a
serverOption = (<$> getServerOptions)

getWorld' :: MOO (TVar World)
getWorld' = asks (taskWorld . task)

getWorld :: MOO World
getWorld = liftSTM . readTVar =<< getWorld'

putWorld :: World -> MOO ()
putWorld world = liftSTM . flip writeTVar world =<< getWorld'

modifyWorld :: (World -> World) -> MOO ()
modifyWorld f = liftSTM . flip modifyTVar f =<< getWorld'

updateConnections :: TVar World ->
                     (Map ObjId Connection -> Map ObjId Connection) -> VTx ()
updateConnections world' f = do
  world <- DV.liftSTM $ readTVar world'
  let connections' = f (connections world)
  DV.liftSTM $ writeTVar world' world { connections = connections' }

  writePVar (persistenceConnected $ persistence world) $ M.foldMapWithKey
    (\player conn -> [(player, connectionListener conn)]) connections'

getTask :: TaskId -> MOO (Maybe Task)
getTask taskId = M.lookup taskId . tasks <$> getWorld

putTask :: Task -> MOO ()
putTask task = modifyWorld $ \world ->
  world { tasks = M.insert (taskId task) task $ tasks world }

purgeTask :: Task -> MOO ()
purgeTask task = modifyWorld $ \world ->
  world { tasks = M.delete (taskId task) $ tasks world }

getDatabase :: MOO Database
getDatabase = database <$> getWorld

putDatabase :: Database -> MOO ()
putDatabase db = do
  modifyWorld $ \world -> world { database = db }

  p <- persistence <$> getWorld
  liftVTx $ writePVar (persistenceDatabase p) db

getVSpace :: MOO VSpace
getVSpace = liftVTx getVTxSpace

getPlayer :: MOO ObjId
getPlayer = asks (taskPlayer . task)

getObject :: ObjId -> MOO (Maybe Object)
getObject oid = liftVTx . dbObject oid =<< getDatabase

getObjectName :: ObjId -> MOO StrT
getObjectName oid = maybe objNum objNameNum <$> getObject oid
  where objNum = Str.fromText (toText $ Obj oid)
        objNameNum obj = Str.concat [objectName obj, " (", objNum, ")"]

getProperty :: Object -> StrT -> MOO Property
getProperty obj name = liftVTx (lookupProperty obj name) >>=
                       maybe (raise E_PROPNF) return

getVerb :: Object -> Value -> MOO Verb
getVerb obj desc@Str{} = do
  numericStrings <- serverOption supportNumericVerbnameStrings
  liftVTx (lookupVerb numericStrings obj desc) >>= maybe (raise E_VERBNF) return
getVerb obj desc@(Int index)
  | index < 1 = raise E_INVARG
  | otherwise = liftVTx (lookupVerb False obj desc) >>=
                maybe (raise E_VERBNF) return
getVerb _ _ = raise E_TYPE

findVerb :: (Verb -> Bool) -> StrT -> ObjId -> MOO (Maybe ObjId, Maybe Verb)
findVerb acceptable name = findVerb'
  where findVerb' oid = do
          maybeObj <- getObject oid
          case maybeObj of
            Just obj -> do
              maybeVerb <- liftVTx $ searchVerbs (objectVerbs obj)
              case maybeVerb of
                Just verb -> return (Just oid, Just verb)
                Nothing   -> maybe (return (Just oid, Nothing))
                             findVerb' (objectParent obj)
            Nothing -> return (Nothing, Nothing)

        searchVerbs :: [([StrT], PVar (VRef Verb))] -> VTx (Maybe Verb)
        searchVerbs ((names,verbPVar):rest)
          | verbNameMatch name names = deref <$> readPVar verbPVar >>= \verb ->
            if acceptable verb then return (Just verb) else searchVerbs rest
          | otherwise = searchVerbs rest
        searchVerbs [] = return Nothing

callSystemVerb :: StrT -> [Value] -> MOO (Maybe Value)
callSystemVerb name args = callSystemVerb' systemObject name args Str.empty

callSystemVerb' :: ObjId -> StrT -> [Value] -> StrT -> MOO (Maybe Value)
callSystemVerb' object name args argstr = getPlayer >>= \player ->
  findVerb verbPermX name object >>= \found -> case found of
    (Just verbLoc, Just verb) ->
      let vars = mkVariables [
              ("player", Obj player)
            , ("this"  , Obj object)
            , ("verb"  , Str name)
            , ("args"  , fromList args)
            , ("argstr", Str argstr)
            ]
      in Just <$> runVerb verb initFrame {
          variables     = vars
        , verbName      = name
        , verbLocation  = verbLoc
        , initialThis   = Obj object
        , initialPlayer = player
        }
    _ -> return Nothing

callCommandVerb :: ObjId -> (ObjId, Verb) -> ObjId ->
                   Command -> ObjId -> ObjId -> MOO Value
callCommandVerb player (verbLoc, verb) this command dobj iobj =
  let name = commandVerb command
      vars = mkVariables [
          ("player" , Obj player)
        , ("this"   , Obj this)
        , ("caller" , Obj player)
        , ("verb"   , Str name)
        , ("argstr" , Str        $ commandArgStr  command)
        , ("args"   , stringList $ commandArgs    command)
        , ("dobjstr", Str        $ commandDObjStr command)
        , ("dobj"   , Obj dobj)
        , ("prepstr", Str        $ commandPrepStr command)
        , ("iobjstr", Str        $ commandIObjStr command)
        , ("iobj"   , Obj iobj)
        ]
  in runVerb verb initFrame {
      variables     = vars
    , verbName      = name
    , verbLocation  = verbLoc
    , initialThis   = Obj this
    , initialPlayer = player
    }

callVerb' :: Value -> ObjId -> Verb -> StrT -> [Value] -> MOO Value
callVerb' this verbLoc verb name args = do
  thisFrame <- frame id
  wizard <- isWizard (permissions thisFrame)
  let var = (vars HM.!)
      player = case (wizard, var "player") of
        (True, Obj oid) -> oid
        _               -> initialPlayer thisFrame
      name' = case this of
# ifdef MOO_WAIF
        Waf{} -> mangleWaifVerbName name
# endif
        _     -> name
      vars  = variables thisFrame
      vars' = mkVariables [
          ("this"  , this)
        , ("verb"  , Str name')
        , ("args"  , fromList args)
        , ("caller", initialThis thisFrame)
        , ("player", Obj player)
        , retain "argstr"
        , retain "dobjstr"
        , retain "dobj"
        , retain "prepstr"
        , retain "iobjstr"
        , retain "iobj"
        ]
      retain x = (x, var x)

  runVerb verb initFrame {
      variables     = vars'
    , verbName      = name
    , verbLocation  = verbLoc
    , initialThis   = this
    , initialPlayer = player
    }

callVerb :: Value -> ObjId -> StrT -> [Value] -> MOO Value
callVerb this oid name args =
  findVerb verbPermX name oid >>= \found -> case found of
    (Just verbLoc, Just verb) -> callVerb' this verbLoc verb name args
    (Nothing     , _        ) -> raise E_INVIND
    (_           , Nothing  ) -> raise E_VERBNF

callFromFunc :: StrT -> LineNo -> (ObjId, StrT) -> [Value] -> MOO (Maybe Value)
callFromFunc func index (oid, name) args =
  findVerb verbPermX name oid >>= \found -> case found of
    (Just verbLoc, Just verb) -> fmap Just $ evalFromFunc func index $
                                 callVerb' (Obj oid) verbLoc verb name args
    _                         -> return Nothing

evalFromFunc :: StrT -> LineNo -> MOO Value -> MOO Value
evalFromFunc func index code = do
  (depthLeft, player) <- frame (depthLeft &&& initialPlayer)
  code `runInFrame` initFrame {
      depthLeft     = depthLeft
    , verbName      = func
    , initialPlayer = player
    , builtinFunc   = True
    , lineNumber    = index
    }

runVerb :: Verb -> StackFrame -> MOO Value
runVerb verb verbFrame = do
  Stack frames <- gets stack
  depthLeft' <- case frames of
    frame:_ -> return (depthLeft frame)
    []      -> serverOption maxStackDepth
  unless (depthLeft' > 0) $ raise E_MAXREC

  compile (deref $ verbProgram verb) `runInFrame` verbFrame {
      depthLeft    = depthLeft' - 1
    , debugBit     = verbPermD verb
    , permissions  = verbOwner verb
    , verbFullName = verbNames verb
    }

runTick :: MOO ()
runTick = do
  ticksLeft <- gets ticksLeft
  unless (ticksLeft > 0) $ interrupt . Timeout Ticks =<< gets stack
  modify $ \state -> state { ticksLeft = ticksLeft - 1 }

modifyProperty :: Object -> StrT -> (Property -> MOO Property) -> MOO ()
modifyProperty obj name f = case lookupPropertyRef obj name of
  Just propPVar -> do
    prop  <- liftVTx $ deref <$> readPVar propPVar
    prop' <- f prop
    liftVTx $ writePVar propPVar $ vref (pvar_space propPVar) prop'
  Nothing -> raise E_PROPNF

modifyVerb :: (ObjId, Object) -> Value -> (Verb -> MOO Verb) -> MOO ()
modifyVerb (oid, obj) desc f = do
  numericStrings <- serverOption supportNumericVerbnameStrings
  case lookupVerbRef numericStrings obj desc of
    Just (index, verbPVar) -> do
      verb  <- liftVTx $ deref <$> readPVar verbPVar
      verb' <- f verb
      liftVTx $ writePVar verbPVar $ vref (pvar_space verbPVar) verb'
      unless (verbNames verb `Str.equal` verbNames verb') $ do
        db <- getDatabase
        liftVTx $ modifyObject oid db $ replaceVerb index verb'
    Nothing -> raise E_VERBNF

readProperty :: ObjId -> StrT -> MOO (Maybe Value)
readProperty oid name = getObject oid >>= \maybeObj ->
  case maybeObj of
    Just obj -> maybe (search obj) (return . Just . ($ obj)) $
                builtinProperty name
    Nothing  -> return Nothing

  where search :: Object -> MOO (Maybe Value)
        search obj = do
          maybeProp <- liftVTx $ lookupProperty obj name
          case maybeProp of
            Just prop -> case propertyValue prop of
              Nothing -> do
                parentObj <- maybe (return Nothing) getObject (objectParent obj)
                maybe (error $ "No inherited value for property " ++
                       Str.toString name) search parentObj
              just -> return (deref <$> just)
            Nothing -> return Nothing

writeProperty :: ObjId -> StrT -> Value -> MOO ()
writeProperty oid name value = getObject oid >>= \maybeObj ->
  case maybeObj of
    Just obj
      | isBuiltinProperty name -> setBuiltinProperty (oid, obj) name value
      | otherwise -> case lookupPropertyRef obj name of
          Just propPVar -> liftVTx $ modifyPVar propPVar $ \prop ->
            let vspace = pvar_space propPVar
            in vref vspace $
               (deref prop) { propertyValue = Just (vref vspace value) }
          Nothing -> return ()
    Nothing -> return ()

modifyObject' :: ObjId -> (Object -> Object) -> MOO ()
modifyObject' oid f = getDatabase >>= \db ->
  liftVTx $ modifyObject oid db $ return . f

setBuiltinProperty :: (ObjId, Object) -> StrT -> Value -> MOO ()
setBuiltinProperty (oid, obj) "name" (Str name) = do
  if objectIsPlayer obj
    then checkWizard
    else checkPermission (objectOwner obj)
  modifyObject' oid $ \obj -> obj { objectName = name }
setBuiltinProperty (oid, _) "owner" (Obj owner) = do
  checkWizard
  modifyObject' oid $ \obj -> obj { objectOwner = owner }
setBuiltinProperty _ "location" (Obj _) = raise E_PERM
setBuiltinProperty _ "contents" (Lst _) = raise E_PERM
setBuiltinProperty (oid, _) "programmer" bit = do
  checkWizard
  modifyObject' oid $ \obj -> obj { objectProgrammer = truthOf bit }
setBuiltinProperty (oid, obj) "wizard" bit = do
  checkWizard
  when (objectWizard obj /= bit') $ do
    writeLog' <- writeLog <$> getWorld
    programmer <- frame permissions
    liftSTM $ writeLog' $ (if bit' then "" else "DE") <> "WIZARDED: " <>
      toText (Obj oid) <> " by programmer " <> toText (Obj programmer)
    setWizardBit `catchException` (liftSTM . mapM_ writeLog' . formatTraceback)
  where bit' = truthOf bit
        setWizardBit = do
          modifyObject' oid $ \obj -> obj { objectWizard = bit' }
          let message = "Wizard bit " <> if bit' then "set." else "unset."
          raiseException (Err E_NONE) message bit
setBuiltinProperty (oid, obj) "r" bit = do
  checkPermission (objectOwner obj)
  modifyObject' oid $ \obj -> obj { objectPermR = truthOf bit }
setBuiltinProperty (oid, obj) "w" bit = do
  checkPermission (objectOwner obj)
  modifyObject' oid $ \obj -> obj { objectPermW = truthOf bit }
setBuiltinProperty (oid, obj) "f" bit = do
  checkPermission (objectOwner obj)
  modifyObject' oid $ \obj -> obj { objectPermF = truthOf bit }
setBuiltinProperty _ _ _ = raise E_TYPE

-- | The stack of verb and/or built-in function frames
newtype CallStack = Stack [StackFrame]

-- | A local continuation for loop constructs
newtype Continuation = Continuation (() -> MOO Value)

-- | A structure describing a (possibly nested) context for the current frame,
-- used to manage loop break/continue and try/finally interactions
data Context =
  Loop {
    loopName     :: Maybe Id
  , loopBreak    :: Continuation
  , loopContinue :: Continuation
  } |
  TryFinally {
    finally      :: MOO Value
  }

-- | The data tracked for each verb and/or built-in function call
data StackFrame = Frame {
    depthLeft     :: Int

  , contextStack  :: [Context]
  , variables     :: HashMap Id Value
  , debugBit      :: Bool
  , permissions   :: ObjId

  , verbName      :: StrT
  , verbFullName  :: StrT
  , verbLocation  :: ObjId
  , initialThis   :: Value
  , initialPlayer :: ObjId

  , builtinFunc   :: Bool
  , lineNumber    :: LineNo
  }

initFrame :: StackFrame
initFrame = Frame {
    depthLeft     = defaultMaxStackDepth

  , contextStack  = []
  , variables     = initVariables
  , debugBit      = True
  , permissions   = nothing

  , verbName      = Str.empty
  , verbFullName  = Str.empty
  , verbLocation  = nothing
  , initialThis   = Obj nothing
  , initialPlayer = nothing

  , builtinFunc   = False
  , lineNumber    = 0
  }

formatFrames :: Bool -> [StackFrame] -> Value
formatFrames includeLineNumbers = fromListBy formatFrame

  where formatFrame :: StackFrame -> Value
        formatFrame frame = fromList $
                 initialThis   frame
          : Str (verbName      frame)
          : Obj (permissions   frame)
          : Obj (verbLocation  frame)
          : Obj (initialPlayer frame)
          : [Int $ fromIntegral $ lineNumber frame | includeLineNumbers]

runInFrame :: MOO a -> StackFrame -> MOO a
runInFrame code frame = do
  pushFrame frame
  result <- code `catchException` \except -> popFrame >> passException except
  popFrame
  return result

  where pushFrame :: StackFrame -> MOO ()
        pushFrame frame = modify $ \state@State { stack = Stack frames } ->
          state { stack = Stack (frame : frames) }

        popFrame :: MOO ()
        popFrame = do
          unwindContexts (const False)
          modify $ \state@State { stack = Stack (_:frames) } ->
            state { stack = Stack frames }

currentFrame :: CallStack -> StackFrame
currentFrame (Stack (frame:_)) = frame
currentFrame (Stack [])        = error "currentFrame: Empty call stack"

previousFrame :: CallStack -> Maybe StackFrame
previousFrame (Stack (_:frames)) = previousFrame' frames
  where previousFrame' (frame:frames)
          | builtinFunc frame = previousFrame' frames
          | otherwise         = Just frame
        previousFrame' [] = Nothing
previousFrame (Stack []) = error "previousFrame: Empty call stack"

activeFrame :: Task -> StackFrame
activeFrame = currentFrame . stack . taskState

frame :: (StackFrame -> a) -> MOO a
frame f = gets (f . currentFrame . stack)

caller :: (StackFrame -> a) -> MOO (Maybe a)
caller f = gets (fmap f . previousFrame . stack)

modifyFrame :: (StackFrame -> StackFrame) -> MOO ()
modifyFrame f = modify $ \state@State { stack = Stack (frame:frames) } ->
  state { stack = Stack (f frame : frames) }

setLineNumber :: LineNo -> MOO ()
setLineNumber lineNo = modifyFrame $ \frame -> frame { lineNumber = lineNo }

pushContext :: Context -> MOO ()
pushContext context = modifyFrame $ \frame ->
  frame { contextStack = context : contextStack frame }

pushTryFinallyContext :: MOO Value -> MOO ()
pushTryFinallyContext finally =
  pushContext TryFinally { finally = finally }

pushLoopContext :: Maybe Id -> Continuation -> MOO ()
pushLoopContext name break =
  pushContext Loop {
      loopName     = name
    , loopBreak    = break
    , loopContinue = undefined
  }

setLoopContinue :: Continuation -> MOO ()
setLoopContinue continue =
  modifyFrame $ \frame@Frame { contextStack = loop:loops } ->
    frame { contextStack = loop { loopContinue = continue } : loops }

popContext :: MOO ()
popContext = modifyFrame $ \frame@Frame { contextStack = _:contexts } ->
  frame { contextStack = contexts }

unwindContexts :: (Context -> Bool) -> MOO [Context]
unwindContexts p = do
  stack <- unwind =<< frame contextStack
  modifyFrame $ \frame -> frame { contextStack = stack }
  return stack

  where unwind :: [Context] -> MOO [Context]
        unwind stack@(this:next)
          | p this    = return stack
          | otherwise = do
              case this of
                TryFinally { finally = finally } -> do
                  modifyFrame $ \frame -> frame { contextStack = next }
                  void finally
                _ -> return ()
              unwind next
        unwind [] = return []

unwindLoopContext :: Maybe Id -> MOO Context
unwindLoopContext maybeName = do
  contexts <- unwindContexts testContext
  case contexts of
    (loop:_) -> return loop
    [] -> error "unwindLoopContext: No matching loop context found"

  where testContext :: Context -> Bool
        testContext Loop { loopName = name } =
          isNothing maybeName || maybeName == name
        testContext _ = False

breakLoop :: Maybe Id -> MOO Value
breakLoop maybeName = do
  loop <- unwindLoopContext maybeName
  case loop of
    Loop { loopBreak = Continuation break } -> break ()
    _ -> error "breakLoop: No matching loop context found"

continueLoop :: Maybe Id -> MOO Value
continueLoop maybeName = do
  loop <- unwindLoopContext maybeName
  case loop of
    Loop { loopContinue = Continuation continue } -> continue ()
    _ -> error "continueLoop: No matching loop context found"

-- | The default collection of verb variables
initVariables :: HashMap Id Value
initVariables = HM.fromList $ [
    ("player" , noObject)
  , ("this"   , noObject)
  , ("caller" , noObject)

  , ("args"   , emptyList)
  , ("argstr" , emptyString)

  , ("verb"   , emptyString)
  , ("dobjstr", emptyString)
  , ("dobj"   , noObject)
  , ("prepstr", emptyString)
  , ("iobjstr", emptyString)
  , ("iobj"   , noObject)
  ] ++ typeVariables

  where noObject = Obj nothing :: Value

        typeVariables :: [(Id, Value)]
        typeVariables = map (fmap $ Int . typeCode) [
            ("INT"  , TInt)
          , ("NUM"  , TInt)
          , ("FLOAT", TFlt)
          , ("LIST" , TLst)
          , ("STR"  , TStr)
          , ("OBJ"  , TObj)
          , ("ERR"  , TErr)
# ifdef MOO_WAIF
          , ("WAIF" , TWaf)
# endif
          ]

-- | Create a variable block for a verb by overriding the default.
mkVariables :: [(Id, Value)] -> HashMap Id Value
mkVariables = foldr (uncurry HM.insert) initVariables

newtype ExceptionHandler = Handler (Exception -> MOO Value)

-- | A MOO exception
data Exception = Exception {
    exceptionCode      :: Code
  , exceptionMessage   :: Message
  , exceptionValue     :: Value

  , exceptionCallStack :: CallStack
  , exceptionDebugBit  :: Bool
    -- ^ A copy of the debug bit from the verb frame in which the exception
    -- was raised
  }

type Code    = Value
type Message = StrT

initException :: Exception
initException = Exception {
    exceptionCode      = Err E_NONE
  , exceptionMessage   = Str.fromText (error2text E_NONE)
  , exceptionValue     = zero

  , exceptionCallStack = Stack []
  , exceptionDebugBit  = True
  }

newException :: Code -> Message -> Value -> Exception
newException code message value = initException {
    exceptionCode    = code
  , exceptionMessage = message
  , exceptionValue   = value
  }

-- | Install a local exception handler for the duration of the passed
-- computation.
catchException :: MOO a -> (Exception -> MOO a) -> MOO a
catchException action handler = callCC $ \k -> local (mkHandler k) action
  where mkHandler k env = env { exceptionHandler = Handler $ \e ->
                                 local (const env) $ handler e >>= k }

-- | Re-raise an exception to the next enclosing handler.
passException :: Exception -> MOO a
passException except = do
  Handler handler <- asks exceptionHandler
  handler except
  error "Returned from exception handler"

-- | Abort execution of the current computation and call the nearest enclosing
-- exception handler.
raiseException :: Code -> Message -> Value -> MOO a
raiseException code message value = do
  let except = newException code message value
  callStack <- gets stack
  debug <- frame debugBit
  passException except {
      exceptionCallStack = callStack
    , exceptionDebugBit  = debug
    }

-- | Execute the passed computation, capturing any exception raised in verb
-- frames with debug bit unset and returning the error code as an ordinary
-- value instead of propagating the exception.
handleDebug :: MOO Value -> MOO Value
handleDebug = (`catchException` handler)
  where handler Exception {
            exceptionDebugBit = False
          , exceptionCode     = code
          } = return code
        handler except = passException except

-- | Placeholder for features not yet implemented
notyet :: StrT -> MOO a
notyet = raiseException (Err E_QUOTA) "Not yet implemented" . Str

-- | Create and raise an exception for the given MOO error.
raise :: Error -> MOO a
raise err = raiseException (Err err) (Str.fromText $ error2text err) zero

-- | Verify that the given floating point number is neither infinite nor NaN,
-- raising 'E_FLOAT' or 'E_INVARG' respectively if so. Also, return the
-- corresponding MOO value.
checkFloat :: FltT -> MOO Value
checkFloat flt
  | isInfinite flt = raise E_FLOAT
  | isNaN      flt = raise E_INVARG
  | otherwise      = return (Flt flt)

-- | Verify that the given object has a programmer bit, raising 'E_PERM' if
-- not.
checkProgrammer' :: ObjId -> MOO ()
checkProgrammer' perm = do
  programmer <- maybe False objectProgrammer <$> getObject perm
  unless programmer $ raise E_PERM

-- | Verify that the current task permissions have programmer privileges,
-- raising 'E_PERM' if not.
checkProgrammer :: MOO ()
checkProgrammer = checkProgrammer' =<< frame permissions

-- | Determine whether the given object has its wizard bit set.
isWizard :: ObjId -> MOO Bool
isWizard = fmap (maybe False objectWizard) . getObject

-- | Verify that the given object is a wizard, raising 'E_PERM' if not.
checkWizard' :: ObjId -> MOO ()
checkWizard' perm = do
  wizard <- isWizard perm
  unless wizard $ raise E_PERM

-- | Verify that the current task permissions have wizard privileges, raising
-- 'E_PERM' if not.
checkWizard :: MOO ()
checkWizard = checkWizard' =<< frame permissions

-- | Verify that the current task permissions either have wizard privileges or
-- are the same as the given object, raising 'E_PERM' if not.
checkPermission :: ObjId -> MOO ()
checkPermission who = do
  perm <- frame permissions
  unless (perm == who) $ checkWizard' perm

-- | Verify that the given object is valid, raising 'E_INVARG' if not. Also,
-- return the referenced object.
checkValid :: ObjId -> MOO Object
checkValid = getObject >=> maybe (raise E_INVARG) return

-- | Verify that the given object is fertile for the current task permissions,
-- raising 'E_PERM' if not.
checkFertile :: ObjId -> MOO ()
checkFertile = getObject >=> maybe (raise E_PERM) checkFertile'
  where checkFertile' obj = unless (objectPermF obj) $
                            checkPermission (objectOwner obj)

-- | Verify that the named built-in property is not protected by
-- @$server_options.protect_/prop/@, or that the current task permissions have
-- wizard privileges if it is, raising 'E_PERM' otherwise.
checkProtectedProperty :: Id -> MOO ()
checkProtectedProperty name = do
  protected <- ($ name) <$> serverOption protectProperty
  when protected checkWizard

-- | Verify that the given /object/ does not have a recursive relationship
-- with the given /subject/, raising 'E_RECMOVE' if so.
checkRecurrence :: (Object -> Maybe ObjId)  -- ^ relationship projection
                -> ObjId                    -- ^ /subject/
                -> ObjId                    -- ^ /object/ to check
                -> MOO ()
checkRecurrence relation subject = checkRecurrence'
  where checkRecurrence' object = do
          when (object == subject) $ raise E_RECMOVE
          maybeObject <- getObject object
          maybe (return ()) checkRecurrence' $ maybeObject >>= relation

-- | Verify that the programmer has not reached their queued task limit
-- (before creating a new forked, suspended, or reading task).
checkQueuedTaskLimit :: MOO ()
checkQueuedTaskLimit = do
  programmer <- frame permissions
  programmerLimit <- readProperty programmer "queued_task_limit"
  limit <- case programmerLimit of
    Just (Int n) | n >= 0 -> return (Just $ fromIntegral n)
    _                     -> serverOption queuedTaskLimit

  case limit of
    Just limit -> do
      tasks <- filter ((== programmer) . taskOwner) <$> queuedTasks
      when (length tasks >= limit) $ raise E_QUOTA
    Nothing -> return ()

-- | Translate a MOO /binary string/ into a Haskell 'ByteString', raising
-- 'E_INVARG' if the MOO string is improperly formatted.
binaryString :: StrT -> MOO ByteString
binaryString = maybe (raise E_INVARG) return . Str.toBinary

-- | Generate and return a pseudorandom value in the given range, modifying
-- the local generator state.
random :: Random a => (a, a) -> MOO a
random = getRandom . randomR

-- | Split the local random number generator state in two, updating the local
-- state with one of them and returning the other.
newRandomGen :: MOO StdGen
newRandomGen = getRandom splitGen

getRandom :: (StdGen -> (a, StdGen)) -> MOO a
getRandom f = do
  (r, gen) <- f <$> gets randomGen
  modify $ \state -> state { randomGen = gen }
  return r

-- | Generate traceback lines for an exception, suitable for displaying to a
-- user.
formatTraceback :: Exception -> [Text]
formatTraceback except@Exception { exceptionCallStack = Stack frames } =
  T.splitOn "\n" $ builder2text $ execWriter (traceback frames)

  where traceback :: [StackFrame] -> Writer Builder ()
        traceback (frame:frames) =
          describeVerb frame >> tell ":  " >> traceback' frames
        traceback [] = traceback' []

        traceback' :: [StackFrame] -> Writer Builder ()
        traceback' frames = do
          tell $ Str.toBuilder (exceptionMessage except)
          forM_ frames $ \frame ->
            tell "\n... called from " >> describeVerb frame
          tell "\n(End of traceback)"

        describeVerb :: StackFrame -> Writer Builder ()
        describeVerb Frame { builtinFunc = False
                           , verbLocation = loc, verbFullName = name
                           , initialThis = this, lineNumber = line } = do
          tell $ "#" <> TLB.decimal loc <> ":" <> Str.toBuilder name
          when (this /= Obj loc) $ tell $ " (this == " <> toBuilder' this <> ")"
          when (line > 0)        $ tell $ ", line " <> TLB.decimal line
        describeVerb Frame { builtinFunc = True, verbName = name } =
          tell $ "built-in function " <> Str.toBuilder name <> "()"

-- | Begin the server shutdown process.
shutdown :: StrT -> MOO ()
shutdown message = do
  world <- getWorld
  delayIO $ void $ tryPutMVar (shutdownMessage world) (Str.toText message)
