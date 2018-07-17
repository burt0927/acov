module Width
  ( run
  , Script(..)
  , Module(..)
  ) where

import Control.Applicative
import Control.Exception.Base
import Data.Array
import Data.Bits
import qualified Data.Map.Strict as Map
import Data.Maybe

import qualified Expressions as E
import qualified Symbols as S
import qualified Parser as P
import SymbolTable
import ErrorsOr
import Operators
import VInt
import Ranged

{-
  The width pass does width checking (working with a Verilog-like
  semantics but where we don't do magic width promotion based on the
  destination size). The statements unchanged, but we note the width
  of recorded expressions (this is the Int in the type of modRecs)
-}
data Module = Module { modSyms :: SymbolTable (Ranged E.Slice)
                     , modBlocks :: [E.Block]
                     , modRecs :: SymbolTable Int
                     }

data Script = Script { scrModules :: SymbolTable Module
                     , scrStmts :: [S.TLStmt]
                     }

symBits :: SymbolTable (Ranged E.Slice) -> Symbol -> (Int, Int)
symBits st sym =
  let E.Slice a b = rangedData (stAt sym st) in (max a b, min a b)

symWidth :: SymbolTable (Ranged E.Slice) -> Symbol -> Int
symWidth st sym = E.sliceWidth $ rangedData $ stAt sym st

intWidth :: LCRange -> VInt -> ErrorsOr Int
intWidth rng n =
  case vIntWidth n of
    Just w -> good w
    Nothing ->
      bad1 $ Ranged rng "Integer with no width used in expression."

{-
  Try to interpret the expression as an integer. If we can't figure
  out the answer, return Nothing. If something is properly wrong,
  return an error.
-}
exprAsVInt :: E.Expression -> ErrorsOr (Maybe VInt)
exprAsVInt (E.ExprSym _) = good $ Nothing
exprAsVInt (E.ExprInt vi) = good $ Just vi
exprAsVInt (E.ExprSel _ _ _) = good $ Nothing
exprAsVInt (E.ExprConcat _ _) = good $ Nothing
exprAsVInt (E.ExprReplicate _ _) = good $ Nothing
exprAsVInt (E.ExprUnOp ruo re) =
  do { expr <- get re
     ; case expr of
         Nothing -> good $ Nothing
         Just expr' ->
           case applyUnOp (rangedData ruo) expr' of
             Left msg -> bad1 $ copyRange ruo $
                         "Cannot apply unary operator: " ++ msg
             Right val -> good $ Just val
     }
  where get = exprAsVInt . rangedData

exprAsVInt (E.ExprBinOp rbo re0 re1) =
  do { (e0, e1) <- liftA2 (,) (get re0) (get re1)
     ; if isNothing e0 || isNothing e1 then
         good $ Nothing
       else
         let Just e0' = e0 ; Just e1' = e1 in
           case applyBinOp (rangedData rbo) e0' e1' of
             Left msg -> bad1 $ copyRange rbo $
                         "Cannot apply binary operator: " ++ msg
             Right val -> good $ Just val
     }
  where get = exprAsVInt . rangedData

exprAsVInt (E.ExprCond a b c) =
  do { (ea, eb, ec) <- liftA3 (,,) (get a) (get b) (get c)
     ; if isNothing ea || isNothing eb || isNothing ec then
         good $ Nothing
       else
         let Just ea' = ea ; Just eb' = eb ; Just ec' = ec in
           case applyCond ea' eb' ec' of
             Left msg -> bad1 $ copyRange a $
                         "Cannot apply conditional: " ++ msg
             Right val -> good $ Just val
     }
  where get = exprAsVInt . rangedData

selBits :: Ranged E.Expression -> Maybe (Ranged E.Expression) ->
           ErrorsOr (Maybe (Integer, Integer))
selBits re0 mre1 =
   case mre1 of
     Nothing ->
       do { mv0 <- get re0
          ; good $
            case mv0 of
              Nothing -> Nothing
              Just v0 -> Just (toInteger v0, toInteger v0)
          }
     Just re1 ->
       do { (mv0, mv1) <- liftA2 (,) (get re0) (get re1)
          ; good $
            if isNothing mv0 || isNothing mv1 then
              Nothing
            else
              Just (toInteger $ fromJust mv0, toInteger $ fromJust mv1)
          }
  where get = exprAsVInt . rangedData


checkSel :: SymbolTable (Ranged E.Slice) -> Ranged Symbol -> 
            Maybe (Integer, Integer) -> ErrorsOr ()
checkSel st rsym used =
  case used of
    -- If we can't figure out the bits in advance, we can't help.
    Nothing -> good ()
    -- If we can, we can check them against the size of the
    -- underlying symbol
    Just (a, b) ->
      let (uhi, ulo) = (max a b, min a b)
          (shi, slo) = symBits st (rangedData rsym) in
        if ulo < toInteger slo || uhi > toInteger shi then
          bad1 $ copyRange rsym $
          "Bit selection overflows size of symbol."
        else
          good ()

-- TODO: We should support +: and -: so that I can write x[y +: 2] and
-- have a sensible width.
selWidth :: SymbolTable (Ranged E.Slice) -> Ranged Symbol -> 
            Ranged E.Expression -> Maybe (Ranged E.Expression) ->
            ErrorsOr Int
selWidth st rsym re0 mre1 =
  do { used <- selBits re0 mre1
     ; checkSel st rsym used
     ; case used of
         Nothing -> bad1 $ copyRange rsym
                    "Can't compute width of bit selection."
         Just (a, b) -> good $ fromInteger $ max a b - min a b + 1
     }

concatWidth :: SymbolTable (Ranged E.Slice) -> Ranged E.Expression ->
               [Ranged E.Expression] -> ErrorsOr Int
concatWidth st re res =
  do { (w0, ws) <- liftA2 (,) (get re) (mapEO get res)
     ; good $ w0 + sum ws
     }
  where get = exprWidth st

repWidth :: SymbolTable (Ranged E.Slice) -> Int ->
            Ranged E.Expression -> ErrorsOr Int
repWidth st n re = ((*) n) <$> (exprWidth st re)

unOpWidth :: SymbolTable (Ranged E.Slice) ->
             Ranged UnOp -> Ranged E.Expression -> ErrorsOr Int
unOpWidth st uo re =
  do { ew <- exprWidth st re
     ; return $ if unOpIsReduction (rangedData uo) then 1 else ew
     }

checkWidth1 :: LCRange -> Int -> ErrorsOr ()
checkWidth1 rng n =
  if n /= 1 then
    bad1 $ Ranged rng $
    "Expression has width " ++ show n ++
    " != 1 so can't be used as a condition."
  else
    good ()

checkWidths :: String -> LCRange -> Int -> Int -> ErrorsOr ()
checkWidths opname rng n m =
  if n /= m then
    bad1 $ Ranged rng $
    "Left and right side of " ++ opname ++
    " operator have different widths: " ++
    show n ++ " != " ++ show m ++ "."
  else
    good ()

binOpWidth :: SymbolTable (Ranged E.Slice) ->
              Ranged BinOp -> Ranged E.Expression -> Ranged E.Expression ->
              ErrorsOr Int
binOpWidth st bo re0 re1 =
  do { (ew0, ew1) <- liftA2 (,) (exprWidth st re0) (exprWidth st re1)
     ; checkWidths (show $ rangedData bo) (rangedRange bo) ew0 ew1
     ; good $ if binOpIsReduction (rangedData bo) then 1 else ew0
     }

condWidth :: SymbolTable (Ranged E.Slice) -> Ranged E.Expression -> Ranged E.Expression ->
             Ranged E.Expression -> ErrorsOr Int
condWidth st e0 e1 e2 =
  do { (ew0, ew1, ew2) <- liftA3 (,,) (get e0) (get e1) (get e2)
     ; liftA2 (,) (checkWidth1 (rangedRange e0) ew0)
                  (checkWidths "conditional" (rangedRange e1) ew1 ew2)
     ; return ew1
     }
  where get = exprWidth st

exprWidth :: SymbolTable (Ranged E.Slice) -> Ranged E.Expression -> ErrorsOr Int
exprWidth st rexpr = exprWidth' st (rangedRange rexpr) (rangedData rexpr)

exprWidth' :: SymbolTable (Ranged E.Slice) -> LCRange -> E.Expression -> ErrorsOr Int
exprWidth' st _ (E.ExprSym sym) = return $ symWidth st sym
exprWidth' _ rng (E.ExprInt vint) = intWidth rng vint
exprWidth' st _ (E.ExprSel sym ex0 ex1) = selWidth st sym ex0 ex1
exprWidth' st _ (E.ExprConcat e0 es) = concatWidth st e0 es
exprWidth' st _ (E.ExprReplicate n e) = repWidth st n e
exprWidth' st _ (E.ExprUnOp uo e) = unOpWidth st uo e
exprWidth' st _ (E.ExprBinOp bo e0 e1) = binOpWidth st bo e0 e1
exprWidth' st _ (E.ExprCond e0 e1 e2) = condWidth st e0 e1 e2

takeRecord :: SymbolTable (Ranged E.Slice) -> Map.Map Symbol Int ->
              E.Record -> ErrorsOr (Map.Map Symbol Int)
takeRecord st m (E.Record expr sym) =
  do { w <- exprWidth st expr
     ; assert (not $ Map.member sym m) $
       good $ Map.insert sym w m
     }

takeBlock :: SymbolTable (Ranged E.Slice) -> Map.Map Symbol Int ->
             E.Block -> ErrorsOr (Map.Map Symbol Int)
takeBlock st m (E.Block guard recs) =
  do { (_, m') <- liftA2 (,) (checkGuard guard) (foldEO (takeRecord st) m recs)
     ; good m'
     }
  where checkGuard Nothing = good ()
        checkGuard (Just g) =
          do { gw <- exprWidth st g
             ; if gw /= 1 then
                 bad1 $ copyRange g $
                 ("Block is guarded by expression with width " ++
                   show gw ++ ", not 1.")
               else
                 good ()
             }

readModule :: E.Module -> ErrorsOr Module
readModule mod =
  Module (E.modSyms mod) blocks <$>
  do { widths <- foldEO (takeBlock (E.modSyms mod)) Map.empty blocks
     ; return $ stMapWithSymbol (f widths) (E.modRecs mod)
     }
  where blocks = E.modBlocks mod
        f widths sym () =
          assert (Map.member sym widths) $
          fromJust (Map.lookup sym widths)

readModules :: SymbolTable E.Module -> ErrorsOr (SymbolTable Module)
readModules = traverseEO readModule

fitsInBits :: Integer -> Int -> Bool
fitsInBits n w = assert (w > 0) $ shift (abs n) (- sw) == 0
  where sw = if n >= 0 then w else w - 1

checkCover1 :: Int -> Ranged VInt -> ErrorsOr ()
checkCover1 w rint =
  if fitsInBits asInt w then good ()
  else bad1 $ copyRange rint $
       "Cover list has entry of " ++ show asInt ++
       ", but the cover expression has width " ++ show w ++ "."
  where asInt = toInteger (rangedData rint)

checkCover' :: LCRange -> Int -> Maybe P.CoverList -> ErrorsOr ()
checkCover' rng w Nothing =
  if w > 16 then
    bad1 $ Ranged rng "Symbol has width more than 16 and no cover list."
  else
    good ()

checkCover' _ w (Just (P.CoverList vints)) =
  mapEO (checkCover1 w) vints >> good ()

checkCover :: SymbolTable Module ->
              Ranged S.DottedSymbol -> Maybe P.CoverList ->
              ErrorsOr ()
checkCover mods dsym clist = checkCover' (rangedRange dsym) width clist
  where S.DottedSymbol msym vsym = rangedData dsym
        width = stAt vsym (modRecs (stAt msym mods))

checkTLStmt :: SymbolTable Module -> S.TLStmt -> ErrorsOr ()
checkTLStmt mods (S.Cover dsym cov) = checkCover mods dsym cov
checkTLStmt _ (S.Cross _) = good ()

checkTLStmts :: SymbolTable Module -> [S.TLStmt] -> ErrorsOr ()
checkTLStmts mods = foldEO (\ _ -> checkTLStmt mods) ()

run :: E.Script -> ErrorsOr Script
run script = do { mods <- readModules (E.scrMods script)
                ; checkTLStmts mods stmts
                ; good $ Script mods stmts
                }
  where stmts = E.scrStmts script
