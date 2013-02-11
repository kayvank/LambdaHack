{-# LANGUAGE OverloadedStrings #-}
-- | The main loop of the server, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Server.LoopAction (loopSer, cmdAtomicBroad) where

import Control.Arrow (second)
import Control.Monad
import qualified Control.Monad.State as St
import Control.Monad.Writer.Strict (WriterT, execWriterT, runWriterT, tell)
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.CmdAtomic
import Game.LambdaHack.CmdAtomicSem
import Game.LambdaHack.CmdCli
import Game.LambdaHack.CmdSer
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.Random
import Game.LambdaHack.Server.Action
import Game.LambdaHack.Server.Config
import qualified Game.LambdaHack.Server.DungeonGen as DungeonGen
import Game.LambdaHack.Server.EffectSem
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.State
import Game.LambdaHack.State
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert

-- | Start a clip (a part of a turn for which one or more frames
-- will be generated). Do whatever has to be done
-- every fixed number of time units, e.g., monster generation.
-- Run the leader and other actors moves. Eventually advance the time
-- and repeat.
loopSer :: forall m . (MonadAction m, MonadServerChan m)
        => (LevelId -> CmdSer -> m ())
        -> (FactionId -> ConnCli -> Bool -> IO ())
        -> Kind.COps
        -> m ()
loopSer cmdSer executorC cops = do
  -- Recover states.
  restored <- tryRestore cops
  -- TODO: use the _msg somehow
  case restored of
    Right _msg ->  -- Starting a new game.
      gameReset cops
    Left (gloRaw, ser, _msg) -> do  -- Running a restored game.
      putState $ updateCOps (const cops) gloRaw
      putServer ser
  -- Set up connections
  connServer
  -- Launch clients.
  launchClients executorC
  -- Send init messages.
  initPer
  pers <- getsServer sper
  defLoc <- getsState localFromGlobal
  quit <- getsServer squit
  case quit of
    Nothing -> do  -- game restarted
      let bcast = funBroadcastCli (\fid -> RestartCli (pers EM.! fid) defLoc)
      bcast
      withAI bcast
      -- TODO: factor out common parts from restartGame and restoreOrRestart
      cmdAtomicBroad initialLevel SyncAtomic
      -- Save ASAP in case of crashes and disconnects.
      saveGameBkp
    _ -> do  -- game restored from a savefile
      let bcast = funBroadcastCli (\fid -> ContinueSavedCli (pers EM.! fid))
      bcast
      withAI bcast
  modifyServer $ \ser1 -> ser1 {squit = Nothing}
  let cinT = let r = timeTurn `timeFit` timeClip
             in assert (r > 2) r
  -- Loop.
  let loop :: (Maybe FactionId) -> Int -> m ()
      loop prevHuman clipN = do
        let h pHuman arena = do
              -- Regenerate HP and add monsters each turn, not each clip.
              when (clipN `mod` cinT == 0) $ generateMonster arena
              when (clipN `mod` cinT == 1) $ regenerateLevelHP arena
              when (clipN `mod` cinT == 2) checkEndGame
              pHumanOut <- handleActors cmdSer arena timeZero pHuman
              modifyState $ updateTime arena $ timeAdd timeClip
              return pHumanOut
        let f fac = do
              case gleader fac of
                Nothing -> return Nothing
                Just leader -> do
                  b <- getsState $ getActorBody leader
                  return $ Just $ blid b
        faction <- getsState sfaction
        marenas <- mapM f $ EM.elems faction
        let arenas = ES.toList $ ES.fromList $ catMaybes marenas
            mapH pHuman [] = return pHuman
            mapH pHuman (arena : as) = do
              pHumanOut <- h pHuman arena
              mapH pHumanOut as
        pHumanOut <- mapH prevHuman arenas
        endOrLoop prevHuman (loop pHumanOut (clipN + 1))
  loop Nothing 1

initPer :: MonadServer m => m ()
initPer = do
  cops <- getsState scops
  glo <- getState
  ser <- getServer
  config <- getsServer sconfig
  let tryFov = stryFov $ sdebugSer ser
      fovMode = fromMaybe (configFovMode config) tryFov
      pers = dungeonPerception cops fovMode glo
  modifyServer $ \ser1 -> ser1 {sper = pers}

cmdAtomicBroad :: (MonadAction m, MonadServerChan m)
               => LevelId -> CmdAtomic -> m ()
cmdAtomicBroad arena cmd = do
  lvlOld <- getsLevel arena id
  actorDOld <- getsState sactorD
  itemDOld <- getsState sitemD
  factionOld <- getsState sfaction
  cmdAtomicSem cmd
  lvlNew <- getsLevel arena id
  actorDNew <- getsState sactorD
  itemDNew <- getsState sitemD
  factionNew <- getsState sfaction
  (pStart, pEnd) <- cmdPosAtomic cmd
  let vis per = all (`ES.member` totalVisible per)
      send fid = do
        perOld <- getPerFid fid arena
        resets <- resetsFovAtomic fid cmd
        if resets then do
          resetFidPerception fid arena
          perNew <- getPerFid fid arena
          let startSeen = either id (vis perOld) pStart
              endSeen = either id (vis perNew) pEnd
          if startSeen && endSeen then do
            let sendUp =
                  sendUpdateCli fid
                  $ RememberPerCli perNew lvlOld arena actorDOld itemDOld factionOld
            sendUp
            withAI sendUp
            let sendCmd = sendUpdateCli fid $ AtomicSeenCli cmd
            sendCmd
            withAI sendCmd
          else do
            let sendUp =
                  sendUpdateCli fid
                  $ RememberPerCli perNew lvlNew arena actorDNew itemDNew factionNew
            sendUp
            withAI sendUp
        else do
          let startSeen = either id (vis perOld) pStart
              endSeen = either id (vis perOld) pEnd
          if startSeen && endSeen
          then do
            let sendCmd = sendUpdateCli fid $ AtomicSeenCli cmd
            sendCmd
            withAI sendCmd
          else do
            let sendUp =
                  sendUpdateCli fid
                  $ RememberCli lvlNew arena actorDNew itemDNew factionNew
            sendUp
            withAI sendUp
  mapM_ send $ EM.keys factionNew

-- TODO: switch levels alternating between player factions,
-- if there are many and on distinct levels.
-- TODO: If a faction has no actors left in the dungeon,
-- announce game end for this faction. Not sure if here's the right place.
-- TODO: Let the spawning factions that remain duke it out somehow,
-- if the player requests to see it.
-- | If no actor of a non-spawning faction on the level,
-- switch levels. If no level to switch to, end game globally.
checkEndGame ::  (MonadAction m, MonadServerChan m) => m ()
checkEndGame = do
  -- Actors on the current level go first so that we don't switch levels
  -- unnecessarily.
  as <- getsState $ EM.elems . sactorD
  glo <- getState
  let aNotSp = filter (not . isSpawningFaction glo . bfaction) as
  case aNotSp of
    [] -> gameOver undefined undefined True  -- TODO: should send to all factions
    _ : _ -> return ()

-- | Perform moves for individual actors, as long as there are actors
-- with the next move time less than or equal to the current time.
-- Some very fast actors may move many times a clip and then
-- we introduce subclips and produce many frames per clip to avoid
-- jerky movement. Otherwise we push exactly one frame or frame delay.
-- We start by updating perception, because the selected level of dungeon
-- has changed since last time (every change, whether by human or AI
-- or @generateMonster@ is followd by a call to @handleActors@).
handleActors :: (MonadAction m, MonadServerChan m)
             => (LevelId -> CmdSer -> m ())
             -> LevelId
             -> Time  -- ^ start time of current subclip, exclusive
             -> Maybe FactionId
             -> m (Maybe FactionId)
handleActors cmdSer arena subclipStart prevHuman = do
  Kind.COps{coactor} <- getsState scops
  time <- getsState $ getTime arena  -- the end time of this clip, inclusive
  prio <- getsLevel arena lprio
  gquit <- case prevHuman of
    Just fid -> getsState $ gquit . (EM.! fid) . sfaction
    Nothing -> return Nothing
  quit <- getsServer squit
  s <- getState
  let mnext = if EM.null prio  -- wait until any actor spawned
              then Nothing
              else let -- Actors of the same faction move together.
--                       order = Ord.comparing (btime . snd &&& bfaction . snd)
                       (atime, as) = EM.findMin prio
                       actor = head as
                       m = getActorBody actor s
                   in if atime > time
                      then Nothing  -- no actor is ready for another move
                      else Just (actor, m)
  case mnext of
    _ | isJust quit || isJust gquit -> return prevHuman
    Nothing -> do
      when (subclipStart == timeZero) $
        broadcastUI [] $ DisplayDelayCli
      return prevHuman
    Just (actor, body) -> do
      broadcastUI [] DisplayPushCli  -- TODO: too often
      let side = bfaction body
      isHuman <- getsState $ flip isHumanFaction side
      mleader <- getsState $ gleader . (EM.! side) . sfaction
      if Just actor == mleader && isHuman
        then do
          nHuman <- if isHuman && Just side /= prevHuman
                    then do
                      newRuns <- sendQueryCli side IsRunningCli
                      if newRuns
                        then return prevHuman
                        else do
                          case prevHuman of
                            Just fid -> do
                              b <- sendQueryUI fid $ FlushFramesCli side
                              if b
                                then return $ Just side
                                else return prevHuman
                            Nothing -> return $ Just side
                    else return prevHuman
          -- TODO: check that the command is legal, that is, the leader
          -- is acting, etc. Or perhaps instead have a separate type
          -- of actions for humans. OTOH, AI is controlled by the servers
          -- so the generated commands are assumed to be legal.
          cmdS <- sendQueryUI side HandleHumanCli
          tryWith (\msg -> do
                      sendUpdateCli side $ ShowMsgCli msg
                      sendUpdateUI side DisplayPushCli
                      handleActors cmdSer arena subclipStart nHuman
                  ) $ do
            mapM_ (cmdSer arena) cmdS
            -- Advance time once, after the leader switched perhaps many times.
            -- TODO: this is correct only when all heroes have the same
            -- speed and can't switch leaders by, e.g., aiming a wand
            -- of domination. We need to generalize by displaying
            -- "(next move in .3s [RET]" when switching leaders.
            -- RET waits .3s and gives back control,
            -- Any other key does the .3s wait and the action form the key
            -- at once. This requires quite a bit of refactoring
            -- and is perhaps better done when the other factions have
            -- selected leaders as well.
            mleaderNew <- getsState $ gleader . (EM.! side) . sfaction
            quitNew <- getsServer squit
            bodyNew <- case mleaderNew of
              Just leaderNew | any timedCmdSer cmdS && isNothing quitNew -> do
                bNew <- getsState $ getActorBody leaderNew
                advanceTime (blid bNew) leaderNew
                return bNew
              _ -> return body
            -- Human moves always start a new subclip.
            -- _pos <- getsState $ bpos . getActorBody (fromMaybe actor leaderNew)
            -- TODO: send messages with time (or at least DisplayPushCli)
            -- and then send DisplayPushCli only to actors that see _pos.
            -- Right now other need it too, to notice the delay.
            -- This will also be more accurate since now unseen
            -- simultaneous moves also generate delays.
            handleActors cmdSer arena (btime bodyNew) nHuman
        else do
--          recordHistory
          advanceTime arena actor  -- advance time while the actor still alive
          let subclipStartDelta = timeAddFromSpeed coactor body subclipStart
          if isHuman && not (bproj body)
             || subclipStart == timeZero
             || btime body > subclipStartDelta
            then do
              -- Start a new subclip if its our own faction moving
              -- or it's another faction, but it's the first move of
              -- this whole clip or the actor has already moved during
              -- this subclip, so his multiple moves would be collapsed.
              cmdS <- withAI $ sendQueryCli side $ HandleAI actor
    -- If the following action aborts, we just advance the time and continue.
    -- TODO: or just fail at each abort in AI code? or use tryWithFrame?
              tryWith (\msg -> if T.null msg
                               then return ()
                               else assert `failure` msg <> "in AI"
                      )
                      (cmdSer arena cmdS)
              handleActors cmdSer arena (btime body) prevHuman
            else do
              -- No new subclip.
              cmdS <- withAI $ sendQueryCli side $ HandleAI actor
    -- If the following action aborts, we just advance the time and continue.
    -- TODO: or just fail at each abort in AI code? or use tryWithFrame?
              tryWith (\msg -> if T.null msg
                               then return ()
                               else assert `failure` msg <> "in AI"
                      )
                      (cmdSer arena cmdS)
              handleActors cmdSer arena subclipStart prevHuman

-- | Advance the move time for the given actor.
advanceTime :: MonadAction m => LevelId -> ActorId -> m ()
advanceTime lid aid = do
  Kind.COps{coactor} <- getsState scops
  b <- getsState $ getActorBody aid
  let oldTime = btime b
      newTime = timeAddFromSpeed coactor b oldTime
      upd body = body {btime = newTime}
  modifyState $ updateActorBody aid upd
  let rm Nothing = assert `failure` aid
      rm (Just l) = let l2 = delete aid l
                    in if null l2 then Nothing else Just l2
  updateLevel lid $ updatePrio $ EM.alter rm oldTime
  let add Nothing = Just [aid]
      add (Just l) = Just $ aid : l
  updateLevel lid $ updatePrio $ EM.alter add newTime

-- | Continue or restart or exit the game.
endOrLoop :: (MonadAction m, MonadServerChan m)
          => Maybe FactionId -> m () -> m ()
endOrLoop Nothing loopServer = loopServer
endOrLoop (Just fid) loopServer = do
  quitS <- getsServer squit
  fac <- getsState $ (EM.! fid) . sfaction
  let quitG = gquit fac
  total <- case gleader fac of
    Nothing -> return 0
    Just leader -> do
      b <- getsState $ getActorBody leader
      getsState $ snd . calculateTotal fid (blid b)
  -- The first, boolean component of quit determines
  -- if ending screens should be shown, the other argument describes
  -- the cause of the disruption of game flow.
  case (quitS, quitG) of
    (Just _, _) -> do
      -- Save and display in parallel.
--      mv <- liftIO newEmptyMVar
      saveGameSer
--      liftIO $ void
--        $ forkIO (Save.saveGameSer config s ser `finally` putMVar mv ())
-- 7.6        $ forkFinally (Save.saveGameSer config s ser) (putMVar mv ())
--      tryIgnore $ do
--        handleScores False Camping total
--        broadcastUI [] $ MoreFullCli "See you soon, stronger and braver!"
        -- TODO: show the above
      broadcastCli [] $ GameDisconnectCli False
      withAI $ broadcastCli [] $ GameDisconnectCli True
--      liftIO $ takeMVar mv  -- wait until saved
      -- Do nothing, that is, quit the game loop.
    (Nothing, Just (showScreens, status@Killed{})) -> do
      -- TODO: rewrite; handle killed faction, if human, mostly ignore if not
      nullR <- sendQueryCli fid NullReportCli
      unless nullR $ do
        -- Sisplay any leftover report. Suggest it could be the cause of death.
        broadcastUI [] $ MoreBWCli "Who would have thought?"
      tryWith
        (\ finalMsg ->
          let highScoreMsg = "Let's hope another party can save the day!"
              msg = if T.null finalMsg then highScoreMsg else finalMsg
          in broadcastUI [] $ MoreBWCli msg
          -- Do nothing, that is, quit the game loop.
        )
        (do
           when showScreens $ handleScores fid True status total
           go <- sendQueryUI fid
                 $ ConfirmMoreBWCli "Next time will be different."
           when (not go) $ abortWith "You could really win this time."
           restartGame loopServer
        )
    (Nothing, Just (showScreens, status@Victor)) -> do
      nullR <- sendQueryCli fid NullReportCli
      unless nullR $ do
        -- Sisplay any leftover report. Suggest it could be the master move.
        broadcastUI [] $ MoreFullCli "Brilliant, wasn't it?"
      when showScreens $ do
        tryIgnore $ handleScores fid True status total
        broadcastUI [] $ MoreFullCli "Can it be done better, though?"
      restartGame loopServer
    (Nothing, Just (_, Restart)) -> restartGame loopServer
    (Nothing, _) -> loopServer  -- just continue

restartGame :: (MonadAction m, MonadServerChan m) => m () -> m ()
restartGame loopServer = do
  cops <- getsState scops
  gameReset cops
  initPer
  pers <- getsServer sper
  -- This state is quite small, fit for transmition to the client.
  -- The biggest part is content, which really needs to be updated
  -- at this point to keep clients in sync with server improvements.
  defLoc <- getsState localFromGlobal
  let bcast = funBroadcastCli (\fid -> RestartCli (pers EM.! fid) defLoc)
  bcast
  withAI bcast
  cmdAtomicBroad initialLevel SyncAtomic
  saveGameBkp
  broadcastCli [] $ ShowMsgCli "This time for real."
  broadcastUI [] $ DisplayPushCli
  loopServer

-- | Create a set of initial heroes on the current level, at position ploc.
initialHeroes :: (MonadAction m, MonadServer m)
              => LevelId -> (FactionId, Point, [(Int, Text)]) -> m ()
initialHeroes lid (side, ppos, configHeroNames) = do
  configExtraHeroes <- getsServer $ configExtraHeroes . sconfig
  replicateM_ (1 + configExtraHeroes) $ do
    cmds <- execWriterT $ addHero side ppos lid configHeroNames
    mapM_ cmdAtomicSem cmds

createFactions :: Kind.COps -> Config -> Rnd FactionDict
createFactions Kind.COps{ cofact=Kind.Ops{opick, okind}
                        , costrat=Kind.Ops{opick=sopick} } config = do
  let g isHuman (gname, fType) = do
        gkind <- opick fType (const True)
        let fk = okind gkind
            genemy = []  -- fixed below
            gally  = []  -- fixed below
            gquit = Nothing
        gAiLeader <-
          if isHuman
          then return Nothing
          else fmap Just $ sopick (fAiLeader fk) (const True)
        gAiMember <- sopick (fAiMember fk) (const True)
        let gleader = Nothing
        return Faction{..}
  lHuman <- mapM (g True) (configHuman config)
  lComputer <- mapM (g False) (configComputer config)
  let rawFs = zip [toEnum 1..] $ lHuman ++ lComputer
      isOfType fType fact =
        let fk = okind $ gkind fact
        in case lookup fType $ ffreq fk of
          Just n | n > 0 -> True
          _ -> False
      enemyAlly fact =
        let f fType = filter (isOfType fType . snd) rawFs
            fk = okind $ gkind fact
            setEnemy = ES.fromList $ map fst $ concatMap f $ fenemy fk
            setAlly  = ES.fromList $ map fst $ concatMap f $ fally fk
            genemy = ES.toList setEnemy
            gally = ES.toList $ setAlly ES.\\ setEnemy
        in fact {genemy, gally}
  return $! EM.fromDistinctAscList $ map (second enemyAlly) rawFs

gameReset :: (MonadAction m, MonadServer m) => Kind.COps -> m ()
gameReset cops@Kind.COps{coitem, corule, cotile} = do
  -- Rules config reloaded at each new game start.
  -- Taking the original config from config file, to reroll RNG, if needed
  -- (the current config file has the RNG rolled for the previous game).
  (sconfig, dungeonSeed, random) <- mkConfigRules corule
  let rnd :: Rnd (FactionDict, FlavourMap, Discoveries, DiscoRev,
                  DungeonGen.FreshDungeon)
      rnd = do
        faction <- createFactions cops sconfig
        flavour <- dungeonFlavourMap coitem
        (discoS, discoRev) <- serverDiscos coitem
        freshDng <- DungeonGen.dungeonGen cops sconfig
        return (faction, flavour, discoS, discoRev, freshDng)
  let (faction, flavour, discoS, discoRev, DungeonGen.FreshDungeon{..}) =
        St.evalState rnd dungeonSeed
      defState = defStateGlobal freshDungeon freshDepth discoS faction cops
      defSer = defStateServer discoRev flavour random sconfig
      notSpawning (_, fact) = not $ isSpawningFact cops fact
      needInitialCrew = map fst $ filter notSpawning $ EM.assocs faction
      heroNames = configHeroNames sconfig : repeat []
  putState defState
  putServer defSer
  let initialItems (lid, (Level{ltile}, citemNum)) = do
        nri <- rndToAction $ rollDice citemNum
        replicateM nri $ do
          pos <- rndToAction
                 $ findPos ltile (const (Tile.hasFeature cotile F.Boring))
          cmds <- execWriterT $ createItems 1 pos lid
          mapM_ cmdAtomicSem cmds
  mapM_ initialItems itemCounts
  mapM_ (initialHeroes entryLevel) $ zip3 needInitialCrew entryPoss heroNames

-- * Assorted helper functions

-- | Generate a monster, possibly.
generateMonster :: (MonadAction m, MonadServerChan m) => LevelId -> m ()
generateMonster arena = do
  cops@Kind.COps{cofact=Kind.Ops{okind}} <- getsState scops
  pers <- getsServer sper
  lvl@Level{ldepth} <- getsLevel arena id
  faction <- getsState sfaction
  s <- getState
  let f fid = fspawn (okind (gkind (faction EM.! fid))) > 0
      spawns = actorNotProjList f arena s
  rc <- rndToAction $ monsterGenChance ldepth (length spawns)
  when rc $ do
    let allPers =
          ES.unions $ map (totalVisible . (EM.! arena)) $ EM.elems pers
    pos <- rndToAction $ rollSpawnPos cops allPers arena lvl s
    (_, cmds) <- runWriterT $ spawnMonsters 1 pos arena
    mapM_ (cmdAtomicBroad arena) cmds

-- | Create a new monster on the level, at a random position.
rollSpawnPos :: Kind.COps -> ES.EnumSet Point -> LevelId -> Level -> State
             -> Rnd Point
rollSpawnPos Kind.COps{cotile} visible lid lvl s = do
  let inhabitants = actorNotProjList (const True) lid s
      isLit = Tile.isLit cotile
      distantAtLeast d =
        \ l _ -> all (\ h -> chessDist (lxsize lvl) (bpos h) l > d) inhabitants
  findPosTry 40 (ltile lvl)
    [ \ _ t -> not (isLit t)
    , distantAtLeast 15
    , \ l t -> not (isLit t) || distantAtLeast 15 l t
    , distantAtLeast 10
    , \ l _ -> not $ l `ES.member` visible
    , distantAtLeast 5
    , \ l t -> Tile.hasFeature cotile F.Walkable t
               && unoccupied (actorList (const True) lid s) l
    ]

-- | Possibly regenerate HP for all actors on the current level.
--
-- We really want hero selection to be a purely UI distinction,
-- so all heroes need to regenerate, not just the leader.
-- Only the heroes on the current level regenerate (others are frozen
-- in time together with their level). This prevents cheating
-- via sending one hero to a safe level and waiting there.
regenerateLevelHP :: (MonadAction m, MonadServerChan m) => LevelId -> m ()
regenerateLevelHP arena = do
  Kind.COps{ coitem
           , coactor=Kind.Ops{okind}
           } <- getsState scops
  time <- getsState $ getTime arena
  discoS <- getsState sdisco
  s <- getState
  let pick (a, m) =
        let ak = okind $ bkind m
            items = getActorItem a s
            regen = max 1 $
                      aregen ak `div`
                      case strongestRegen coitem discoS items of
                        Just i  -> 5 * jpower i
                        Nothing -> 1
            bhpMax = maxDice (ahp ak)
            deltaHP = min 1 (bhpMax - bhp m)
        in if (time `timeFit` timeTurn) `mod` regen /= 0 || deltaHP <= 0
           then Nothing
           else Just a
  toRegen <-
    getsState $ catMaybes . map pick .actorNotProjAssocs (const True) arena
  mapM_ (\aid -> cmdAtomicBroad arena $ HealAtomic 1 aid) toRegen

-- TODO: let only some actors/items leave smell, e.g., a Smelly Hide Armour.
-- | Add a smell trace for the actor to the level.
_addSmell :: MonadActionRO m => ActorId -> WriterT [CmdAtomic] m ()
_addSmell aid = do
  b <- getsState $ getActorBody aid
  time <- getsState $ getTime $ blid b
  oldS <- getsLevel (blid b) $ (EM.lookup $ bpos b) . lsmell
  let newTime = timeAdd time smellTimeout
  tell [AlterSmellAtomic (blid b) [(bpos b, (oldS, Just newTime))]]
