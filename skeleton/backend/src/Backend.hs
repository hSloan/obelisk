{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
module Backend where

import Common.Route
import Data.Aeson
import Data.Text (Text)
import Data.Functor.Identity
import Data.Map.Monoidal (MonoidalMap (..))
import qualified Data.Map.Monoidal as Map
import Data.Semigroup
import Obelisk.Backend
import Obelisk.Route
import Obelisk.Api
import Obelisk.Api.Pipeline --TODO: Move Request to Obelisk.Api
import Obelisk.Db
import Obelisk.Postgres.LogicalDecoding.Plugins.TestDecoding
import Obelisk.Request.TH
import Reflex.Class
import Reflex.Query.Class

import Debug.Trace

newtype VS k v a = VS (MonoidalMap k a)
  deriving (Semigroup, Monoid, Functor, Foldable, Traversable, Group, ToJSON, FromJSON, Eq)

newtype V k v a = V (MonoidalMap k (a, First (Maybe v)))
  deriving (Semigroup, Monoid, Functor, Foldable, Traversable, ToJSON, FromJSON, Eq)

instance FunctorMaybe (V k v) where
  fmapMaybe f (V m) = V $ Map.mapMaybe (\(a, v) -> (,v) <$> f a) m

instance (Ord k, Semigroup a) => Query (VS k v a) where
  type QueryResult (VS k v a) = V k v a
  crop _ = id

data MyRequest a where
  MyRequest_Echo :: Text -> MyRequest Text

makeRequestForData ''MyRequest

backend :: Backend BackendRoute FrontendRoute
backend = Backend
  { _backend_run = \serve -> do
      withDbUri "db" $ \dbUri -> do
        print dbUri
        let onNotify :: forall a. VS Int Text a -> Transaction -> ReadDb (V Int Text a)
            onNotify (VS _) txn = do
              traceM $ show txn
              pure $ V $ MonoidalMap mempty
            onSubscribe :: forall a. VS Int Text a -> ReadDb (V Int Text a)
            onSubscribe (VS _) = do
              pure $ V $ MonoidalMap mempty
        withApiHandler dbUri (\(MyRequest_Echo a) -> pure a) onNotify onSubscribe $ \handler -> do
          serve $ \case
            BackendRoute_Api :/ () -> handler
            _ -> return ()
  , _backend_routeEncoder = backendRouteEncoder
  }
