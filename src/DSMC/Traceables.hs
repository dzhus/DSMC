{-# LANGUAGE BangPatterns #-}

{-|

Ray-casting routines for constructive solid geometry.

This module provides constructors for complex bodies as well as
routines to compute intersections of such bodies with ray. In DSMC it
is used to calculate points at which particles hit the body surface.

-}

module DSMC.Traceables
    ( -- * Bodies
      Body
    -- ** Primitives
    , plane
    , sphere
    , cylinder
    , cone
    -- ** Compositions
    , intersect
    , unite
    , complement
    -- * Ray casting
    , HitPoint(..)
    , hitPoint
    , HitSegment
    , Trace
    , trace
    -- * Body membership
    , inside
    )

where

import Prelude hiding (Just, Nothing, Maybe, fst, snd, reverse)

import Data.Functor
import Data.Strict.Maybe
import Data.Strict.Tuple

import DSMC.Particles
import DSMC.Types
import DSMC.Util
import DSMC.Util.Vector


-- | Time when particle hits the surface with normal at the hit point.
-- If hit is in infinity, then normal is Nothing.
--
-- Note that this datatype is strict only on first argument: we do not
-- compare normals when classifying traces.
data HitPoint = HitPoint !Double (Maybe Vec3)
                deriving (Eq, Ord, Show)


-- | A segment on time line when particle is inside the body.
--
-- Using strict tuple performs better: 100 traces for 350K
-- particles perform roughly 7s against 8s with common datatypes.
type HitSegment = (Pair HitPoint HitPoint)


-- | Trace of a linearly-moving particle on a body is a list of time
-- segments/intervals during which the particle is inside the body.
--
-- >                       # - particle
-- >                        \
-- >                         \
-- >                          o------------
-- >                      ---/ *           \---
-- >                    -/      *              \-
-- >                   /         *               \
-- >                  (           *  - trace      )
-- >                   \           *             /
-- >                    -\          *          /-
-- >       primitive -  ---\         *     /---
-- >                          --------o----
-- >                                   \
-- >                                    \
-- >                                    _\/
-- >                                      \
--
--
-- For example, since a ray intersects a plane only once, a halfspace
-- primitive defined by this plane results in a half-interval trace of
-- a particle:
--
-- >                                          /
-- >                                         /
-- >                                        /
-- >              #------------------------o*****************>
-- >              |                       /                  |
-- >           particle                  /            goes to infinity
-- >                                    /
-- >                                   /
-- >                                  /
-- >                                 / - surface of halfspace
--
-- Ends of segments or intervals are calculated by intersecting the
-- trajectory ray of a particle and the surface of the primitive. This
-- may be done by substituting the equation of trajectory @X(t) = X_o
-- + V*t@ into the equation which defines the surface and solving it
-- for @t@. If the body is a composition, traces from primitives are
-- then classified according to operators used to define the body
-- (union, intersection or complement).
--
-- Although only convex primitives are used in current implementation,
-- compositions may result in concave bodies, which is why trace is
-- defined as a list of segments.
--
--
-- In this example, body is an intersection of a sphere and sphere
-- complement:
-- 
-- >                                /|\
-- >                                 |
-- >                                 |
-- >                                 |
-- >                   -----------   |
-- >              ----/           \--o-
-- >            -/                   * \-
-- >          -/               hs2 - *   \
-- >        -/                       * ---/
-- >       /                         o/
-- >      /                        -/|
-- >     /                        /  |
-- >     |                       /   |
-- >    /                        |   |
-- >    |                       /    |
-- >    |                       |    |
-- >    |                       \    |
-- >    \                        |   |
-- >     |                       \   |
-- >     \                        \  |
-- >      \                        -\|
-- >       \                         o\
-- >        -\                       * ---\
-- >          -\               hs1 - *   /
-- >            -\                   * /-
-- >              ----\           /--o-
-- >                   -----------   |
-- >                                 |
-- >                                 |
-- >                                 # - particle
--
-- If only intersections of concave primitives were allowed, then
-- trace type might be simplified to be just single 'HitSegment'.
type Trace = [HitSegment]


-- | IEEE positive infinity.
infinityP :: Double
infinityP = (/) 1 0


-- | Negative infinity.
infinityN :: Double
infinityN = -infinityP


hitN :: HitPoint
hitN = (HitPoint infinityN Nothing)


hitP :: HitPoint
hitP = (HitPoint infinityP Nothing)


-- | CSG body is a recursive composition of primitive objects or other
-- bodies.
data Body = Plane !Vec3 !Double
          -- ^ Halfspace with normalized outward normal and distance
          -- from origin.
          | Sphere !Vec3 !Double
          | Cylinder !Vec3 !Point !Double
          -- ^ Cylinder with normalized axis vector, point on axis and
          -- radius.
          | Cone !Vec3 !Point !Double !Matrix !Double !Double
          -- ^ Cone given by axis direction, vertex and angle h
          -- between axis and outer edge (in radians).
          --
          -- Additionally transformation matrix $n * n - cos^2 h$,
          -- angle tangent and odelta are stored for intersection
          -- calculations.
          | Union !Body !Body
          | Intersection !Body !Body
          | Complement !Body
            deriving Show


-- | Half-space defined by plane with outward normal and distance from
-- origin.
plane :: Vec3 -> Double -> Body
plane n d = Plane (normalize n) d


-- | Sphere defined by center point and radius.
sphere :: Vec3 -> Double -> Body
sphere o r = Sphere o r


-- | Infinite cylinder defined by vector collinear to axis, point on
-- axis and radius.
cylinder :: Vec3 -> Point -> Double -> Body
cylinder a o r = Cylinder (normalize a) o r

-- | Right circular cone defined by outward axis vector, apex point and
-- angle between generatrix and axis.
cone :: Vec3 -> Point -> Double -> Body
cone a o h =
    let
        h' = cos $! h
        n = normalize $ a .^ (-1)
        gamma = diag (-h' * h')
        m = addM (n `vxv` n) gamma
        ta = tan $ h
        odelta = n .* o
    in
      Cone n o h m ta odelta

-- | Intersection of two bodies.
intersect :: Body -> Body -> Body
intersect !b1 !b2 = Intersection b1 b2


-- | Union of two bodies.
unite :: Body -> Body -> Body
unite !b1 !b2 = Union b1 b2


-- | Complement to a body (normals flipped).
complement :: Body -> Body
complement !b = Complement b


-- | Calculate a trace of a particle on a body.
trace :: Body -> Particle -> Trace
{-# INLINE trace #-}

trace !(Plane n d) !(pos, v) =
    let
        !f = -(n .* v)
    in
      -- Check if ray is parallel to plane
      if f == 0
      then []
      else
          let
              !t = (pos .* n - d) / f
          in
            if f > 0
            then [(HitPoint t (Just n)) :!: (HitPoint infinityP Nothing)]
            else [(HitPoint infinityN Nothing) :!: (HitPoint t (Just n))]

trace !(Sphere c r) !(pos, v) =
      let
          !d = pos <-> c
          !roots = solveq (v .* v) (v .* d * 2) (d .* d - r * r)
          normal !u = normalize (u <-> c)
      in
        case roots of
          Nothing -> []
          Just (t1 :!: t2) ->
              [HitPoint t1 (Just $ normal $ moveBy pos v t1) :!:
               HitPoint t2 (Just $ normal $ moveBy pos v t2)]

trace !(Cylinder n c r) !(pos, v) =
    let
        r2 = r * r
        d = (pos <-> c) >< n
        e = v >< n
        roots = solveq (e .* e) (d .* e * 2) (d .* d - r2)
        normal u = normalize $ h <-> (n .^ (h .* n))
            where h = u <-> c
    in
      case roots of
        Nothing -> []
        Just (t1 :!: t2) ->
            [HitPoint t1 (Just $ normal $ moveBy pos v t1) :!:
                      HitPoint t2 (Just $ normal $ moveBy pos v t2)]

trace !(Cone n c _ m ta odelta) !(pos, v) =
    let
      delta = pos <-> c
      c2 = dotM v     v     m
      c1 = dotM v     delta m
      c0 = dotM delta delta m
      roots = solveq c2 (2 * c1) c0
      normal !u = normalize $ nx .^ (1 / ta)  <-> ny .^ ta
          where h = u <-> c
                -- Component of h parallel to cone axis
                ny' = n .^ (n .* h)
                ny = normalize ny'
                -- Perpendicular component
                nx = normalize $ h <-> ny'
    in
      case roots of
        Nothing -> []
        Just (t1 :!: t2) ->
            let
                pos1 = moveBy pos v t1
                pos2 = moveBy pos v t2
            in
              case ((pos1 .* n - odelta) > 0, (pos1 .* n - odelta) > 0) of
                (True, True) -> [HitPoint t1 (Just $ normal pos1) :!:
                                 HitPoint t2 (Just $ normal pos2)]
                (True, False) -> [HitPoint infinityN Nothing :!:
                                  HitPoint t1 (Just $ normal pos1)]
                (False, True) -> [HitPoint t2 (Just $ normal pos2) :!:
                                  HitPoint infinityP Nothing]
                (False, False) -> []

trace !(Intersection b1 b2) !p =
    intersectTraces tr1 tr2
        where
          tr1 = trace b1 p
          tr2 = trace b2 p

trace !(Union b1 b2) !p =
    uniteTraces tr1 tr2
        where
          tr1 = trace b1 p
          tr2 = trace b2 p

trace !(Complement b) !p =
    complementTraces tr
        where
          tr = trace b p

uniteTraces :: Trace -> Trace -> Trace
uniteTraces u [] = u
uniteTraces u (v:t2) =
      uniteTraces (unite1 u v) t2
      where
        merge :: HitSegment -> HitSegment -> HitSegment
        merge !(a1 :!: b1) !(a2 :!: b2) = (min a1 a2) :!: (max b1 b2)
        {-# INLINE merge #-}
        unite1 :: Trace -> HitSegment -> Trace
        unite1 [] hs = [hs]
        unite1 t@(hs1@(a1 :!: b1):tr') hs2@(a2 :!: b2)
            | b1 < a2 = hs1:(unite1 tr' hs2)
            | a1 > b2 = hs2:t
            | otherwise = unite1 tr' (merge hs1 hs2)
        {-# INLINE unite1 #-}
{-# INLINE uniteTraces #-}


intersectTraces :: Trace -> Trace -> Trace
intersectTraces tr1 tr2 =
    let
        -- Overlap two overlapping segments
        overlap :: HitSegment -> HitSegment -> HitSegment
        overlap !(a1 :!: b1) !(a2 :!: b2) = (max a1 a2) :!: (min b1 b2)
        {-# INLINE overlap #-}
    in
      case tr2 of
        [] -> []
        (hs2@(a2 :!: b2):tr2') ->
            case tr1 of
              [] -> []
              (hs1@(a1 :!: b1):tr1') ->
                  case (b1 < a2) of
                    True -> (intersectTraces tr1' tr2)
                    False ->
                        case (b2 < a1) of
                          True -> intersectTraces tr1 tr2'
                          False -> (overlap hs1 hs2):(intersectTraces tr1' tr2)
{-# INLINE intersectTraces #-}


-- | Complement to trace (normals flipped) in @R^3@.
complementTraces :: Trace -> Trace
complementTraces ((sp@(HitPoint ts _) :!: ep):xs) =
    start ++ (complementTraces' ep xs)
    where
      flipNormals :: HitSegment -> HitSegment
      flipNormals !((HitPoint t1 n1) :!: (HitPoint t2 n2)) =
          (HitPoint t1 (reverse <$> n1)) :!: (HitPoint t2 (reverse <$> n2))
      {-# INLINE flipNormals #-}
      -- Start from infinity if first hitpoint is finite
      start = if (isInfinite ts)
              then []
              else [flipNormals $ hitN :!: sp]
      complementTraces' :: HitPoint -> Trace -> Trace
      complementTraces' c ((a :!: b):tr) =
          -- Bridge between last point of previous segment and first
          -- point of the next one.
          (flipNormals (c :!: a)):(complementTraces' b tr)
      complementTraces' a@(HitPoint t _) [] =
          -- End in infinity if last hitpoint is finite
          if (isInfinite t)
          then []
          else [flipNormals (a :!: hitP)]
complementTraces [] = [hitN :!: hitP]
{-# INLINE complementTraces #-}


-- | If the particle has hit the body during last time step, calculate
-- the first corresponding 'HitPoint'. Note that the time at which the hit
-- occured will be negative. This is the primary function to calculate
-- ray-body intersections.
hitPoint :: Time -> Body -> Particle -> Maybe HitPoint
hitPoint !dt !b !p =
    let
        lastHit = [(HitPoint (-dt) Nothing) :!: (HitPoint 0 Nothing)]
    in
      case (intersectTraces lastHit $ trace b p) of
        [] -> Nothing
        (hs:_) -> Just $ fst hs
{-# INLINE hitPoint #-}


-- | True if particle is in inside the body.
--
-- Note that this uses 'trace' internally. A more efficient version
-- would implement custom membership predicates for all primitives and
-- use boolean operations to handle compositions.
inside :: Body -> Particle -> Bool
inside !b !(pos, _) = 
    not $ 
    null $
    intersectTraces (trace b (pos, (1, 0, 0)))
                    [(HitPoint 0 Nothing) :!: (HitPoint 0 Nothing)]
{-# INLINE inside #-}
