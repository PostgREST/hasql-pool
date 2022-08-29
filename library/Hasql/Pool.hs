module Hasql.Pool
  ( -- * Pool
    Pool,
    acquire,
    acquireDynamically,
    release,
    use,

    -- * Errors
    UsageError (..),
  )
where

import Hasql.Connection (Connection)
import qualified Hasql.Connection as Connection
import Hasql.Pool.Prelude
import Hasql.Session (Session)
import qualified Hasql.Session as Session

data ReuseConnection = Keep | Close

-- | A pool of connections to DB.
data Pool = Pool
  { -- | Connection settings.
    poolFetchConnectionSettings :: IO Connection.Settings,
    -- | Avail connections.
    poolConnectionQueue :: TQueue Connection,
    -- | Remaining capacity.
    -- The pool size limits the sum of poolCapacity, the length
    -- of length poolConnectionQueue and the number of in-flight
    -- connections.
    poolCapacity :: TVar Int,
    -- | Whether to return a connection to the pool.
    poolReuseToggle :: TVar (TVar ReuseConnection)
  }

-- | Given the pool-size and connection settings create a connection-pool.
--
-- No connections actually get established by this function. It is delegated
-- to 'use'.
acquire :: Int -> Connection.Settings -> IO Pool
acquire poolSize connectionSettings =
  acquireDynamically poolSize (pure connectionSettings)

-- | Given the pool-size and connection settings constructor action
-- create a connection-pool.
--
-- No connections actually get established by this function. It is delegated
-- to 'use'.
--
-- In difference to 'acquire' new settings get fetched each time a connection
-- is created. This may be useful for some security models.
acquireDynamically :: Int -> IO Connection.Settings -> IO Pool
acquireDynamically poolSize fetchConnectionSettings = do
  Pool fetchConnectionSettings
    <$> newTQueueIO
    <*> newTVarIO poolSize
    <*> (newTVarIO =<< newTVarIO Keep)

-- | Release all the idle connections in the pool, and mark the in-use connections
-- to be released on return. Any connections acquired after the call will be
-- newly established.
release :: Pool -> IO ()
release Pool {..} =
  join . atomically $ do
    prevReuseToggle <- readTVar poolReuseToggle
    writeTVar prevReuseToggle Close
    newReuseToggle <- newTVar Keep
    writeTVar poolReuseToggle newReuseToggle
    conns <- flushTQueue poolConnectionQueue
    modifyTVar' poolCapacity (+ (length conns))
    return $ forM_ conns Connection.release

-- | Use a connection from the pool to run a session and return the connection
-- to the pool, when finished.
--
-- Session failing with a 'Session.ClientError' gets interpreted as a loss of
-- connection. In such case the connection does not get returned to the pool
-- and a slot gets freed up for a new connection to be established the next
-- time one is needed. The error still gets returned from this function.
use :: Pool -> Session.Session a -> IO (Either UsageError a)
use Pool {..} sess =
  join . atomically $ do
    reuseToggle <- readTVar poolReuseToggle
    asum
      [ readTQueue poolConnectionQueue <&> onConn reuseToggle,
        do
          capVal <- readTVar poolCapacity
          if capVal > 0
            then do
              writeTVar poolCapacity $! pred capVal
              return $ onNewConn reuseToggle
            else retry
      ]
  where
    onNewConn reuseToggle = do
      settings <- poolFetchConnectionSettings
      connRes <- Connection.acquire settings
      case connRes of
        Left connErr -> do
          atomically $ modifyTVar' poolCapacity succ
          return $ Left $ ConnectionUsageError connErr
        Right conn -> onConn reuseToggle conn
    onConn reuseToggle conn = do
      sessRes <- Session.run sess conn
      case sessRes of
        Left err -> case err of
          Session.QueryError _ _ (Session.ClientError _) -> do
            atomically $ modifyTVar' poolCapacity succ
            return $ Left $ SessionUsageError err
          _ -> do
            returnConn
            return $ Left $ SessionUsageError err
        Right res -> do
          returnConn
          return $ Right res
      where
        returnConn =
          join . atomically $ do
            reuse <- readTVar reuseToggle
            case reuse of
              Keep -> writeTQueue poolConnectionQueue conn $> return ()
              Close -> do
                modifyTVar' poolCapacity succ
                return $ Connection.release conn

-- | Union over all errors that 'use' can result in.
data UsageError
  = -- | Attempt to establish a connection failed.
    ConnectionUsageError Connection.ConnectionError
  | -- | Session execution failed.
    SessionUsageError Session.QueryError
  deriving (Show, Eq)

instance Exception UsageError
