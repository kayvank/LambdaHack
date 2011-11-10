module Cave
  ( Cave, Party, SecretMapXY, ItemMapXY, TileMapXY
  , caveEmpty, caveNoise, caveRogue
  ) where

import Control.Monad
import qualified Data.Map as M
import qualified Data.IntMap as IM
import qualified Data.List as L

import Geometry
import Actor
import Area
import AreaRnd
import Loc
import Level
import Item
import Random
import Content.TileKind
import Tile
import qualified Kind
import Content.CaveKind

type SecretMapXY = M.Map (X, Y) SecretStrength

type ItemMapXY = M.Map (X, Y) Item

type TileMapXY = M.Map (X, Y) (Kind.Id TileKind)

data Cave = Cave
  { dxsize    :: X
  , dysize    :: Y
  , dmonsters :: Party      -- ^ fixed monsters on the level
  , dsecret   :: SecretMapXY
  , ditem     :: ItemMapXY
  , dmap      :: TileMapXY
  , dmeta     :: String
  }
  deriving Show

-- | Cave consisting of only one, empty room.
caveEmpty :: Int -> CaveKind -> Rnd (TileMapXY, SecretMap, String)
caveEmpty _ CaveKind{cxsize, cysize} =
  let room = (1, 1, cxsize - 2, cysize - 2)
  in return $ (digRoom True room M.empty, IM.empty, "empty room")

-- | Cave consisting of only one room with randomly distributed pillars.
caveNoise :: Int -> CaveKind -> Rnd (TileMapXY, SecretMap, String)
caveNoise n cfg@CaveKind{cxsize, cysize} = do
  (em, _, _) <- caveEmpty n cfg
  nri <- 100 *~ nrItems cfg
  lxy <- replicateM nri $ xyInArea (1, 1, cxsize - 2, cysize - 2)
  let insertRock lm xy = M.insert xy Tile.wallId lm
  return (L.foldl' insertRock em lxy, IM.empty, "noise room")

-- | If the room has size 1, it is at most a start of a corridor.
digRoom :: Bool -> Room -> TileMapXY -> TileMapXY
digRoom dl (x0, y0, x1, y1) lmap
  | x0 == x1 && y0 == y1 = lmap
  | otherwise =
  let floorDL = if dl then Tile.floorLightId else Tile.floorDarkId
      rm =
        [ ((x, y), floorDL) | x <- [x0..x1], y <- [y0..y1] ]
        ++ [ ((x, y), Tile.wallId)
           | x <- [x0-1, x1+1], y <- [y0..y1] ]
        ++ [ ((x, y), Tile.wallId)
           | x <- [x0-1..x1+1], y <- [y0-1, y1+1] ]
  in M.union (M.fromList rm) lmap

{-
Rogue cave is generated by an algorithm inspired by the original Rogue,
as follows:

  * The available area is divided into a 3 by 3 grid
    where each of the 9 grid cells has approximately the same size.

  * In each of the 9 grid cells one room is placed at a random location.
    The minimum size of a room is 2 by 2 floor tiles. A room is surrounded
    by walls, and the walls still have to fit into the assigned grid cells.

  * Rooms that are on horizontally or vertically adjacent grid cells
    may be connected by a corridor. Corridors consist of 3 segments of straight
    lines (either "horizontal, vertical, horizontal" or "vertical, horizontal,
    vertical"). They end in openings in the walls of the room they connect.
    It is possible that one or two of the 3 segments have length 0, such that
    the resulting corridor is L-shaped or even a single straight line.

  * Corridors are generated randomly in such a way that at least every room
    on the grid is connected, and a few more might be. It is not sufficient
    to always connect all adjacent rooms.
-}
-- | Cave generated by an algorithm inspired by the original Rogue,
caveRogue :: Int -> CaveKind -> Rnd (TileMapXY, SecretMap, String)
caveRogue n cfg@CaveKind{cxsize, cysize} =
  do
    lgrid@(gx, gy) <- levelGrid cfg
    lminroom <- minRoomSize cfg
    let gs = grid lgrid (0, 0, cxsize - 1, cysize - 1)
    -- grid locations of "no-rooms"
    nrnr <- noRooms cfg lgrid
    nr   <- replicateM nrnr $ xyInArea (0, 0, gx - 1, gy - 1)
    rs0  <- mapM (\ (i, r) -> do
                              r' <- if i `elem` nr
                                      then mkNoRoom (border cfg) r
                                      else mkRoom (border cfg) lminroom r
                              return (i, r')) gs
    let rooms :: [Area]
        rooms = L.map snd rs0
    dlrooms <- mapM (\ r -> darkRoomChance cfg n
                            >>= \ c -> return (r, not c)) rooms
               :: Rnd [(Area, Bool)]
    let rs = M.fromList rs0
    connects <- connectGrid lgrid
    addedConnects <- replicateM
                       (extraConnects cfg lgrid)
                       (randomConnection lgrid)
    let allConnects = L.nub (addedConnects ++ connects)
    cs <- mapM
           (\ (p0, p1) -> do
                           let r0 = rs M.! p0
                               r1 = rs M.! p1
                           connectRooms r0 r1) allConnects
    let lrooms = L.foldr (\ (r, dl) m -> digRoom dl r m) M.empty dlrooms
        lcorridors = M.unions (L.map digCorridors cs)
        lrocks =
          M.fromList [ ((x, y), Tile.wallId) | x <- [0..cxsize - 1], y <- [0..cysize - 1] ]
        lm = M.union (M.unionWith mergeCorridor lcorridors lrooms) lrocks
    -- convert openings into doors
    (dlmap, secretMap) <- do
      let f (l, le) o@((x, y), t) =
                  case t of
                    _ | Tile.isOpening t ->
                      do
                        -- openings have a certain chance to be doors;
                        -- doors have a certain chance to be open; and
                        -- closed doors have a certain chance to be
                        -- secret
                        rb <- doorChance cfg
                        ro <- doorOpenChance cfg
                        if not rb
                          then return (o : l, le)
                          else if ro
                               then return (((x, y), Tile.doorOpenId) : l, le)
                               else do
                                 rsc <- doorSecretChance cfg
                                 if not rsc
                                   then return (((x, y), Tile.doorClosedId) : l, le)
                                   else do
                                     rs1 <- randomR (doorSecretMax cfg `div` 2,
                                                     doorSecretMax cfg)
                                     return (((x, y), Tile.doorSecretId) : l, IM.insert (toLoc cxsize (x, y)) (SecretStrength rs1) le)
                    _ -> return (o : l, le)
      (l, le) <- foldM f ([], IM.empty) (M.toList lm)
      return (M.fromList l, le)
    return (dlmap, secretMap, show allConnects)

type Corridor = [(X, Y)]
type Room = Area

-- | Create a random room according to given parameters.
mkRoom :: Int ->      -- ^ border columns
          (X, Y) ->    -- ^ minimum size
          Area ->     -- ^ this is an area, not the room itself
          Rnd Room    -- ^ this is the upper-left and lower-right corner of the room
mkRoom bd (xm, ym) (x0, y0, x1, y1) =
  do
    (rx0, ry0) <- xyInArea (x0 + bd, y0 + bd, x1 - bd - xm + 1, y1 - bd - ym + 1)
    (rx1, ry1) <- xyInArea (rx0 + xm - 1, ry0 + ym - 1, x1 - bd, y1 - bd)
    return (rx0, ry0, rx1, ry1)

-- | Create a no-room, i.e., a single corridor field.
mkNoRoom :: Int ->      -- ^ border columns
            Area ->     -- ^ this is an area, not the room itself
            Rnd Room    -- ^ this is the upper-left and lower-right corner of the room
mkNoRoom bd (x0, y0, x1, y1) =
  do
    (rx, ry) <- xyInArea (x0 + bd, y0 + bd, x1 - bd, y1 - bd)
    return (rx, ry, rx, ry)

digCorridors :: Corridor -> TileMapXY
digCorridors (p1:p2:ps) =
  M.union corPos (digCorridors (p2:ps))
  where
    corXY  = fromTo p1 p2
    corPos = M.fromList $ L.zip corXY (repeat Tile.floorDarkId)
digCorridors _ = M.empty

mergeCorridor :: Kind.Id TileKind -> Kind.Id TileKind -> Kind.Id TileKind
mergeCorridor _ t | Tile.isWalkable t = t
mergeCorridor _ t | Tile.isUnknown t  = Tile.floorDarkId
mergeCorridor _ _                     = Tile.openingId
