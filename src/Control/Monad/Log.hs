{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE AutoDeriveTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Control.Monad.Log
       ( -- * Introduction
         -- $intro

         -- * Getting Started
         -- $tutorialIntro

         -- ** Working with @logging-effect@
         -- *** Emitting log messages
         -- $tutorial-monadlog

         -- *** Outputting with 'LoggingT'
         -- $tutorial-loggingt

         -- *** Adapting and composing logging
         -- $tutorial-composing
         
         -- * @MonadLog@
         MonadLog(..), mapLogMessage,

         -- * Message transformers
         -- ** Timestamps
         WithTimestamp(..), withTimestamps, renderWithTimestamp,
         -- ** Severity
         WithSeverity(..), Severity(..), renderWithSeverity,
         -- ** Call stacks
         WithCallStack(..), withCallStack, renderWithCallStack, 

         -- * @LoggingT@, a general handler
         LoggingT, pattern LoggingT, runLoggingT, mapLoggingT,

         -- ** 'LoggingT' Handlers
         Handler, withFDHandler,

         -- *** Batched handlers
         withBatchedHandler, BatchingOptions(..), defaultBatchingOptions,

         -- * Pure logging
         PureLoggingT(..), runPureLoggingT,

         -- * Discarding logs
         DiscardLoggingT, discardLogging

         -- * Aside: An @mtl@ refresher
         -- $tutorialMtl
       ) where

import GHC.Stack
import Data.Coerce
import Control.Concurrent.STM
import Control.Concurrent.STM.Delay
import Control.Applicative
import Control.Monad (MonadPlus, guard)
import Control.Monad.Catch
       (MonadThrow(..), MonadMask(..), MonadCatch(..), bracket)
import Control.Monad.Cont.Class (MonadCont(..))
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Fix
import Control.Monad.Free.Class (MonadFree(..))
import Control.Monad.RWS.Class (MonadRWS(..))
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Writer.Class (MonadWriter(..))
import Control.Monad.Trans.State.Strict (StateT(..))
import Control.Monad.Trans.Writer.Strict (runWriterT)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.Chan
       (newChan, writeChan, getChanContents)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Reader (ReaderT(..))
import Data.Char
import Data.Monoid
import Data.Text (Text, pack)
import Data.Text.IO (hPutStr)
import Data.Time (UTCTime, TimeLocale, getCurrentTime)
import System.IO (Handle, stderr, stdout)
import qualified Data.Text as T

--------------------------------------------------------------------------------
-- | The class of monads that support logging.
class Monad m => MonadLog message m | m -> message where
  -- | Append a message to the log for this computation.
  logMessage :: message -> m ()

-- | Re-interpret the log messages in one computation. This can be useful to
-- embed a computation with one log type in a larger general computation.
mapLogMessage
  :: MonadLog message' m
  => (message -> message') -> LoggingT message m a -> m a
mapLogMessage f m =
  runLoggingT m
              (logMessage . f)

--------------------------------------------------------------------------------
-- | Add \"Severity\" information to a log message. This is often used to convey
-- how significant a log message is.
data WithSeverity a =
  WithSeverity {msgSeverity :: Severity -- ^ Retrieve the 'Severity' a message.
               ,discardSeverity :: a -- ^ View the underlying message.
               }
  deriving (Eq,Ord,Read,Show,Functor)

-- | Classes of severity for log messages. These have been chosen to match
-- @syslog@ severity levels
data Severity =
 Emergency -- ^ System is unusable. By @syslog@ convention, this level should not be used by applications.
 | Alert -- ^ Should be corrected immediately.
 | Critical -- ^ Critical conditions.
 | Error -- ^ Error conditions.
 | Warning -- ^ May indicate that an error will occur if action is not taken.
 | Notice -- ^ Events that are unusual, but not error conditions.
 | Informational -- ^ Normal operational messages that require no action.
 | Debug -- ^ Information useful to developers for debugging the application.
  deriving (Eq,Enum,Bounded,Read,Show,Ord)

-- | Given a way to render the underlying message @a@ render a message with its
-- timestamp.
--
-- >>> renderWithSeverity id Debug (WithSeverity Info "Flux capacitor is functional")
-- [Info] Flux capacitor is functional
renderWithSeverity
  :: (a -> Text) -> (WithSeverity a -> Text)
renderWithSeverity k (WithSeverity u a) = "[" <> pack (show u) <> "] " <> k a

--------------------------------------------------------------------------------
-- | Add a timestamp to log messages.
data WithTimestamp a =
  WithTimestamp {discardTimestamp :: a -- ^ Retireve the time a message was logged.
                ,msgTimestamp :: UTCTime -- ^ View the underlying message.
                }
  deriving (Functor,Traversable,Foldable)

-- | Given a way to render the underlying message @a@ and a way to format
-- 'UTCTime', render a message with its timestamp.
--
-- >>> renderWithTimestamp (formatTime defaultTimeLocale rfc822DateFormat) id timestamppedLogMessage
-- [Tue, 19 Jan 2016 11:29:42 UTC] Setting target speed to plaid
renderWithTimestamp :: (UTCTime -> String)
                       -- ^ How to format the timestamp. 
                    -> (a -> Text)
                       -- ^ How to render the rest of the message.
                    -> (WithTimestamp a -> Text)
renderWithTimestamp formatter k (WithTimestamp a t) =
  "[" <> pack (formatter t) <> "] " <> k a

-- TODO Is this faster with a custom handler?
-- logMessage msg = liftIO getCurrentTime >>= \t -> lift (logMessage (WithTimestamp t msg))
-- | Add timestamps to all messages logged. Timestamps will be calculated
-- synchronously when log entries are emitted.
withTimestamps :: (MonadLog (WithTimestamp message) m,MonadIO m)
               => LoggingT message m a -> m a
withTimestamps m =
  runLoggingT
    m
    (\msg ->
       do now <- liftIO getCurrentTime
          logMessage (WithTimestamp msg now))

--------------------------------------------------------------------------------
data WithCallStack a = WithCallStack { msgCallStack :: CallStack
                                     , discardCallStack :: a }
  deriving (Functor,Traversable,Foldable)

renderWithCallStack :: (a -> Text) -> WithCallStack a -> Text
renderWithCallStack k (WithCallStack stack msg) =
  k msg <> "\n" <> T.pack (showCallStack stack)

withCallStack :: (?stack :: CallStack) => a -> WithCallStack a
withCallStack = WithCallStack (popCallStack ?stack) 

-- TODO
popCallStack = id

--------------------------------------------------------------------------------
-- | 'LoggingT' is a very general handler for the 'MonadLog' effect. Whenever a
-- log entry is emitted, the given 'Handler' is invoked, producing some
-- side-effect (such as writing to @stdout@, or appending a database table).
newtype LoggingT message m a =
  MkLoggingT {unLoggingT :: ReaderT (Handler m message) m a}
  deriving (Monad,Applicative,Functor,MonadFix,Alternative,MonadPlus,MonadIO,MonadWriter w,MonadCont,MonadError e,MonadMask,MonadCatch,MonadThrow,MonadState s)

-- | 'LoggingT' @messasge@ @m@ is isomorphic to @Handler message m -> m ()@.
-- This is a reader monad with base effects in @m@ and access to
-- @Handler message m@.This pattern synonym witnesses that isomorphism.
pattern LoggingT f = MkLoggingT (ReaderT f)

-- | Given a 'Handler' for a given @message@, interleave this 'Handler' into the
-- underlying @m@ computation whenever 'logMessage' is called.
runLoggingT
  :: LoggingT message m a -> Handler m message -> m a
runLoggingT (LoggingT m) handler = m handler

instance MonadTrans (LoggingT message) where
  lift = LoggingT . const

instance MonadReader r m => MonadReader r (LoggingT message m) where
  ask = lift ask
  local f (LoggingT m) = LoggingT (local f . m)
  reader f = lift (reader f)

-- | The main instance of 'MonadLog', which dispatches 'logMessage' calls to a 'Handler'.
instance Monad m => MonadLog message (LoggingT message m) where
  logMessage m = LoggingT (\f -> f m)

instance MonadRWS r w s m => MonadRWS r w s (LoggingT message m)

instance (Functor f,MonadFree f m) => MonadFree f (LoggingT message m)

-- | 'LoggingT' unfortunately does admit an instance of the @MFunctor@ type
-- class, which provides the @hoist@ method to change the monad underneith
-- a monad transformer. However, it is possible to do this with 'LoggingT'
-- provided that you have a way to re-interpret a log handler in the
-- original monad.
mapLoggingT :: (forall a. (Handler m message -> m a) -> (Handler n message' -> n a))
            -> LoggingT message m a
            -> LoggingT message' n a
mapLoggingT eta (LoggingT f) = LoggingT (eta f)

--------------------------------------------------------------------------------
-- | Handlers are mechanisms to interpret the meaning of logging as an action
-- in the underlying monad. They are simply functions from log messages to
-- @m@-actions.
type Handler m message = message -> m ()

-- | Options that be used to configure 'withBatchingHandler'.
data BatchingOptions =
  BatchingOptions {flushMaxDelay :: Int -- ^ The maximum amount of time to wait between flushes
                  ,flushMaxQueueSize :: Int -- ^ The maximum amount of messages to hold in memory between flushes}
                  ,blockWhenFull :: Bool -- ^ If the 'Handler' becomes full, 'logMessage' will block until the queue is flushed if 'blockWhenFull' is 'True', otherwise it will drop that message and continue.
                  }
  deriving (Eq,Ord,Read,Show)

-- | Defaults for 'BatchingOptions'
--
-- @
-- 'defaultBatchingOptions' = 'BatchingOptions' {'flushMaxDelay' = 1000000
--                                          ,'flushMaxQueueSize' = 100
--                                          ,'blockWhenFull' = 'True'}
-- @
defaultBatchingOptions :: BatchingOptions
defaultBatchingOptions = BatchingOptions 1000000 100 True

-- | Create a new batched handler. Batched handlers take batches of messages to
-- log at once, which can be more performant than logging each individual
-- message.
--
-- A batched handler flushes under three criteria:
--
--   1. The flush interval has elapsed and the queue is not empty.
--   2. The queue has become full and needs to be flushed.
--   3. The scope of 'withBatchedHandler' is exited.
--
-- Batched handlers queue size and flush period can be configured via
-- 'BatchingOptions'.
withBatchedHandler :: (MonadIO io,MonadMask io)
                   => BatchingOptions
                   -> ([message] -> IO ())
                   -> (Handler io message -> io a)
                   -> io a
withBatchedHandler BatchingOptions{..} flush k =
  do do closed <- liftIO (newTVarIO False)
        channel <- liftIO (newTBQueueIO flushMaxQueueSize)
        bracket (liftIO (async (repeatWhileTrue (publish closed channel))))
                (\publisher ->
                   do liftIO (do atomically (writeTVar closed True)
                                 wait publisher))
                (\_ ->
                   k (\msg ->
                        liftIO (atomically
                                  (writeTBQueue channel msg <|>
                                   check (not blockWhenFull)))))
  where repeatWhileTrue m =
          do again <- m
             if again
                then repeatWhileTrue m
                else return ()
        publish closed channel =
          do flushAlarm <- newDelay flushMaxDelay
             (messages,stillOpen) <-
               atomically
                 (do messages <-
                       flushAfter flushAlarm <|> flushFull <|> flushOnClose
                     stillOpen <- fmap not (readTVar closed)
                     return (messages,stillOpen))
             flush messages
             pure stillOpen
          where flushAfter flushAlarm =
                  do waitDelay flushAlarm
                     isEmptyTBQueue channel >>= guard . not
                     emptyTBQueue channel
                flushFull =
                  do isFullTBQueue channel >>= guard
                     emptyTBQueue channel
                flushOnClose =
                  do readTVar closed >>= guard
                     emptyTBQueue channel
        emptyTBQueue q =
          do mx <- tryReadTBQueue q
             case mx of
               Nothing -> return []
               Just x -> fmap (x :) (emptyTBQueue q)
  
-- | 'withFDHandler' creates a new 'Handler' that will append a given file
-- descriptor (or 'Handle', as it is known in the "base" library). Note that
-- this 'Handler' requires log messages to be of type 'Text'. 
--
-- These 'Handler's asynchronously log messages to the given file descriptor,
-- rather than blocking.
withFDHandler
  :: (MonadIO io,MonadMask io)
  => BatchingOptions -> Handle -> (Handler io Text -> io a) -> io a
withFDHandler options fd =
  withBatchedHandler options
                     (hPutStr fd . T.unlines)

--------------------------------------------------------------------------------
-- | A 'MonadLog' handler optimised for pure usage. Log messages are accumulated
-- strictly, given that messasges form a 'Monoid'.
newtype PureLoggingT log m a = MkPureLoggingT (StateT log m a)
  deriving (Functor,Applicative,Monad,MonadFix,MonadCatch,MonadThrow,MonadIO,MonadMask,MonadReader r,MonadWriter w,MonadCont,MonadError e,Alternative,MonadPlus)

runPureLoggingT
  :: Monoid log
  => PureLoggingT log m a -> m (a,log)
runPureLoggingT (MkPureLoggingT (StateT m)) = m mempty

mkPureLoggingT
  :: (Monad m,Monoid log)
  => m (a,log) -> PureLoggingT log m a
mkPureLoggingT m =
  MkPureLoggingT
    (StateT (\s ->
               do (a,l) <- m
                  return (a,s <> l)))

instance MonadTrans (PureLoggingT log) where
  lift = MkPureLoggingT . lift

instance (Functor f, MonadFree f m) => MonadFree f (PureLoggingT log m)

-- | A pure handler of 'MonadLog' that accumulates log messages under the structure of their 'Monoid' instance.
instance (Monad m, Monoid log) => MonadLog log (PureLoggingT log m) where
  logMessage message = mkPureLoggingT (return ((), message)) 

instance MonadRWS r w s m => MonadRWS r w s (PureLoggingT message m)

instance MonadState s m => MonadState s (PureLoggingT log m) where
  state f = lift (state f) 
  get = lift get
  put = lift . put 

--------------------------------------------------------------------------------
newtype DiscardLoggingT message m a =
  DiscardLoggingT {discardLogging :: m a}
  deriving (Functor,Applicative,Monad,MonadFix,MonadCatch,MonadThrow,MonadIO,MonadMask,MonadReader r,MonadWriter w,MonadCont,MonadError e,Alternative,MonadPlus,MonadState s,MonadRWS r w s)

instance MonadTrans (DiscardLoggingT message) where
  lift = DiscardLoggingT

instance (Functor f,MonadFree f m) => MonadFree f (DiscardLoggingT message m)

-- | The trivial instance of 'MonadLog' that simply discards all messages logged.
instance Monad m => MonadLog message (DiscardLoggingT message m) where
  logMessage _ = return ()

--------------------------------------------------------------------------------
-- Test cases
testApp :: MonadLog (WithSeverity Text) m
        => m ()
testApp =
  do logMessage (WithSeverity Informational "Don't mind me")
     logMessage (WithSeverity Error "But do mind me!")

withSplitLogging
  :: LoggingT (WithSeverity Text) IO () -> IO ()
withSplitLogging m =
  withFDHandler defaultBatchingOptions stderr $
  \stderrHandler ->
    withFDHandler defaultBatchingOptions stdout $
    \stdoutHandler ->
      runLoggingT
        m
        (\message ->
           case msgSeverity message of
             Error -> stdoutHandler (renderWithSeverity id message)
             _ ->
               stdoutHandler
                 (renderWithSeverity (T.map toUpper)
                                     message))

{- $intro

"Control.Monad.Log" provides a toolkit for general logging in Haskell programs
and libraries. The library consists of the type class 'MonadLog' to add log
output to computations, and this library comes with a set of instances to help
you decide how this logging should be performed. There are predefined handlers
to write to file handles, to accumulate logs purely, or to discard logging
entirely.

Unlike other logging libraries available on Hackage, 'MonadLog' does /not/
assume that you will be logging text information. Instead, the choice of logging
data is up to you. This leads to a highly compositional form of logging, with
the able to reinterpret logs into different formats, and avoid throwing
information away if your final output is structured (such as logging to a
relational database).

-}

{- $tutorialIntro

"Control.Monad.Log" is designed to be used via the 'MonadLog' type class and
encourages an "mtl" style approach to programming. If you're not familiar with
the @mtl@ library, this approach uses type classes to keep the choice of monad
polymorphic as you program, and you later choose a specific monad transformer
stack when you execute your program. For more information, see
<#tutorialMtl Aside: An mtl refresher>.

-}

{- $tutorialMtl #tutorialMtl#

If you are already familiar with @mtl@ you can skip this section. This is not
designed to be an exhaustive introduction to the @mtl@ library, but hopefully
via a short example you'll have a basic familarity with the approach.

In this example, we'll write a program with access to state and general 'IO'
actions. One way to do this would be to work with monad transformers, stacking
'StateT' on top of 'IO':

@
import Control.Monad.Trans.State.Strict (StateT, get, put)
import Control.Monad.Trans.Class (lift)

transformersProgram :: StateT Int IO ()
transformersProgram = do
  stateNow <- get
  lift launchMissles
  put (stateNow + 42)
@

This is OK, but it's not very flexible. For example, the transformers library
actually provides us with two implementations of state monads - strict and a
lazy variant. In the above approach we have forced the user into a choice (we
chose the strict variant), but this can be undesirable. We could imagine that
in the future there may be even more implementations of state monads (for
example, a state monad that persists state entirely on a remote machine) - if
requirements change we are unable to reuse this program without changing its
type.

With the @mtl@, we instead program to an /abstract specification/ of the effects
we require, and we postpone the choice of handler until the point when the
computation is ran.

Rewriting the @transformersProgram@ using @mtl@, we have the following:

@
import Control.Monad.State.Class (MonadState(get, put))
import Control.Monad.IO.Class (MonadIO(liftIO))

mtlProgram :: (MonadState Int m, MonadIO m) => m ()
mtlProgram = do
  stateNow <- get
  liftIO launchMissles
  put (stateNow + 42)
@

Notice that @mtlProgram@ doesn't specify a concrete choice of state monad. The
"transformers" library gives us two choices - strict or lazy state monads. We
make the choice of a specific monad stack when we run our program:

@
import Control.Monad.Trans.State.Strict (execStateT)

main :: IO ()
main = execStateT mtlProgram 99
@

Here we chose the strict variant via 'execStateT'. Using 'execStateT'
*eliminates* the 'MonadState' type class from @mtlProgram@, so now we only have
to fulfill the 'MonadIO' obligation. There is only one way to handle this, and
that's by working in the 'IO' monad. Fortunately we're inside the @main@
function, which is in the 'IO' monad, so we're all good.

-}

{- $tutorial-monadlog

To add logging to your applications, you will need to make two changes.

First, use the 'MonadLog' type class to indicate that a computation has
access to logging. 'MonadLog' is parameterized on the type of messages
that you intend to log. In this example, we will log 'Text' that is
wrapped in the 'WithSeverity'. 

@
testApp :: MonadLog (WithSeverity Text) m => m ()
testApp = do
  logMessage (WithSeverity Info "Don't mind me")
  logMessage (WithSeverity Error "But do mind me!")
@

Note that this does /not/ specify where the logs "go", we'll address that when
we run the program.

-}

{- $tutorial-loggingt

Next, we need to run this computation under a 'MonadLog' effect handler. The
most flexible handler is 'LoggingT'. 'LoggingT' runs a 'MonadLog' computation
by providing it with a 'Handler', which is a computation that can be in the
underlying monad.

For example, we can easily fulfill the 'MonadLog' type class by just using
'print' as our 'Handler':

>>> runLoggingT testApp print
WithSeverity Info "Don't mind me"
WithSeverity Error "But do mind me!"

The log messages are printed according to their 'Show' instances, and while
this works is not particularly user friendly. As 'Handler's are just functions
from log messages to monadic actions, we can easily reformat log messages.
"logging-effect" comes with a few "log message transformers" (such as
'WithSeverity'), and each of these message transformers has a canonical way to
render in a human-readable format:

>>> runLoggingT testApp (print . renderWithSeverity id)
[Info] Don't mind me
[Error] But do mind me!

That's looking much more usable - and in fact this approach is probably fine for
command line applications.

However, for longer running high performance applications there is a slight
problem. Remember that 'runLoggingT' simply interleaves the given 'Handler'
whenever 'logMessage' is called. By providing 'print' as a 'Handler', our
application will actually block until the log is complete. This is undesirable
for high performance applications, where it's much better to log asynchronously.

"logging-effect" comes with "batched handlers" for this problem. Batched handlers
are handlers that log asynchronously, are flushed periodically, and have maximum
memory impact. Batched handlers are created with 'withBatchedHandler', though
if you are just logging to file descriptors you can also use 'withFDHandler'.
We'll use this next to log to @STDOUT@:

@
main :: IO ()
main =
  withFDHandler defaultBatchingOptions stdout $ \logToStdout ->
  runLoggingT testApp logToStdout
@

Finally, as 'Handler's are just functions (we can't stress this enough!) you
are free to slice-and-dice your log messages however you want. As our log
messages are structured, we can pattern match on the messages and dispatch them
to multiple handlers. In this final example of using 'LoggingT' we'll split
our log messages between @STDOUT@ and @STDERR@, and change the formatting of
error messages:

@
main :: IO ()
main = do
  'withFDHandler' 'defaultBatchingOptions' 'stderr' $ \stderrHandler ->
  'withFDHandler' 'defaultBatchingOptions' 'stdout' $ \stdoutHandler ->
  'runLoggingT' m 
              (\\message ->
                 case 'msgSeverity' message of
                   'Error' -> stderrHandler  ("T".'T.map' 'toUpper' ('discardSeverity' message))
                   _ -> stdoutHandler ('renderWithSeverity' id message))
@

>>> main
STDOUT: [Info] Don't mind me!
STDERR: BUT DO MIND ME!

-}

{- $tutorial-composing

So far we've considered very small applications where all log messages fit nicely
into a single type. However, as applications grow and begin to reuse components,
it's unlikely that this approach will scale. 'Control.Monad.Log' comes with a
mapping function - 'mapLogMessage' - which allows us to map log messages from one
type to another (just like how we can use 'map' to change elements of a list).

For example, we've already seen the basic @testApp@ computation above that used
'WithSeverity' to add severity information to log messages. Elsewhere we might
have some older code that doesn't yet have any severity information:

@
legacyCode :: MonadLog Text m => m ()
legacyCode = logMessage "Does anyone even remember writing this function?"
@

Here @legacyCode@ is only logging 'Text', while our @testApp@ is logging
'WithSeverity' 'Text'. What happens if we compose these programs?

>>> :t testApp >> legacyCode
  Couldn't match type ‘[Char]’ with ‘WithSeverity Text’

Whoops! 'MonadLog' has /functional dependencies/ on the type class which means
that there can only be a single way to log per monad. One solution might be
to 'lift' one set of logs into the other:

>>> :t testApp >> lift legacyCode
  :: (MonadTrans t, MonadLog Text m, MonadLog (WithSeverity Text) (t m)) => t m ()

And indeed, this is /a/ solution, but it's not a particularly nice one.

Instead, we can map both of these computations into a common log format:

>>> :t mapLogMessage Left testApp >> mapLogMessage Right (logMessage "Hello")
  :: (MonadLog (Either (WithSeverity Text) Text) m) => m ()

This is a trivial way of combining two different types of log message. In larger
applications you will probably want to define a new sum-type that combines all of
your log messages, and generally sticking with a single log message type per
application. 

-}
