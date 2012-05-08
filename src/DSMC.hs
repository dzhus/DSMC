{-|
  
  Simulation procedures.

-}
module DSMC
    ( processParticles
    )

where

import Data.Maybe

import DSMC.Particles
import DSMC.Types
import DSMC.Traceables
import DSMC.Util.Vector


-- | Update particle position and velocity after specular hit given a
-- normalized normal vector of surface in hit point and time since hit
-- (not positive)
reflectSpecular :: Particle -> Vector -> Time -> Particle
reflectSpecular p n t =
    move (-1 * t) p{velocity = v <-> (n .^ (v .* n) .^ 2)}
    where
      v = velocity p


-- | A very small amount of time for which the particle is moved after
-- reflecting from body surface.
hitShift :: Time
hitShift = 10e-10


-- | Particle after possible collision with body during timestep.
hit :: Time -> Body -> Particle -> Particle
hit dt b p = 
    let
        justHit = [(((-dt), Nothing), (0, Nothing))]
        fullTrace = trace b p
        insideTrace = intersectTraces fullTrace justHit
    in
      if null insideTrace
      then p
      else
          let
              hitPoint = fst (head insideTrace)
              t = fst hitPoint
              n = snd hitPoint
              particleAtHit = move t p
          in
            move hitShift (reflectSpecular particleAtHit (fromJust n) t)


-- | Remove particles which accidentally ended up inside body.
clipBody :: Body -> [Particle] -> [Particle]
clipBody body particles = filter (\p -> not (inside body p)) particles


-- | Collisionless flow simulation step.
--
-- Given a list of particles, time step and body, linearly move all
-- particles for, then possibly calculate new particle velocities and
-- positions wrt body structure.
processParticles :: [Particle] -> Time -> Body -> [Particle]
processParticles particles dt body =
    clipBody body (map ((hit dt body) . (move dt)) particles)
