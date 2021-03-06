{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

-- | Generate VHDL for assorted Netlist datatypes
module CLaSH.Netlist.VHDL
  ( genVHDL
  , mkTyPackage
  , vhdlType
  , vhdlTypeErrValue
  , vhdlTypeMark
  , inst
  , expr
  )
where

import qualified Control.Applicative                  as A
import           Control.Lens                         hiding (Indexed)
import           Control.Monad                        (forM,join,liftM,when,zipWithM)
import           Control.Monad.State                  (State)
import           Data.Graph.Inductive                 (Gr, mkGraph, topsort')
import qualified Data.HashMap.Lazy                    as HashMap
import qualified Data.HashSet                         as HashSet
import           Data.List                            (mapAccumL,nubBy)
import           Data.Maybe                           (catMaybes,mapMaybe)
import           Data.Text.Lazy                       (unpack)
import qualified Data.Text.Lazy                       as T
import           Text.PrettyPrint.Leijen.Text.Monadic

import           CLaSH.Netlist.Types
import           CLaSH.Netlist.Util
import           CLaSH.Util                           (curLoc, makeCached, (<:>))

type VHDLM a = State VHDLState a

-- | Generate VHDL for a Netlist component
genVHDL :: Component -> VHDLM (String,Doc)
genVHDL c = (unpack cName,) A.<$> vhdl
  where
    cName   = componentName c
    vhdl    = tyImports <$$> linebreak <>
              entity c <$$> linebreak <>
              architecture c

-- | Generate a VHDL package containing type definitions for the given HWTypes
mkTyPackage :: [HWType]
            -> VHDLM Doc
mkTyPackage hwtys =
   "library IEEE;" <$>
   "use IEEE.STD_LOGIC_1164.ALL;" <$>
   "use IEEE.NUMERIC_STD.ALL;" <$$> linebreak <>
   "package" <+> "types" <+> "is" <$>
      indent 2 ( packageDec <$>
                 vcat (sequence funDecs)
               ) <>
      (case showDecs of
         [] -> empty
         _  -> linebreak <$>
               "-- pragma translate_off" <$>
               indent 2 (vcat (sequence showDecs)) <$>
               "-- pragma translate_on"
      ) <$>
   "end" <> semi <> packageBodyDec
  where
    usedTys     = nubBy eqHWTy $ concatMap mkUsedTys hwtys
    needsDec    = nubBy eqHWTy (hwtys ++ filter needsTyDec usedTys)
    hwTysSorted = topSortHWTys needsDec
    packageDec  = vcat $ mapM tyDec hwTysSorted
    (funDecs,funBodies) = unzip . catMaybes $ map funDec usedTys
    (showDecs,showBodies) = unzip $ map mkToStringDecls hwTysSorted

    packageBodyDec :: VHDLM Doc
    packageBodyDec = case (funBodies,showBodies) of
        ([],[]) -> empty
        _  -> linebreak <$>
              "package" <+> "body" <+> "types" <+> "is" <$>
                indent 2 (vcat (sequence funBodies)) <$>
                linebreak <>
                "-- pragma translate_off" <$>
                indent 2 (vcat (sequence showBodies)) <$>
                "-- pragma translate_on" <$>
              "end" <> semi

    eqHWTy :: HWType -> HWType -> Bool
    eqHWTy (Vector _ elTy1) (Vector _ elTy2) = case (elTy1,elTy2) of
      (Sum _ _,Sum _ _)    -> typeSize elTy1 == typeSize elTy2
      (Unsigned n,Sum _ _) -> n == typeSize elTy2
      (Sum _ _,Unsigned n) -> typeSize elTy1 == n
      _ -> elTy1 == elTy2
    eqHWTy ty1 ty2 = ty1 == ty2

mkUsedTys :: HWType
        -> [HWType]
mkUsedTys v@(Vector _ elTy)   = v : mkUsedTys elTy
mkUsedTys p@(Product _ elTys) = p : concatMap mkUsedTys elTys
mkUsedTys sp@(SP _ elTys)     = sp : concatMap mkUsedTys (concatMap snd elTys)
mkUsedTys t                   = [t]

topSortHWTys :: [HWType]
             -> [HWType]
topSortHWTys hwtys = sorted
  where
    nodes  = zip [0..] hwtys
    nodesI = HashMap.fromList (zip hwtys [0..])
    edges  = concatMap edge hwtys
    graph  = mkGraph nodes edges :: Gr HWType ()
    sorted = reverse $ topsort' graph

    edge t@(Vector _ elTy) = maybe [] ((:[]) . (HashMap.lookupDefault (error $ $(curLoc) ++ "Vector") t nodesI,,()))
                                      (HashMap.lookup (mkVecZ elTy) nodesI)
    edge t@(Product _ tys) = let ti = HashMap.lookupDefault (error $ $(curLoc) ++ "Product") t nodesI
                             in mapMaybe (\ty -> liftM (ti,,()) (HashMap.lookup (mkVecZ ty) nodesI)) tys
    edge t@(SP _ ctys)     = let ti = HashMap.lookupDefault (error $ $(curLoc) ++ "SP") t nodesI
                             in concatMap (\(_,tys) -> mapMaybe (\ty -> liftM (ti,,()) (HashMap.lookup (mkVecZ ty) nodesI)) tys) ctys
    edge _                 = []

mkVecZ :: HWType -> HWType
mkVecZ (Vector _ elTy) = Vector 0 elTy
mkVecZ t               = t

needsTyDec :: HWType -> Bool
needsTyDec (Vector _ Bit) = False
needsTyDec (Vector _ _)   = True
needsTyDec (Product _ _)  = True
needsTyDec (SP _ _)       = True
needsTyDec Bool           = True
needsTyDec Integer        = True
needsTyDec _              = False

tyDec :: HWType -> VHDLM Doc
tyDec (Vector _ elTy) = "type" <+> "array_of_" <> tyName elTy <+> "is array (integer range <>) of" <+> vhdlType elTy <> semi

tyDec ty@(Product _ tys) = prodDec
  where
    prodDec = "type" <+> tName <+> "is record" <$>
                indent 2 (vcat $ zipWithM (\x y -> x <+> colon <+> y <> semi) selNames selTys) <$>
              "end record" <> semi

    tName    = tyName ty
    selNames = map (\i -> tName <> "_sel" <> int i) [0..]
    selTys   = map vhdlType tys

tyDec _ = empty

funDec :: HWType -> Maybe (VHDLM Doc,VHDLM Doc)
funDec Bool = Just
  ( "function" <+> "toSLV" <+> parens ("b" <+> colon <+> "in" <+> "boolean") <+> "return" <+> "std_logic_vector" <> semi <$>
    "function" <+> "fromSL" <+> parens ("sl" <+> colon <+> "in" <+> "std_logic") <+> "return" <+> "boolean" <> semi
  , "function" <+> "toSLV" <+> parens ("b" <+> colon <+> "in" <+> "boolean") <+> "return" <+> "std_logic_vector" <+> "is" <$>
    "begin" <$>
      indent 2 (vcat $ sequence ["if" <+> "b" <+> "then"
                                ,  indent 2 ("return" <+> dquotes (int 1) <> semi)
                                ,"else"
                                ,  indent 2 ("return" <+> dquotes (int 0) <> semi)
                                ,"end" <+> "if" <> semi
                                ]) <$>
    "end" <> semi <$>
    "function" <+> "fromSL" <+> parens ("sl" <+> colon <+> "in" <+> "std_logic") <+> "return" <+> "boolean" <+> "is" <$>
    "begin" <$>
      indent 2 (vcat $ sequence ["if" <+> "sl" <+> "=" <+> squotes (int 1) <+> "then"
                                ,   indent 2 ("return" <+> "true" <> semi)
                                ,"else"
                                ,   indent 2 ("return" <+> "false" <> semi)
                                ,"end" <+> "if" <> semi
                                ]) <$>
    "end" <> semi
  )

funDec Integer = Just
  ( "function" <+> "to_integer" <+> parens ("i" <+> colon <+> "in" <+> "integer") <+> "return" <+> "integer" <> semi
  , "function" <+> "to_integer" <+> parens ("i" <+> colon <+> "in" <+> "integer") <+> "return" <+> "integer" <+> "is" <$>
    "begin" <$>
      indent 2 ("return" <+> "i" <> semi) <$>
    "end" <> semi
  )

funDec _ = Nothing

mkToStringDecls :: HWType -> (VHDLM Doc, VHDLM Doc)
mkToStringDecls t@(Product _ elTys) =
  ( "function to_string" <+> parens ("value :" <+> vhdlType t) <+> "return STRING" <> semi
  , "function to_string" <+> parens ("value :" <+> vhdlType t) <+> "return STRING is" <$>
    "begin" <$>
    indent 2 ("return" <+> parens (hcat (punctuate " & " elTyPrint)) <> semi) <$>
    "end function to_string;"
  )
  where
    elTyPrint = forM [0..(length elTys - 1)]
                     (\i -> "to_string" <>
                            parens ("value." <> vhdlType t <> "_sel" <> int i))
mkToStringDecls (Vector _ Bit)  = (empty,empty)
mkToStringDecls t@(Vector _ elTy) =
  ( "function to_string" <+> parens ("value : " <+> vhdlTypeMark t) <+> "return STRING" <> semi
  , "function to_string" <+> parens ("value : " <+> vhdlTypeMark t) <+> "return STRING is" <$>
      indent 2
        ( "alias ivalue    : " <+> vhdlTypeMark t <> "(1 to value'length) is value;" <$>
          "variable result : STRING" <> parens ("1 to value'length * " <> int (typeSize elTy)) <> semi
        ) <$>
    "begin" <$>
      indent 2
        ("for i in ivalue'range loop" <$>
            indent 2
              (  "result" <> parens (parens ("(i - 1) * " <> int (typeSize elTy)) <+> "+ 1" <+>
                                             "to i*" <> int (typeSize elTy)) <+>
                          ":= to_string" <> parens (if elTy == Bool then "toSLV(ivalue(i))" else "ivalue(i)") <> semi
              ) <$>
         "end loop;" <$>
         "return result;"
        ) <$>
    "end function to_string;"
  )
mkToStringDecls _ = (empty,empty)

tyImports :: VHDLM Doc
tyImports =
  punctuate' semi $ sequence
    [ "library IEEE"
    , "use IEEE.STD_LOGIC_1164.ALL"
    , "use IEEE.NUMERIC_STD.ALL"
    , "use work.all"
    , "use work.types.all"
    ]


entity :: Component -> VHDLM Doc
entity c = do
    rec (p,ls) <- fmap unzip (ports (maximum ls))
    "entity" <+> text (componentName c) <+> "is" <$>
      (case p of
         [] -> empty
         _  -> indent 2 ("port" <>
                         parens (align $ vcat $ punctuate semi (A.pure p)) <>
                         semi)
      ) <$>
      "end" <> semi
  where
    ports l = sequence
            $ [ (,fromIntegral $ T.length i) A.<$> (fill l (text i) <+> colon <+> "in" <+> vhdlType ty)
              | (i,ty) <- inputs c ] ++
              [ (,fromIntegral $ T.length i) A.<$> (fill l (text i) <+> colon <+> "in" <+> vhdlType ty)
              | (i,ty) <- hiddenPorts c ] ++
              [ (,fromIntegral $ T.length (fst $ output c)) A.<$> (fill l (text (fst $ output c)) <+> colon <+> "out" <+> vhdlType (snd $ output c))
              ]

architecture :: Component -> VHDLM Doc
architecture c =
  nest 2
    ("architecture structural of" <+> text (componentName c) <+> "is" <$$>
     decls (declarations c)) <$$>
  nest 2
    ("begin" <$$>
     insts (declarations c)) <$$>
    "end" <> semi

-- | Convert a Netlist HWType to a VHDL type
vhdlType :: HWType -> VHDLM Doc
vhdlType hwty = do
  when (needsTyDec hwty) (_1 %= HashSet.insert (mkVecZ hwty))
  vhdlType' hwty

vhdlType' :: HWType -> VHDLM Doc
vhdlType' Bit             = "std_logic"
vhdlType' Bool            = "boolean"
vhdlType' (Clock _)       = "std_logic"
vhdlType' (Reset _)       = "std_logic"
vhdlType' Integer         = "integer"
vhdlType' (Signed n)      = if n == 0 then "signed (0 downto 1)"
                                      else "signed" <> parens (int (n-1) <+> "downto 0")
vhdlType' (Unsigned n)    = if n == 0 then "unsigned (0 downto 1)"
                                      else "unsigned" <> parens ( int (n-1) <+> "downto 0")
vhdlType' (Vector n Bit)  = "std_logic_vector" <> parens (int (n-1) <+> "downto 0")
vhdlType' (Vector n elTy) = "array_of_" <> tyName elTy <> parens (int (n-1) <+> "downto 0")
vhdlType' t@(SP _ _)      = "std_logic_vector" <> parens (int (typeSize t - 1) <+> "downto 0")
vhdlType' t@(Sum _ _)     = case typeSize t of
                              0 -> "unsigned (0 downto 1)"
                              n -> "unsigned" <> parens (int (n -1) <+> "downto 0")
vhdlType' t@(Product _ _) = tyName t
vhdlType' Void            = "std_logic_vector" <> parens (int (-1) <+> "downto 0")

-- | Convert a Netlist HWType to the root of a VHDL type
vhdlTypeMark :: HWType -> VHDLM Doc
vhdlTypeMark hwty = do
  when (needsTyDec hwty) (_1 %= HashSet.insert (mkVecZ hwty))
  vhdlTypeMark' hwty
  where
    vhdlTypeMark' Bit             = "std_logic"
    vhdlTypeMark' Bool            = "boolean"
    vhdlTypeMark' (Clock _)       = "std_logic"
    vhdlTypeMark' (Reset _)       = "std_logic"
    vhdlTypeMark' Integer         = "integer"
    vhdlTypeMark' (Signed _)      = "signed"
    vhdlTypeMark' (Unsigned _)    = "unsigned"
    vhdlTypeMark' (Vector _ Bit)  = "std_logic_vector"
    vhdlTypeMark' (Vector _ elTy) = "array_of_" <> tyName elTy
    vhdlTypeMark' (SP _ _)        = "std_logic_vector"
    vhdlTypeMark' (Sum _ _)       = "unsigned"
    vhdlTypeMark' t@(Product _ _) = tyName t
    vhdlTypeMark' t               = error $ $(curLoc) ++ "vhdlTypeMark: " ++ show t

tyName :: HWType -> VHDLM Doc
tyName Integer           = "integer"
tyName Bit               = "std_logic"
tyName Bool              = "boolean"
tyName (Vector n Bit)    = "std_logic_vector_" <> int n
tyName (Vector n elTy)   = "array_of_" <> int n <> "_" <> tyName elTy
tyName (Signed n)        = "signed_" <> int n
tyName (Unsigned n)      = "unsigned_" <> int n
tyName t@(Sum _ _)       = "unsigned_" <> int (typeSize t)
tyName t@(Product _ _)   = makeCached t _3 prodName
  where
    prodName = do i <- _2 <<%= (+1)
                  "product" <> int i
tyName t@(SP _ _)        = "std_logic_vector_" <> int (typeSize t)
tyName _ = empty

-- | Convert a Netlist HWType to an error VHDL value for that type
vhdlTypeErrValue :: HWType -> VHDLM Doc
vhdlTypeErrValue Bit                 = "'1'"
vhdlTypeErrValue Bool                = "true"
vhdlTypeErrValue Integer             = "integer'high"
vhdlTypeErrValue (Signed _)          = "(others => 'X')"
vhdlTypeErrValue (Unsigned _)        = "(others => 'X')"
vhdlTypeErrValue (Vector _ elTy)     = parens ("others" <+> rarrow <+> vhdlTypeErrValue elTy)
vhdlTypeErrValue (SP _ _)            = "(others => 'X')"
vhdlTypeErrValue (Sum _ _)           = "(others => 'X')"
vhdlTypeErrValue (Product _ elTys)   = tupled $ mapM vhdlTypeErrValue elTys
vhdlTypeErrValue (Reset _)           = "'X'"
vhdlTypeErrValue (Clock _)           = "'X'"
vhdlTypeErrValue Void                = "(0 downto 1 => 'X')"

decls :: [Declaration] -> VHDLM Doc
decls [] = empty
decls ds = do
    rec (dsDoc,ls) <- fmap (unzip . catMaybes) $ mapM (decl (maximum ls)) ds
    case dsDoc of
      [] -> empty
      _  -> vcat (punctuate semi (A.pure dsDoc)) <> semi

decl :: Int ->  Declaration -> VHDLM (Maybe (Doc,Int))
decl l (NetDecl id_ ty netInit) = Just A.<$> (,fromIntegral (T.length id_)) A.<$>
  "signal" <+> fill l (text id_) <+> colon <+> vhdlType ty <> (maybe empty (\e -> " :=" <+> expr False e) netInit)

decl _ _ = return Nothing

insts :: [Declaration] -> VHDLM Doc
insts [] = empty
insts is = vcat . punctuate linebreak . fmap catMaybes $ mapM inst is

-- | Turn a Netlist Declaration to a VHDL concurrent block
inst :: Declaration -> VHDLM (Maybe Doc)
inst (Assignment id_ e) = fmap Just $
  text id_ <+> larrow <+> expr False e <> semi

inst (CondAssignment id_ scrut es) = fmap Just $
  text id_ <+> larrow <+> align (vcat (conds es)) <> semi
    where
      conds :: [(Maybe Expr,Expr)] -> VHDLM [Doc]
      conds []                = return []
      conds [(_,e)]           = expr False e <:> return []
      conds ((Nothing,e):_)   = expr False e <:> return []
      conds ((Just c ,e):es') = (expr False e <+> "when" <+> parens (expr True scrut <+> "=" <+> expr True c) <+> "else") <:> conds es'

inst (InstDecl nm lbl pms) = fmap Just $
    nest 2 $ text lbl <> "_comp_inst" <+> colon <+> "entity"
              <+> text nm <$$> pms' <> semi
  where
    pms' = do
      rec (p,ls) <- fmap unzip $ sequence [ (,fromIntegral (T.length i)) A.<$> fill (maximum ls) (text i) <+> "=>" <+> expr False e | (i,e) <- pms]
      nest 2 $ "port map" <$$> tupled (A.pure p)

inst (BlackBoxD bs) = fmap Just $ string bs

inst _ = return Nothing

-- | Turn a Netlist expression into a VHDL expression
expr :: Bool -- ^ Enclose in parenthesis?
     -> Expr -- ^ Expr to convert
     -> VHDLM Doc
expr _ (Literal sizeM lit)                           = exprLit sizeM lit
expr _ (Identifier id_ Nothing)                      = text id_
expr _ (Identifier id_ (Just (Indexed (ty@(SP _ args),dcI,fI)))) = fromSLV argTy id_ start end
  where
    argTys   = snd $ args !! dcI
    argTy    = argTys !! fI
    argSize  = typeSize argTy
    other    = otherSize argTys (fI-1)
    start    = typeSize ty - 1 - conSize ty - other
    end      = start - argSize + 1

expr _ (Identifier id_ (Just (Indexed (ty@(Product _ _),_,fI)))) = text id_ <> dot <> tyName ty <> "_sel" <> int fI
expr _ (Identifier id_ (Just (DC (ty@(SP _ _),_)))) = text id_ <> parens (int start <+> "downto" <+> int end)
  where
    start = typeSize ty - 1
    end   = typeSize ty - conSize ty

expr _ (Identifier id_ (Just _)) = text id_
expr _ (DataCon ty@(Vector 1 _) _ [e])           = vhdlTypeMark ty <> "'" <> parens (int 0 <+> rarrow <+> expr False e)
expr _ e@(DataCon ty@(Vector _ _) _ [e1,e2])     = vhdlTypeMark ty <> "'" <> case vectorChain e of
                                                     Just es -> tupled (mapM (expr False) es)
                                                     Nothing -> parens (expr False e1 <+> "&" <+> expr False e2)
expr _ (DataCon ty@(SP _ args) (Just (DC (_,i))) es) = assignExpr
  where
    argTys     = snd $ args !! i
    dcSize     = conSize ty + sum (map typeSize argTys)
    dcExpr     = expr False (dcToExpr ty i)
    argExprs   = zipWith toSLV argTys es -- (map (expr False) es)
    extraArg   = case typeSize ty - dcSize of
                   0 -> []
                   n -> [exprLit (Just n) (NumLit 0)]
    assignExpr = "std_logic_vector'" <> parens (hcat $ punctuate " & " $ sequence (dcExpr:argExprs ++ extraArg))

expr _ (DataCon ty@(Sum _ _) (Just (DC (_,i))) []) = "to_unsigned" <> tupled (sequence [int i,int (typeSize ty)])
expr _ (DataCon ty@(Product _ _) _ es)             = tupled $ zipWithM (\i e -> tName <> "_sel" <> int i <+> rarrow <+> expr False e) [0..] es
  where
    tName = tyName ty

expr b (BlackBoxE bs (Just (DC (ty@(SP _ _),_)))) = parenIf b $ parens (string bs) <> parens (int start <+> "downto" <+> int end)
  where
    start = typeSize ty - 1
    end   = typeSize ty - conSize ty
expr b (BlackBoxE bs _) = parenIf b $ string bs

expr _ (DataTag Bool (Left e))           = "false when" <+> expr False e <+> "= 0 else true"
expr _ (DataTag Bool (Right e))          = "1 when" <+> expr False e <+> "else 0"
expr _ (DataTag Bit (Left e))            = "'0' when" <+> expr False e <+> "= 0 else '1'"
expr _ (DataTag Bit (Right e))           = "0 when" <+> expr False e <+> "= '0' else 1"
expr _ (DataTag hty@(Sum _ _) (Left e))  = "to_unsigned" <> tupled (sequence [expr False e,int (typeSize hty)])
expr _ (DataTag (Sum _ _) (Right e))     = "to_integer" <> parens (expr False e)

expr _ (DataTag (Product _ _) (Right _)) = int 0
expr _ (DataTag hty@(SP _ _) (Right e))  = "to_integer" <> parens
                                                ("unsigned" <> parens
                                                (expr False e <> parens
                                                (int start <+> "downto" <+> int end)))
  where
    start = typeSize hty - 1
    end   = typeSize hty - conSize hty

expr _ (DataTag (Vector 0 _) (Right _)) = int 0
expr _ (DataTag (Vector _ _) (Right _)) = int 1

expr _ _ = empty

otherSize :: [HWType] -> Int -> Int
otherSize _ n | n < 0 = 0
otherSize []     _    = 0
otherSize (a:as) n    = typeSize a + otherSize as (n-1)

vectorChain :: Expr -> Maybe [Expr]
vectorChain (DataCon (Vector _ _) Nothing _)        = Just []
vectorChain (DataCon (Vector 1 _) (Just _) [e])     = Just [e]
vectorChain (DataCon (Vector _ _) (Just _) [e1,e2]) = Just e1 <:> vectorChain e2
vectorChain _                                       = Nothing

exprLit :: Maybe Size -> Literal -> VHDLM Doc
exprLit Nothing   (NumLit i) = int i
exprLit (Just sz) (NumLit i) = bits (toBits sz i)
exprLit _         (BoolLit t) = if t then "true" else "false"
exprLit _         (BitLit b) = squotes $ bit_char b
exprLit _         l          = error $ $(curLoc) ++ "exprLit: " ++ show l

toBits :: Integral a => Int -> a -> [Bit]
toBits size val = map (\x -> if odd x then H else L)
                $ reverse
                $ take size
                $ map (`mod` 2)
                $ iterate (`div` 2) val

bits :: [Bit] -> VHDLM Doc
bits = dquotes . hcat . mapM bit_char

bit_char :: Bit -> VHDLM Doc
bit_char H = char '1'
bit_char L = char '0'
bit_char U = char 'U'
bit_char Z = char 'Z'

toSLV :: HWType -> Expr -> VHDLM Doc
toSLV Bit          e = parens (int 0 <+> rarrow <+> expr False e)
toSLV Bool         e = "toSLV" <> parens (expr False e)
toSLV Integer      e = "std_logic_vector" <> parens ("to_signed" <> tupled (sequence [expr False e,int 32]))
toSLV (Signed _)   e = "std_logic_vector" <> parens (expr False e)
toSLV (Unsigned _) e = "std_logic_vector" <> parens (expr False e)
toSLV (Sum _ _)    e = "std_logic_vector" <> parens (expr False e)
toSLV t@(Product _ tys) (Identifier id_ Nothing) = do
    selIds' <- sequence selIds
    encloseSep lparen rparen " & " (zipWithM toSLV tys selIds')
  where
    tName    = tyName t
    selNames = map (fmap (displayT . renderOneLine) ) [text id_ <> dot <> tName <> "_sel" <> int i | i <- [0..(length tys)-1]]
    selIds   = map (fmap (\n -> Identifier n Nothing)) selNames
toSLV (Product _ tys) (DataCon _ _ es) = encloseSep lparen rparen " & " (zipWithM toSLV tys es)
toSLV (SP _ _) e = expr False e
toSLV (Vector _ Bit) e = expr False e
toSLV (Vector n elTy) (Identifier id_ Nothing) = do
    selIds' <- sequence selIds
    parens (encloseSep lparen rparen " & " (mapM (toSLV elTy) selIds'))
  where
    selNames = map (fmap (displayT . renderOneLine) ) $ reverse [text id_ <> parens (int i) | i <- [0 .. (n-1)]]
    selIds   = map (fmap (`Identifier` Nothing)) selNames
toSLV (Vector n elTy) (DataCon _ _ es) = encloseSep lparen rparen " & " (zipWithM toSLV [elTy,Vector (n-1) elTy] es)
toSLV hty      e = error $ $(curLoc) ++  "toSLV: ty:" ++ show hty ++ "\n expr: " ++ show e

fromSLV :: HWType -> Identifier -> Int -> Int -> VHDLM Doc
fromSLV Bit               id_ start _   = text id_ <> parens (int start)
fromSLV Bool              id_ start _   = "fromSL" <> parens (text id_ <> parens (int start))
fromSLV Integer           id_ start end = "to_integer" <> parens (fromSLV (Signed 32) id_ start end)
fromSLV (Signed _)        id_ start end = "signed" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV (Unsigned _)      id_ start end = "unsigned" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV (Sum _ _)         id_ start end = "unsigned" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV t@(Product _ tys) id_ start _   = tupled $ zipWithM (\s e -> s <+> rarrow <+> e) selNames args
  where
    tName      = tyName t
    selNames   = [tName <> "_sel" <> int i | i <- [0..]]
    argLengths = map typeSize tys
    starts     = start : snd (mapAccumL ((join (,) .) . (-)) start argLengths)
    ends       = map (+1) (tail starts)
    args       = zipWith3 (`fromSLV` id_) tys starts ends

fromSLV (SP _ _)          id_ start end = text id_ <> parens (int start <+> "downto" <+> int end)
fromSLV (Vector _ Bit)    id_ start end = text id_ <> parens (int start <+> "downto" <+> int end)
fromSLV (Vector n elTy)   id_ start _   = tupled args
  where
    argLength = typeSize elTy
    starts    = take (n + 1) $ iterate (subtract argLength) start
    ends      = map (+1) (tail starts)
    args      = zipWithM (fromSLV elTy id_) starts ends
fromSLV hty               _   _     _   = error $ $(curLoc) ++ "fromSLV: " ++ show hty

dcToExpr :: HWType -> Int -> Expr
dcToExpr ty i = Literal (Just $ conSize ty) (NumLit i)

larrow :: VHDLM Doc
larrow = "<="

rarrow :: VHDLM Doc
rarrow = "=>"

parenIf :: Monad m => Bool -> m Doc -> m Doc
parenIf True  = parens
parenIf False = id

punctuate' :: Monad m => m Doc -> m [Doc] -> m Doc
punctuate' s d = vcat (punctuate s d) <> s
