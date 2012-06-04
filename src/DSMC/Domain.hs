{-# LANGUAGE BangPatterns #-}

{-|

Domain operations

-}

module DSMC.Domain
    ( Domain
    , makeDomain
    , clipToDomain
    , openBoundaryInjection
    , initialParticles
    )

where

import Control.Monad

import Control.Monad.ST
import qualified Data.Array.Repa as R
import qualified Data.Vector.Unboxed as VU

import System.Random.MWC
import System.Random.MWC.Distributions (normal)

import DSMC.Constants
import DSMC.Particles
import DSMC.Util.Vector


-- | Domain in which particles are spawned or system evolution is
-- simulated.
data Domain = Domain !Double !Double !Double !Double !Double !Double
            -- ^ Rectangular volume, given by min/max value on every
            -- dimension.
              deriving Show


-- | Create a rectangular domain with center in the given point and
-- dimensions.
makeDomain :: Point
        -- ^ Center point.
        -> Double
        -- ^ X dimension.
        -> Double
        -- ^ Y dimension.
        -> Double
        -- ^ Z dimension.
        -> Domain
makeDomain !(x, y, z) !w !l !h =
    let
        xmin = x - w / 2
        ymin = y - l / 2
        zmin = z - h / 2
        xmax = x + w / 2
        ymax = y + l / 2
        zmax = z + h / 2
    in
      Domain xmin xmax ymin ymax zmin zmax
{-# INLINE makeDomain #-}


-- | Calculate width, length and height of a domain, which are
-- dimensions measured by x, y and z axes, respectively.
getDimensions :: Domain -> (Double, Double, Double)
getDimensions !(Domain xmin xmax ymin ymax zmin zmax) =
    (xmax - xmin, ymax - ymin, zmax - zmin)
{-# INLINE getDimensions #-}


-- | Calculate geometric center of a domain.
getCenter :: Domain -> Point
getCenter !(Domain xmin xmax ymin ymax zmin zmax) =
    (xmin + (xmax - xmin) / 2, ymin + (ymax - ymin) / 2, zmin + (zmax - zmin) / 2)
{-# INLINE getCenter #-}


-- | Measure volume of domain.
volume :: Domain -> Double
volume !(Domain xmin xmax ymin ymax zmin zmax) =
    (xmax - xmin) * (ymax - ymin) * (zmax - zmin)
{-# INLINE volume #-}


-- | Sample new particles inside a domain.
--
-- PRNG state implies this to be a monadic action. We want to use this
-- with Strategies, thus fixing monad type as ST.
spawnParticles :: GenST s
               -> Domain
               -> Flow
               -> ST s (VU.Vector Particle)
spawnParticles g d@(Domain xmin xmax ymin ymax zmin zmax) flow =
    let
        !s = sqrt $ boltzmann * (temperature flow) / (mass flow)
        !(u0, v0, w0) = velocity flow
        count = round $ (modelConcentration flow) * (volume d)
    in do
      VU.replicateM count $ do
         u <- normal u0 s g
         v <- normal v0 s g
         w <- normal w0 s g
         x <- uniformR (xmin, xmax) g
         y <- uniformR (ymin, ymax) g
         z <- uniformR (zmin, zmax) g
         return $! ((x, y, z), (u, v, w))


initialParticles :: GenST s
                 -> Domain
                 -> Flow
                 -> ST s Ensemble
initialParticles g d flow = liftM fromUnboxed1 $ spawnParticles g d flow



-- | Sample new particles in 6 interface domains along each side of
-- rectangular simulation domain and add them to existing ensemble.
--
-- This function implements open boundary condition for
-- three-dimensional simulation domain.
--
-- Interface domains are built on faces of simulation domain using
-- extrusion along the outward normal of the face.
--
-- In 2D projection:
-- >          +-----------------+
-- >          |    Interface1   |
-- >       +--+-----------------+--+
-- >       |I3|    Simulation   |I4|
-- >       |  |      domain     |  |
-- >       +--+-----------------+--+
-- >          |        I2       |
-- >          +-----------------+
--
-- PRNG state requires this to be a monadic action.
--
-- TODO: VU.concat is O(n), but we could generate this in one single
-- pass. For 
openBoundaryInjection :: GenST s
                      -> Domain
                      -- ^ Simulation domain.
                      -> Double
                      -- ^ Interface domain extrusion length.
                      -> Flow
                      -> Ensemble
                      -> ST s Ensemble
openBoundaryInjection g domain ex flow ens =
    let
        (w, l, h) = getDimensions domain
        (cx, cy, cz) = getCenter domain
        d1 = makeDomain (cx - (w + ex) / 2, cy, cz) ex l h
        d2 = makeDomain (cx + (w + ex) / 2, cy, cz) ex l h
        d3 = makeDomain (cx, cy + (l + ex) / 2, cz) w ex h
        d4 = makeDomain (cx, cy - (l + ex) / 2, cz) w ex h
        d5 = makeDomain (cx, cy, cz - (h + ex) / 2) w l ex
        d6 = makeDomain (cx, cy, cz + (h + ex) / 2) w l ex
        v = [R.toUnboxed ens]
    in do
      new <- mapM (\d -> spawnParticles g d flow) [d1, d2, d3, d4, d5, d6]
      return $ fromUnboxed1 $ VU.concat (new ++ v)


-- | Filter out particles which are outside of the domain.
--
-- This is a monadic action because 'selectP' is used, which does
-- 'unsafePerformIO' under the hood.
clipToDomain :: Monad m => Domain -> Ensemble -> m Ensemble
clipToDomain (Domain xmin xmax ymin ymax zmin zmax) ens = 
    let
        (R.Z R.:. size) = R.extent ens
        -- | Get i-th particle from ensemble
        getter :: Int -> Particle
        getter i = (R.!) ens (R.ix1 i)
        {-# INLINE getter #-}
        -- | Check if particle is in the domain.
        pred :: Int -> Bool
        pred i =
            let 
                ((x, y, z), _) = getter i
            in
              xmax >= x && x >= xmin &&
              ymax >= y && y >= ymin &&
              zmax >= z && z >= zmin
        {-# INLINE pred #-}
    in do
      return $ R.selectP pred getter size ens
