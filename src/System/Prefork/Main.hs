-- Copyright: (c) 2013 GREE, Inc.
-- License: MIT-style

module System.Prefork.Main (
    defaultMain
  , runSettings
  ) where

import System.Environment (lookupEnv)
import System.Posix.Env (setEnv)

import System.Prefork.Class
import System.Prefork.Types
import System.Prefork.Worker
import System.Prefork.Main.Internal

defaultMain :: (WorkerContext w) => PreforkSettings sc -> (w -> IO ()) -> IO ()
defaultMain = runSettings

runSettings :: (WorkerContext w) => PreforkSettings sc -> (w -> IO ()) -> IO ()
runSettings settings workerAction = do
  mPrefork <- lookupEnv preforkEnvKey
  case mPrefork of
    Just _ -> workerMain workerAction
    Nothing -> do
      setEnv preforkEnvKey "server" True
      masterMain settings

