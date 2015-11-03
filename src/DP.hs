-- | The Davis-Putnam and Davis-Putnam-Loveland-Logemann procedures.
--
-- Copyright (c) 2003-2007, John Harrison. (See "LICENSE.txt" for details.)

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module DP
    ( dp,   dpsat,   dptaut
    , dpli, dplisat, dplitaut
    , dpll, dpllsat, dplltaut
    , dplb, dplbsat, dplbtaut
#ifndef NOTESTS
    , testDP
#endif
    ) where

import Data.Map as Map (empty, Map)
import Data.Set as Set (delete, difference, empty, filter, findMin, fold, insert, intersection, map, member,
                        minView, null, partition, Set, singleton, size, union)
import DefCNF (NumAtom(ai, ma), defcnfs)
import Formulas (IsFormula(AtomOf), IsNegatable, (.~.), negative, positive, negate, negated)
import Lib (Failing(Success, Failure), failing, allpairs, minimize, maximize, defined, (|->), setmapfilter, flatten)
import Prelude hiding (negate, pure)
import Prop (trivial, IsPropositional, JustPropositional)
import PropExamples (Knows(K))
#ifndef NOTESTS
import Prop (PFormula)
import PropExamples (prime)
import Test.HUnit
#endif

instance NumAtom (Knows Integer) where
    ma n = K "p" n Nothing
    ai (K _ n _) = n

-- | The DP procedure.
dp :: (IsNegatable lit, Ord lit) => Set (Set lit) -> Bool
dp clauses
  | Set.null clauses = True
  | Set.member Set.empty clauses = False
  | otherwise = try1
  where
    try1 :: Bool
    try1 = failing (const try2) dp (one_literal_rule clauses)
    try2 :: Bool
    try2 = failing (const try3) dp (affirmative_negative_rule clauses)
    try3 :: Bool
    try3 = dp (resolution_rule clauses)
{-
      case one_literal_rule clauses >>= dp of
        Success x -> Success x
        Failure _ ->
            case affirmative_negative_rule clauses >>= dp of
              Success x -> Success x
              Failure _ -> resolution_rule clauses >>= dp
-}

one_literal_rule :: (IsNegatable lit, Ord lit) => Set (Set lit) -> Failing (Set (Set lit))
one_literal_rule clauses =
    case Set.minView (Set.filter (\ cl -> Set.size cl == 1) clauses) of
      Nothing -> Failure ["one_literal_rule"]
      Just (s, _) ->
          let u = Set.findMin s in
          let u' = (.~.) u in
          let clauses1 = Set.filter (\ cl -> not (Set.member u cl)) clauses in
          Success (Set.map (\ cl -> Set.delete u' cl) clauses1)

affirmative_negative_rule :: (IsNegatable lit, Ord lit) => Set (Set lit) -> Failing (Set (Set lit))
affirmative_negative_rule clauses =
  let (neg',pos) = Set.partition negative (flatten clauses) in
  let neg = Set.map (.~.) neg' in
  let pos_only = Set.difference pos neg
      neg_only = Set.difference neg pos in
  let pure = Set.union pos_only (Set.map (.~.) neg_only) in
  if Set.null pure
  then Failure ["affirmative_negative_rule"]
  else Success (Set.filter (\ cl -> Set.null (Set.intersection cl pure)) clauses)

resolve_on :: (IsNegatable lit, Ord lit) => lit -> Set (Set lit) -> Set (Set lit)
resolve_on p clauses =
  let p' = (.~.) p
      (pos,notpos) = Set.partition (Set.member p) clauses in
  let (neg,other) = Set.partition (Set.member p') notpos in
  let pos' = Set.map (Set.filter (\ l -> l /= p)) pos
      neg' = Set.map (Set.filter (\ l -> l /= p')) neg in
  let res0 = allpairs Set.union pos' neg' in
  Set.union other (Set.filter (not . trivial) res0)

resolution_blowup :: (IsNegatable lit, Ord lit) => Set (Set lit) -> lit -> Int
resolution_blowup cls l =
  let m = Set.size (Set.filter (Set.member l) cls)
      n = Set.size (Set.filter (Set.member ((.~.) l)) cls) in
  m * n - m - n

resolution_rule :: (IsNegatable lit, Ord lit) => Set (Set lit) -> Set (Set lit)
resolution_rule clauses = resolve_on p clauses
    where
      pvs = Set.filter positive (flatten clauses)
      Just p = minimize (resolution_blowup clauses) pvs

-- | Davis-Putnam satisfiability tester.
dpsat :: (IsPropositional pf, JustPropositional pf, Ord pf, NumAtom (AtomOf pf)) => pf -> Bool
dpsat = dp . defcnfs

-- | Davis-Putnam tautology checker.
dptaut :: (IsPropositional pf, JustPropositional pf, Ord pf, NumAtom (AtomOf pf)) => pf -> Bool
dptaut = not . dpsat . negate

#ifndef NOTESTS
-- Examples.

test01 :: Test
test01 = TestCase (assertEqual "dptaut(prime 11) p. 84" True (dptaut (prime 11 :: PFormula (Knows Integer))))
#endif

-- | The same thing but with the DPLL procedure. (p. 84)
dpll :: (IsNegatable lit, Ord lit) => Set (Set lit) -> Bool
dpll clauses
  | Set.null clauses = True
  | Set.member Set.empty clauses = False
  | otherwise = try1
  where
    try1 = failing (const try2) dpll (one_literal_rule clauses)
    try2 = failing (const try3) dpll (affirmative_negative_rule clauses)
    try3 = dpll (Set.insert (Set.singleton p) clauses) || dpll (Set.insert (Set.singleton (negate p)) clauses)
    Just p = maximize (posneg_count clauses) pvs
    pvs = Set.filter positive (flatten clauses)
{-
  | failing (const try3)
  | otherwise =
      case one_literal_rule clauses >>= dpll of
        Success x -> Success x
        Failure _ ->
            case affirmative_negative_rule clauses >>= dpll of
              Success x -> Success x
              Failure _ ->
                  let pvs = Set.filter positive (flatten clauses) in
                  case maximize (posneg_count clauses) pvs of
                    Nothing -> Failure ["dpll"]
                    Just p ->
                        case (dpll (Set.insert (Set.singleton p) clauses), dpll (Set.insert (Set.singleton (negate p)) clauses)) of
                          (Success a, Success b) -> Success (a || b)
                          (Failure a, Failure b) -> Failure (a ++ b)
                          (Failure a, _) -> Failure a
                          (_, Failure b) -> Failure b
-}

posneg_count :: (IsNegatable formula, Ord formula) => Set (Set formula) -> formula -> Int
posneg_count cls l =
  let m = Set.size(Set.filter (Set.member l) cls)
      n = Set.size(Set.filter (Set.member (negate l)) cls) in
  m + n

dpllsat :: (IsPropositional pf, AtomOf pf ~ Knows Integer, JustPropositional pf, Ord pf) =>
           pf -> Bool
dpllsat = dpll . defcnfs

dplltaut :: (IsPropositional pf, AtomOf pf ~ Knows Integer, JustPropositional pf, Ord pf) =>
            pf -> Bool
dplltaut = not . dpllsat . negate

#ifndef NOTESTS
-- Example.
test02 :: Test
test02 = TestCase (assertEqual "dplltaut(prime 11)" True (dplltaut (prime 11 :: PFormula (Knows Integer))))
#endif

-- | Iterative implementation with explicit trail instead of recursion.
dpli :: forall pf. (IsPropositional pf, Ord pf) => Set (pf, TrailMix) -> Set (Set pf) -> Bool
dpli trail cls =
  let (cls', trail') = unit_propagate (cls, trail) in
  if Set.member Set.empty cls' then
    case Set.minView trail of
      Just ((p,Guessed), tt) -> dpli (Set.insert (negate p, Deduced) tt) cls
      _ -> False
  else
      case unassigned cls (trail' :: Set (pf, TrailMix)) of
        s | Set.null s -> True
        ps -> let Just p = maximize (posneg_count cls') ps in
              dpli (Set.insert (p :: pf, Guessed) trail') cls

data TrailMix = Guessed | Deduced deriving (Eq, Ord)

unassigned :: (IsNegatable formula, Ord formula, Eq formula) => Set (Set formula) -> Set (formula, TrailMix) -> Set formula
unassigned cls trail =
    Set.difference (flatten (Set.map (Set.map litabs) cls)) (Set.map (litabs . fst) trail)
    where litabs p = if negated p then negate p else p

unit_subpropagate :: (IsNegatable formula, Ord formula) =>
                     (Set (Set formula), Map formula (), Set (formula, TrailMix))
                  -> (Set (Set formula), Map formula (), Set (formula, TrailMix))
unit_subpropagate (cls,fn,trail) =
  let cls' = Set.map (Set.filter (not . defined fn . negate)) cls in
  let uu cs =
          case Set.minView cs of
            Nothing -> Failure ["unit_subpropagate"]
            Just (c, _) -> if Set.size cs == 1 && not (defined fn c)
                           then Success cs
                           else Failure ["unit_subpropagate"] in
  let newunits = flatten (setmapfilter uu cls') in
  if Set.null newunits then (cls',fn,trail) else
  let trail' = Set.fold (\ p t -> Set.insert (p,Deduced) t) trail newunits
      fn' = Set.fold (\ u -> (u |-> ())) fn newunits in
  unit_subpropagate (cls',fn',trail')

unit_propagate :: forall t. (IsNegatable t, Ord t) =>
                  (Set (Set t), Set (t, TrailMix))
               -> (Set (Set t), Set (t, TrailMix))
unit_propagate (cls,trail) =
  let fn = Set.fold (\ (x,_) -> (x |-> ())) Map.empty trail in
  let (cls',_fn',trail') = unit_subpropagate (cls,fn,trail) in (cls',trail')

backtrack :: forall t. Set (t, TrailMix) -> Set (t, TrailMix)
backtrack trail =
  case Set.minView trail of
    Just ((_p,Deduced), tt) -> backtrack tt
    _ -> trail

dplisat :: (IsPropositional pf, JustPropositional pf, Ord pf, NumAtom (AtomOf pf)) =>
           pf -> Bool
dplisat = dpli Set.empty . defcnfs

dplitaut :: (IsPropositional pf, JustPropositional pf, Ord pf, NumAtom (AtomOf pf)) =>
            pf -> Bool
dplitaut = not . dplisat . negate

-- | With simple non-chronological backjumping and learning.
dplb :: forall a. (IsNegatable a, Ord a) =>
        Set (a, TrailMix) -> Set (Set a) -> Bool
dplb trail cls =
  let (cls',trail') = unit_propagate (cls,trail) in
  if Set.member Set.empty cls' then
    case Set.minView (backtrack trail) of
      Just ((p,Guessed), tt) ->
        let trail'' = backjump cls p tt in
        let declits = Set.filter (\ (_,d) -> d == Guessed) trail'' in
        let conflict = Set.insert (negate p) (Set.map (negate . fst) declits) in
        dplb (Set.insert (negate p, Deduced) trail'') (Set.insert conflict cls)
      _ -> False
  else
    case unassigned cls trail' of
      s | Set.null s -> True
      ps -> let Just p = maximize (posneg_count cls') ps in
            dplb (Set.insert (p,Guessed) trail') cls

backjump :: (IsNegatable a, Ord a) => Set (Set a) -> a -> Set (a, TrailMix) -> Set (a, TrailMix)
backjump cls p trail =
  case Set.minView (backtrack trail) of
    Just ((_q,Guessed), tt) ->
        let (cls',_trail') = unit_propagate (cls, Set.insert (p,Guessed) tt) in
        if Set.member Set.empty cls' then backjump cls p tt else trail
    _ -> trail

dplbsat :: (IsPropositional pf, JustPropositional pf, Ord pf, NumAtom (AtomOf pf)) =>
           pf -> Bool
dplbsat = dplb Set.empty . defcnfs

dplbtaut :: (IsPropositional pf, JustPropositional pf, Ord pf, NumAtom (AtomOf pf)) =>
            pf -> Bool
dplbtaut = not . dplbsat . negate

#ifndef NOTESTS
-- | Examples.
test03 :: Test
test03 = TestList [TestCase (assertEqual "dplitaut(prime 101)" True (dplitaut (prime 101 :: PFormula (Knows Integer)))),
                   TestCase (assertEqual "dplbtaut(prime 101)" True (dplbtaut (prime 101 :: PFormula (Knows Integer))))]

testDP :: Test
testDP = TestLabel "DP" (TestList [test01, test02, test03])
#endif
