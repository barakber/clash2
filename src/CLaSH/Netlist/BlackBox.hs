{-# LANGUAGE PatternGuards #-}
module CLaSH.Netlist.BlackBox where

import           Control.Monad (mzero)
import           Control.Monad.State (state)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Writer (tell)
import           Control.Monad.Trans.Maybe (MaybeT(..))
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.Either       (lefts,partitionEithers)
import qualified Data.HashMap.Lazy as HashMap
import           Data.List         (partition)
import qualified Data.Label.PureM  as LabelM
import           Data.Maybe        (catMaybes,fromJust)
import           Data.Text.Lazy    (Text,pack)
import qualified Data.Text.Lazy    as Text
import           Unbound.LocallyNameless (name2String,unembed)

import CLaSH.Core.Literal            as L (Literal(..))
import CLaSH.Core.Prim               (Prim (..))
import CLaSH.Core.Term               as C (Term(..),TmName)
import CLaSH.Core.Util               (collectArgs,isFun)
import CLaSH.Core.Var                as V (Id,Var(..))
import CLaSH.Normalize.Util          (isSimple)
import {-# SOURCE #-} CLaSH.Netlist  (genComponent)
import CLaSH.Netlist.BlackBox.Parser as B
import CLaSH.Netlist.BlackBox.Types  as B
import CLaSH.Netlist.BlackBox.Util   as B
import CLaSH.Netlist.Id              as N
import CLaSH.Netlist.Types           as N
import CLaSH.Netlist.Util            as N
import CLaSH.Netlist.VHDL            as N
import CLaSH.Primitives.Types        as P
import CLaSH.Util

mkBlackBoxContext ::
  Id
  -> [Term]
  -> NetlistMonad BlackBoxContext
mkBlackBoxContext resId args = do
  let res               = Left . mkBasicId . pack $ name2String (V.varName resId)
  let resTy             = N.coreTypeToHWType_fail $ unembed $ V.varType resId
  isFunArgs             <- mapM isFun args
  let args'             = zip args isFunArgs
  varInps               <- mapM (runMaybeT . mkInput resId) args'
  let (_,otherArgs)     = partitionEithers $ map unVar args'
  let (litArgs,funArgs) = partition (\(t,b) -> not b && isSimple t) otherArgs
  litInps               <- mapM (runMaybeT . mkLitInput . fst) litArgs
  funInps               <- mapM (runMaybeT . mkFunInput resId . fst) funArgs
  return $ Context (res,resTy) (catMaybes varInps)
                               (catMaybes litInps)
                               (catMaybes funInps)

unVar :: (Term, Bool) -> Either TmName (Term, Bool)
unVar (Var _ v, False) = Left v
unVar t                = Right t

mkBlackBoxDecl ::
  Text
  -> BlackBoxContext
  -> NetlistMonad [Declaration]
mkBlackBoxDecl templ bbCtx = do
  let (l,err) = runParse templ
  case (null err && verifyBlackBoxContext l bbCtx) of
    True -> do
      i <- LabelM.gets varCount
      let (l',i') = setSym (fromInteger i) l
      LabelM.puts varCount (toInteger i')
      (tmpl,clks) <- liftState vhdlMState $ state $ renderBlackBox l' bbCtx
      tell clks
      return [N.BlackBox tmpl]
    False -> error $ $(curLoc) ++ "\nCan't match context:\n" ++ show bbCtx ++ "\nwith template:\n" ++ show templ ++ "\ngiven errors:\n" ++ show err

mkInput ::
  Id
  -> (Term, Bool)
  -> MaybeT NetlistMonad (SyncIdentifier,HWType)
mkInput _ ((Var ty v), False) = do
  let vT = mkBasicId . pack $ name2String v
  let hwTy = N.coreTypeToHWType_fail ty
  case synchronizedClk ty of
    Just clk -> return ((Right (vT,clk)), hwTy)
    Nothing  -> return ((Left vT), hwTy)

mkInput resId (e@(App _ _), False)
  | (Prim (PrimFun nm _), args) <- collectArgs e
  = do
    bbM <- fmap (HashMap.lookup . BSL.pack $ name2String nm) $ LabelM.gets primitives
    case bbM of
      Just p@(P.BlackBox {}) -> do
        bbCtx <- lift $ mkBlackBoxContext resId (lefts args)
        case (Text.null $ templateI p) of
          True -> error $ $(curLoc) ++ "Can't create inlined blackbox: " ++ show p
          False -> do
            (N.BlackBox bb:_) <- lift $ mkBlackBoxDecl (templateI p) bbCtx
            let hwTy = error $ $(curLoc) ++ "No Type"
            return (Left bb, hwTy)
      _ -> error $ "No blackbox found: " ++ show bbM

mkInput _ (_, True) = return (Left $ pack "__FUN__", error $ $(curLoc) ++ "No Type")

mkInput _ (e, _)    = do e' <- mkLitInput e
                         return (Left e', error $ $(curLoc) ++ "No Type")

mkLitInput ::
  Monad m
  => Term
  -> MaybeT m Identifier
mkLitInput (C.Literal (IntegerLiteral i)) = return (pack $ show i)
mkLitInput _                              = mzero

mkFunInput ::
  Id
  -> Term
  -> MaybeT NetlistMonad (Line,BlackBoxContext)
mkFunInput resId e = case (collectArgs e) of
  (Prim (PrimFun nm _), args) -> do
    bbM <- fmap (HashMap.lookup . BSL.pack $ name2String nm) $ LabelM.gets primitives
    case bbM of
      Just p@(P.BlackBox {}) -> do
        bbCtx <- lift $ mkBlackBoxContext resId (lefts args)
        let (l,err) = runParse (template p)
        if null err
          then do
            i <- LabelM.gets varCount
            let (l',i') = setSym (fromInteger i) l
            LabelM.puts varCount (toInteger i')
            return (l',bbCtx)
          else error $ $(curLoc) ++ "\nTemplate:\n" ++ show (template p) ++ "\nHas errors:\n" ++ show err
      _ -> error $ "No blackbox found: " ++ show bbM
  (Var _ fun, args) -> do
    bbCtx <- lift $ mkBlackBoxContext resId (lefts args)
    (Component compName hidden compInps compOutp _) <- lift $
      do vCnt <- LabelM.gets varCount
         vEnv <- LabelM.gets varEnv
         comp <- genComponent fun Nothing
         LabelM.puts varCount vCnt
         LabelM.puts varEnv vEnv
         return comp
    let hiddenAssigns = map (\(i,_) -> (i,Identifier i Nothing)) hidden
        inpAssigns    = zip (map fst compInps) [ Identifier (pack ("~ARG[" ++ show x ++ "]")) Nothing | x <- [(0::Int)..] ]
        outpAssign    = (fst compOutp,Identifier (pack "~RESULT") Nothing)
    i <- getAndModify varCount (+1)
    let instDecl      = InstDecl compName (pack ("comp_inst_" ++ show i)) (outpAssign:hiddenAssigns ++ inpAssigns)
    templ <- fmap (pack . show . fromJust) $ liftState vhdlMState $ inst instDecl
    let (line,err)    = runParse templ
    if (null err)
      then return (line,bbCtx)
      else error $ $(curLoc) ++ "\nTemplate:\n" ++ show templ ++ "\nHas errors:\n" ++ show err
  _ -> error (show e)
