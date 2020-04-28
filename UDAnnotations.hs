module UDAnnotations where

import UDConcepts
import PGF hiding (CncLabels)
import GFConcepts

import qualified Data.Map as M
import Data.List
import Data.Char
import Data.Maybe

--------

data UDEnv = UDEnv {
  udFormat    :: String, -- default .conllu
  absLabels   :: AbsLabels,
  cncLabels   :: Language -> CncLabels,
  pgfGrammar  :: PGF,
  actLanguage :: Language,
  startCategory :: PGF.Type
  }

getEnv :: String -> String -> String -> IO UDEnv
getEnv pref eng cat = do
  pgf <- readPGF (stdGrammarFile pref)
  abslabels <- readFile (stdAbsLabelsFile pref) >>= return . pAbsLabels
  cnclabels <- readFile (stdCncLabelsFile pref eng) >>= return . const . pCncLabels
  let env = mkUDEnv pgf abslabels cnclabels (stdLanguage pref eng) cat
  putStrLn $ unlines $ checkAbsLabels env abslabels
  return $ addMissing env
  
mkUDEnv pgf absl cncl eng cat =
  initUDEnv {pgfGrammar = pgf, absLabels = absl, cncLabels = cncl, actLanguage = eng, startCategory = maybe undefined id $ readType cat}
initUDEnv =
  UDEnv "conllu" initAbsLabels (const initCncLabels) (error "no pgf") (error "no language") (error "no startcat")


stdLanguage pref eng = mkLanguage $ tail (dropWhile (/='/') pref ++ eng)
stdGrammarFile pref = pref ++ ".pgf"
stdAbsLabelsFile pref = pref ++ ".labels"
stdCncLabelsFile pref eng = pref ++ eng ++ ".labels"
mkLanguage =  maybe undefined id . readLanguage

isEnvUD2 env = annotGuideline (absLabels env) == Just "UD2"

parseEng env s = head $ parse (pgfGrammar env) (actLanguage env) (startCategory env) s

data AbsLabels = AbsLabels {
  annotGuideline    :: Maybe String,
  funLabels         :: M.Map CId [Label],
  catLabels         :: M.Map CId String,
  auxCategories     :: M.Map CId String,  -- ud2gf only
  macroFunctions    :: M.Map CId (AbsType,(([CId],AbsTree),[(Label,[UDData])])), -- ud2gf only
  altFunLabels      :: M.Map CId [[Label]], -- all labellings, ud2gf only, added by #altfun
  disabledFunctions :: M.Map Fun ()  -- list of functions not to be used in ud2gf, added by #disable
  }

initAbsLabels :: AbsLabels
initAbsLabels = AbsLabels (Just "UD2") M.empty M.empty M.empty M.empty M.empty M.empty

-- is be VERB cop head
data CncLabels = CncLabels {
  wordLabels    :: M.Map String (String,[UDData]),         -- word -> (lemma,morpho)          e.g. #word been be AUX  Tense=Past|VerbForm=Part
  lemmaLabels   :: M.Map (Fun,String) (Cat,(Label,Label)), -- (fun,lemma) -> (auxcat,(label,targetLabel)), e.g. #lemma UseComp be Cop cop head
  morphoLabels  :: M.Map (Cat,Int) [UDData],               -- (cat,int) -> morphotag,              e.g. #morpho V,V2,VS 0 VerbForm=Inf
  discontLabels :: M.Map (Cat,Int) (POS,Label,Label),      -- (cat,field) -> (pos,label,target)    e.g. #discont  V2  5,ADP,case,obj   6,ADV,advmod,head
  multiLabels   :: M.Map Cat (Bool, Label)                 -- cat -> (if-head-first, other-labels) e.g. #multiword Prep head first fixed
  }

initCncLabels = CncLabels M.empty M.empty M.empty M.empty M.empty

-- check the soundness of labels

checkAbsLabels :: UDEnv -> AbsLabels -> [String]
checkAbsLabels env als =
  ---- check completeness, too, as well as if a function is included twice
  concatMap chFun funs ++
  ["no annotation for function " ++ showCId f |  -- not needed if 0 or 1 args
       (f,(_,args)) <- allfuns,
       length args > 1,
       Nothing <- [M.lookup f (funLabels als)]] ++ 
  concatMap chCat cats ++
  take 1 ["no annotation for category " ++ showCId c |  -- needed only if cat has 0-place functions
       c <- categories pgf, 
       Nothing <- [M.lookup c (catLabels als)],
       _ <- [() | (f,(val,[])) <- allfuns, c==val]
       ] 

 where
  pgf  = pgfGrammar env
  funs = M.toList (funLabels als)
  cats = M.toList (catLabels als)
  allfuns = pgf2functions pgf

  chFun (f,ls) =
    ["unknown function " ++ showCId f | notElem f (map fst allfuns)] ++
    ["no head in "       ++ showCId f | notElem "head" ls] ++
    ["wrong number of labels in " ++ showCId f ++ " : " ++ showType [] typ |
      Just typ <- [functionType pgf f],
      let (hs,_,_) = unType typ,
      length hs /= length ls
      ]
      ++
      if (isEnvUD2 env) then concatMap checkUDLabel (filter (/="head") ls) else []

  chCat (c,p) =
    ["unknown category " ++ showCId c | notElem c (categories pgf)] ++
    if (isEnvUD2 env) then checkUDPOS p else []


-- get the labels from file

pAbsLabels :: String -> AbsLabels
pAbsLabels = dispatch . map words . uncomment . lines
 where
  dispatch = foldr add initAbsLabels
  add ws labs = case ws of
    "#guidelines":w:_   -> labs{annotGuideline = Just w} --- overwrites earlier declaration
    "#fun":f:xs         -> labs{funLabels = M.insert (mkCId f) xs (funLabels labs)}
    "#cat":c:p:[]       -> labs{catLabels = M.insert (mkCId c) p (catLabels labs)}
    "#auxcat":c:p:[]    -> labs{auxCategories = M.insert (mkCId c) p (auxCategories labs)}
    "#auxfun":f:typdef  -> labs{macroFunctions = M.insert (mkCId f) (pMacroFunction (f:typdef)) (macroFunctions labs)}
    "#disable":fs       -> labs{disabledFunctions = inserts [(mkCId f,()) | f <- fs] (disabledFunctions labs)}
    "#altfun":f:xs      -> labs{altFunLabels = M.insertWith (++) (mkCId f) [xs] (altFunLabels labs)}
    
  --- fun or cat without keywords, for backward compatibility
    f:xs@(_:_:_)        -> labs{funLabels = M.insert (mkCId f) xs (funLabels labs)}
    f:"head":[]         -> labs{funLabels = M.insert (mkCId f) [head_Label] (funLabels labs)}
    c:p:[]              -> labs{catLabels = M.insert (mkCId c) p (catLabels labs)}

 --- ignores ill-formed lines silently
    _ -> labs 

addMissing env = env {
  absLabels = (absLabels env){
    funLabels =
      foldr (\ (k,v) m -> M.insert k v m) (funLabels (absLabels env))
        [(f,[head_Label]) | 
          (f,(_,[_])) <- pgf2functions (pgfGrammar env),
          Nothing <- [M.lookup f (funLabels (absLabels env))]
          ]
       }
    }

-- #macro PredCop np cop comp : NP -> Cop -> Comp -> Cl = PredVP np (UseComp comp) ; subj cop head
-- CId (AbsType,(([CId],AbsTree),[Label]))
pMacroFunction (f:ws) = case break (==":") ws of
  (xs,_:ww) -> case break (=="=") ww of
    (ty,_:tl) -> case break (==";") tl of
      (df,_:ls) -> (pAbsType (unwords ty), ((map mkCId xs, pAbsTree (unwords df)),map labelAndMorpho ls))
      _ -> error $ "missing labels in #macro " ++ unwords (f:ws)
    _ -> error $ "missing definition in #macro " ++ unwords (f:ws)
  _ -> error $ "missing type in #macro " ++ unwords (f:ws)

inserts kvs mp = foldr (\ (k,v) m -> M.insert k v m) mp kvs

pCncLabels :: String -> CncLabels
pCncLabels = dispatch . map words . uncomment . lines
 where
  dispatch = foldr add initCncLabels
  add ws labs = case ws of
    "#morpho"  :cs:i:p:_  | all isDigit i -> labs{morphoLabels = inserts [((mkCId c,read i),(prs p)::[UDData]) | c <- getSeps (==',') cs] (morphoLabels labs)}
    "#word"    :w:l:m:_ -> labs{wordLabels   = M.insert w (l,prs m) (wordLabels labs)}
    "#lemma"   :w:l:c:p:t:_ -> labs{lemmaLabels  = inserts [((mkCId f,l),(mkCId c,(p,t))) | f <- getSeps (==',') w] (lemmaLabels labs)}
    "#discont" :c:h:ps    -> labs{discontLabels = inserts
                               ([((mkCId c,i),(x_POS,head_Label,root_Label)) | is:"head":_ <- [getSeps (==',') h], i <- readRange is] ++ -- bogus pos and target, to be thrown away
                                [((mkCId c,read i),(pos,lab,hd))                | p <- ps, i:pos:lab:hd:_ <- [getSeps (==',') p]])
                                   (discontLabels labs)}
    "#multiword":c:hp:lab:_  -> labs{multiLabels = M.insert (mkCId c) (hp/="head-last",lab) (multiLabels labs)}
    _ -> labs --- ignores silently

  readRange s = case break (=='-') s of
    (a@(_:_),_:b@(_:_)) | all isDigit a && all isDigit b -> [read a .. read b]
    _ -> error $ "no valid numeric range from " ++ s

uncomment :: [String] -> [String]
uncomment = filter (not . all isSpace)  . map uncom
 where
  uncom cs = case cs of
    '-':'-':_ -> ""
    c:cc -> c:uncom cc
    _ -> cs
    

--------------------------
-- interfacing with GF
--------------------------

-- valcat, [argcat * label]
type LabelledType = (Cat,[(Cat,(Label,[UDData]))])  -- UDData says that certain morpho parameters must be present

mkLabelledType :: Type -> [String] -> LabelledType
mkLabelledType typ labs = case unType typ of
  (hypos,cat,_) -> (cat, zip [valCat ty | (_,_,ty) <- hypos] (map labelAndMorpho labs))
 where
  valCat ty = case unType ty of
    (_,cat,_) -> cat

labelAndMorpho :: String -> (Label,[UDData])
labelAndMorpho s = case break (=='[') s of  -- obj[Num=Sing]
    (l,_:m) -> (l, prs (init m))
    _ -> (s,[])

isEndoType, isExoType :: LabelledType -> Bool
isEndoType labtyp@(val,args) = elem val (map fst args)
isExoType = not . isEndoType

catsForPOS :: UDEnv -> M.Map POS [Either Cat Cat]
catsForPOS env = M.fromListWith (++) $ 
  [(p,[Left  c]) | (c, p) <- M.assocs (catLabels (absLabels env))] ++
  [(p,[Right c]) | (c, p) <- M.assocs (auxCategories (absLabels env))]


----------------------------------------
-- special applications of annotations
----------------------------------------

-- CId (AbsType,(([CId],AbsTree),[Label]))
expandMacro :: UDEnv -> AbsTree -> AbsTree
expandMacro env tr@(RTree f ts) = case M.lookup f (macroFunctions (absLabels env)) of
  Just (_,((xx,df),_)) -> subst (zip xx (map (expandMacro env) ts)) df
  _ -> RTree f (map (expandMacro env) ts)
 where
   subst xts t@(RTree h us) = case us of
     [] -> maybe t id (lookup h xts)
     _  -> RTree h (map (subst xts) us)

----------------------------------------------------------------------------
-- used in ud2gf: macros + real abstract functions, except the disabled ones

allFunsEnv :: UDEnv -> [(Fun,LabelledType)]
allFunsEnv env =
    [(f,(val,zip args ls))  |
      (f,((val,args),((xx,df),ls))) <- M.assocs (macroFunctions (absLabels env))]
     ++
    [(f, mkLabelledType typ labels) |
      (f,labels) <- M.assocs (funLabels (absLabels env)),
                    M.notMember f (disabledFunctions (absLabels env)),
                    not (isBackupFunction f), ---- apply backups only later
      Just typ   <- [functionType (pgfGrammar env) f]
    ]
     ++
    [(f, mkLabelledType typ labels) |
      (f,labelss) <- M.assocs (altFunLabels (absLabels env)),
      labels      <- labelss,
      Just typ    <- [functionType (pgfGrammar env) f]
    ]

mkBackup ast cat = RTree (mkCId (showCId cat ++ "Backup")) [ast]
isBackupFunction f = isSuffixOf "Backup" (showCId f)
