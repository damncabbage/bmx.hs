{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Test.BMX.Function where

import           Control.Monad.Identity (Identity)
import           Data.Text (Text)
import           Test.QuickCheck

import           BMX.Function
import           BMX.Internal

import           Test.BMX.Arbitrary ()

import           P

-- Couple of units to check that failing items don't consume input, alternative works, etc

-- flattenFunction - runs

flattenFunction :: [Value] -> [Param] -> FunctionT (BMX Identity) a -> Either Text a
flattenFunction v p f = first renderEvalError ee
  >>= either (Left . renderFunctionError) (return . id)
  where ee = runBMX mempty (runFunctionT v p f)

anything :: FunctionT (BMX Identity) [Value]
anything = many value

allParams :: FunctionT (BMX Identity) [Param]
allParams = many value *> many param

--------------------------------------------------------------------------------

-- values get propagated correctly to the function
prop_fun_anyval vs ps = flattenFunction vs ps anything === pure vs

-- params get propagated correctly to the function
prop_fun_anyparam vs ps = flattenFunction vs ps allParams === pure ps

-- functions must use all arguments
prop_fun_no_trailing vs ps = isLeft (flattenFunction vs ps fun) .||. null vs
  where len = length vs
        fun = replicateM (len - 1) value

-- functions can't take more arguments than are there
prop_fun_infinite_arg_works vs ps = isLeft (flattenFunction vs ps fun)
  where len = length vs
        fun = replicateM (len + 1) value

-- functions can't take too many block params
prop_fun_infinite_params vs ps = isLeft (flattenFunction vs ps fun)
  where len = length ps
        fun = replicateM (len + 1) param

-- each combinator works properly
prop_fun_comb_string v ps = (isString v .&&. val === pure v) .||. (not (isString v) .&&. isLeft val)
  where val = flattenFunction [v] ps string
        isString (StringV _) = True
        isString _ = False

prop_fun_comb_num v ps = (isNum v .&&. val === pure v) .||. (not (isNum v) .&&. isLeft val)
  where val = flattenFunction [v] ps number
        isNum (IntV _) = True
        isNum _ = False

prop_fun_comb_bool v ps = (isBool v .&&. val === pure v) .||. (not (isBool v) .&&. isLeft val)
  where val = flattenFunction [v] ps boolean
        isBool (BoolV _) = True
        isBool _ = False

prop_fun_comb_list v ps = (isList v .&&. val === pure v) .||. (not (isList v) .&&. isLeft val)
  where val = flattenFunction [v] ps list
        isList (ListV _) = True
        isList _ = False

prop_fun_comb_context v ps = (isCtx v .&&. val === pure v) .||. (not (isCtx v) .&&. isLeft val)
  where val = flattenFunction [v] ps context
        isCtx (ContextV _) = True
        isCtx _ = False

prop_fun_comb_undef v ps = (isUndef v .&&. val === pure v) .||. (not (isUndef v) .&&. isLeft val)
  where val = flattenFunction [v] ps undef
        isUndef UndefinedV = True
        isUndef _ = False

-- alternative instance should work for simple cases
prop_fun_backtrack_1 v ps = (flattenFunction [v] ps fun === pure v) .||. garbage v
  where fun = boolean <|> string <|> number
        garbage (BoolV _) = False
        garbage (StringV _) = False
        garbage (IntV _) = False
        garbage _ = True

--------------------------------------------------------------------------------

prop_fun_unit_backtrack_1 ps = once $
  flattenFunction vals ps fun === pure (StringV "hey")
  where vals = [IntV 55, IntV 65, StringV "hey"]
        f1 = number *> number *> number
        f2 = number *> number *> string
        fun = f1 <|> f2

prop_fun_unit_backtrack_2 ps = once $
  flattenFunction vals ps fun === pure (StringV "hey")
  where vals = [IntV 55, IntV 65, StringV "hey"]
        f1 = number *> number *> number
        f2 = number *> number *> string
        fun = f2 <|> f1



--------------------------------------------------------------------------------

return []
tests = $quickCheckAll