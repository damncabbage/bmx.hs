{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A templating library in the style of <http://handlebarsjs.com Handlebars.js>,
-- embedded in Haskell for static or server-side rendering.
--

module BMX (
  -- * Differences from Handlebars
  -- $whatsnew

  -- * Templates
  -- $templates
    Template
  , templateFromText
  , templateToText

  -- * Pages
  -- $pages
  , Page
  , renderPage

  -- * Rendering a Template
  -- $rendering
  , renderTemplate
  , renderTemplateIO
  , BMXState
  , defaultState

  -- * Errors
  , BMXError (..)
  , renderBMXError

  -- * Providing data
  -- $values
  , Context
  , Value (..)
  , contextFromList
  , usingContext

  -- * Partials
  -- $partials
  , Partial
  , partialFromTemplate
  , usingPartials

  -- * Helpers
  -- $helpers
  , Helper
  , usingHelpers

  -- * Decorators
  -- $decorators
  , Decorator
  , usingDecorators
  ) where

import           Control.Monad.Identity (Identity)
import           Control.Monad.IO.Class (MonadIO)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Text (Text)

import           BMX.Builtin
import           BMX.Data
import           BMX.Function
import           BMX.Lexer as X (tokenise)
import           BMX.Parser as X (parse)

import           P

-- $whatsnew
--
-- BMX is considerably stricter than Handlebars. A number
-- of error-prone constructs that Handlebars accepts will result in a 'BMXError':
--
-- * Any attempt (mustache or 'Helper') to print @undefined@, @null@,
-- a list, or a 'Context' will result in an error.
-- * TBD


-- $templates BMX templates are syntactically compatible with
-- Handlebars 4.
--
-- Use 'templateFromText' to parse a 'Template' from some 'Text',
-- pretty-print it with 'templateToText', and apply it to some data
-- with 'renderTemplate' / 'renderTemplateIO'.

-- $pages Rendering a 'Template' produces a 'Page', which is little
-- more than a 'Text' field with additional formatting
-- information.
--
-- Extract the final 'Text' artefact with 'renderPage'.

-- $rendering
--
-- Apply a 'Template' to some 'EvalState' to produce a 'Page', a
-- fully-evaluated document that is ready to print.
--
-- Build up an 'EvalState' by using 'mempty' or
-- 'defaultState' as a base, and then applying 'usingContext',
-- 'usingPartials', 'usingHelpers', and 'usingDecorators' to supply
-- custom functions and data as needed.
--
-- > myEvalState = defaultState
-- >   `usingContext` coolContext
-- >   `usingPartials` [("login", loginTemplate), ("logout", logoutTemplate)]

-- $values
--
-- To make use of a 'Template', we need to supply it with data at runtime.
--
-- A 'Context' is a set of mappings from 'Text' to 'Value', i.e. local
-- variable bindings. The current 'Context' is stored in the
-- 'EvalState', and is used for all variable lookups. The initial
-- context can be set via 'usingContext'.
--
-- Values can be integers, strings, booleans, undefined, lists, or
-- nested contexts / namespaces. Use the constructors directly.

-- $partials
--
-- A 'Partial' produces a 'Page' that another 'Template' can render
-- inline. The partial has full access to the local
-- 'EvalState' when run.
--
-- Most partials will be constructed from 'Template' values using
-- 'partialFromTemplate'. However, the type is general enough to admit
-- arbitrary Haskell functions. See 'BMX.Function.partial'.

-- $helpers
--
-- A 'Helper' comes in two varieties:
--
-- * A 'BMX.Function.helper' is a function that produces a 'Value'.
--   Regular helpers can be invoked in mustache expressions, and in
--   subexpression arguments to other helpers.
--
-- * A 'BMX.Function.blockHelper' is a function that accepts two
--   'Template' parameters (roughly equivalent to @then@ and @else@
--   branches), producing a 'Page'. Block helpers can be invoked in
--   blocks, partial blocks, and inverse blocks.
--
-- A default set of helpers is provided - 'builtinHelpers'.
--
-- See <BMX-Function.html BMX.Function> for details on implementing
-- custom helpers.

-- $decorators
--
-- A 'Decorator' is a function that can make arbitrary changes to the
-- 'EvalState'. The changes made will only affect the surrounding
-- block.  Decorators are preprocessed before their containing block
-- is rendered.
--
-- A default set of decorators is provided - 'builtinDecorators'.
--
-- See <BMX-Function.html BMX.Function> for details on implementing
-- custom decorators.

data BMXState m = BMXState
  { bmxContext :: Context
  , bmxPartials :: [(Text, Partial m)]
  , bmxHelpers :: [(Text, Helper m)]
  , bmxDecorators :: [(Text, Decorator m)]
  }

instance Monoid (BMXState m) where
  mempty = BMXState mempty mempty mempty mempty
  mappend a b = BMXState {
      bmxContext = bmxContext a <> bmxContext b
    , bmxPartials = bmxPartials a <> bmxPartials b
    , bmxHelpers = bmxHelpers a <> bmxHelpers b
    , bmxDecorators = bmxDecorators a <> bmxDecorators b
    }

-- | The default state: an empty context, all the helpers from
-- 'BMX.Builtin.Helpers.builtinHelpers', and all the decorators from
-- 'BMX.Builtin.Decorators.builtinDecorators'.
defaultState :: (Applicative m, Monad m) => BMXState m
defaultState = mempty {
    bmxHelpers = builtinHelpers
  , bmxDecorators = builtinDecorators
  }

-- | Set the initial context in an 'EvalState'.
usingContext :: (Applicative m, Monad m) => BMXState m -> Context -> BMXState m
usingContext st c = st { bmxContext = c }

-- | Add a named collection of templates to the 'EvalState' as partials.
usingPartials :: (Applicative m, Monad m) => BMXState m -> [(Text, Template)] -> BMXState m
usingPartials st ps = st { bmxPartials = (fmap . fmap) partialFromTemplate ps <> bmxPartials st }

-- | Add a named collection of helpers to the 'EvalState'.
usingHelpers :: (Applicative m, Monad m) => BMXState m -> [(Text, Helper m)] -> BMXState m
usingHelpers st hs = st { bmxHelpers = hs <> bmxHelpers st }

-- | Add a named collection of decorators to the 'EvalState'.
usingDecorators :: (Applicative m, Monad m) => BMXState m -> [(Text, Decorator m)] -> BMXState m
usingDecorators st ds = st { bmxDecorators = ds <> bmxDecorators st }

-- | Lex and parse a 'Template' from some 'Text'.
templateFromText :: Text -> Either BMXError Template
templateFromText = either convert (bimap BMXParseError id . parse) . tokenise
  where
    convert = Left . BMXLexError

-- | Apply a 'Template' to some 'EvalState', producing a 'Page'.
--
-- All helpers, partials and decorators must be pure. Use 'renderTemplateIO'
-- if IO helpers are required.
renderTemplate :: BMXState Identity -> Template -> Either BMXError Page
renderTemplate bst t = do
  st <- packState bst
  bimap BMXEvalError id $ fst (runBMX st (eval t))

-- | Apply a 'Template' to some 'EvalState', producing a 'Page'.
--
-- Helpers, partials and decorators may involve IO. Use @renderTemplate@ if
-- no IO helpers are to be invoked.
renderTemplateIO :: (Applicative m, MonadIO m) => BMXState m -> Template -> m (Either BMXError Page)
renderTemplateIO bst t = either (return . Left) runIt (packState bst)
  where runIt es = do
          ep <- runBMXIO es (eval t)
          return (bimap BMXEvalError id . fst $ ep)

-- | Pack the association lists from 'BMXState' into the maps of 'EvalState',
-- throwing errors whenever shadowing is encountered.
packState :: (Applicative m, Monad m) => BMXState m -> Either BMXError (EvalState m)
packState bst = do
  let ctx = [bmxContext bst]
  partials <- mapUnique (bmxPartials bst)
  helpers <- mapUnique (bmxHelpers bst)
  decorators <- mapUnique (bmxDecorators bst)
  let dta = mempty
  return EvalState {
      evalContext = ctx
    , evalData = dta
    , evalHelpers = helpers
    , evalPartials = partials
    , evalDecorators = decorators
    }

mapUnique :: [(Text, a)] -> Either BMXError (Map Text a)
mapUnique = foldM foldFun M.empty
  where foldFun m (k, v)  = if M.member k m
          then Left (BMXEvalError (SomeError "shadowing - i need my own error!"))
          else Right (M.insert k v m)

-- | Produce a 'Partial' from an ordinary 'Template'.
partialFromTemplate :: (Applicative m, Monad m) => Template -> Partial m
partialFromTemplate = partial . eval
