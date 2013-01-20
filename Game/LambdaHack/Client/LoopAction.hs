{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | The main loop of the client, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Client.LoopAction (loopCli2) where

import Data.Dynamic

import Game.LambdaHack.Action
import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.State
import Game.LambdaHack.CmdCli
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.State

loopCli2 :: MonadClientChan m
           => (CmdUpdateCli -> m ())
           -> (forall a. Typeable a => CmdQueryCli a -> m a)
           -> m ()
loopCli2 cmdUpdateCli cmdQueryCli = do
  factionName <- getsState $ gname . getSide
  cops@Kind.COps{corule} <- getsState scops
  sper <- getsClient sper
  configUI <- askConfigUI
  let pathsDataFile = rpathsDataFile $ Kind.stdRuleset corule
      title = rtitle $ Kind.stdRuleset corule
  restored <- restoreGame factionName configUI pathsDataFile title
  case restored of
    Right msg -> do  -- First visit ever, use the initial state.
      -- TODO: create or restore from config clients RNG seed
      msgAdd msg
      -- TODO: somehow check that RestartCli arrives before any other cmd
    Left (s, cli, msg) -> do  -- Restore a game or at least history.
      let sCops = updateCOps (const cops) s
          cliPer = cli {sper}
      putState sCops
      putClient cliPer
      msgAdd msg
      -- TODO: somehow check that ContinueSave arrives before any other cmd
  loop
 where
  loop = do
    cmd2 <- readChanFromSer
    case cmd2 of
      CmdUpdateCli cmd -> do
        cmdUpdateCli cmd
      CmdQueryCli cmd -> do
        a <- cmdQueryCli cmd
        writeChanToSer $ toDyn a
    loop
