module FOV.Common where

import qualified Data.List as L

import Geometry

type Interval = (Rational, Rational)
type Distance = Int
type Progress = Int

-- | Coordinates of points in a single quadrant.
-- (The first quadrant for Permissive FOV, hence both coordinates positive,
-- a adjacent diagonal halves of the first and the second quadrant
-- for Digital FOV, hence y positive.)
newtype Bump = B Loc
  deriving (Show)

type Line         = (Bump, Bump)
type ConvexHull   = [Bump]
type Edge         = (Line, ConvexHull)
type EdgeInterval = (Edge, Edge)

-- | The translation, rotation and symmetry functions for octants.
tr0, tr1, tr2, tr3, tr4, tr5, tr6, tr7 :: Loc -> Loc -> Loc
tr0 (oy,ox) (d,p) = (oy + d,ox + p)
tr1 (oy,ox) (d,p) = (oy + d,ox - p)
tr2 (oy,ox) (d,p) = (oy - d,ox + p)
tr3 (oy,ox) (d,p) = (oy - d,ox - p)
tr4 (oy,ox) (d,p) = (oy + p,ox + d)
tr5 (oy,ox) (d,p) = (oy + p,ox - d)
tr6 (oy,ox) (d,p) = (oy - p,ox + d)
tr7 (oy,ox) (d,p) = (oy - p,ox - d)

-- | The translation and rotation functions for quadrants.
qtr0, qtr1, qtr2, qtr3 :: Loc -> Bump -> Loc
qtr0 (oy, ox) (B(y, x)) = (oy - y, ox + x)  -- quadrant I
qtr1 (oy, ox) (B(y, x)) = (oy + x, ox + y)  -- II (we rotate counter-clockwise)
qtr2 (oy, ox) (B(y, x)) = (oy + y, ox - x)  -- III
qtr3 (oy, ox) (B(y, x)) = (oy - x, ox - y)  -- IV

-- | Integer division, rounding up.
divUp :: Int -> Int -> Int
divUp n k = - (-n) `div` k

-- | Maximal element of a non-empty list. Prefers elements from the rear,
-- which is essential for PFOV, to avoid ill-defined lines.
maximal :: (a -> a -> Bool) -> [a] -> a
maximal gte = L.foldl1' (\ acc x -> if gte x acc then x else acc)

-- | Check if the line from the second point to the first is more steep
-- than the line from the third point to the first. This is related
-- to the formal notion of gradient (or angle), but hacked wrt signs
-- to work in this particular setup. Returns True for ill-defined lines.
steeper :: Bump ->  Bump -> Bump -> Bool
steeper (B(yf, xf)) (B(y1, x1)) (B(y2, x2)) =
  (yf - y1)*(xf - x2) >= (yf - y2)*(xf - x1)

-- | Adds a bump to the convex hull of bumps represented as a list.
addHull :: (Bump -> Bump -> Bool) -> Bump -> ConvexHull -> ConvexHull
addHull gte b l =
  case l of
    x:y:zs ->
      if gte x y
      then addHull gte b (y:zs)
      else b : l
    _ -> b : l
