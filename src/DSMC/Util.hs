{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE Rank2Types #-}

-- | Utility functions and definitions.

module DSMC.Util
    ( solveq
    , SquareRoots
    , fromUnboxed1
    , iforM_
    , Time
    )

where

import Prelude hiding (Just, Nothing, Maybe, fst)

import Data.Strict.Maybe
import Data.Strict.Tuple

import qualified Data.Array.Repa as R
import qualified Data.Vector.Unboxed as VU


-- | Results of solving a quadratic equation.
type SquareRoots = Maybe (Pair Double Double)

-- | Solve quadratic equation @ax^2 + bx + c = 0@.
--
-- If less than two roots exist, Nothing is returned.
solveq :: Double
       -- ^ a
       -> Double
       -- ^ b
       -> Double
       -- ^ c
       -> SquareRoots
solveq !a !b !c
    | (d > 0)   = Just $ min r1 r2 :!: max r1 r2
    | otherwise = Nothing
    where
      d  =   b * b - 4 * a * c
      q  =   sqrt d
      t  =   2 * a
      r  = - b / t
      s  =   q / t
      r1 =   r - s
      r2 =   r + s
{-# INLINE solveq #-}


-- | Convert between Repa 'R.DIM1'-arrays and unboxed 'VU.Vector's.
fromUnboxed1 :: (VU.Unbox e) => VU.Vector e -> R.Array R.U R.DIM1 e
fromUnboxed1 v = R.fromUnboxed (R.ix1 $ VU.length v) v
{-# INLINE fromUnboxed1 #-}


-- | Map monadic action over pairs of vector indices and items and
-- throw away the results.
iforM_ :: (Monad m, VU.Unbox a) =>
          VU.Vector a
       -> ((Int, a) -> m b)
       -> m ()
iforM_ v = VU.forM_ (VU.imap (,) v)
{-# INLINE iforM_ #-}


-- | Time in seconds.
type Time = Double
