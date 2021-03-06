-- | Here is main monad of server is declared. Each handler operates in the
-- monad.
module Kaissa.Bot.Monad(
    ServerM
  , ServerEnv
  , newServerEnv
  , runServerM
  , runServerMIO
  , serverMToHandler
  -- * Helpers
  , getConfig
  , runTelegram
  , runTelegram'
  , pollTelegramUpdates
  , logInfo
  , logWarn
  , logError
  , logDebug
  , showt
  ) where

import Control.Lens
import Control.Monad.Base
import Control.Monad.Except
import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Data.ByteString (ByteString)
import Data.IORef
import Data.Monoid
import Data.Text (Text, pack)
import Data.Text.Encoding
import Kaissa.Bot.Config
import Network.HTTP.Client      (newManager, Manager)
import Network.HTTP.Client.TLS  (tlsManagerSettings)
import Servant.Common.Req
import Servant.Server
import Web.Telegram.API.Bot.API
import Web.Telegram.API.Bot.API.Updates
import Web.Telegram.API.Bot.Data
import Web.Telegram.API.Bot.Requests
import Web.Telegram.API.Bot.Responses

import qualified Control.Immortal as Immortal
import qualified Data.ByteString.Lazy as BL
import qualified Data.Foldable as F

-- | Environment of 'ServerM' monad
data ServerEnv = ServerEnv {
  -- | Stored server config
  serverConfig  :: !Config
  -- | HTTPS client manager
, serverManager :: !Manager
  -- | ID of last processed update from Telegram
, serverTelegramOffset :: !(IORef (Maybe Int))
}

-- | Create fresh server environment
newServerEnv :: Config -> (Update -> ServerM ()) -> IO ServerEnv
newServerEnv cfg sink = do
  mng <- newManager tlsManagerSettings
  offsetRef <- liftIO $ newIORef Nothing
  let env = ServerEnv {
          serverConfig  = cfg
        , serverManager = mng
        , serverTelegramOffset = offsetRef
        }
  runServerMIO env $ telegramWorker sink
  pure env

-- | Main monad of server, each handler of API operates in the monad.
newtype ServerM a = ServerM { unServerM :: ReaderT ServerEnv (LoggingT Handler) a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO, MonadLogger, MonadError ServantErr)

-- | Helper for 'MonadBaseControl' instance
newtype StMServerM a = StMServerM { unStMServerM :: StM (ReaderT ServerEnv (LoggingT Handler)) a }

-- | Allow unlifting IO arguments of functions into the monad
instance MonadBaseControl IO ServerM where
  type StM ServerM a = StMServerM a
  liftBaseWith f = ServerM $ liftBaseWith $ \q -> f (fmap StMServerM . q . unServerM)
  restoreM = ServerM . restoreM . unStMServerM

-- | Getting server configuration
getConfig :: ServerM Config
getConfig = ServerM $ asks serverConfig

-- | Getting manager for connecting another servers
getManager :: ServerM Manager
getManager = ServerM $ asks serverManager

-- | Execute server monad to default servant handler
runServerM :: ServerEnv -> ServerM a -> Handler a
runServerM e m = runStdoutLoggingT $ runReaderT (unServerM m) e

-- | Run server handler in IO monad
runServerMIO :: ServerEnv -> ServerM a -> IO a
runServerMIO e m = do
  er <- runExceptT $ runServerM e m
  case er of
    Left er -> fail . show $ er
    Right a -> pure a

-- | Transformation from 'ServerM' monad to 'Handler'
serverMToHandler :: ServerEnv -> ServerM :~> Handler
serverMToHandler e = Nat (runServerM e)

-- | Shortcut for displaying something as text
showt :: Show a => a -> Text
showt = pack . show

-- | Shortcut for displaying something as bytestring
showb :: Show a => a -> ByteString
showb = encodeUtf8 . showt

-- | Run telegram request in server monad
runTelegram :: TelegramClient a -> ServerM (Either ServantError a)
runTelegram m = do
  cfg <- getConfig
  mng <- getManager
  liftIO $ runClient m (Token $ cfg ^. configToken) mng

-- | Run telegram request in server monad and rethrow errors and log them
runTelegram' :: TelegramClient a -> ServerM a
runTelegram' m = do
  res <- runTelegram m
  case res of
    Left err -> do
      logInfoN $ "runTelegram: " <> showt err
      throwError err500 { errBody = BL.fromStrict $ showb err }
    Right a -> pure a

-- | Poll next updates from Telegram server
pollTelegramUpdates :: ServerM [Update]
pollTelegramUpdates = do
  cfg <- getConfig
  offsetRef <- ServerM $ asks serverTelegramOffset
  offset <- liftIO $ readIORef offsetRef
  mng <- getManager
  let token = Token $ cfg ^. configToken
  res <- liftIO $ getUpdates token offset (cfg ^. configPollLimit) (cfg ^. configPollTimeout) mng
  case res of
    Left e -> do
      logInfoN $ "pollTelegramUpdates: " <> showt e
      throwError err500 { errBody = BL.fromStrict $ showb e }
    Right resp -> do
      let upds = result resp
      unless (null upds) $ liftIO $ writeIORef offsetRef (Just . (+1) . maximum . fmap update_id $ upds)
      return upds

-- | Make immortal worker that polls updates from telegram
telegramWorker :: (Update -> ServerM ()) -> ServerM ()
telegramWorker sink = void $ Immortal.createWithLabel "telegramWorker" $ const $ forever $ do
  updates <- pollTelegramUpdates
  F.traverse_ sink updates
