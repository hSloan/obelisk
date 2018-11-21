{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Obelisk.Api where

import Prelude hiding ((.))

import Obelisk.Api.Pipeline
import Obelisk.Db
import Obelisk.Postgres.Replication
import Obelisk.Postgres.LogicalDecoding.Plugins.TestDecoding
import Obelisk.Request (Request)

import Control.Category
import Control.Concurrent.Async
import Control.Concurrent.STM (TChan, atomically, readTChan, writeTChan, newTChanIO)
import Control.Monad (forever)
import Control.Monad.Reader
import Control.Monad.Trans (lift)
import Data.Aeson (FromJSON, ToJSON)
import Data.Attoparsec.ByteString
import Data.ByteString (ByteString)
import Data.Default
import Data.Map.Monoidal (MonoidalMap)
import Data.MonoidMap (MonoidMap (..))
import Data.Pool (withResource)
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as PG
import Reflex (FunctorMaybe (..))
import Reflex.Patch (Group)
import Reflex.Query.Class (QueryResult, SelectedCount (..))
import Snap.Core (Snap)

{-
-- | A way for a pipeline to retrieve data
newtype QueryHandler q m = QueryHandler
  { runQueryHandler :: q -> m (QueryResult q) }

-- | A way to push data into a pipeline
newtype Recipient q m = Recipient
  { tellRecipient :: QueryResult q -> m () }

-- | A way of attaching to (and later detaching from) a pipeline
newtype Registrar q = Registrar { unRegistrar :: Recipient q IO -> IO (QueryHandler q IO, IO ()) }

-- | A way of connecting a source of data to a consumer of data. The consumer
-- can pull data from the datasource and the datasource can push data to the
-- consumer.
--
-- q is the consumer side
-- q' is the datasource side
newtype Pipeline m q q' = Pipeline { unPipeline :: QueryHandler q' m -> Recipient q m -> IO (QueryHandler q m, Recipient q' m) }

instance Category (Pipeline m) where
  id = Pipeline $ \qh r -> return (qh, r)
  Pipeline f . Pipeline g = Pipeline $ \qh r -> do
    rec (qh'', r') <- g qh' r
        (qh', r'') <- f qh r'
    return (qh'', r'')

-- | A key used to track particular consumers
newtype ClientKey = ClientKey { unClientKey :: Integer }
  deriving (Eq, Ord, Show)

servePostgres
  :: ( Monoid q'
     , Semigroup q'
     )
  => Pool Postgresql -- ^ The DB to connect to
  -> (forall a. request a -> write a)
  -> (ByteString -> q' -> read (QueryResult q'))
  -> (q' -> read (QueryResult q))
  -> Pipeline IO q q'
  -> (Snap () -> IO a)
  -> IO a
servePostgres db handleApi handleNotify handleQuery pipe = do
  (getNextNotification, finalizeListener) <- startNotificationListener db
  rec (qh, finalizeFeed) <- feedPipeline (handleNotify <$> getNextNotification) handleQuery r
      (qh', r) <- unPipeline pipe qh r'
      (r', handleListen) <- connectPipelineToWebsockets "" (RequestHandler handleApi) qh'
  return (handleListen, finalizeFeed >> finalizeListener)
-}

newtype ReadDb a = ReadDb { unReadDb :: ReaderT PG.Connection IO a }
  deriving (Functor, Applicative, Monad)

readTransaction :: PG.Connection -> ReadDb a -> IO a
readTransaction conn (ReadDb r) = PG.withTransactionModeRetry m PG.isSerializationError conn $ runReaderT r conn
  where m = PG.TransactionMode
          { PG.isolationLevel = PG.Serializable
          , PG.readWriteMode = PG.ReadOnly
          }

newtype WriteDb a = WriteDb { unWriteDb :: ReaderT PG.Connection IO a }
  deriving (Functor, Applicative, Monad)

writeTransaction :: PG.Connection -> WriteDb a -> IO a
writeTransaction conn (WriteDb r) = PG.withTransactionModeRetry m PG.isSerializationError conn $ runReaderT r conn
  where m = PG.TransactionMode
          { PG.isolationLevel = PG.Serializable
          , PG.readWriteMode = PG.ReadWrite
          }

unsafeReadDb :: (PG.Connection -> IO a) -> ReadDb a
unsafeReadDb f = ReadDb $ lift . f =<< ask

unsafeWriteDb :: (PG.Connection -> IO a) -> WriteDb a
unsafeWriteDb f = WriteDb $ lift . f =<< ask

withApiHandler
  :: forall query queryResult request a.
     ( Monoid (query SelectedCount)
     , QueryResult (query (MonoidMap ClientKey SelectedCount)) ~ queryResult (MonoidMap ClientKey SelectedCount)
     , QueryResult (query SelectedCount) ~ queryResult SelectedCount
     , QueryResult (query ()) ~ queryResult ()
     , Foldable queryResult
     , Functor query
     , Functor queryResult
     , FunctorMaybe queryResult
     , Monoid (query (MonoidMap ClientKey SelectedCount))
     , Monoid (queryResult SelectedCount)
     , Eq (queryResult SelectedCount)
     , Eq (query (MonoidMap ClientKey SelectedCount))
     , Eq (query SelectedCount)
     , Group (query SelectedCount)
     , ToJSON (queryResult ())
     , FromJSON (query ())
     , Request request
     )
  => ByteString -- ^ The URI of the DB to connect to
  -> (forall x. request x -> WriteDb x) -- ^ How to handle an API request
  -> (forall x. query x -> Transaction -> ReadDb (QueryResult (query x))) -- ^ How to handle a change
  -> (forall x. query x -> ReadDb (QueryResult (query x))) -- ^ How to handle a query
  -> (Snap () -> IO a)
  -> IO a
withApiHandler dbUri handleApi handleChange handleQuery go = do
  withNonEmptyTransactions dbUri $ \transactions -> do
    withConnectionPool dbUri $ \db -> do
      let onChange :: Transaction -> query x -> IO (QueryResult (query x))
          onChange m q = withResource db $ \conn -> readTransaction conn $ handleChange q m
      let pipe :: Pipeline IO (MonoidalMap ClientKey (query SelectedCount)) (query (MonoidMap ClientKey SelectedCount))
          pipe = queryMorphismPipeline $ transposeMonoidMap . monoidMapQueryMorphism
      rec (qh, finalizeFeed) <- feedPipeline (onChange <$> atomically (readTChan transactions)) (QueryHandler $ \q -> withResource db $ \conn -> readTransaction conn $ handleQuery q) r
          (qh', r) <- unPipeline pipe qh r'
          (r', handleListen) <- connectPipelineToWebsockets "" (\r'' -> withResource db $ \conn -> writeTransaction conn $ handleApi r'') qh'
      go handleListen

withNonEmptyTransactions :: ByteString -> (TChan Transaction -> IO a) -> IO a
withNonEmptyTransactions dbUri go = do
  let opts = def
        { _logicalDecodingOptions_pluginOptions = [("skip-empty-xacts", Nothing)]
        }
  withLogicalDecoding dbUri "test_decoding" opts $ \decodedLines -> do
    transactions <- newTChanIO
    processLine <- linesToTransactions
    let processLines = forever $ do
          lineRaw <- atomically $ readTChan decodedLines
          let Right l = parseOnly (line <* endOfInput) lineRaw
          Right mTransaction <- processLine l
          forM_ mTransaction $ \transaction ->
            atomically $ writeTChan transactions transaction
    withAsync processLines $ \a -> link a >> do
      go transactions
{-

standardChangeChannel :: PG.Identifier
standardChangeChannel = "obelisk_api_updates"

standardChangeSubscriberTable :: PG.Identifier
standardChangeSubscriberTable = "obelisk_api_updates_subscriber"

standardChangeSpillTable :: PG.Identifier
standardChangeSpillTable = "obelisk_api_updates_spill"

-- | Listen on a Postgres notification channel.  Uses a connection from the Pool for as long as it is r-- | Listen for Postgresql changes on a particular channel
withChangeListener :: FromJSON change => Pool PG.Connection -> (change -> IO ()) -> IO a -> IO a
withChangeListener db onChange = withBigNotificationListener db standardChangeChannel standardChangeSpillTable $ \message ->
  case Aeson.eitherDecode' $ LBS.fromStrict message of
    Left e -> fail $ "withChangeListener: " <> e
    Right change -> onChange change
-}
