module Text.OpenGL.Api where

import Control.Applicative ((<$>))
import Data.List (find, groupBy, intersperse, nubBy, partition)
import Data.Char (toUpper)
import qualified Data.Map as M
import Data.Function (on)
import Numeric (showHex)

import System.IO.Unsafe (unsafePerformIO)

import qualified Text.OpenGL.Spec as Spec
import Text.OpenGL.Spec (
  Value,
  ReturnType, ParamType, Passing, Category, Question, Wglflag, Dlflag,
  Glxflag, FExtension, Glfflag,
  TmType(..), Passing(..))

-- gl.spec

data Function = Function
  { funReturnType :: ReturnType
  , funName :: String
  , funParameters :: [Parameter]
  , funCategory :: Category
  , funOldCategory :: Maybe Category
  , funSubcategory :: Maybe String
  , funVersion :: Maybe (Int,Int)
  , funGlxropcode :: Maybe Question
  , funOffset :: Maybe (Maybe Question)
  , funWglflags :: Maybe [Wglflag]
  , funDlflags :: Maybe Dlflag
  , funGlxflags :: Maybe ([Glxflag],Maybe [Glxflag])
  , funGlxsingle :: Maybe Question
  , funDeprecated :: Maybe (Int,Int)
  , funExtension :: Maybe [FExtension]
  , funGlxvendorpriv :: Maybe Question
  , funGlfflags :: Maybe [Glfflag]
  , funAllowInside :: Bool
  , funVectorequiv :: Maybe String
  , funGlxvectorequiv :: Maybe String
  , funAlias :: Maybe String
  , funGlextmask :: Maybe [String]
  }
  deriving Show

data Parameter = Parameter String String Bool Passing
  deriving Show

mkFunction :: String -> [String] -> [Spec.Prop] -> Function
mkFunction a b (Spec.Return r:ps) =
  if length b /= length params
  then error $ "The list of properties hasn't the same number of " ++
         "parameters than the list af arguments."
  else Function
    { funReturnType = r
    , funName = a
    , funParameters = args
    , funCategory = c
    , funOldCategory = c'
    , funSubcategory = extractSubcategory ps''
    , funVersion = extractFVersion ps''
    , funGlxropcode = extractGlxropcode ps''
    , funOffset = extractOffset ps''
    , funWglflags = extractWglflags ps''
    , funDlflags = extractDlflags ps''
    , funGlxflags = extractGlxflags ps''
    , funGlxsingle = extractGlxsingle ps''
    , funDeprecated = extractDeprecated ps''
    , funExtension = extractFExtension ps''
    , funGlxvendorpriv = extractGlxvendorpriv ps''
    , funGlfflags = extractGlfflags ps''
    , funAllowInside = extractAllowInside ps''
    , funVectorequiv = extractVectorequiv ps''
    , funGlxvectorequiv = extractGlxvectorequiv ps''
    , funAlias = extractAlias ps''
    , funGlextmask = extractGlextmask ps''
    }
  where
  (params,ps') = partition f ps
  ([Spec.Category c c'],ps'') = partition h ps'
  f (Spec.Param _ _) = True
  f _ = False
  h (Spec.Category _ _) = True
  h _ = False
  args = zipWith g b params
  g x0 (Spec.Param x1 (Spec.ParamType x y z))
    | x0 == x1 = Parameter x0 x y z
    | otherwise = error "argument and parameter don't match"
mkFunction _ _ _ =
  error "The list of properties doesn't begin with the return type."

extractFunctions_ :: [Spec.FunLine] -> [(String,[String],[Spec.Prop])]
extractFunctions_ xs = go y ys
  where
  (y:ys) = filter f xs
  f (Spec.Function _ _) = True
  f (Spec.Prop _) = True
  f _ = False
  g (Spec.Function _ _) = True
  g _ = False
  e (Spec.Prop p) = p
  go (Spec.Function a b) zs =
    let (props,r) = break g zs
    in case r of
      (fun2:rest) -> (a,b,map e props) : go fun2 rest
      [] -> [(a,b,map e props)]

data HeaderItem =
    HPassthru String
  | HNewCategory Category [String] -- The strings are passthru lines
  | HFunctions [Function] [String] -- idem
  deriving Show

showHeaderItem tm i = case i of
  HPassthru [] -> [""]
  HPassthru (_:str) -> [str]
  HNewCategory c ss ->
    [ "#ifndef GL_" ++ cCategory c
    , "#define GL_" ++ cCategory c ++ " 1"
    ] ++ map (drop 1) ss ++
    [ "#endif",""
    ]
  HFunctions fs ss ->
    [ "#ifndef GL_" ++ cCategory (funCategory $ head fs)
    , "#define GL_" ++ cCategory (funCategory $ head fs) ++ " 1"
    ] ++ map (drop 1) ss ++
    [ "#ifdef GL_GLEXT_PROTOTYPES"
    ] ++ map (cDeclaration tm) fs ++
    [ "#endif /* GL_GLEXT_PROTOTYPES */"
    ] ++ map (cDeclaration' tm) fs ++
    [ "#endif", ""
    ]

cCategory c = case c of
  Spec.Version i j b -> "VERSION_" ++ show i ++ "_" ++ show j ++
    if b then "_DEPRECATED" else ""
  Spec.Extension e s b -> Spec.showExtension e ++ "_" ++ s ++
    if b then "_DEPRECATED" else ""
  Spec.Name s -> s

extractHeaderItems :: [Spec.FunLine] -> [HeaderItem]
extractHeaderItems [] = []
extractHeaderItems xs = go xs
  where
  g (Spec.Prop _) = False
  g _ = True
  e (Spec.Prop p) = p
  go (Spec.FPassthru str : zs) =
    HPassthru str : go zs
  go (Spec.NewCategory c : zs) =
    goC (HNewCategory c []) zs
  go (Spec.Function a b : zs) =
    let (props,r) = break g zs
        f = mkFunction a b $ map e props
    in if hasHeaderCategory f
       then goF (HFunctions [f] []) r
       else go r
  go (z:zs) = go zs
  go [] = []
  goC (HNewCategory c ps) (Spec.FPassthru str : zs) =
    goC (HNewCategory c (ps++[str])) zs
  goC (HNewCategory c ps) (Spec.NewCategory c' : zs) =
    HNewCategory c ps : goC (HNewCategory c' []) zs
  goC (HNewCategory c ps) (Spec.Function a b : zs) =
    let (props,r) = break g zs
        f = mkFunction a b $ map e props
    in if hasHeaderCategory f
          then HNewCategory c ps : goF (HFunctions [f] []) r
          else goC (HNewCategory c ps) r
  goC c (z:zs) = goC c zs
  goC c [] = [c]
  goF (HFunctions fs ps) (Spec.FPassthru str : zs) =
    goF (HFunctions fs (ps++[str])) zs
  goF fs (Spec.NewCategory c' : zs) =
    fs : goC (HNewCategory c' []) zs
  goF (HFunctions fs ps) (Spec.Function a b : zs) =
    let (props,r) = break g zs
        f = mkFunction a b $ map e props
        newf = case fs of
          [] -> False
          (f':_) -> funCategory f /= funCategory f'
    in if newf
       then HFunctions fs ps : goF (HFunctions [f] []) r
       else goF (HFunctions (fs++[f]) ps) r
  goF fs (z:zs) = goF fs zs
  goF fs [] = [fs]

hasHeaderCategory f = case funCategory f of
  Spec.Version 1 0 _ -> False
  Spec.Version 1 1 _ -> False
  _ -> True

extractFunctions :: [Spec.FunLine] -> [Function]
extractFunctions = map (\(a,b,c) -> mkFunction a b c) . extractFunctions_

-- TODO return Either
extractFunctions'_ :: FilePath -> IO [(String,[String],[Spec.Prop])]
extractFunctions'_ fn = do
  r <- Spec.funLines <$> readFile fn
  case r of
    Left err -> print err >> return []
    Right a -> return $ extractFunctions_ a

-- TODO return Either
extractFunctions' :: FilePath -> IO [Function]
extractFunctions' fn = do
  r <- Spec.funLines <$> readFile fn
  case r of
    Left err -> print err >> return []
    Right a -> return $ extractFunctions a

has :: (Spec.Prop -> Bool) -> (a,b,[Spec.Prop]) -> Bool
has f (_,_,x) = any f x

isReturn (Spec.Return _) = True
isReturn _ = False

isParam (Spec.Param _ _) = True
isParam _ = False

isCategory (Spec.Category _ _) = True
isCategory _ = False

isSubcategory (Spec.Subcategory _) = True
isSubcategory _ = False

isFVersion (Spec.FVersion _ _) = True
isFVersion _ = False

isGlxropcode (Spec.Glxropcode _) = True
isGlxropcode _ = False

isOffset (Spec.Offset _) = True
isOffset _ = False

isWglflags (Spec.Wglflags _) = True
isWglflags _ = False

isDlflags (Spec.Dlflags _) = True
isDlflags _ = False

isGlxflags (Spec.Glxflags _ _) = True
isGlxflags _ = False

isGlxsingle (Spec.Glxsingle _) = True
isGlxsingle _ = False

isDeprecated (Spec.Deprecated _ _) = True
isDeprecated _ = False

isFExtension (Spec.FExtension _) = True
isFExtension _ = False

isGlxvendorpriv (Spec.Glxvendorpriv _) = True
isGlxvendorpriv _ = False

isGlfflags (Spec.Glfflags _) = True
isGlfflags _ = False

isAllowInside Spec.AllowInside = True
isAllowInside _ = False

isVectorequiv (Spec.Vectorequiv _) = True
isVectorequiv _ = False

isGlxvectorequiv (Spec.Glxvectorequiv _) = True
isGlxvectorequiv _ = False

isAlias (Spec.Alias _) = True
isAlias _ = False

isGlextmask (Spec.Glextmask _) = True
isGlextmask _ = False

extractSubcategory l = case filter isSubcategory l of
  [] -> Nothing
  [Spec.Subcategory s] -> Just s
  _ -> error "More than one element"

extractFVersion l = case filter isFVersion l of
  [] -> Nothing
  [Spec.FVersion i j] -> Just (i,j)
  [_,Spec.FVersion i j] -> Just (i,j) -- TODO some functions have two version properties
  _ -> error "More than one element"

extractGlxropcode l = case filter isGlxropcode l of
  [] -> Nothing
  [Spec.Glxropcode q] -> Just q
  _ -> error "More than one element"

extractOffset l = case filter isOffset l of
  [] -> Nothing
  [Spec.Offset mq] -> Just mq
  _ -> error "More than one element"

extractWglflags l = case filter isWglflags l of
  [] -> Nothing
  [Spec.Wglflags fs] -> Just fs
  _ -> error "More than one element"

extractDlflags l = case filter isDlflags l of
  [] -> Nothing
  [Spec.Dlflags fs] -> Just fs
  _ -> error "More than one element"

extractGlxflags l = case filter isGlxflags l of
  [] -> Nothing
  [Spec.Glxflags fs mfs] -> Just (fs,mfs)
  [_,Spec.Glxflags fs mfs] -> Just (fs,mfs) -- TODO some have two properties
  _ -> error "More than one element"

extractGlxsingle l = case filter isGlxsingle l of
  [] -> Nothing
  [Spec.Glxsingle q] -> Just q
  _ -> error "More than one element"

extractDeprecated l = case filter isDeprecated l of
  [] -> Nothing
  [Spec.Deprecated i j] -> Just (i,j)
  _ -> error "More than one element"

extractFExtension l = case filter isFExtension l of
  [] -> Nothing
  [Spec.FExtension es] -> Just es
  _ -> error "More than one element"

extractGlxvendorpriv l = case filter isGlxvendorpriv l of
  [] -> Nothing
  [Spec.Glxvendorpriv q] -> Just q
  _ -> error "More than one element"

extractGlfflags l = case filter isGlfflags l of
  [] -> Nothing
  [Spec.Glfflags fs] -> Just fs
  _ -> error "More than one element"

extractAllowInside l = case filter isAllowInside l of
  [] -> False
  [Spec.AllowInside] -> True
  _ -> error "More than one element"

extractVectorequiv l = case filter isVectorequiv l of
  [] -> Nothing
  [Spec.Vectorequiv s] -> Just s
  _ -> error "More than one element"

extractGlxvectorequiv l = case filter isGlxvectorequiv l of
  [] -> Nothing
  [Spec.Glxvectorequiv s] -> Just s
  _ -> error "More than one element"

extractAlias l = case filter isAlias l of
  [] -> Nothing
  [Spec.Alias s] -> Just s
  _ -> error "More than one element"

extractGlextmask l = case filter isGlextmask l of
  [] -> Nothing
  [Spec.Glextmask ss] -> Just ss
  _ -> error "More than one element"

-- A few checks on the raw function data[0]. The Function representation
-- of this module is written w.r.t. these checks.
--
-- [0]: That is, (String,[String],[Spec.Prop]).

-- For instance, to check if every function has a category:
-- all (has isCategory) <$> extractFunctions'_ "spec-files/opengl/gl.spec"

returns = all (has isReturn)

params = all (has isParam)

categories = all (has isCategory)

subcategories = all (has isSubcategory)

versions = all (has isFVersion)

glxropcodes = all (has isGlxropcode)

offsets = all (has isOffset)

wglflags = all (has isWglflags)

dlflags = all (has isDlflags)

glxflags = all (has isGlxflags)

glxsingles = all (has isGlxsingle)

deprecateds = all (has isDeprecated)

extensions = all (has isFExtension)

glxvendorprivs = all (has isGlxvendorpriv)

glfflags = all (has isGlfflags)

allowinsides = all (has isAllowInside)

vectorequivs = all (has isVectorequiv)

glxvectorequivs = all (has isGlxvectorequiv)

alias = all (has isAlias)

glextmasks = all (has isGlextmask)

checkPresence fn = do
  fs <- extractFunctions'_ fn
  let f x = if x fs
        then putStrLn "always."
        else putStrLn "not always."
  mapM_ f
    [ returns -- always
    , params
    , categories -- always
    , subcategories
    , versions
    , glxropcodes
    , offsets
    , wglflags
    , dlflags
    , glxflags
    , glxsingles
    , deprecateds
    , extensions
    , glxvendorprivs
    , glfflags
    , allowinsides
    , vectorequivs
    , glxvectorequivs
    , alias
    , glextmasks
    ]

showFunction f = unlines $
  [ show $ funReturnType f
  , funName f
  ] ++
  map show (funParameters f) ++
  [ show $ funCategory f
  , show $ funOldCategory f
  , show $ funSubcategory f
  , show $ funVersion f
  , show $ funGlxropcode f
  , show $ funOffset f
  , show $ funWglflags f
  , show $ funDlflags f
  , show $ funGlxflags f
  , show $ funGlxsingle f
  , show $ funDeprecated f
  , show $ funExtension f
  , show $ funGlxvendorpriv f
  , show $ funGlfflags f
  , show $ funAllowInside f
  , show $ funVectorequiv f
  , show $ funGlxvectorequiv f
  , show $ funAlias f
  , show $ funGlextmask f
  ]

-- gl.tm

type TypeMap = M.Map String (TmType,Bool)

mkTypeMap str = case Spec.tmLines str of
  Left err -> Left err
  Right xs -> Right $ foldr f M.empty xs
  where f (Spec.TmComment _) m = m
        f (Spec.TmEntry x t b) m = M.insert x (t,b) m

--

cDeclaration :: TypeMap -> Function -> String
cDeclaration tm f = unwords
  [ "GLAPI"
  , cReturnType (funReturnType f)
  , "APIENTRY"
  , "gl" ++ funName f
  , "(" ++ cParameters tm (funParameters f) ++ ");"
  ]

cDeclaration' :: TypeMap -> Function -> String
cDeclaration' tm f = unwords
  [ "typedef"
  , cReturnType (funReturnType f)
  , "(APIENTRYP PFNGL" ++ map toUpper (funName f) ++ "PROC)"
  , "(" ++ cParameters tm (funParameters f) ++ ");"
  ]

-- TODO use the typeMap, which means maybe regroug ReturnType with the
-- String to lookup the typemap.
cReturnType t = case t of
  Spec.Void -> "void"
  Spec.Boolean -> "GLboolean"
  Spec.VoidPointer -> "GLvoid*"
  Spec.UInt32 -> "GLuint"
  Spec.Int32 -> "GLint"
  Spec.String -> "const GLubyte *"
  Spec.GLEnum -> "GLenum"
  Spec.HandleARB -> "GLhandleARB"
  Spec.BufferOffset -> "GLintptr"
  Spec.FramebufferStatus -> "GLenum"
  Spec.Sync -> "GLsync"
  x -> show x

cParameters tm [] = "void"
cParameters tm p = concat . intersperse ", " $ map (cParameter tm) p

cParameter tm (Parameter x t i p) = c ++ t' ++ x
  where
  t' = case M.lookup t tm of
    Nothing -> "Nothing"
    Just (a,b) -> case p of
      Value -> cType a ++ (if b then " *" else " ")
      Array _ _ -> cType a ++ (if b then "* *" else " *")
      Reference -> cType a ++ (if b then "* *" else " *")
  c = case (p,i) of
    (Array _ _,True) -> "const "
    (Reference,True) -> "const "
    _ -> ""

cType t = case t of
  Star -> "void"
  UnderscoreGLfuncptr -> "_GLfuncptr"
  GLvoidStarConst -> "GLvoid* const"
  x -> show x

--

-- From gl.spec, version means:
-- Core version in which a function was introduced, or against
-- which an extension can be implemented.
withVersion fs ij = filter ((== Just ij) . funVersion) fs

withCategory fs c = filter ((== c) . funCategory) fs

withName fs n = filter ((== n) . funName) fs

-- unsafe read data, for convenience during develoment

functions = unsafePerformIO $ extractFunctions' "spec-files/opengl/gl.spec"

typeMap = unsafePerformIO $ do
  ls <- readFile "spec-files/opengl/gl.tm"
  case mkTypeMap ls of
    Left err -> putStrLn (show err) >> return M.empty
    Right a -> return a

headerItems = unsafePerformIO $ do
  ls <- readFile "spec-files/opengl/gl.spec"
  case Spec.funLines ls of
    Left err -> putStrLn (show err) >> return []
    Right a -> return $ extractHeaderItems a

glextHeader = unlines $
  [ "#ifndef __glext_h_"
  , "#define __glext_h_"
  , ""
  , "#ifdef __cplusplus"
  , "extern \"C\" {"
  , "#endif"
  , ""
  , "/* Header file version number, required by OpenGL ABI for Linux */"
  , "/* This glext.h file was auto-generated from the spec files. */"
  , "/* Current version at http://www.opengl.org/registry/ */"
  , "#define GL_GLEXT_VERSION " ++ show glextVersion
  , "/* Function declaration macros - to move into glplatform.h */"
  , ""
  , "#if defined(_WIN32) && !defined(APIENTRY) && !defined(__CYGWIN__) && !defined(__SCITECH_SNAP__)"
  , "#define WIN32_LEAN_AND_MEAN 1"
  , "#include <windows.h>"
  , "#endif"
  , ""
  , "#ifndef APIENTRY"
  , "#define APIENTRY"
  , "#endif"
  , "#ifndef APIENTRYP"
  , "#define APIENTRYP APIENTRY *"
  , "#endif"
  , "#ifndef GLAPI"
  , "#define GLAPI extern"
  , "#endif"
  , ""
  , "/*************************************************************/"
  , ""
  ] ++
  concatMap cEnumeration es ++
  [ ""
  , "/*************************************************************/"
  , ""
  ] ++
  concatMap (showHeaderItem typeMap) hi ++
  glextEnding
  where
  glextVersion = 63
  hi = rewrite $ nubBy f headerItems
  es = map g . filter hasHeaderCategory' $ groupEnums enums
  -- The "newcategory: NV_fragment_program" is unecessary as some functions
  -- have that category.
  rewrite (HNewCategory
    (Spec.Extension Spec.NV "fragment_program" False) [p] : 
    HFunctions fs ps :
    ys) = HFunctions fs (p:ps) : rewrite ys
  rewrite (x:xs) = x : rewrite xs
  rewrite [] = []
  -- The "newcategory: MESA_ycbcr_texture" is present twice.
  f (HNewCategory (Spec.Extension Spec.MESA "ycbcr_texture" False) [])
    (HNewCategory (Spec.Extension Spec.MESA "ycbcr_texture" False ) []) = True
  f a b = False
  -- The "SGIX_ycrcb_subsample" has no enum in the original glext.h.
  -- The enum "2X_BIT_ATI" is present twice.
  g (Enumeration v@(Spec.Extension Spec.SGIX "ycrcb_subsample" False) _) =
    Enumeration v []
  g (Enumeration c es) = Enumeration c $ nubBy g' es
  g e = e
  g' (EEnum "2X_BIT_ATI" _) (EEnum "2X_BIT_ATI" _) = True
  g' _ _ = False

glextEnding =
  [ ""
  , "#ifdef __cplusplus"
  , "}"
  , "#endif"
  , ""
  , "#endif"
  ]

--

enums = unsafePerformIO $ do
  r <- Spec.enumLines <$> readFile "spec-files/opengl/enumext.spec"
  case r of
    Left err -> putStrLn (show err) >> return []
    Right a -> return a

data Enumeration =
    Enumeration Category [E]
  | EPassthru String
  deriving Show

data E =
    EEnum String Value
  | EPassthru' String
  | EUse String String
  deriving Show

hasHeaderCategory' (Enumeration c _) = case c of
  Spec.Version 1 0 _ -> False
  Spec.Version 1 1 _ -> False
  _ -> True
hasHeaderCategory' _ = True

cEnumeration e = case e of
  Enumeration c es ->
    [ "#ifndef GL_" ++ cCategory c
    ] ++ map cE es ++
    [ "#endif"
    , ""
    ]
  EPassthru str -> [str]

cE e = case e of
  EEnum a b -> "#define GL_" ++ a ++ pad a ++ " " ++ showValue b
  EPassthru' str -> "/* " ++ str ++ "*/"
  EUse _ b -> "/* reuse GL_" ++ b ++ " */"

pad s = replicate (30 - length s) ' '

showValue :: Value -> String
showValue v = case v of
  Spec.Hex i l Nothing -> "0x" ++ showHex' l i
  Spec.Hex i l (Just Spec.U) -> "0x" ++ showHex' l i ++ "u"
  Spec.Hex i l (Just Spec.Ull) -> "0x" ++ showHex' l i ++ "ull"
  Spec.Deci i -> show i
  Spec.Identifier x -> x

showHex' :: Integral a => Int -> a -> String
showHex' l i = replicate (l - length h) '0' ++ h
  where h = map toUpper (showHex i "")

groupEnums xs = go xs
  where
  go (Spec.Comment _ : zs) = go zs
  go (Spec.BlankLine : zs) = go zs
  go (Spec.Start se _ : zs) = goS (Enumeration se []) zs
  go (Spec.Passthru str : zs) = EPassthru str : go zs
  go (Spec.Enum _ _ _ : _) = error "encoutering an Enum before a Start"
  go (Spec.Use _ _ : _) = error "encoutering a Use before a Start"
  go [] = []
  goS e (Spec.Comment _ : zs) = goS e zs
  goS e (Spec.BlankLine : zs) = goS e zs
  goS e (Spec.Start se _ : zs) = e : goS (Enumeration se []) zs
  goS (Enumeration se es) (Spec.Passthru str : zs) =
    goS (Enumeration se (es++[EPassthru' str])) zs
  goS (Enumeration se es) (Spec.Enum a b _ : zs) =
    goS (Enumeration se (es++[EEnum a b])) zs
  goS (Enumeration se es) (Spec.Use a b : zs) =
    goS (Enumeration se (es++[EUse a b])) zs
  goS e [] = [e]

