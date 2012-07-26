{-# LANGUAGE BangPatterns #-}

{-|

Macroscopic parameters calculation.

We use regular spatial grid and time averaging for sampling. Sampling
should start after particle system has reached steady state. Samples
are then collected in each cell for a certain number of time steps.

Sampling is performed in 'MacroSamplingMonad' to ensure that no wrong
parameters get passed to sample collecting routines.

-}

module DSMC.Macroscopic
    ( MacroSamples
    , MacroField
    , MacroParameters
    -- * Macroscopic sampling monad
    , MacroSamplingMonad
    , startMacroSampling
    , updateSamples
    , getField
    )

where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State.Strict

import qualified Data.Strict.Maybe as S

import qualified Data.Array.Repa as R
import qualified Data.Vector.Unboxed as VU

import DSMC.Cells
import DSMC.Particles
import DSMC.Util
import DSMC.Util.Vector


-- | Macroscopic parameters calculated in every cell: particle count,
-- mean absolute velocity, mean square of thermal velocity.
--
-- These are then post-processed into number density, flow velocity,
-- pressure and translational temperature.
--
-- Note the lack of root on thermal velocity!
type MacroParameters = (Double, Vec3, Double)


-- | Vector which stores averaged macroscropic parameters in each
-- cell.
--
-- If samples are collected for M iterations, then this vector is
-- built as a sum of vectors @V1, .. VM@, where @Vi@ is vector of
-- parameters sampled on @i@-th time step divided by @M@.
type MacroSamples = R.Array R.U R.DIM1 MacroParameters


-- | Array of central points of grid cells with averaged macroscopic
-- parameters.
type MacroField = R.Array R.U R.DIM1 (Point, MacroParameters)


-- | Monad which keeps track of sampling process data and stores
-- options of macroscopic sampling.
--
-- State contains counter for averaging steps left and current samples
-- (note that this is a partial sum till sampling is complete). If
-- Nothing, then averaging has not started yet, while -1 means that
-- it's complete.
--
-- We use this to make sure that only safe values for cell count and
-- classifier are used in 'updateSamples' and 'averageSamples' (that
-- may otherwise cause unbounded access errors).
type MacroSamplingMonad =
    StateT (Maybe (Int, MacroSamples)) (Reader MacroSamplingOptions)


-- | Options for macroscopic sampling: uniform grid and averaging
-- steps count.
data MacroSamplingOptions =
    MacroSamplingOptions { _sorting :: (Int, Classifier)
                         , _indexer :: Int -> Point
                         , _averagingSteps :: Int
                         }


-- | Fetch macroscopic field if averaging is complete.
getField :: MacroSamplingMonad (Maybe MacroField)
getField = do
  (cellCount, _) <- lift $ asks _sorting
  indexer <- lift $ asks _indexer
  res <- get
  case res of
    Just ((-1), samples) -> do
             let centralPoints = R.fromFunction (R.ix1 $ cellCount)
                                 (\(R.Z R.:. cellNumber) -> indexer cellNumber)
             f <- R.computeP $ R.zipWith (,) centralPoints samples
             return $ Just f
    _ -> return $ Nothing


-- | Parameters in empty cell.
emptySample :: MacroParameters
emptySample = (0, (0, 0, 0), 0)


-- | Run 'MacroSamplingMonad' action with given sampling options and
-- last state with macroscopic samples.
startMacroSampling :: MacroSamplingMonad r
                   -> UniformGrid
                   -- ^ Grid used to sample macroscopic parameters.
                   -> Int
                   -- ^ Averaging steps count.
                   -> (r, Maybe (Int, MacroSamples))
startMacroSampling f subdiv ssteps = 
    runReader (runStateT f Nothing) $
              MacroSamplingOptions
              (makeUniformClassifier subdiv)
              (makeUniformIndexer subdiv)
              ssteps


-- | Create empty 'MacroSamples' array.
initializeSamples :: Int
                  -- ^ Cell count.
                  -> MacroSamples
initializeSamples cellCount = fromUnboxed1 $
                              VU.replicate cellCount emptySample


-- | Gather samples from ensemble. Return True if sampling is
-- finished, False otherwise.
updateSamples :: Ensemble
              -> MacroSamplingMonad Bool
updateSamples ens =
    let
        addCellParameters :: MacroParameters
                          -> MacroParameters
                          -> MacroParameters
        addCellParameters !(n1, v1, c1) !(n2, v2, c2) =
            (n1 + n2, v1 <+> v2, c1 + c2)
    in do
      sorting@(cellCount, _) <- lift $ asks _sorting

      maxSteps <- lift $ asks _averagingSteps

      sampling <- get

      -- n is steps left for averaging
      let (n, oldSamples) =
              case sampling of
                Nothing -> (maxSteps, initializeSamples cellCount)
                Just o -> o
          weight = 1 / fromIntegral maxSteps
          -- Sort particles into macroscopic cells for sampling
          sorted = sortParticles sorting ens
          -- Sampling results from current step
          stepSamples = cellMap (\_ c -> sampleMacroscopic c weight) sorted
       -- Add samples from current step to all sum of samples collected so
       -- far
      !newSamples <- R.computeP $
                     R.zipWith addCellParameters oldSamples stepSamples

      -- Update state of sampling process
      put $ Just (n - 1, newSamples)

      return (n == 0)

-- | Sample macroscopic values in a cell.
sampleMacroscopic :: S.Maybe CellContents
                  -> Double
                  -- ^ Multiply all sampled parameters by this number,
                  -- which is the statistical weight of one sample.
                  -- Typically this is inverse to the amount of steps
                  -- used for averaging.
                  -> MacroParameters
sampleMacroscopic !c !weight =
    case c of
      S.Nothing -> emptySample
      S.Just ens ->
          let
              -- Particle count
              n = fromIntegral $ VU.length ens
              -- Particle averaging factor
              s = 1 / n
              -- Velocities factor
              sv = s * weight
              -- Mean absolute velocity
              m1 = (VU.foldl' (\v0 (_, v) -> v0 <+> v) (0, 0, 0) ens) .^ sv
              -- Mean square thermal velocity
              c2 = (VU.foldl' (+) 0 $
                      VU.map (\(_, v) ->
                                  let
                                    thrm = (v <-> m1)
                                  in
                                    (thrm .* thrm))
                      ens) * sv
          in
            (n * weight, m1, c2)
