{-# LANGUAGE RankNTypes, ScopedTypeVariables, TypeOperators, FlexibleContexts, GADTs, TypeFamilies #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
module Database.Beam.Query.Combinators where

import Database.Beam.Schema
import Database.Beam.Query.Types
import Database.Beam.Query.Rewrite

import Database.Beam.SQL
import Database.HDBC

import Control.Monad.Writer hiding (All)

import Data.Proxy
import Data.Semigroup hiding (All)
import Data.Typeable
import Data.Convertible
import Data.Coerce
import qualified Data.Text as T

import GHC.Generics

-- * Query combinators

of_ :: Table table => table Column
of_ = undefined

all_ :: (Table table, ScopeFields (table Column)) => table Column -> Query (table Column)
all_ (_ :: table Column) = All (Proxy :: Proxy table) 0

maxTableOrdinal :: Query a -> Int
maxTableOrdinal q = getMax (execWriter (traverseQueryM maxQ maxE q))
    where maxQ :: Query a -> Writer (Max Int) ()
          maxQ (All _ i) = tell (Max i)
          maxQ _ = return ()

          maxE :: QExpr a -> Writer (Max Int) ()
          maxE _ = return ()

join_ :: (Project (Scope a), Project (Scope b)) => Query a -> Query b -> Query (a :|: b)
join_ l r = Join l (rewriteForJoin l r)

rewriteForJoin :: Query a -> Query b -> Query b
rewriteForJoin l r = r'
    where maxOrdL = max (maxTableOrdinal l) (maxTableOrdinal r) + 1

          remapQuery :: Query b -> Maybe (Query b)
          remapQuery (All tbl i)
              | i < maxOrdL = Just (All tbl (i + maxOrdL))
              | otherwise = Nothing
          remapQuery _ = Nothing

          remapExpr :: QExpr b -> Maybe (QExpr b)
          remapExpr (FieldE (ScopedField i tbl :: ScopedField table c ty))
              | i < maxOrdL = Just (FieldE (ScopedField (i + maxOrdL) tbl :: ScopedField table c ty))
              | otherwise = Nothing
          remapExpr _ = Nothing

          r' = rewriteQuery remapQuery remapExpr r

leftJoin_ :: (Project (Scope a), Project (Scope b)) => Query a -> (Query b, Scope (a :|: b) -> QExpr Bool) -> Query (a :|: Maybe b)
leftJoin_ l (r, mkOn) = LeftJoin l r' (mkOn (getScope l :|: getScope r'))
    where r' = rewriteForJoin l r
rightJoin_ :: (Project (Scope a), Project (Scope b)) => Query a -> (Query b, Scope (a :|: b) -> QExpr Bool) -> Query (Maybe a :|: b)
rightJoin_ l (r, mkOn) = RightJoin l r' (mkOn (getScope l :|: getScope r'))
    where r' = rewriteForJoin l r
outerJoin_ :: (Project (Scope a), Project (Scope b)) => Query a -> (Query b, Scope (a :|: b) -> QExpr Bool) -> Query (Maybe a :|: Maybe b)
outerJoin_ l (r, mkOn) = OuterJoin l r' (mkOn ((getScope l) :|: (getScope r')))
    where r' = rewriteForJoin l r

project_ :: (Rescopable a, Rescopable b) =>  Query a -> (Scope a -> Scope b) -> Query b
project_ q a = Project q a

limit_, offset_ :: Query a -> Integer -> Query a
limit_ = Limit
offset_ = Offset

sortAsc_, sortDesc_ :: Typeable b => Query a -> (Scope a -> QExpr b) -> Query a
sortAsc_ q mkExpr = OrderBy q (GenQExpr (mkExpr (getScope q))) Ascending
sortDesc_ q mkExpr = OrderBy q (GenQExpr (mkExpr (getScope q))) Descending

groupBy_ :: Typeable b => Query a -> (Scope a -> QExpr b) -> Query a
groupBy_ q mkExpr = GroupBy q (GenQExpr (mkExpr (getScope q)))

where_ :: Query a -> (Scope a -> QExpr Bool) -> Query a
where_ q mkExpr = Filter q (mkExpr (getScope q))


primaryKeyExpr :: ( Table table, Table related ) =>
                  Proxy table -> Proxy related -> PrimaryKey table (ScopedField related Column) -> PrimaryKey table Column -> QExpr Bool
primaryKeyExpr (_ :: Proxy table) (_ :: Proxy related) pkFields pkValues =
    foldl1 (&&#) $
    zipWith (\(GenScopedField (x :: ScopedField related Column ty)) (GenQExpr (q :: QExpr ty2)) ->
                 case cast q of
                   Just q -> FieldE (x :: ScopedField related Column ty) ==# (q :: QExpr (ColumnType Column ty)) :: QExpr Bool
                   Nothing -> val_ False) pkFieldNames pkValueExprs
    where pkFieldNames = pkAllValues (Proxy :: Proxy table) mkScopedField pkFields
          pkValueExprs = pkAllValues (Proxy :: Proxy table) mkValE pkValues

          mkScopedField :: (Table table, FieldSchema a) => ScopedField related Column a -> GenScopedField related Column
          mkScopedField = GenScopedField
          mkValE :: FieldSchema a => Column a -> GenQExpr
          mkValE (x :: Column a) = GenQExpr (ValE (makeSqlValue (columnValue x)) :: QExpr a)

          from' :: Generic a => a -> Rep a ()
          from' = from

(@->) :: Table related =>
         table Column -> (forall a. table a -> ForeignKey related a) -> Query (related Column)
table @-> (f :: forall a. table a -> ForeignKey related a) =
    all_ (of_ :: related Column)
      `where_` (\fields -> primaryKeyExpr (Proxy :: Proxy related) (Proxy :: Proxy related) (primaryKey fields) pk)
    where pk :: PrimaryKey related Column
          ForeignKey pk = f table

(<-@) :: ( Table related, Table table ) =>
         (forall a. related a -> ForeignKey table a) -> table Column -> Query (related Column)
(f :: forall a. related a -> ForeignKey table a) <-@ fields =
    all_ (of_ :: related Column)
      `where_` (\scope ->
                let ForeignKey pk = f scope
                in primaryKeyExpr (Proxy :: Proxy table) (Proxy :: Proxy related) pk (primaryKey fields))

foreignKeyJoin :: ( Table table, Table related ) =>
                  Proxy table -> Proxy related -> PrimaryKey related (ScopedField table Column) -> PrimaryKey related (ScopedField related Column) -> QExpr Bool
foreignKeyJoin (_ :: Proxy table) (_ :: Proxy related) parent related = foldl1 (&&#) fieldEqExprs
    where parentFields = pkAllValues (Proxy :: Proxy related) genPar parent
          relatedFields = pkAllValues (Proxy :: Proxy related) genRel related

          from' :: Generic a => a -> Rep a ()
          from' = from

          genPar :: (Typeable ty, Show ty) => ScopedField table Column ty -> GenScopedField table Column
          genRel :: (Typeable ty, Show ty) => ScopedField related Column ty -> GenScopedField related Column
          genPar = gen
          genRel = gen

          gen :: (Table t, Typeable ty, Show ty) => ScopedField t Column ty -> GenScopedField t Column
          gen = GenScopedField

          fieldEqExprs :: [QExpr Bool]
          fieldEqExprs = zipWith (\(GenScopedField (ScopedField i name)) (GenScopedField (y :: ScopedField table' c' ty)) ->
                                  FieldE (ScopedField i name :: ScopedField table' c' ty) ==# FieldE y) parentFields relatedFields

-- | Given a query for a table, and an accessor for a foreignkey reference, return a query that joins the two tables
(==>) :: ( Table table, Table related
         , Project (related (ScopedField related Column))
         , Project (table (ScopedField table Column)) ) =>
         Query (table Column) -> (forall a. table a -> ForeignKey related a) -> Query (table Column :|: related Column)
q ==> (f :: forall a. table a -> ForeignKey related a) =
    join_ q (All (Proxy :: Proxy related) 0) `where_`
      (\(table :|: relatedFields) -> foreignKeyJoin (Proxy :: Proxy table) (Proxy :: Proxy related) (fk table) (primaryKey relatedFields))
    where fk scope = let ForeignKey x = f scope
                     in x

-- | Like '(==>)' but with its arguments reversed
(<==) :: ( Table table, Table related
         , Project (related (ScopedField related Column))
         , Project (table (ScopedField table Column)) ) =>
         Query (table Column) -> (forall a. related a -> ForeignKey table a) -> Query (table Column :|: related Column)
q <== (f :: forall a. related a -> ForeignKey table a) =
    join_ q (All (Proxy :: Proxy related) 0) `where_`
              (\(tableFields :|: related) -> foreignKeyJoin (Proxy :: Proxy related) (Proxy :: Proxy table)
                                                            (reference . f $ related) (primaryKey tableFields))

-- | Given a query for a table, and an accessor for a foreignkey reference, return a query that returns all rows from the left query, regardless of whether
--   an associated row exists for the foreign key (a LEFT JOIN)
(=>?) :: ( Table table, Table related
         , Project (related (ScopedField related Column))
         , Project (table (ScopedField table Column)) ) =>
         Query (table Column) -> (forall a. table a -> ForeignKey related a) -> Query (table Column :|: Maybe (related Column))
q =>? (f :: forall a. table a -> ForeignKey related a) =
    leftJoin_ q (All (Proxy :: Proxy related) 0,
                 \(table :|: relatedFields) -> foreignKeyJoin (Proxy :: Proxy table) (Proxy :: Proxy related) (fk table) (primaryKey relatedFields))
    where fk scope = let ForeignKey x = f scope
                     in x

(<=?) :: ( Table table, Table related
         , Project (related (ScopedField related Column))
         , Project (table (ScopedField table Column)) ) =>
        Query (table Column) -> (forall a. related a -> ForeignKey table a) -> Query (table Column :|: Maybe (related Column))
q <=? (f :: forall a. related a -> ForeignKey table a) =
    leftJoin_ q
              (All (Proxy :: Proxy related) 0,
               \(tableFields :|: related) -> foreignKeyJoin (Proxy :: Proxy related) (Proxy :: Proxy table)
                                                            (reference . f $ related) (primaryKey tableFields))

(<#), (>#), (<=#), (>=#), (==#) :: (Typeable a, Show a) => QExpr a -> QExpr a -> QExpr Bool
(==#) = EqE
(<#) = LtE
(>#) = GtE
(<=#) = LeE
(>=#) = GeE

(&&#), (||#) :: QExpr Bool -> QExpr Bool -> QExpr Bool
(&&#) = AndE
(||#) = OrE

infixr 3 &&#
infixr 2 ||#
infix 4 ==#

(=#) :: Table table => ScopedField table c ty -> QExpr (ColumnType c ty) -> QAssignment
(=#) = QAssignment

list_ :: [QExpr a] -> QExpr [a]
list_ = ListE
in_ :: (Typeable a, Show a)=> QExpr a -> QExpr [a] -> QExpr Bool
in_ = InE

count_ :: Typeable a => QExpr a -> QExpr Int
count_ = CountE

min_, max_, sum_, average_ :: Typeable a => QExpr a -> QExpr a
min_ = MinE
max_ = MaxE
sum_ = SumE
average_ = AverageE


text_ :: T.Text -> QExpr T.Text
text_ = ValE . SqlString . T.unpack
num_ :: Integral a => a -> QExpr a
num_ = ValE . SqlInteger . fromIntegral
val_ :: Convertible a SqlValue => a -> QExpr a
val_ = ValE . convert
enum_ :: Show a => a -> QExpr (BeamEnum a)
enum_ = ValE . SqlString . show
field_ :: (Table table, Typeable c, Typeable ty) => ScopedField table c ty -> QExpr (ColumnType c ty)
field_ = FieldE

just_ :: Show a => QExpr a -> QExpr (Maybe a)
just_ = JustE
nothing_ :: QExpr (Maybe a)
nothing_ = NothingE

isNothing_, isJust_ :: Typeable a => QExpr (Maybe a) -> QExpr Bool
isNothing_ = IsNothingE
isJust_ = IsJustE
