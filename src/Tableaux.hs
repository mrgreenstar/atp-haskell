-- | Tableaux, seen as an optimized version of a Prawitz-like procedure.
--
-- Copyright (c) 2003-2007, John Harrison. (See "LICENSE.txt" for details.)

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wall #-}

module Tableaux
    ( unify_literals
    , unify_atoms
    , unify_atoms_eq
    , prawitz
    , deepen, Depth(Depth), K(K)
    , tab
#ifndef NOTESTS
    , testTableaux
#endif
    ) where

import Control.Monad.RWS (RWS)
import Control.Monad.State (execStateT, StateT)
import Data.List as List (map)
import Data.Map as Map
import Data.Set as Set
import Data.String (IsString(..))
import Debug.Trace (trace)
import FOL (asubst, exists, fApp, foldQuantified, for_all, fv, generalize, HasApply(TermOf),
            HasApply, HasApplyAndEquate, JustApply, IsFirstOrder, IsQuantified(VarOf), IsTerm(TVarOf, FunOf),
            pApp, Quant((:!:)), subst, V, vt, zipPredicates, zipPredicatesEq)
import Formulas
import Lib
import Lit
import Prelude hiding (compare)
import Pretty (assertEqual', Pretty(pPrint), prettyShow, text)
import Prop (Propositional, simpdnf, unmarkPropositional)
import Skolem (askolemize, HasSkolem(toSkolem), runSkolem, skolemize)
import Unif (Unify(unify), unify_terms)
#ifndef NOTESTS
import Herbrand (davisputnam)
import Skolem (MyFormula, MyAtom, MyTerm)
import Test.HUnit hiding (State)
#endif

-- | Unify literals (just pretend the toplevel relation is a function).
unify_literals :: (IsLiteral lit, HasApply atom, Unify atom v term,
                   atom ~ AtomOf lit, term ~ TermOf atom, v ~ VarOf lit, v ~ TVarOf term) =>
                  lit -> lit -> StateT (Map v term) Failing ()
unify_literals f1 f2 =
    maybe err id (zipLiterals' ho ne tf at f1 f2)
    where
      ho _ _ = Nothing
      ne p q = Just $ unify_literals p q
      tf p q = if p == q then Just (unify_terms []) else Nothing
      at a1 a2 = Just $ unify a1 a2
      err = fail "Can't unify literals"

unify_atoms :: (JustApply atom, term ~ TermOf atom, v ~ TVarOf term) =>
               (atom, atom) -> StateT (Map v term) Failing ()
unify_atoms (a1, a2) =
    maybe (fail "unify_atoms") id (zipPredicates (\_ tpairs -> Just (unify_terms tpairs)) a1 a2)

unify_atoms_eq :: (HasApplyAndEquate atom, term ~ TermOf atom, v ~ TVarOf term) =>
                  atom -> atom -> StateT (Map v term) Failing ()
unify_atoms_eq a1 a2 =
    maybe (fail "unify_atoms") id (zipPredicatesEq (\l1 r1 l2 r2 -> Just (unify_terms [(l1, l2), (r1, r2)]))
                                                   (\_ tpairs -> Just (unify_terms tpairs))
                                                   a1 a2)

-- | Unify complementary literals.
unify_complements :: (IsLiteral lit, HasApply atom, Unify atom v term,
                      atom ~ AtomOf lit, term ~ TermOf atom, v ~ VarOf lit, v ~ TVarOf term) =>
                     lit -> lit -> StateT (Map v term) Failing ()
unify_complements p q = unify_literals p ((.~.) q)

-- | Unify and refute a set of disjuncts.
unify_refute :: (IsLiteral lit, Ord lit, HasApply atom, Unify atom v term, IsTerm term,
                 atom ~ AtomOf lit, term ~ TermOf atom, v ~ VarOf lit, v ~ TVarOf term) =>
                Set (Set lit) -> Map v term -> Failing (Map v term)
unify_refute djs env =
    case Set.minView djs of
      Nothing -> Success env
      Just (d, odjs) ->
          settryfind (\ (p, n) -> execStateT (unify_complements p n) env >>= unify_refute odjs) pairs
          where
            pairs = allpairs (,) pos neg
            (pos,neg) = Set.partition positive d

-- | Hence a Prawitz-like procedure (using unification on DNF).
prawitz_loop :: (IsLiteral lit, Ord lit, HasApply atom, Unify atom v term, IsTerm term,
                 atom ~ AtomOf lit, term ~ TermOf atom, v ~ VarOf lit, v ~ TVarOf term) =>
                Set (Set lit) -> [VarOf lit] -> Set (Set lit) -> Int -> (Map v term, Int)
prawitz_loop djs0 fvs djs n =
    let inst = Map.fromList (zip fvs (List.map newvar [1..])) in
    let djs1 = distrib (Set.map (Set.map (onatoms (atomic . asubst inst))) djs0) djs in
    case unify_refute djs1 Map.empty of
      Failure _ -> prawitz_loop djs0 fvs djs1 (n + 1)
      Success env -> (env, n + 1)
    where
      newvar k = vt (fromString ("_" ++ show (n * length fvs + k)))

prawitz :: forall formula atom term function v.
           (IsFirstOrder formula, Ord formula, Unify atom v term, HasSkolem function v,
            atom ~ AtomOf formula, v ~ VarOf formula, v ~ TVarOf term, term ~ TermOf atom, function ~ FunOf term) =>
           formula -> Int
prawitz fm =
    snd (prawitz_loop dnf (Set.toList fvs) dnf0 0)
    where
      dnf0 = Set.singleton Set.empty
      dnf = simpdnf id pf :: Set (Set (Marked Literal formula))
      fvs = overatoms (\ a s -> Set.union (fv (atomic a :: formula)) s) pf (Set.empty :: Set v)
      pf = runSkolem (skolemize id ((.~.)(generalize fm))) :: Marked Propositional formula

#ifndef NOTESTS
-- -------------------------------------------------------------------------
-- Examples.
-- -------------------------------------------------------------------------

instance Unify MyAtom V MyTerm where
    unify = unify_atoms_eq

p20 :: Test
p20 = TestCase $ assertEqual "p20 - prawitz (p. 175)" expected input
    where fm :: MyFormula
          fm = (for_all "x" (for_all "y" (exists "z" (for_all "w" (pApp "P" [vt "x"] .&. pApp "Q" [vt "y"] .=>.
                                                                   pApp "R" [vt "z"] .&. pApp "U" [vt "w"]))))) .=>.
               (exists "x" (exists "y" (pApp "P" [vt "x"] .&. pApp "Q" [vt "y"]))) .=>. (exists "z" (pApp "R" [vt "z"]))
          input = prawitz fm
          expected = 2
#endif

-- -------------------------------------------------------------------------
-- Comparison of number of ground instances.
-- -------------------------------------------------------------------------

#ifndef NOTESTS
compare :: (atom ~ AtomOf formula, term ~ TermOf atom, v ~ VarOf formula, v ~ TVarOf term, function ~ FunOf term,
            IsFirstOrder formula, Ord formula,
            Unify atom v term,
            HasSkolem function v
           ) => formula -> (Int, Failing Int)
compare fm = (prawitz fm, davisputnam fm)

p19 :: Test
p19 = TestCase $ assertEqual "p19" expected input
    where
      fm :: MyFormula
      fm = exists "x" (for_all "y" (for_all "z" ((pApp "P" [vt "y"] .=>. pApp "Q" [vt "z"]) .=>. pApp "P" [vt "x"] .=>. pApp "Q" [vt "x"])))
      input = compare fm
      expected = (3, Success 3)

{-
START_INTERACTIVE;;
let p20 = compare
 <<(for_all x y. exists z. for_all w. P[vt "x"] .&. Q[vt "y"] .=>. R[vt "z"] .&. U[vt "w"])
   .=>. (exists x y. P[vt "x"] .&. Q[vt "y"]) .=>. (exists z. R[vt "z"])>>;;

let p24 = compare
 <<~(exists x. U[vt "x"] .&. Q[vt "x"]) .&.
   (for_all x. P[vt "x"] .=>. Q[vt "x"] .|. R[vt "x"]) .&.
   ~(exists x. P[vt "x"] .=>. (exists x. Q[vt "x"])) .&.
   (for_all x. Q[vt "x"] .&. R[vt "x"] .=>. U[vt "x"])
   .=>. (exists x. P[vt "x"] .&. R[vt "x"])>>;;

let p39 = compare
 <<~(exists x. for_all y. P(y,x) .<=>. ~P(y,y))>>;;

let p42 = compare
 <<~(exists y. for_all x. P(x,y) .<=>. ~(exists z. P(x,z) .&. P(z,x)))>>;;

{- **** Too slow?

let p43 = compare
 <<(for_all x y. Q(x,y) .<=>. for_all z. P(z,x) .<=>. P(z,y))
   .=>. for_all x y. Q(x,y) .<=>. Q(y,x)>>;;

 ***** -}

let p44 = compare
 <<(for_all x. P[vt "x"] .=>. (exists y. G[vt "y"] .&. H(x,y)) .&.
   (exists y. G[vt "y"] .&. ~H(x,y))) .&.
   (exists x. J[vt "x"] .&. (for_all y. G[vt "y"] .=>. H(x,y)))
   .=>. (exists x. J[vt "x"] .&. ~P[vt "x"])>>;;

let p59 = compare
 <<(for_all x. P[vt "x"] .<=>. ~P(f[vt "x"])) .=>. (exists x. P[vt "x"] .&. ~P(f[vt "x"]))>>;;

let p60 = compare
 <<for_all x. P(x,f[vt "x"]) .<=>.
             exists y. (for_all z. P(z,y) .=>. P(z,f[vt "x"])) .&. P(x,y)>>;;

END_INTERACTIVE;;
-}
#endif

-- | Try f with higher and higher values of n until it succeeds, or
-- optional maximum depth limit is exceeded.
{-
let rec deepen f n =
  try print_string "Searching with depth limit ";
      print_int n; print_newline(); f n
  with Failure _ -> deepen f (n + 1);;
-}
deepen :: (Depth -> Failing t) -> Depth -> Maybe Depth -> Failing (t, Depth)
deepen _ n (Just m) | n > m = Failure ["Exceeded maximum depth limit"]
deepen f n m =
    -- If no maximum depth limit is given print a trace of the
    -- levels tried.  The assumption is that we are running
    -- interactively.
    let n' = maybe (trace ("Searching with depth limit " ++ show n) n) (\_ -> n) m in
    case f n' of
      Failure _ -> deepen f (succ n) m
      Success x -> Success (x, n)

newtype Depth = Depth Int deriving (Eq, Ord, Show)

instance Enum Depth where
    toEnum = Depth
    fromEnum (Depth n) = n

instance Pretty Depth where
    pPrint = text . show

newtype K = K Int deriving (Eq, Ord, Show)

instance Enum K where
    toEnum = K
    fromEnum (K n) = n

instance Pretty K where
    pPrint (K n) = text ("K" ++ show n)

-- | More standard tableau procedure, effectively doing DNF incrementally.  (p. 177)
#if 1
tableau :: forall formula atom term v function.
           (atom ~ AtomOf formula, v ~ VarOf formula, v ~ TVarOf term, term ~ TermOf atom, function ~ FunOf term,
            IsFirstOrder formula,
            Unify atom v term) =>
           [formula] -> Depth -> RWS () () () (Failing (K, Map v term))
tableau fms n0 =
    go (fms, [], n0) (return . Success) (K 0, Map.empty)
    where
      go :: ([formula], [formula], Depth)
         -> ((K, Map v term) -> RWS () () () (Failing (K, Map v term)))
         -> (K, Map v term)
         -> RWS () () () (Failing (K, Map v term))
      go (_, _, n) _ (_, _) | n < Depth 0 = return $ Failure ["no proof at this level"]
      go ([], _, _) _ (_, _) =  return $ Failure ["tableau: no proof"]
      go (fm : unexp, lits, n) cont (k, env) =
          foldQuantified qu co (\_ -> go2 fm unexp) (\_ -> go2 fm unexp) (\_ -> go2 fm unexp) fm
          where
            qu :: Quant -> v -> formula -> RWS () () () (Failing (K, Map v term))
            qu (:!:) x p =
                let y = vt (fromString (prettyShow k))
                    p' = subst (x |=> y) p in
                go ([p'] ++ unexp ++ [for_all x p],lits,pred n) cont (succ k, env)
            qu _ _ _ = go2 fm unexp
            co p (:&:) q =
                go (p : q : unexp,lits,n) cont (k, env)
            co p (:|:) q =
                go (p : unexp,lits,n) (go (q : unexp,lits,n) cont) (k, env)
            co _ _ _ = go2 fm unexp

            go2 :: formula -> [formula] -> RWS () () () (Failing (K, Map v term))
            go2 fm' unexp' =
                tryfindM (tryLit fm') lits >>=
                failing (\_ -> go (unexp', fm' : lits, n) cont (k, env))
                        (return . Success)
            tryLit :: formula -> formula -> RWS () () () (Failing (K, Map v term))
            tryLit fm' l = failing (return . Failure) (\env' -> cont (k, env')) (execStateT (unify_complements fm' l) env)
#else
tableau :: forall formula atom term v function.
           (atom ~ AtomOf formula, v ~ VarOf formula, v ~ TVarOf term, term ~ TermOf atom, function ~ FunOf term,
            IsFirstOrder formula,
            Unify atom v term) =>
           [formula] -> Depth -> Failing (K, Map v term)
tableau fms n0 =
    go (fms, [], n0) Success (K 0, Map.empty)
    where
      go :: ([formula], [formula], Depth)
         -> ((K, Map v term) -> Failing (K, Map v term))
         -> (K, Map v term)
         -> Failing (K, Map v term)
      go (_, _, n) _ (_, _) | n < Depth 0 = Failure ["no proof at this level"]
      go ([], _, _) _ (_, _) =  Failure ["tableau: no proof"]
      go (fm : unexp, lits, n) cont (k, env) =
          foldQuantified qu co (\_ -> go2 fm unexp) (\_ -> go2 fm unexp) (\_ -> go2 fm unexp) fm
          where
            qu :: Quant -> v -> formula -> Failing (K, Map v term)
            qu (:!:) x p =
                let y = vt (fromString (prettyShow k))
                    p' = subst (x |=> y) p in
                go ([p'] ++ unexp ++ [for_all x p],lits,pred n) cont (succ k, env)
            qu _ _ _ = go2 fm unexp
            co p (:&:) q =
                go (p : q : unexp,lits,n) cont (k, env)
            co p (:|:) q =
                go (p : unexp,lits,n) (go (q : unexp,lits,n) cont) (k, env)
            co _ _ _ = go2 fm unexp

            go2 :: formula -> [formula] -> Failing (K, Map v term)
            go2 fm' unexp =
                case tryfind (tryLit fm') lits of
                  Failure _ -> go (unexp, fm' : lits, n) cont (k, env)
                  Success x -> Success x
            tryLit :: formula -> formula -> Failing (K, Map v term)
            tryLit fm' l = failing Failure (\env' -> cont (k, env')) (execStateT (unify_complements fm' l) env)
#endif

tabrefute :: (atom ~ AtomOf formula, v ~ VarOf formula, v ~ TVarOf term, term ~ TermOf atom, function ~ FunOf term,
              IsFirstOrder formula,
              Unify atom v term) =>
             Maybe Depth -> [formula] -> Failing ((K, Map v term), Depth)
tabrefute limit fms =
#if 1
    let r = deepen (\n -> (,n) <$> evalRS (tableau fms n) () ()) (Depth 0) limit in
#else
    let r = deepen (\n -> (,n) <$> tableau fms n) (Depth 0) limit in
#endif
    failing Failure (Success . fst) r

tab :: (atom ~ AtomOf formula, term ~ TermOf atom, v ~ VarOf formula, v ~ TVarOf term, function ~ FunOf term,
        IsFirstOrder formula, Unify atom v term, Pretty formula, HasSkolem function v) =>
       Maybe Depth -> formula -> Failing ((K, Map v term), Depth)
tab limit fm =
  let sfm = runSkolem (askolemize((.~.)(generalize fm))) in
  if asBool sfm == Just False then (error "Tableaux.tab") else tabrefute limit [sfm]

#ifndef NOTESTS
p38 :: Test
p38 =
    let [p, r] = [pApp "P", pApp "R"] :: [[MyTerm] -> MyFormula]
        [a, w, x, y, z] = [vt "a", vt "w", vt "x", vt "y", vt "z"] :: [MyTerm]
        fm = (for_all "x"
               (p[a] .&. (p[x] .=>. (exists "y" (p[y] .&. r[x,y]))) .=>.
                (exists "z" (exists "w" (p[z] .&. r[x,w] .&. r[w,z]))))) .<=>.
             (for_all "x"
              (((.~.)(p[a]) .|. p[x] .|. (exists "z" (exists "w" (p[z] .&. r[x,w] .&. r[w,z])))) .&.
               ((.~.)(p[a]) .|. (.~.)(exists "y" (p[y] .&. r[x,y])) .|.
               (exists "z" (exists "w" (p[z] .&. r[x,w] .&. r[w,z]))))))
        expected = Success ((K 19, Map.fromList
                                      [("K0",fApp (toSkolem "x")[]),
                                       ("K1",fApp (toSkolem "y")[]),
                                       ("K10",fApp (toSkolem "x")[]),
                                       ("K11",fApp (toSkolem "z")["K13"]),
                                       ("K12",fApp (toSkolem "w")["K15"]),
                                       ("K13",fApp (toSkolem "x")[]),
                                       ("K14",fApp (toSkolem "y")[]),
                                       ("K15",fApp (toSkolem "x")[]),
                                       ("K16",fApp (toSkolem "y")[]),
                                       ("K17",fApp (toSkolem "x")[]),
                                       ("K18",fApp (toSkolem "y")[]),
                                       ("K2",fApp (toSkolem "z")["K0"]),
                                       ("K3",fApp (toSkolem "w")["K0"]),
                                       ("K4",fApp (toSkolem "z")["K0"]),
                                       ("K5",fApp (toSkolem "w")["K0"]),
                                       ("K6",fApp (toSkolem "z")["K8"]),
                                       ("K7",fApp (toSkolem "w")["K9"]),
                                       ("K8",fApp (toSkolem "x")[]),
                                       ("K9",fApp (toSkolem "x")[])]),
                            Depth 4) in
    TestCase $ assertEqual' "p38, p. 178" expected (tab Nothing fm)
{-
-- -------------------------------------------------------------------------
-- Example.
-- -------------------------------------------------------------------------

START_INTERACTIVE;;
let p38 = tab
 <<(for_all x.
     P[vt "a"] .&. (P[vt "x"] .=>. (exists y. P[vt "y"] .&. R(x,y))) .=>.
     (exists z w. P[vt "z"] .&. R(x,w) .&. R(w,z))) .<=>.
   (for_all x.
     (~P[vt "a"] .|. P[vt "x"] .|. (exists z w. P[vt "z"] .&. R(x,w) .&. R(w,z))) .&.
     (~P[vt "a"] .|. ~(exists y. P[vt "y"] .&. R(x,y)) .|.
     (exists z w. P[vt "z"] .&. R(x,w) .&. R(w,z))))>>;;
END_INTERACTIVE;;
-}
#endif
-- -------------------------------------------------------------------------
-- Try to split up the initial formula first; often a big improvement.
-- -------------------------------------------------------------------------
splittab :: forall formula atom term v function.
            (atom ~ AtomOf formula, term ~ TermOf atom, v ~ VarOf formula, v ~ TVarOf term, function ~ FunOf term,
             IsFirstOrder formula, Unify atom v term,
             Ord formula, Pretty formula, HasSkolem function v
            ) => formula -> [Failing ((K, Map v term), Depth)]
splittab fm =
    (List.map (tabrefute Nothing) . ssll . simpdnf' . runSkolem . skolemize id . (.~.) . generalize) fm
    where ssll :: Set (Set (Marked Literal (Marked Propositional formula))) -> [[formula]]
          ssll = List.map Set.toList . Set.toList . Set.map (Set.map (unmarkPropositional . unmarkLiteral))
          simpdnf' :: Marked Propositional formula -> Set (Set (Marked Literal (Marked Propositional formula)))
          simpdnf' = simpdnf id

#ifndef NOTESTS
{-
-- -------------------------------------------------------------------------
-- Example: the Andrews challenge.
-- -------------------------------------------------------------------------

START_INTERACTIVE;;
let p34 = splittab
 <<((exists x. for_all y. P[vt "x"] .<=>. P[vt "y"]) .<=>.
    ((exists x. Q[vt "x"]) .<=>. (for_all y. Q[vt "y"]))) .<=>.
   ((exists x. for_all y. Q[vt "x"] .<=>. Q[vt "y"]) .<=>.
    ((exists x. P[vt "x"]) .<=>. (for_all y. P[vt "y"])))>>;;

-- -------------------------------------------------------------------------
-- Another nice example from EWD 1602.
-- -------------------------------------------------------------------------

let ewd1062 = splittab
 <<(for_all x. x <= x) .&.
   (for_all x y z. x <= y .&. y <= z .=>. x <= z) .&.
   (for_all x y. f[vt "x"] <= y .<=>. x <= g[vt "y"])
   .=>. (for_all x y. x <= y .=>. f[vt "x"] <= f[vt "y"]) .&.
       (for_all x y. x <= y .=>. g[vt "x"] <= g[vt "y"])>>;;
END_INTERACTIVE;;

-- -------------------------------------------------------------------------
-- Do all the equality-free Pelletier problems, and more, as examples.
-- -------------------------------------------------------------------------

{- **********

let p1 = time splittab
 <<p .=>. q .<=>. ~q .=>. ~p>>;;

let p2 = time splittab
 <<~ ~p .<=>. p>>;;

let p3 = time splittab
 <<~(p .=>. q) .=>. q .=>. p>>;;

let p4 = time splittab
 <<~p .=>. q .<=>. ~q .=>. p>>;;

let p5 = time splittab
 <<(p .|. q .=>. p .|. r) .=>. p .|. (q .=>. r)>>;;

let p6 = time splittab
 <<p .|. ~p>>;;

let p7 = time splittab
 <<p .|. ~ ~ ~p>>;;

let p8 = time splittab
 <<((p .=>. q) .=>. p) .=>. p>>;;

let p9 = time splittab
 <<(p .|. q) .&. (~p .|. q) .&. (p .|. ~q) .=>. ~(~q .|. ~q)>>;;

let p10 = time splittab
 <<(q .=>. r) .&. (r .=>. p .&. q) .&. (p .=>. q .&. r) .=>. (p .<=>. q)>>;;

let p11 = time splittab
 <<p .<=>. p>>;;

let p12 = time splittab
 <<((p .<=>. q) .<=>. r) .<=>. (p .<=>. (q .<=>. r))>>;;

let p13 = time splittab
 <<p .|. q .&. r .<=>. (p .|. q) .&. (p .|. r)>>;;

let p14 = time splittab
 <<(p .<=>. q) .<=>. (q .|. ~p) .&. (~q .|. p)>>;;

let p15 = time splittab
 <<p .=>. q .<=>. ~p .|. q>>;;

let p16 = time splittab
 <<(p .=>. q) .|. (q .=>. p)>>;;

let p17 = time splittab
 <<p .&. (q .=>. r) .=>. s .<=>. (~p .|. q .|. s) .&. (~p .|. ~r .|. s)>>;;

-- -------------------------------------------------------------------------
-- Pelletier problems: monadic predicate logic.
-- -------------------------------------------------------------------------

let p18 = time splittab
 <<exists y. for_all x. P[vt "y"] .=>. P[vt "x"]>>;;

let p19 = time splittab
 <<exists x. for_all y z. (P[vt "y"] .=>. Q[vt "z"]) .=>. P[vt "x"] .=>. Q[vt "x"]>>;;

let p20 = time splittab
 <<(for_all x y. exists z. for_all w. P[vt "x"] .&. Q[vt "y"] .=>. R[vt "z"] .&. U[vt "w"])
   .=>. (exists x y. P[vt "x"] .&. Q[vt "y"]) .=>. (exists z. R[vt "z"])>>;;

let p21 = time splittab
 <<(exists x. P .=>. Q[vt "x"]) .&. (exists x. Q[vt "x"] .=>. P)
   .=>. (exists x. P .<=>. Q[vt "x"])>>;;

let p22 = time splittab
 <<(for_all x. P .<=>. Q[vt "x"]) .=>. (P .<=>. (for_all x. Q[vt "x"]))>>;;

let p23 = time splittab
 <<(for_all x. P .|. Q[vt "x"]) .<=>. P .|. (for_all x. Q[vt "x"])>>;;

let p24 = time splittab
 <<~(exists x. U[vt "x"] .&. Q[vt "x"]) .&.
   (for_all x. P[vt "x"] .=>. Q[vt "x"] .|. R[vt "x"]) .&.
   ~(exists x. P[vt "x"] .=>. (exists x. Q[vt "x"])) .&.
   (for_all x. Q[vt "x"] .&. R[vt "x"] .=>. U[vt "x"]) .=>.
   (exists x. P[vt "x"] .&. R[vt "x"])>>;;

let p25 = time splittab
 <<(exists x. P[vt "x"]) .&.
   (for_all x. U[vt "x"] .=>. ~G[vt "x"] .&. R[vt "x"]) .&.
   (for_all x. P[vt "x"] .=>. G[vt "x"] .&. U[vt "x"]) .&.
   ((for_all x. P[vt "x"] .=>. Q[vt "x"]) .|. (exists x. Q[vt "x"] .&. P[vt "x"]))
   .=>. (exists x. Q[vt "x"] .&. P[vt "x"])>>;;

let p26 = time splittab
 <<((exists x. P[vt "x"]) .<=>. (exists x. Q[vt "x"])) .&.
   (for_all x y. P[vt "x"] .&. Q[vt "y"] .=>. (R[vt "x"] .<=>. U[vt "y"]))
   .=>. ((for_all x. P[vt "x"] .=>. R[vt "x"]) .<=>. (for_all x. Q[vt "x"] .=>. U[vt "x"]))>>;;

let p27 = time splittab
 <<(exists x. P[vt "x"] .&. ~Q[vt "x"]) .&.
   (for_all x. P[vt "x"] .=>. R[vt "x"]) .&.
   (for_all x. U[vt "x"] .&. V[vt "x"] .=>. P[vt "x"]) .&.
   (exists x. R[vt "x"] .&. ~Q[vt "x"])
   .=>. (for_all x. U[vt "x"] .=>. ~R[vt "x"])
       .=>. (for_all x. U[vt "x"] .=>. ~V[vt "x"])>>;;

let p28 = time splittab
 <<(for_all x. P[vt "x"] .=>. (for_all x. Q[vt "x"])) .&.
   ((for_all x. Q[vt "x"] .|. R[vt "x"]) .=>. (exists x. Q[vt "x"] .&. R[vt "x"])) .&.
   ((exists x. R[vt "x"]) .=>. (for_all x. L[vt "x"] .=>. M[vt "x"])) .=>.
   (for_all x. P[vt "x"] .&. L[vt "x"] .=>. M[vt "x"])>>;;

let p29 = time splittab
 <<(exists x. P[vt "x"]) .&. (exists x. G[vt "x"]) .=>.
   ((for_all x. P[vt "x"] .=>. H[vt "x"]) .&. (for_all x. G[vt "x"] .=>. J[vt "x"]) .<=>.
    (for_all x y. P[vt "x"] .&. G[vt "y"] .=>. H[vt "x"] .&. J[vt "y"]))>>;;

let p30 = time splittab
 <<(for_all x. P[vt "x"] .|. G[vt "x"] .=>. ~H[vt "x"]) .&.
   (for_all x. (G[vt "x"] .=>. ~U[vt "x"]) .=>. P[vt "x"] .&. H[vt "x"])
   .=>. (for_all x. U[vt "x"])>>;;

let p31 = time splittab
 <<~(exists x. P[vt "x"] .&. (G[vt "x"] .|. H[vt "x"])) .&.
   (exists x. Q[vt "x"] .&. P[vt "x"]) .&.
   (for_all x. ~H[vt "x"] .=>. J[vt "x"])
   .=>. (exists x. Q[vt "x"] .&. J[vt "x"])>>;;

let p32 = time splittab
 <<(for_all x. P[vt "x"] .&. (G[vt "x"] .|. H[vt "x"]) .=>. Q[vt "x"]) .&.
   (for_all x. Q[vt "x"] .&. H[vt "x"] .=>. J[vt "x"]) .&.
   (for_all x. R[vt "x"] .=>. H[vt "x"])
   .=>. (for_all x. P[vt "x"] .&. R[vt "x"] .=>. J[vt "x"])>>;;

let p33 = time splittab
 <<(for_all x. P[vt "a"] .&. (P[vt "x"] .=>. P[vt "b"]) .=>. P[vt "c"]) .<=>.
   (for_all x. P[vt "a"] .=>. P[vt "x"] .|. P[vt "c"]) .&. (P[vt "a"] .=>. P[vt "b"] .=>. P[vt "c"])>>;;

let p34 = time splittab
 <<((exists x. for_all y. P[vt "x"] .<=>. P[vt "y"]) .<=>.
    ((exists x. Q[vt "x"]) .<=>. (for_all y. Q[vt "y"]))) .<=>.
   ((exists x. for_all y. Q[vt "x"] .<=>. Q[vt "y"]) .<=>.
    ((exists x. P[vt "x"]) .<=>. (for_all y. P[vt "y"])))>>;;

let p35 = time splittab
 <<exists x y. P(x,y) .=>. (for_all x y. P(x,y))>>;;

-- -------------------------------------------------------------------------
-- Full predicate logic (without identity and functions).
-- -------------------------------------------------------------------------

let p36 = time splittab
 <<(for_all x. exists y. P(x,y)) .&.
   (for_all x. exists y. G(x,y)) .&.
   (for_all x y. P(x,y) .|. G(x,y)
   .=>. (for_all z. P(y,z) .|. G(y,z) .=>. H(x,z)))
       .=>. (for_all x. exists y. H(x,y))>>;;

let p37 = time splittab
 <<(for_all z.
     exists w. for_all x. exists y. (P(x,z) .=>. P(y,w)) .&. P(y,z) .&.
     (P(y,w) .=>. (exists u. Q(u,w)))) .&.
   (for_all x z. ~P(x,z) .=>. (exists y. Q(y,z))) .&.
   ((exists x y. Q(x,y)) .=>. (for_all x. R(x,x))) .=>.
   (for_all x. exists y. R(x,y))>>;;

let p38 = time splittab
 <<(for_all x.
     P[vt "a"] .&. (P[vt "x"] .=>. (exists y. P[vt "y"] .&. R(x,y))) .=>.
     (exists z w. P[vt "z"] .&. R(x,w) .&. R(w,z))) .<=>.
   (for_all x.
     (~P[vt "a"] .|. P[vt "x"] .|. (exists z w. P[vt "z"] .&. R(x,w) .&. R(w,z))) .&.
     (~P[vt "a"] .|. ~(exists y. P[vt "y"] .&. R(x,y)) .|.
     (exists z w. P[vt "z"] .&. R(x,w) .&. R(w,z))))>>;;

let p39 = time splittab
 <<~(exists x. for_all y. P(y,x) .<=>. ~P(y,y))>>;;

let p40 = time splittab
 <<(exists y. for_all x. P(x,y) .<=>. P(x,x))
  .=>. ~(for_all x. exists y. for_all z. P(z,y) .<=>. ~P(z,x))>>;;

let p41 = time splittab
 <<(for_all z. exists y. for_all x. P(x,y) .<=>. P(x,z) .&. ~P(x,x))
  .=>. ~(exists z. for_all x. P(x,z))>>;;

let p42 = time splittab
 <<~(exists y. for_all x. P(x,y) .<=>. ~(exists z. P(x,z) .&. P(z,x)))>>;;

let p43 = time splittab
 <<(for_all x y. Q(x,y) .<=>. for_all z. P(z,x) .<=>. P(z,y))
   .=>. for_all x y. Q(x,y) .<=>. Q(y,x)>>;;

let p44 = time splittab
 <<(for_all x. P[vt "x"] .=>. (exists y. G[vt "y"] .&. H(x,y)) .&.
   (exists y. G[vt "y"] .&. ~H(x,y))) .&.
   (exists x. J[vt "x"] .&. (for_all y. G[vt "y"] .=>. H(x,y))) .=>.
   (exists x. J[vt "x"] .&. ~P[vt "x"])>>;;

let p45 = time splittab
 <<(for_all x.
     P[vt "x"] .&. (for_all y. G[vt "y"] .&. H(x,y) .=>. J(x,y)) .=>.
       (for_all y. G[vt "y"] .&. H(x,y) .=>. R[vt "y"])) .&.
   ~(exists y. L[vt "y"] .&. R[vt "y"]) .&.
   (exists x. P[vt "x"] .&. (for_all y. H(x,y) .=>.
     L[vt "y"]) .&. (for_all y. G[vt "y"] .&. H(x,y) .=>. J(x,y))) .=>.
   (exists x. P[vt "x"] .&. ~(exists y. G[vt "y"] .&. H(x,y)))>>;;

let p46 = time splittab
 <<(for_all x. P[vt "x"] .&. (for_all y. P[vt "y"] .&. H(y,x) .=>. G[vt "y"]) .=>. G[vt "x"]) .&.
   ((exists x. P[vt "x"] .&. ~G[vt "x"]) .=>.
    (exists x. P[vt "x"] .&. ~G[vt "x"] .&.
               (for_all y. P[vt "y"] .&. ~G[vt "y"] .=>. J(x,y)))) .&.
   (for_all x y. P[vt "x"] .&. P[vt "y"] .&. H(x,y) .=>. ~J(y,x)) .=>.
   (for_all x. P[vt "x"] .=>. G[vt "x"])>>;;

-- -------------------------------------------------------------------------
-- Well-known "Agatha" example; cf. Manthey and Bry, CADE-9.
-- -------------------------------------------------------------------------

let p55 = time splittab
 <<lives(agatha) .&. lives(butler) .&. lives(charles) .&.
   (killed(agatha,agatha) .|. killed(butler,agatha) .|.
    killed(charles,agatha)) .&.
   (for_all x y. killed(x,y) .=>. hates(x,y) .&. ~richer(x,y)) .&.
   (for_all x. hates(agatha,x) .=>. ~hates(charles,x)) .&.
   (hates(agatha,agatha) .&. hates(agatha,charles)) .&.
   (for_all x. lives[vt "x"] .&. ~richer(x,agatha) .=>. hates(butler,x)) .&.
   (for_all x. hates(agatha,x) .=>. hates(butler,x)) .&.
   (for_all x. ~hates(x,agatha) .|. ~hates(x,butler) .|. ~hates(x,charles))
   .=>. killed(agatha,agatha) .&.
       ~killed(butler,agatha) .&.
       ~killed(charles,agatha)>>;;

let p57 = time splittab
 <<P(f([vt "a"],b),f(b,c)) .&.
   P(f(b,c),f(a,c)) .&.
   (for_all [vt "x"] y z. P(x,y) .&. P(y,z) .=>. P(x,z))
   .=>. P(f(a,b),f(a,c))>>;;

-- -------------------------------------------------------------------------
-- See info-hol, circa 1500.
-- -------------------------------------------------------------------------

let p58 = time splittab
 <<for_all P Q R. for_all x. exists v. exists w. for_all y. for_all z.
    ((P[vt "x"] .&. Q[vt "y"]) .=>. ((P[vt "v"] .|. R[vt "w"])  .&. (R[vt "z"] .=>. Q[vt "v"])))>>;;

let p59 = time splittab
 <<(for_all x. P[vt "x"] .<=>. ~P(f[vt "x"])) .=>. (exists x. P[vt "x"] .&. ~P(f[vt "x"]))>>;;

let p60 = time splittab
 <<for_all x. P(x,f[vt "x"]) .<=>.
            exists y. (for_all z. P(z,y) .=>. P(z,f[vt "x"])) .&. P(x,y)>>;;

-- -------------------------------------------------------------------------
-- From Gilmore's classic paper.
-- -------------------------------------------------------------------------

{- **** This is still too hard for us! Amazing...

let gilmore_1 = time splittab
 <<exists x. for_all y z.
      ((F[vt "y"] .=>. G[vt "y"]) .<=>. F[vt "x"]) .&.
      ((F[vt "y"] .=>. H[vt "y"]) .<=>. G[vt "x"]) .&.
      (((F[vt "y"] .=>. G[vt "y"]) .=>. H[vt "y"]) .<=>. H[vt "x"])
      .=>. F[vt "z"] .&. G[vt "z"] .&. H[vt "z"]>>;;

 ***** -}

{- ** This is not valid, according to Gilmore

let gilmore_2 = time splittab
 <<exists x y. for_all z.
        (F(x,z) .<=>. F(z,y)) .&. (F(z,y) .<=>. F(z,z)) .&. (F(x,y) .<=>. F(y,x))
        .=>. (F(x,y) .<=>. F(x,z))>>;;

 ** -}

let gilmore_3 = time splittab
 <<exists x. for_all y z.
        ((F(y,z) .=>. (G[vt "y"] .=>. H[vt "x"])) .=>. F(x,x)) .&.
        ((F(z,x) .=>. G[vt "x"]) .=>. H[vt "z"]) .&.
        F(x,y)
        .=>. F(z,z)>>;;

let gilmore_4 = time splittab
 <<exists x y. for_all z.
        (F(x,y) .=>. F(y,z) .&. F(z,z)) .&.
        (F(x,y) .&. G(x,y) .=>. G(x,z) .&. G(z,z))>>;;

let gilmore_5 = time splittab
 <<(for_all x. exists y. F(x,y) .|. F(y,x)) .&.
   (for_all x y. F(y,x) .=>. F(y,y))
   .=>. exists z. F(z,z)>>;;

let gilmore_6 = time splittab
 <<for_all x. exists y.
        (exists u. for_all v. F(u,x) .=>. G(v,u) .&. G(u,x))
        .=>. (exists u. for_all v. F(u,y) .=>. G(v,u) .&. G(u,y)) .|.
            (for_all u v. exists w. G(v,u) .|. H(w,y,u) .=>. G(u,w))>>;;

let gilmore_7 = time splittab
 <<(for_all x. K[vt "x"] .=>. exists y. L[vt "y"] .&. (F(x,y) .=>. G(x,y))) .&.
   (exists z. K[vt "z"] .&. for_all u. L[vt "u"] .=>. F(z,u))
   .=>. exists v w. K[vt "v"] .&. L[vt "w"] .&. G(v,w)>>;;

let gilmore_8 = time splittab
 <<exists x. for_all y z.
        ((F(y,z) .=>. (G[vt "y"] .=>. (for_all u. exists v. H(u,v,x)))) .=>. F(x,x)) .&.
        ((F(z,x) .=>. G[vt "x"]) .=>. (for_all u. exists v. H(u,v,z))) .&.
        F(x,y)
        .=>. F(z,z)>>;;

let gilmore_9 = time splittab
 <<for_all x. exists y. for_all z.
        ((for_all u. exists v. F(y,u,v) .&. G(y,u) .&. ~H(y,x))
          .=>. (for_all u. exists v. F(x,u,v) .&. G(z,u) .&. ~H(x,z))
          .=>. (for_all u. exists v. F(x,u,v) .&. G(y,u) .&. ~H(x,y))) .&.
        ((for_all u. exists v. F(x,u,v) .&. G(y,u) .&. ~H(x,y))
         .=>. ~(for_all u. exists v. F(x,u,v) .&. G(z,u) .&. ~H(x,z))
         .=>. (for_all u. exists v. F(y,u,v) .&. G(y,u) .&. ~H(y,x)) .&.
             (for_all u. exists v. F(z,u,v) .&. G(y,u) .&. ~H(z,y)))>>;;

-- -------------------------------------------------------------------------
-- Example from Davis-Putnam papers where Gilmore procedure is poor.
-- -------------------------------------------------------------------------

let davis_putnam_example = time splittab
 <<exists x. exists y. for_all z.
        (F(x,y) .=>. (F(y,z) .&. F(z,z))) .&.
        ((F(x,y) .&. G(x,y)) .=>. (G(x,z) .&. G(z,z)))>>;;

************ -}

-}

testTableaux :: Test
testTableaux = TestLabel "Tableaux" (TestList [p20, p19, p38])
#endif
