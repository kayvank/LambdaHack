-- | Here the knot of engine code pieces, frontend and the game-specific
-- content definitions is tied, resulting in an executable game.
module TieKnot
  ( tieKnot
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified System.Random as R

import           Game.LambdaHack.Common.ContentData
import qualified Game.LambdaHack.Common.Kind as Kind
import qualified Game.LambdaHack.Common.Tile as Tile
import qualified Game.LambdaHack.Content.CaveKind as CK
import qualified Game.LambdaHack.Content.ItemKind as IK
import qualified Game.LambdaHack.Content.ModeKind as MK
import qualified Game.LambdaHack.Content.PlaceKind as PK
import qualified Game.LambdaHack.Content.RuleKind as RK
import qualified Game.LambdaHack.Content.TileKind as TK
import           Game.LambdaHack.SampleImplementation.SampleMonadServer (executorSer)
import           Game.LambdaHack.Server

import qualified Client.UI.Content.KeyKind as Content.KeyKind
import qualified Content.CaveKind
import qualified Content.ItemKind
import qualified Content.ModeKind
import qualified Content.PlaceKind
import qualified Content.RuleKind
import qualified Content.TileKind

-- | Tie the LambdaHack engine client, server and frontend code
-- with the game-specific content definitions, and run the game.
--
-- The custom monad types to be used are determined by the 'executorSer'
-- call, which in turn calls 'executorCli'. If other functions are used
-- in their place- the types are different and so the whole pattern
-- of computation differs. Which of the frontends is run inside the UI client
-- depends on the flags supplied when compiling the engine library.
-- Similarly for the choice of native vs JS builds.
tieKnot :: ServerOptions -> IO ()
tieKnot options@ServerOptions{sallClear, sboostRandomItem, sdungeonRng} = do
  -- This setup ensures the boosting option doesn't affect generating initial
  -- RNG for dungeon, etc., and also, that setting dungeon RNG on commandline
  -- equal to what was generated last time, ensures the same item boost.
  initialGen <- maybe R.getStdGen return sdungeonRng
  let soptionsNxt = options {sdungeonRng = Just initialGen}
      cotile = createOps $ TK.makeDef Content.TileKind.content
      boostedItems = IK.boostItemKindList initialGen Content.ItemKind.items
      coitem = createOps $ IK.makeDef $
        if sboostRandomItem
        then boostedItems ++ Content.ItemKind.otherItemContent
        else Content.ItemKind.content
      -- Common content operations, created from content definitions.
      -- Evaluated fully to discover errors ASAP and to free memory.
      !cops = Kind.COps
        { cocave  = createOps $ CK.makeDef Content.CaveKind.content
        , coitem
        , comode  = createOps $ MK.makeDef Content.ModeKind.content
        , coplace = createOps $ PK.makeDef Content.PlaceKind.content
        , corule  = createOps $ RK.makeDef Content.RuleKind.content
        , cotile
        , coTileSpeedup = Tile.speedup sallClear cotile
        }
      -- Client content operations containing default keypresses
      -- and command descriptions.
      !copsClient = Content.KeyKind.standardKeys
  -- Wire together game content, the main loops of game clients
  -- and the game server loop.
  executorSer cops copsClient soptionsNxt
