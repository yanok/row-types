-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Row.Variants
--
-- This module implements extensible variants using closed type families.
--
-----------------------------------------------------------------------------


module Data.Row.Variants
  (
  -- * Types and constraints
    Label(..)
  , KnownSymbol, AllUniqueLabels, WellBehaved
  , Var, Row, Empty, type (≈)
  -- * Construction
  , HasType, pattern IsJust, singleton
  , fromLabels
  -- ** Extension
  , type (.\), Lacks, type (.\/), diversify, type (.+)
  -- ** Modification
  , update, focus, Modify, rename, Rename
  -- * Destruction
  , impossible, trial, trial', multiTrial, view
  , restrict, split
  -- ** Types for destruction
  , type (.!), type (.-), type (.\\), type (.==)
  -- * Row operations
  -- ** Map
  , Map, map, map', transform, transform'
  -- ** Fold
  , Forall, erase, eraseWithLabels, eraseZip
  -- ** Sequence
  , sequence
  -- ** Compose
  -- $compose
  , compose, uncompose
  -- ** labels
  , labels
  -- ** UNSAFE operations
  , unsafeMakeVar, unsafeInjectFront
  )
where

import Prelude hiding (zip, map, sequence)

import Control.Applicative
import Control.Arrow ((<<<), (+++), left, right)
import Control.DeepSeq (NFData(..), deepseq)

import Data.Functor.Compose
import Data.Functor.Identity
import Data.Functor.Product
import Data.Maybe (fromMaybe)
import Data.Proxy
import Data.String (IsString)
import Data.Text (Text)

import GHC.TypeLits

import Unsafe.Coerce

import Data.Row.Internal

{--------------------------------------------------------------------
  Polymorphic Variants
--------------------------------------------------------------------}

-- | The variant type.
data Var (r :: Row *) where
  OneOf :: Text -> HideType -> Var r

instance Forall r Show => Show (Var r) where
  show v = (\ (x, y) -> "{" ++ x ++ "=" ++ y ++ "}") $ eraseWithLabels @Show show v

instance Forall r Eq => Eq (Var r) where
  r == r' = fromMaybe False $ eraseZip @Eq (==) r r'

instance (Forall r Eq, Forall r Ord) => Ord (Var r) where
  compare :: Var r -> Var r -> Ordering
  compare x y = getConst $ metamorph' @_ @r @Ord @(Product Var Var) @(Const Ordering) @(Const Ordering) Proxy doNil doUncons doCons (Pair x y)
    where doNil (Pair x _) = impossible x
          doUncons l (Pair r1 r2) = case (trial r1 l, trial r2 l) of
            (Left a,  Left b)  -> Left $ Const $ compare a b
            (Left _,  Right _) -> Left $ Const LT
            (Right _, Left _)  -> Left $ Const GT
            (Right x, Right y) -> Right $ Pair x y
          doCons _ (Left (Const c)) = Const c
          doCons _ (Right (Const c)) = Const c

instance Forall r NFData => NFData (Var r) where
  rnf r = getConst $ metamorph' @_ @r @NFData @Var @(Const ()) @Identity Proxy empty doUncons doCons r
    where empty = const $ Const ()
          doUncons l = left Identity . flip trial l
          doCons _ x = deepseq x $ Const ()


{--------------------------------------------------------------------
  Basic Operations
--------------------------------------------------------------------}

-- | An unsafe way to make a Variant.  This function does not guarantee that
-- the labels are all unique.
unsafeMakeVar :: forall r l. KnownSymbol l => Label l -> r .! l -> Var r
unsafeMakeVar (toKey -> l) = OneOf l . HideType

-- | A Variant with no options is uninhabited.
impossible :: Var Empty -> a
impossible _ = error "Impossible! Somehow, a variant of nothing was produced."

-- | A quick constructor to create a singleton variant.
singleton :: KnownSymbol l => Label l -> a -> Var (l .== a)
singleton = IsJust

-- | A pattern for variants; can be used to both destruct a variant
-- when in a pattern position or construct one in an expression position.
pattern IsJust :: forall l r. (AllUniqueLabels r, KnownSymbol l) => Label l -> r .! l -> Var r
pattern IsJust l a <- (unSingleton @l -> (l, Just a)) where
        IsJust l a = unsafeMakeVar l a

unSingleton :: forall l r. KnownSymbol l => Var r -> (Label l, Maybe (r .! l))
unSingleton v = (l, view l v) where l = Label @l

-- | Make the variant arbitrarily more diverse.
diversify :: forall r' r. Var r -> Var (r .\/ r')
diversify = unsafeCoerce -- (OneOf l x) = OneOf l x

-- | If the variant exists at the given label, update it to the given value.
-- Otherwise, do nothing.
update :: (KnownSymbol l, r .! l ≈ a) => Label l -> a -> Var r -> Var r
update (toKey -> l') a (OneOf l x) = OneOf l $ if l == l' then HideType a else x

-- | If the variant exists at the given label, focus on the value associated with it.
-- Otherwise, do nothing.
focus :: (Applicative f, KnownSymbol l) => Label l -> (r .! l -> f a) -> Var r -> f (Var (Modify l a r))
focus (toKey -> l') f (OneOf l (HideType x)) = if l == l' then (OneOf l . HideType) <$> f (unsafeCoerce x) else pure (OneOf l (HideType x))

-- | Rename the given label.
rename :: (KnownSymbol l, KnownSymbol l') => Label l -> Label l' -> Var r -> Var (Rename l l' r)
rename (toKey -> l1) (toKey -> l2) (OneOf l x) = OneOf (if l == l1 then l2 else l) x

-- | Convert a variant into either the value at the given label or a variant without
-- that label.  This is the basic variant destructor.
trial :: KnownSymbol l => Var r -> Label l -> Either (r .! l) (Var (r .- l))
trial (OneOf l (HideType x)) (toKey -> l') = if l == l' then Left (unsafeCoerce x) else Right (OneOf l (HideType x))

-- | A version of 'trial' that ignores the leftover variant.
trial' :: KnownSymbol l => Var r -> Label l -> Maybe (r .! l)
trial' = (either Just (const Nothing) .) . trial

-- | A trial over multiple types
multiTrial :: forall x y. (AllUniqueLabels x, Forall (y .\\ x) Unconstrained1) => Var y -> Either (Var x) (Var (y .\\ x))
multiTrial (OneOf l x) = if l `elem` labels @(y .\\ x) @Unconstrained1 then Right (OneOf l x) else Left (OneOf l x)

-- | A convenient function for using view patterns when dispatching variants.
--   For example:
--
-- @
-- myShow :: Var ("y" '::= String :| "x" '::= Int :| Empty) -> String
-- myShow (view x -> Just n) = "Int of "++show n
-- myShow (view y -> Just s) = "String of "++s @
view :: KnownSymbol l => Label l -> Var r -> Maybe (r .! l)
view = flip trial'

-- | Split a variant into two sub-variants.
split :: forall s r. (WellBehaved s, Subset s r) => Var r -> Either (Var s) (Var (r .\\ s))
split (OneOf l a) | l `elem` labels @s @Unconstrained1 = Left  $ OneOf l a
                  | otherwise                          = Right $ OneOf l a

-- | Arbitrary variant restriction.  Turn a variant into a subset of itself.
restrict :: forall r r'. (WellBehaved r, Subset r r') => Var r' -> Maybe (Var r)
restrict = either Just (pure Nothing) . split


{--------------------------------------------------------------------
  Folds and maps
--------------------------------------------------------------------}

-- | A standard fold
erase :: forall c ρ b. Forall ρ c => (forall a. c a => a -> b) -> Var ρ -> b
erase f = snd @String . eraseWithLabels @c f

-- | A fold with labels
eraseWithLabels :: forall c ρ s b. (Forall ρ c, IsString s) => (forall a. c a => a -> b) -> Var ρ -> (s,b)
eraseWithLabels f = getConst . metamorph' @_ @ρ @c @Var @(Const (s,b)) @Identity Proxy impossible doUncons doCons
  where doUncons l = left Identity . flip trial l
        doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
               => Label ℓ -> Either (Identity τ) (Const (s,b) ('R ρ)) -> Const (s,b) ('R (ℓ :-> τ ': ρ))
        doCons l (Left (Identity x)) = Const (show' l, f x)
        doCons _ (Right (Const c)) = Const c

-- | A fold over two row type structures at once
eraseZip :: forall c ρ b. Forall ρ c => (forall a. c a => a -> a -> b) -> Var ρ -> Var ρ -> Maybe b
eraseZip f x y = getConst $ metamorph' @_ @ρ @c @(Product Var Var) @(Const (Maybe b)) @(Const (Maybe b)) Proxy doNil doUncons doCons (Pair x y)
  where doNil _ = Const Nothing
        doUncons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
                 => Label ℓ -> Product Var Var ('R (ℓ :-> τ ': ρ)) -> Either (Const (Maybe b) τ) (Product Var Var ('R ρ))
        doUncons l (Pair r1 r2) = case (trial r1 l, trial r2 l) of
          (Left a,  Left b)  -> Left $ Const $ Just $ f a b
          (Right x, Right y) -> Right $ Pair x y
          _ -> Left $ Const Nothing
        doCons _ (Left  (Const c)) = Const c
        doCons _ (Right (Const c)) = Const c


-- | VMap is used internally as a type level lambda for defining variant maps.
newtype VMap (f :: * -> *) (ρ :: Row *) = VMap { unVMap :: Var (Map f ρ) }
newtype VMap2 (f :: * -> *) (g :: * -> *) (ρ :: Row *) = VMap2 { unVMap2 :: Var (Map f (Map g ρ)) }

-- | A function to map over a variant given a constraint.
map :: forall c f r. Forall r c => (forall a. c a => a -> f a) -> Var r -> Var (Map f r)
map f = unVMap . metamorph' @_ @r @c @Var @(VMap f) @Identity Proxy doNil doUncons doCons
  where
    doNil = impossible
    doUncons l = left Identity . flip trial l
    doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
           => Label ℓ -> Either (Identity τ) (VMap f ('R ρ)) -> VMap f ('R (ℓ :-> τ ': ρ))
    doCons l (Left (Identity x)) = VMap $ unsafeMakeVar l $ f x
    doCons _ (Right (VMap v)) = VMap $ unsafeInjectFront v

-- | A function to map over a variant given no constraint.
map' :: forall f r. Forall r Unconstrained1 => (forall a. a -> f a) -> Var r -> Var (Map f r)
map' = map @Unconstrained1

-- | Lifts a natrual transformation over a variant.  In other words, it acts as a
-- variant transformer to convert a variant of @f a@ values to a variant of @g a@
-- values.  If no constraint is needed, instantiate the first type argument with
-- 'Unconstrained1'.
transform :: forall r c (f :: * -> *) (g :: * -> *). Forall r c => (forall a. c a => f a -> g a) -> Var (Map f r) -> Var (Map g r)
transform f = unVMap . metamorph' @_ @r @c @(VMap f) @(VMap g) @f Proxy doNil doUncons doCons . VMap
  where
    doNil = impossible . unVMap
    doUncons l = right VMap . flip trial l . unVMap
    doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
           => Label ℓ -> Either (f τ) (VMap g ('R ρ)) -> VMap g ('R (ℓ :-> τ ': ρ))
    doCons l (Left x) = VMap $ unsafeMakeVar l $ f x
    doCons _ (Right (VMap v)) = VMap $ unsafeInjectFront v

-- | A form of @transformC@ that doesn't have a constraint on @a@
transform' :: forall r (f :: * -> *) (g :: * -> *) . Forall r Unconstrained1 => (forall a. f a -> g a) -> Var (Map f r) -> Var (Map g r)
transform' = transform @r @Unconstrained1

-- | Applicative sequencing over a variant
sequence :: forall f r. (Forall r Unconstrained1, Applicative f) => Var (Map f r) -> f (Var r)
sequence = getCompose . metamorph' @_ @r @Unconstrained1 @(VMap f) @(Compose f Var) @f Proxy doNil doUncons doCons . VMap
  where
    doNil (VMap x) = impossible x
    doUncons l = right VMap . flip trial l . unVMap
    doCons l (Left fx) = Compose $ unsafeMakeVar l <$> fx
    doCons _ (Right (Compose v)) = Compose $ unsafeInjectFront <$> v

-- $compose
-- We can easily convert between mapping two functors over the types of a row
-- and mapping the composition of the two functors.  The following two functions
-- perform this composition with the gaurantee that:
--
-- >>> compose . uncompose = id
--
-- >>> uncompose . compose = id

-- | Convert from a variant where two functors have been mapped over the types to
-- one where the composition of the two functors is mapped over the types.
compose :: forall (f :: * -> *) (g :: * -> *) r . Forall r Unconstrained1 => Var (Map f (Map g r)) -> Var (Map (Compose f g) r)
compose = unVMap . metamorph' @_ @r @Unconstrained1 @(VMap2 f g) @(VMap (Compose f g)) Proxy doNil doUncons doCons . VMap2
  where
    doNil (VMap2 x) = impossible x
    doUncons l = Compose +++ VMap2 <<< flip trial l . unVMap2
    doCons l (Left x) = VMap $ unsafeMakeVar l x
    doCons _ (Right (VMap v)) = VMap $ unsafeInjectFront v

-- | Convert from a variant where the composition of two functors have been mapped
-- over the types to one where the two functors are mapped individually one at a
-- time over the types.
uncompose :: forall (f :: * -> *) (g :: * -> *) r . Forall r Unconstrained1 => Var (Map (Compose f g) r) -> Var (Map f (Map g r))
uncompose = unVMap2 . metamorph' @_ @r @Unconstrained1 @(VMap (Compose f g)) @(VMap2 f g) Proxy doNil doUncons doCons . VMap
  where
    doNil (VMap x) = impossible x
    doUncons l = right VMap . flip trial l . unVMap
    doCons l (Left (Compose x)) = VMap2 $ unsafeMakeVar l x
    doCons _ (Right (VMap2 v)) = VMap2 $ unsafeInjectFront v


{--------------------------------------------------------------------
  Variant initialization
--------------------------------------------------------------------}

-- | A helper function for unsafely adding an element to the front of a variant.
-- This can cause the type of the resulting variant to be malformed, for instance,
-- if the variant already contains labels that are lexicographically before the
-- given label.  Realistically, this function should only be used when writing
-- calls to 'metamorph'.
unsafeInjectFront :: forall l a r. KnownSymbol l => Var (R r) -> Var (R (l :-> a ': r))
unsafeInjectFront = unsafeCoerce

-- | Initialize a variant from a producer function that accepts labels.  If this
-- function returns more than one possibility, then one is chosen arbitrarily to
-- be the value in the variant.
fromLabels :: forall c ρ f. (Alternative f, Forall ρ c, AllUniqueLabels ρ)
           => (forall l a. (KnownSymbol l, c a) => Label l -> f a) -> f (Var ρ)
fromLabels mk = getCompose $ metamorph' @_ @ρ @c @(Const ()) @(Compose f Var) @(Const ())
                                        Proxy doNil doUncons doCons (Const ())
  where doNil _ = Compose $ empty
        doUncons _ _ = Right $ Const ()
        doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
               => Label ℓ -> Either (Const () τ) (Compose f Var ('R ρ)) -> Compose f Var ('R (ℓ :-> τ ': ρ))
        doCons l (Left _) = Compose $ unsafeMakeVar l <$> mk l --This case should be impossible
        doCons l (Right (Compose v)) = Compose $
          unsafeMakeVar l <$> mk l <|> unsafeInjectFront <$> v
