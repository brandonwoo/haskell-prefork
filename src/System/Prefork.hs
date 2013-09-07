
module System.Prefork(Prefork(..), defaultMain) where

import Prelude hiding (catch)
import Data.List
import Data.Map (Map)
import Data.Maybe
import qualified Data.Map as M
import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import System.Posix hiding (version)

data ControlMessage = 
    TerminateCM
  | InterruptCM
  | HungupCM
  | QuitCM
  | ChildCM
  deriving (Eq, Show, Read)

type ControlTChan   = TChan ControlMessage
type ProcessMapTVar = TVar (Map ProcessID String)

data (Show sopt, Read sopt) => Prefork sopt = Prefork {
    pServerOption :: !(TVar sopt)
  , pReadConfigFn :: IO (sopt, String)
  , pCtrlChan     :: !ControlTChan
  , pProcs        :: !ProcessMapTVar
  }

defaultMain :: (Show sopt, Read sopt) => sopt -> IO (sopt, String) -> IO ()
defaultMain sopt readConfigFn = do
  ctrlChan <- newTChanIO
  procs <- newTVarIO M.empty
  soptVar <- newTVarIO sopt
  masterMainLoop (Prefork soptVar readConfigFn ctrlChan procs) False

masterMainLoop :: (Show a, Read a) => Prefork a -> Bool -> IO ()
masterMainLoop prefork finishing = do
  setHandler sigCHLD $ childHandler (pCtrlChan prefork)
  (msg, cids, opt) <- atomically $ do
    msg <- readTChan $ pCtrlChan prefork
    procs <- readTVar $ pProcs prefork
    opt <- readTVar $ pServerOption prefork
    return (msg, M.keys procs, opt)
  cont <- case msg of
    TerminateCM -> do
      mapM_ (sendSignal sigTERM) cids
      return (False)
    InterruptCM -> do
      mapM_ (sendSignal sigINT) cids
      return (False)
    HungupCM -> do
      -- updateServer fs configFile
      return (True)
    QuitCM -> do
      -- when (soVerbose opt) $ showStatus fs
      return (True)
    ChildCM -> do
      cleanupChildren opt cids (pProcs prefork)
      return (True)

  childIds <- fmap M.keys $ readTVarIO (pProcs prefork)
  let finishing' = (finishing || cont == False)
  unless (finishing' && null childIds) $ masterMainLoop prefork finishing'


---------------------------------------------------------------- PRIVATE

cleanupChildren opt cids procs = do
      r <- mapM (getProcessStatus False False) cids
      let finished = catMaybes $ flip map (zip cids r) $ \x -> case x of
                                                                 (pid, Just _exitCode) -> Just pid
                                                                 _ -> Nothing
      atomically $ do
        modifyTVar' procs $ M.filterWithKey (\k _v -> k `notElem` finished)

childHandler :: ControlTChan -> System.Posix.Handler
childHandler ctrlChan = Catch $ do
  atomically $ writeTChan ctrlChan ChildCM

setupServer :: ControlTChan -> IO ()
setupServer chan = do
  setHandler sigTERM $ Catch $ do
    -- opt <- readTVarIO (fsServerOpt fs)
    -- when (soVerbose opt) $ noticeM "server" ("SIGTERM")
    atomically $ writeTChan chan TerminateCM
  setHandler sigINT $ Catch $ do
    -- opt <- readTVarIO (fsServerOpt fs)
    -- when (soVerbose opt) $ noticeM "server" ("SIGINT")
    atomically $ writeTChan chan InterruptCM
  setHandler sigQUIT $ Catch $ do
    -- opt <- readTVarIO (fsServerOpt fs)
    -- when (soVerbose opt) $ noticeM "server" ("SIGQUIT")
    atomically $ writeTChan chan QuitCM
  setHandler sigHUP $ Catch $ do
    -- opt <- readTVarIO (fsServerOpt fs)
    -- when (soVerbose opt) $ noticeM "server" ("SIGHUP")
    atomically $ writeTChan chan HungupCM
  setHandler sigPIPE $ Ignore
  return ()

setHandler :: Signal -> System.Posix.Handler -> IO ()
setHandler sig func = void $ installHandler sig func Nothing

sendSignal :: Signal -> ProcessID -> IO ()
sendSignal sig cid = signalProcess sig cid `catch` ignore
  where
    ignore :: SomeException -> IO ()
    ignore _ = return ()
