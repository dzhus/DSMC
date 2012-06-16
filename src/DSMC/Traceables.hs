{-# LANGUAGE BangPatterns #-}

-- | Body compositions for which particle trajectory intersections
-- can be calculated.

module DSMC.Traceables
    ( -- * Traces
      HitPoint(..)
    , hitPoint
    , trace
    -- * Traceable bodies
    , Body
    -- ** Primitives
    , plane
    , sphere
    , cylinder
    -- ** Compositions
    , intersect
    )

where

import Prelude hiding (Just, Nothing, Maybe, fst, reverse)

import Data.Functor
import Data.Strict.Maybe
import Data.Strict.Tuple

import DSMC.Particles
import DSMC.Types
import DSMC.Util
import DSMC.Util.Vector



-- | Trace of a linearly-moving particle on a primitive is the time
-- interval during which particle is considered to be inside the
-- primitive.
--
-- >                       * - particle
-- >                        \
-- >                         \
-- >                          o------------
-- >                      ---/ =           \---
-- >                    -/      =              \-
-- >                   /         =               \
-- >                  (           =  - trace      )
-- >                   \           =             /
-- >                    -\          =          /-
-- >       primitive -  ---\         =     /---
-- >                          --------o----
-- >                                   \
-- >                                    \
-- >                                    _\/
-- >                                      \
--
-- We consider only primitives defined by quadratic or linear
-- surfaces. Thus trace may contain a single segment, or a single
-- half-interval, or two half-intervals. Ends of segments or intervals
-- are calculated by intersecting the trajectory ray of a particle and
-- the surface of the primitive. This may be done by substituting the
-- equation of trajectory @X(t) = X_o + V*t@ into the equation which
-- defines the surface and solving it for @t@.
--
-- For example, since a ray intersects a plane only once, a halfspace
-- primitive defined by this plane results in a half-interval trace of
-- a particle:
--
-- >                                          /
-- >                                         /
-- >                                        /
-- >              *------------------------o=================>
-- >              |                       /                  |
-- >           particle                  /            goes to infinity
-- >                                    /
-- >                                   /
-- >                                  /
-- >                                 / - surface of halfspace
--
-- Using strict Maybe and tuple performs better: 100 traces for 350K
-- particles perform roughly 7s against 8s with common datatypes.
type Trace = Maybe (Pair HitPoint HitPoint)


-- | Time when particle hits the surface, along with normal at hit
-- point. If hit is in infinity, then normal is Nothing.
--
-- Note that this datatype is strict only on first argument: we do not
-- compare normals when classifying traces.
data HitPoint = HitPoint !Double (Maybe Vec3)
                deriving (Eq, Ord, Show)


-- | IEEE positive infinity.
infinityP :: Double
infinityP = (/) 1 0


-- | Negative infinity.
infinityN :: Double
infinityN = -infinityP


-- | CSG body is a recursive composition of primitive objects or other
-- bodies. We require that prior to tracing particles on a body it's
-- converted to sum-of-products form.
data Body = Plane !Vec3 !Double
          | Sphere !Vec3 !Double
          | Cylinder !Vec3 !Point !Double
          | Cone !Vec3 !Point !Double
          -- | Cone given by axis direction, vertex and angle between
          -- axis and outer edge (in radians).
          | Union !Body !Body
          -- ^ Union of bodies.
          | Intersection !Body !Body
          -- ^ Intersection of bodies.
            deriving Show


-- | Half-space defined by plane with outward normal and
-- distance from origin.
plane :: Vec3 -> Double -> Body
plane n d = Plane (normalize n) d

-- | Sphere defined by center point and radius.
sphere :: Vec3 -> Double -> Body
sphere o r = Sphere o r

-- | Infinite cylinder defined by vector collinear to axis, point on
-- axis and radius.
cylinder :: Vec3 -> Point -> Double -> Body
cylinder a o r = Cylinder (normalize a) o r

intersect :: Body -> Body -> Body
intersect b1 b2 = Intersection b1 b2

-- | Trace a particle on a body.
trace :: Body -> Particle -> Trace

trace !(Plane n d) !(pos, v) =
    let
        !f = -(n .* v)
    in
      -- Check if ray is parallel to plane
      if f == 0
      then Nothing
      else
          let
              !t = (pos .* n - d) / f
          in
            if f > 0
            then Just ((HitPoint t (Just n)) :!: (HitPoint infinityP Nothing))
            else Just ((HitPoint infinityN Nothing) :!: (HitPoint t (Just n)))

trace !(Sphere c r) !(pos, v) =
      let
          !d = pos <-> c
          !roots = solveq (v .* v) (v .* d * 2) (d .* d - r * r)
          normal !u = normalize (u <-> c)
      in
        case roots of
          Nothing -> Nothing
          Just (t1 :!: t2) -> Just $
                           (HitPoint t1 (Just $ normal $ moveBy pos v t1) :!:
                            HitPoint t2 (Just $ normal $ moveBy pos v t2))

trace !(Cylinder n c r) !(pos, v) =
    let
        r2 = r * r
        d = (pos <-> c) >< n
        e = v >< n
        roots = solveq (e .* e) (d .* e * 2) (d .* d - r2)
        normal u = normalize $ h <-> (nn .^ (h .* nn))
            where h = u <-> c
    in
      case roots of
        Nothing -> Nothing
        Just (t1 :!: t2) -> Just $
                            (HitPoint t1 (Just $ normal $ moveBy pos v t1) :!:
                             HitPoint t2 (Just $ normal $ moveBy pos v t2))

trace !(Cone n c a) !(pos, v) =
    let
      nn = normalize n
      a' = cos $! a
      gamma = diag (-a' * a')
      delta = pos <-> c
      m = addM (nn `vxv` nn) gamma
      c2 = dotM v     v     m
      c1 = dotM v     delta m
      c0 = dotM delta delta m
      roots = solveq c2 (2 * c1) c0
      normal u = normalize $ nx .^ (1 / ta)  <-> ny .^ ta
          where h = u <-> c
                -- Component of h parallel to cone axis
                ny' = nn .^ (nn .* h)
                ny = normalize ny'
                -- Perpendicular component
                nx = normalize $ h <-> ny'
                ta = tan $! a
    in
      case roots of
        Nothing -> Nothing
        Just (t1 :!: t2) -> if (v .* nn) / (norm v) < a' then
                                Just $
                                (HitPoint t1 (Just $ normal $ moveBy pos v t1) :!:
                                 HitPoint t2 (Just $ normal $ moveBy pos v t2))
                            else
                                Just $
                                (HitPoint t2 (Just $ normal $ moveBy pos v t2) :!:
                                 HitPoint infinityP Nothing)

trace !(Intersection b1 b2) !p =
    intersectTraces tr1 tr2
        where
          tr1 = trace b1 p
          tr2 = trace b2 p

trace !(Union _ _) _ = error "Can't trace union, perhaps you want 'hitPoint'"


-- | Intersect two traces.
intersectTraces :: Trace -> Trace -> Trace
intersectTraces tr1 tr2 =
    -- Lazy arguments significantly improve the performance.
    case tr1 of
      Nothing -> Nothing
      Just (x :!: y) ->
          case tr2 of
            Nothing -> Nothing
            Just (u :!: v) ->
                case (y > u && x < v) of
                  True -> Just $ max x u :!: min y v
                  False -> Nothing
{-# INLINE intersectTraces #-}


-- | If particle has hit the body during last time step, calculate the
-- corresponding 'HitPoint'. Note that time at which hit occured will
-- be negative.
hitPoint :: Time -> Body -> Particle -> Maybe HitPoint
hitPoint !dt !b !p =
    let
        lastHit = Just $ (HitPoint (-dt) Nothing :!: HitPoint 0 Nothing)
    in
      fst <$> (intersectTraces lastHit $ trace b p)
{-# INLINE hitPoint #-}
