{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
-- {-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE InstanceSigs #-}

module Pact.Core.Errors
 ( PactErrorI
 , LexerError(..)
 , ParseError(..)
 , DesugarError(..)
 , EvalError(..)
 , PactError(..)
 , ArgTypeError(..)
 , peInfo
 , liftDbFunction
 ) where

import Control.Lens hiding (ix)
import Control.Monad.Except(MonadError(..))
import Control.Monad.IO.Class(MonadIO(..))
import Control.Exception
import Data.Text(Text)
import Data.Dynamic (Typeable)

import Pact.Core.Type
import Pact.Core.Names
import Pact.Core.Guards
import Pact.Core.Info
import Pact.Core.Pretty(Pretty(..))
import Pact.Core.Hash
import Pact.Core.Persistence
import Pact.Core.Pacts.Types

import qualified Pact.Core.Pretty as Pretty

type PactErrorI = PactError SpanInfo

data LexerError
  = LexicalError Char Char
  -- ^ Lexical error: encountered character, last seen character
  | InvalidIndentation Int Int
  -- ^ Invalid indentation: ^ current indentation, expected indentation
  | InvalidInitialIndent Int
  -- ^ Invalid initial indentation: got ^, expected 2 or 4
  | StringLiteralError Text
  -- ^ Error lexing string literal
  | OutOfInputError Char
  deriving Show

instance Exception LexerError



instance Pretty LexerError where
  pretty = ("Lexical Error: " <>) . \case
    LexicalError c1 c2 ->
      Pretty.hsep ["Encountered character",  Pretty.parens (pretty c1) <> ",", "Last seen", Pretty.parens (pretty c2)]
    InvalidIndentation curr expected ->
      Pretty.hsep ["Invalid indentation. Encountered", Pretty.parens (pretty curr) <> ",", "Expected", Pretty.parens (pretty expected)]
    StringLiteralError te ->
      Pretty.hsep ["String literal parsing error: ", pretty te]
    InvalidInitialIndent i ->
      Pretty.hsep ["Invalid initial ident. Valid indentation are 2 or 4 spaces. Found: ", Pretty.parens (pretty i)]
    OutOfInputError c ->
      Pretty.hsep ["Ran out of input before finding a lexeme. Last Character seen: ", Pretty.parens (pretty c)]

data ParseError
  = ParsingError Text
  -- ^ Parsing error: [expected]
  | TooManyCloseParens Text
  -- ^ Too many closing parens [Remaining t]
  | UnexpectedInput Text
  -- Todo: Potentially the error here would be better if
  -- ^ Too much input in general. Did not expect more tokens.
  -- Emitted in the case of "Expression was parsed successfully but there's more input remaining."
  | PrecisionOverflowError Int
  -- ^ Way too many decimal places for `Decimal` to deal with, max 255 precision.
  | InvalidBaseType Text
  -- ^ Invalid primitive type
  deriving Show

instance Exception ParseError

instance Pretty ParseError where
  pretty = \case
    ParsingError e ->
      Pretty.hsep ["Expected:", pretty e]
    TooManyCloseParens e ->
      Pretty.hsep ["Too many closing parens, remaining tokens:", pretty e]
    UnexpectedInput e ->
      Pretty.hsep ["Unexpected input after expr, remaining tokens:", pretty e]
    PrecisionOverflowError i ->
      Pretty.hsep ["Precision overflow (>=255 decimal places): ", pretty i, "decimals"]
    InvalidBaseType txt ->
      Pretty.hsep ["No such type:", pretty txt]

data DesugarError
  = UnboundTermVariable Text
  -- ^ Encountered a variable with no binding <varname>
  | UnsupportedType Text
  -- ^ Type left over from old pact type system (e.g poly list)
  | UnboundTypeVariable Text
  -- ^ Found an unbound type variable in a type definition
  -- (note: in this current version of core this should never occur,
  --  there are no userland type variables that can be annotated)
  | UnannotatedArgumentType Text
  -- ^ A declaration has a type parameter without an annotation <argument name>
  | UnannotatedReturnType Text
  -- ^ Function <function name> has an unannotated return type
  | InvalidCapabilityReference Text
  -- ^ Function <function name> is used in a scope that expected a capability
  | CapabilityOutOfScope Text ModuleName
  -- ^ Capability <modulename . defname > is used in a scope outside of its static allowable scope
  | NoSuchModuleMember ModuleName Text
  -- ^ Module <modulename> does not have member <membername>
  | NoSuchModule ModuleName
  -- ^ Module <modulename> does not exist
  | NoSuchInterface ModuleName
  -- ^ Interface <ifname> doesnt exist
  | ImplementationError ModuleName ModuleName Text
  -- ^ Interface implemented in module for member <member> does not match the signature
  | NotImplemented ModuleName ModuleName Text
  -- ^ Interface member not implemented
  | RecursionDetected ModuleName [Text]
  -- ^ Detected use of recursion in module <module>. [functions] for a cycle
  | NotAllowedWithinDefcap Text
  -- ^ Form <text> not allowed within defcap
  | NotAllowedOutsideModule Text
  -- ^ Form not allowed outside of module call <description
  | UnresolvedQualName QualifiedName
  -- ^ no such qualified name
  | InvalidGovernanceRef QualifiedName
  -- ^ No such governance
  | InvalidDefInTermVariable Text
  -- ^ Invalid top level defn references a non-semantic value (e.g defcap, defschema)
  | InvalidModuleReference ModuleName
  -- ^ Invalid: Interface used as module reference
  | EmptyBindingBody
  --
  | EmptyDefPact Text
  -- ^ Defpact without steps
  | LastStepWithRollback QualifiedName
  -- ^ Last Step has Rollback error
  | ExpectedFreeVariable Text
  | InvalidManagedArg Text
  | InvalidImports [Text]
  | InvalidImportModuleHash ModuleName ModuleHash
  -- ^ Expected free variable
  | InvalidSyntax Text
  | InvalidDefInSchemaPosition Text
  | InvalidDynamicInvoke Text
  | DuplicateDefinition Text
  deriving Show

instance Exception DesugarError

instance Pretty DesugarError where
  pretty = \case
    UnsupportedType t ->
      Pretty.hsep ["Unsupported type in pact-core:", pretty t]
    UnannotatedArgumentType t ->
      Pretty.hsep ["Unannotated type in argument:", pretty t]
    UnannotatedReturnType t ->
      Pretty.hsep ["Declaration", pretty t, "is missing a return type"]
    UnboundTermVariable t ->
      Pretty.hsep ["Unbound variable", pretty t]
    UnboundTypeVariable t ->
      Pretty.hsep ["Unbound type variable", pretty t]
    InvalidCapabilityReference t ->
      Pretty.hsep ["Variable or function used in special form is not a capability", pretty t]
    CapabilityOutOfScope fn mn ->
      Pretty.hsep [pretty mn <> "." <> pretty fn, "was used in a capability special form outside of the"]
    NoSuchModuleMember mn txt ->
      Pretty.hsep ["Module", pretty mn, "has no such member:", pretty txt]
    NoSuchModule mn ->
      Pretty.hsep ["Cannot find module: ", pretty mn]
    NoSuchInterface mn ->
      Pretty.hsep ["Cannot find interface: ", pretty mn]
    NotAllowedWithinDefcap dc ->
      Pretty.hsep [pretty dc, "form not allowed within defcap"]
    NotAllowedOutsideModule txt ->
      Pretty.hsep [pretty txt, "not allowed outside of a module"]
    ImplementationError mn1 mn2 defn ->
      Pretty.hsep [ "Module"
                   , pretty mn1
                   , "does not correctly implement the function"
                   , pretty defn
                   , "from Interface"
                   , pretty mn2]
    RecursionDetected mn txts ->
      Pretty.hsep
      ["Recursive cycle detected in Module"
      , pretty mn
      , "in the following functions:"
      , pretty txts]
    UnresolvedQualName qual ->
      Pretty.hsep ["No such name", pretty qual]
    InvalidGovernanceRef gov ->
      Pretty.hsep ["Invalid governance:", pretty gov]
    InvalidDefInTermVariable n ->
      Pretty.hsep ["Invalid definition in term variable position:", pretty n]
    InvalidModuleReference mn ->
      Pretty.hsep ["Invalid Interface attempted to be used as module reference:", pretty mn]
    EmptyBindingBody -> "Bind expression lacks an accompanying body"
    EmptyDefPact dp -> Pretty.hsep ["Defpact has no steps:", pretty dp]
    LastStepWithRollback mn ->
      Pretty.hsep ["rollbacks aren't allowed on the last step in:", pretty mn]
    ExpectedFreeVariable t ->
      Pretty.hsep ["Expected free variable in expression, found locally bound: ", pretty t]
    e -> pretty (show e)

-- | Argument type mismatch meant for errors
--   that does not force you to show the whole PactValue
data ArgTypeError
  = ATEPrim PrimType
  | ATEList
  | ATEObject
  | ATETable
  | ATEClosure
  | ATEModRef
  | ATEPrincipal
  deriving (Show)

instance Pretty ArgTypeError where
  pretty = \case
    ATEPrim p -> Pretty.brackets $ pretty p
    ATEList -> "[list]"
    ATEObject -> "[object]"
    ATETable -> "[table]"
    ATEClosure -> "[closure]"
    ATEModRef -> "[modref]"
    ATEPrincipal -> "[principal]"


-- | All fatal execution errors which should pause
--
data EvalError
  = ArrayOutOfBoundsException Int Int
  -- ^ Array index out of bounds <length> <index>
  | ArithmeticException Text
  -- ^ Arithmetic error <cause>
  | EnumerationError Text
  -- ^ Enumeration error (e.g incorrect bounds with step
  | DecodeError Text
  -- ^ Some form of decoding error
  | GasExceeded Text
  -- ^ Gas went past the gas limit
  | FloatingPointError Text
  -- ^ Floating point operation exception
  | CapNotInScope Text
  -- ^ Capability not in scope
  | InvariantFailure Text
  -- ^ Invariant violation in execution. This is a fatal Error.
  | EvalError Text
  -- ^ Error raised by the program that went unhandled
  | NativeArgumentsError NativeName [ArgTypeError]
  -- ^ Error raised: native called with the wrong arguments
  | ModRefNotRefined Text
  -- ^ Module reference not refined to a value
  | InvalidDefKind DefKind Text
  -- ^ Def used in method has wrong type + reason
  | NoSuchDef FullyQualifiedName
  -- ^ Could not find a definition with the above name
  | InvalidManagedCap FullyQualifiedName
  -- ^ Name does not point to a managed capability
  | CapNotInstalled FullyQualifiedName
  -- ^ Capability not installed
  | NameNotInScope FullyQualifiedName
  -- ^ Name not found in the top level environment
  | DefIsNotClosure Text
  -- ^ Def is not a closure
  | NoSuchKeySet KeySetName
    -- ^ No such keyset
  | YieldOutsiteDefPact
  -- ^ Yield a value outside a running PactExec
  | NoActivePactExec
  -- ^ No Active PactExec in the environment
  | NoYieldInPactStep PactStep
  -- ^ No Yield available in PactStep
  | InvalidPactStepSupplied PactStep PactExec
  -- ^ Supplied PactStep requests an invalid step
  | DefPactIdMissmatch PactId PactId
  -- ^ Requested PactId does not match context PactId
  | CCDefPactContinuationError PactStep PactExec PactExec
  -- ^ Crosschain DefPact contunation must be at least 2 steps before CC continuation step
  --   with <ccExec> <dbExec>
  | NoPreviousDefPactExecutionFound PactStep
  -- ^ No previouse DefPact execution could be found in the environment or database
  | DefPactAlreadyCompleted PactStep
  -- ^ DefPact already completed
  | NestedDefPactParentStepCountMissmatch PactId Int Int
  -- ^ Nested DefPact <stepcount> does not match <parent step count>
  | NestedDefPactParentRollbackMissmatch PactId Bool Bool
  -- ^ Nested DefPact <rollback> does not match <parent rollback>
  | NestedDefPactNeverStarted PactStep
  -- ^ Nested DefPact never started at prior step
  | NestedDefPactDoubleExecution PactStep
  -- ^ Nested DefPact is executed twice
  | MultipleOrNestedDefPactExecFound PactExec
  -- ^ Unexpected PactExec found in the environment
  | DefPactStepNotFound PactStep Int
  -- ^ The expected step could not be found in the DefPact
  | PactStepHasNoRollback PactStep
  -- ^ The requested PactStep has no rollback
  | PactStepNotInEnvironment
  -- ^ PactStep is not in the environment
  | NoDefPactIdAndExecEnvSupplied
  -- ^ No PactId supplied and no PactExec found in the environment
  | DefPactRollbackMissmatch PactStep PactExec
  -- ^ DefPact rollback missmatch
  | DefPactStepMissmatch PactStep PactExec
  -- ^ DefPact missmatch
  | CannotUpgradeInterface ModuleName
  -- ^ Interface cannot be upgrade
  | ModuleGovernanceFailure ModuleName
  -- ^ Failed to acquire module governance
  | DbOpFailure DbOpException
  -- ^ DynName is not a module ref
  | DynNameIsNotModRef Text
  | ModuleDoesNotExist ModuleName
  | ExpectedModule ModuleName
  -- ^ Module does not exist
  | HashNotBlessed ModuleName ModuleHash
  | CannotApplyPartialClosure
  | ClosureAppliedToTooManyArgs
  | FormIllegalWithinDefcap Text
  | RunTimeTypecheckFailure ArgTypeError Type
  | NativeIsTopLevelOnly NativeName
  | EventDoesNotMatchModule ModuleName
  | InvalidEventCap FullyQualifiedName
  | NestedDefpactsNotAdvanced PactId
  | ExpectedPactValue
  | NotInPactExecution
  deriving Show


instance Pretty EvalError where
  pretty :: EvalError -> Pretty.Doc ann
  pretty = \case
    ArrayOutOfBoundsException len ix ->
      Pretty.hsep
      [ "Array index out of bounds. Length"
      , Pretty.parens (pretty len) <> ","
      , "Index"
      , Pretty.parens (pretty ix)]
    ArithmeticException txt ->
      Pretty.hsep ["Arithmetic exception:", pretty txt]
    EnumerationError txt ->
      Pretty.hsep ["Enumeration error:", pretty txt]
    DecodeError txt ->
      Pretty.hsep ["Decoding error:", pretty txt]
    FloatingPointError txt ->
      Pretty.hsep ["Floating point error:", pretty txt]
    -- Todo: probably enhance this data type
    CapNotInScope txt ->
      Pretty.hsep ["Capability not in scope:", pretty txt]
    GasExceeded txt ->
      Pretty.hsep ["Gas Exceeded:", pretty txt]
    InvariantFailure txt ->
      Pretty.hsep ["Fatal execution error, invariant violated:", pretty txt]
    NativeArgumentsError (NativeName n) tys ->
      Pretty.hsep ["Native evaluation error for native", pretty n <> ",", "received incorrect argument(s) of type(s)", Pretty.commaSep tys]
    EvalError txt ->
      Pretty.hsep ["Program encountered an unhandled raised error:", pretty txt]
    -- ModRefNotRefined _ -> error ""
    -- InvalidDefKind _ _ -> error ""
    -- NoSuchDef _ -> error ""
    -- InvalidManagedCap _ -> error ""
    -- CapNotInstalled _ -> error ""
    -- NameNotInScope _ -> error ""
    -- DefIsNotClosure _ -> error ""
    -- NoSuchKeySet _ -> error ""
    YieldOutsiteDefPact ->
      "Try to yield a value outside a running DefPact execution"
    NoActivePactExec ->
      "No active DefPact execution in the environment"
    NoYieldInPactStep (PactStep step _ i _) ->
      Pretty.hsep ["No yield in DefPactStep:", "Step: " <> pretty step, "DefPactId: " <> pretty i]
    InvalidPactStepSupplied (PactStep step _ _ _) pe ->
      Pretty.hsep
      [ "PactStep does not match DefPact properties:"
      , "requested: "<> pretty step
      , "step count:" <> pretty (_peStepCount pe)]
    DefPactIdMissmatch reqId envId ->
      Pretty.hsep
      [ "Requested PactId:", pretty reqId
      , "does not match context PactId:", pretty envId
      ]
    CCDefPactContinuationError pactStep _ccExec _dbExec ->
      Pretty.hsep
      [ "Crosschain DefPact continuation error:"
      , "PactId:" <> pretty (_psStep pactStep)
      ]
    NestedDefPactParentRollbackMissmatch pid rollback parentRollback ->
      Pretty.hsep
      [ "Nested DefPact execution failed, parameter missmatch:"
      , "PactId: " <> pretty pid
      , "Rollback: " <> pretty rollback
      , "Parent rollback:" <> pretty parentRollback
      ]
    NestedDefPactParentStepCountMissmatch pid stepCount parentStepCount ->
      Pretty.hsep
      [ "Nested DefPact execution failed, parameter missmatch:"
      , "PacId: " <> pretty pid
      , "step count: " <> pretty stepCount
      , "Parent step count: " <> pretty parentStepCount
      ]
    NoPreviousDefPactExecutionFound ps ->
      Pretty.hsep ["No previous DefPact exeuction found for PactId: ", pretty (_psPactId ps)]
    DefPactAlreadyCompleted ps -> Pretty.hsep
      [ "Requested DefPact already completed: ", "PactId:" <> pretty (_psPactId ps)]
    NestedDefPactNeverStarted ps -> Pretty.hsep
      ["Requested nested DefPact never started:", "PactId: " <> pretty (_psPactId ps)]
    NestedDefPactDoubleExecution ps -> Pretty.hsep
      ["Requested nested DefPact double execution:", "PactId: " <> pretty (_psPactId ps)]
    MultipleOrNestedDefPactExecFound pe -> Pretty.hsep
      ["DefPact execution context already in the environment: ", "PactId: " <> pretty (_pePactId pe)]
    DefPactStepNotFound ps maxSteps -> Pretty.hsep
      [ "Requested DefPact step exceeds available steps:"
      , "requested: " <> pretty (_psStep ps)
      , "available: " <> pretty maxSteps
      ]
    PactStepHasNoRollback ps -> Pretty.hsep
      ["Step has no rollback:", "PactId: " <> pretty (_psPactId ps)]
    PactStepNotInEnvironment -> "No PactStep in the environment"
    NoDefPactIdAndExecEnvSupplied -> "No PactId or execution environment supplied"
    DefPactRollbackMissmatch ps pe -> Pretty.hsep
      [ "Rollback missmatch in PactStep and DefPact exeuction environment:"
      , "PactId: " <> pretty (_psPactId ps)
      , "step rollback: " <> pretty (_psRollback ps)
      , "PactExec rollback: " <> pretty (_peStepHasRollback pe)
      ]
    DefPactStepMissmatch ps pe -> Pretty.hsep
      [ "Step missmatch in PactStep and DefPact exeuction environment:"
      , "PactId: " <> pretty (_psPactId ps)
      , "step: " <> pretty (_psStep ps)
      , "PactExec step: " <> pretty (_peStep pe + 1)
      ]
    e -> pretty (show e)
    -- CannotUpgradeInterface _ -> error ""
    -- ModuleGovernanceFailure _ -> error ""
    -- DbOpFailure _ -> error ""
    -- DynNameIsNotModRef _ -> error ""
    -- ModuleDoesNotExist _ -> error ""
    -- ExpectedModule _ -> error ""
    -- HashNotBlessed _ _ -> error ""
    -- CannotApplyPartialClosure -> error ""
    -- ClosureAppliedToTooManyArgs -> error ""
    -- FormIllegalWithinDefcap _ -> error ""
    -- RunTimeTypecheckFailure _ _ -> error ""
    -- NativeIsTopLevelOnly _ -> error ""
    -- EventDoesNotMatchModule _ -> error ""
    -- InvalidEventCap _ -> error ""
    -- NestedDefpactsNotAdvanced _ -> error ""
    -- ExpectedPactValue -> error ""
    -- NotInPactExecution -> error ""

instance Exception EvalError

data PactError info
  = PELexerError LexerError info
  | PEParseError ParseError info
  | PEDesugarError DesugarError info
  -- | PETypecheckError TypecheckError info
  -- | PEOverloadError OverloadError info
  | PEExecutionError EvalError info
  deriving Show

instance Pretty (PactError info) where
  pretty = \case
    PELexerError e _ -> pretty e
    PEParseError e _ -> pretty e
    PEDesugarError e _ -> pretty e
    PEExecutionError e _ -> pretty e

peInfo :: Lens (PactError info) (PactError info') info info'
peInfo f = \case
  PELexerError le info ->
    PELexerError le <$> f info
  PEParseError pe info ->
    PEParseError pe <$> f info
  PEDesugarError de info ->
    PEDesugarError de <$> f info
  PEExecutionError ee info ->
    PEExecutionError ee <$> f info

instance (Show info, Typeable info) => Exception (PactError info)

liftDbFunction
  :: (MonadError (PactError i) m, MonadIO m)
  => i
  -> IO a
  -> m a
liftDbFunction info action = do
  e <- liftIO $ catch (Right <$> action) (pure . Left . DbOpFailure)
  either (throwError . (`PEExecutionError` info)) pure e
