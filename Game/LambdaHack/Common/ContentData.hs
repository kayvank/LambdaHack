{-# LANGUAGE GeneralizedNewtypeDeriving, RankNTypes #-}
{-# OPTIONS_GHC -fno-expose-all-unfoldings #-}
-- | A game requires the engine provided by the library, perhaps customized,
-- and game content, defined completely afresh for the particular game.
-- The possible kinds of content are fixed in the library and all defined
-- within the library source code directory. On the other hand, game content,
-- is defined in the directory hosting the particular game definition.
--
-- Content of a given kind is just a list of content items.
-- After the list is verified and the data preprocessed, it's held
-- in the @ContentData@ datatype.
module Game.LambdaHack.Common.ContentData
  ( Ops(..), ContentData, makeContentData, createOps
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Vector as V

import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Random

-- | Verified and preprocessed content data of a particular kind.
data ContentData a = ContentData
  { contentVector :: V.Vector a
  , groupFreq     :: M.Map (GroupName a) [(Int, (ContentId a, a))]
  }

makeContentData :: Show a
               => (a -> Text)
                    -- ^ name of the content itme, used for validation
               -> (a -> [Text])
                    -- ^ validate a content item and list all offences
               -> ([a] -> [Text])
                    -- ^ validate the whole defined content of this type
                    -- and list all offence
               -> (a -> Freqs a)  -- ^ frequency within groups
               -> [a]  -- ^ all content of this type
               -> ContentData a
{-# INLINE makeContentData #-}
makeContentData getName validateSingle validateAll
                getFreq content =
  let correct a = not (T.null (getName a)) && all ((> 0) . snd) (getFreq a)
      singleOffenders = [ (offences, a)
                        | a <- content
                        , let offences = validateSingle a
                        , not (null offences) ]
      allOffences = validateAll content
      groupFreq =
        let tuples = [ (cgroup, (n, (i, k)))
                     | (i, k) <- zip [ContentId 0..] content
                     , (cgroup, n) <- getFreq k
                     , n > 0 ]
            f m (cgroup, nik) = M.insertWith (++) cgroup [nik] m
        in foldl' f M.empty tuples
      contentVector = V.fromList content
  in assert (allB correct content) $
     assert (null singleOffenders `blame` "some content items not valid"
                                  `swith` singleOffenders) $
     assert (null allOffences `blame` "the content set not valid"
                              `swith` allOffences) $
     assert (V.length contentVector <= fromEnum (maxBound :: ContentId a))
     ContentData {..}

-- | Content operations for the content of type @a@.
data Ops a = Ops
  { okind          :: ContentId a -> a  -- ^ content element at given id
  , ouniqGroup     :: GroupName a -> ContentId a
                                 -- ^ the id of the unique member of
                                 --   a singleton content group
  , opick          :: GroupName a -> (a -> Bool) -> Rnd (Maybe (ContentId a))
                                 -- ^ pick a random id belonging to a group
                                 --   and satisfying a predicate
  , ofoldrWithKey  :: forall b. (ContentId a -> a -> b -> b) -> b -> b
                                 -- ^ fold over all content elements of @a@
  , ofoldlWithKey' :: forall b. (b -> ContentId a -> a -> b) -> b -> b
                                 -- ^ fold strictly over all content @a@
  , ofoldlGroup'   :: forall b.
                      GroupName a
                      -> (b -> Int -> ContentId a -> a -> b)
                      -> b
                      -> b
                                 -- ^ fold over the given group only
  , olength        :: Int        -- ^ size of content @a@
  }

-- Not specialized, because no speedup, but big JS code bloat
-- (-fno-expose-all-unfoldings and NOINLINE used to ensure that,
-- in the absence of NOSPECIALIZABLE pragma).
-- | Create content operations for type @a@ from definition of content
-- of type @a@.
createOps :: forall a. Show a => ContentData a -> Ops a
{-# NOINLINE createOps #-}
createOps ContentData{contentVector, groupFreq} =
  Ops  { okind = \ !i -> contentVector V.! fromEnum i
       , ouniqGroup = \ !cgroup ->
           let freq = let assFail = error $ "no unique group"
                                            `showFailure` (cgroup, groupFreq)
                      in M.findWithDefault assFail cgroup groupFreq
           in case freq of
             [(n, (i, _))] | n > 0 -> i
             l -> error $ "not unique" `showFailure` (l, cgroup, groupFreq)
       , opick = \ !cgroup !p ->
           case M.lookup cgroup groupFreq of
             Just freqRaw ->
               let freq = toFreq ("opick ('" <> tshow cgroup <> "')")
                          $ filter (p . snd . snd) freqRaw
               in if nullFreq freq
                  then return Nothing
                  else fmap (Just . fst) $ frequency freq
                    {- with monadic notation; may produce empty freq:
                    (i, k) <- freq
                    breturn (p k) i
                    -}
                    {- with MonadComprehensions:
                    frequency [ i | (i, k) <- groupFreq M.! cgroup, p k ]
                    -}
             _ -> return Nothing
       , ofoldrWithKey = \f z ->
          V.ifoldr (\i c a -> f (toEnum i) c a) z contentVector
       , ofoldlWithKey' = \f z ->
          V.ifoldl' (\a i c -> f a (toEnum i) c) z contentVector
       , ofoldlGroup' = \cgroup f z ->
           case M.lookup cgroup groupFreq of
             Just freq -> foldl' (\acc (p, (i, a)) -> f acc p i a) z freq
             _ -> error $ "no group '" ++ show cgroup
                                       ++ "' among content that has groups "
                                       ++ show (M.keys groupFreq)
                          `showFailure` ()
       , olength = V.length contentVector
       }
