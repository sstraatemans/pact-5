-- | Hedgehog Generators for entities appearing in the PactDB
--   and TxLogs.

{-# LANGUAGE NamedFieldPuns #-}

module Pact.Core.Gen.Serialise where

import qualified Data.ByteString.Short as BSS
import Data.Decimal
import Data.Default (def)
import Data.Map.Strict (fromList)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Vector as Vec
import Hedgehog hiding (Var)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Pact.Core.Names
import Pact.Core.Guards
import Pact.Core.Hash (Hash(..), ModuleHash(..))
import Pact.Core.Type
import Pact.Core.Imports (Import(..))
import Pact.Core.IR.Term
import Pact.Core.Info (SpanInfo)
import Pact.Core.Builtin
import Pact.Core.Literal
import Pact.Core.Capabilities
import Pact.Core.Persistence
import Pact.Core.PactValue
import Pact.Core.DefPacts.Types
import Pact.Core.ChainData (ChainId(..))
import Pact.Core.Namespace (Namespace(..))
import Pact.Core.Test.LexerParserTests (identGen)

namespaceNameGen :: Gen NamespaceName
namespaceNameGen = NamespaceName <$> identGen

namespaceGen :: Gen Namespace
namespaceGen = do
  name <- namespaceNameGen
  user <- guardGen 3 qualifiedNameGen
  Namespace name user <$> guardGen 3 qualifiedNameGen

moduleNameGen :: Gen ModuleName
moduleNameGen =  do
  name <- identGen
  ModuleName name <$> Gen.maybe namespaceNameGen

publicKeyTextGen :: Gen PublicKeyText
publicKeyTextGen = PublicKeyText <$> identGen

-- ksPredicateGen :: Gen (KSPredicate n)
-- ksPredicateGen = Gen.element [minBound .. maxBound]

keySetNameGen :: Gen KeySetName
keySetNameGen = KeySetName <$> identGen <*> Gen.maybe namespaceNameGen

qualifiedNameGen :: Gen QualifiedName
qualifiedNameGen = do
  name <- identGen
  QualifiedName name <$> moduleNameGen

bareNameGen :: Gen BareName
bareNameGen = BareName <$> identGen

dynamicNameGen :: Gen DynamicName
dynamicNameGen = do
  name <- identGen
  DynamicName name <$> identGen

parsedNameGen :: Gen ParsedName
parsedNameGen = Gen.choice
  [ QN <$> qualifiedNameGen
  , BN <$> bareNameGen
  , DN <$> dynamicNameGen
  ]

parsedTyNameGen :: Gen ParsedTyName
parsedTyNameGen = Gen.choice
  [ TQN <$> qualifiedNameGen
  , TBN <$> bareNameGen
  ]

hashGen :: Gen Hash
hashGen = Hash . BSS.toShort . encodeUtf8 <$> identGen

-- | Generate a keyset, polymorphic over the custom
-- predicate function `a`. This particular variant is
-- not supported yet, so the argument is unused.
keySetGen :: Gen a -> Gen KeySet
keySetGen _genA = do
  ksKeysList <- Gen.list (Range.linear 1 10) publicKeyTextGen
  let _ksKeys = Set.fromList ksKeysList
  _ksPredFun <- Gen.choice
    [ pure KeysAll
    , pure Keys2
    , pure KeysAny
    , CustomPredicate <$> parsedTyNameGen
    ]
  pure $ KeySet { _ksKeys, _ksPredFun }

moduleHashGen :: Gen ModuleHash
moduleHashGen = ModuleHash <$> hashGen

fullyQualifiedNameGen :: Gen FullyQualifiedName
fullyQualifiedNameGen = do
  modName <- moduleNameGen
  name <- identGen
  FullyQualifiedName modName name <$> moduleHashGen

dynamicRefGen :: Gen DynamicRef
dynamicRefGen = do
  name <- identGen
  DynamicRef name <$> Gen.word64 Range.constantBounded

nameKindGen :: Gen NameKind
nameKindGen = Gen.choice
  [ NBound <$> Gen.word64 Range.constantBounded
  , NTopLevel <$> moduleNameGen <*> moduleHashGen
  , NModRef <$> moduleNameGen <*> Gen.list (Range.linear 0 100) moduleNameGen
  , NDynRef <$> dynamicRefGen
  ]

nameGen :: Gen Name
nameGen = do
  name <- identGen
  Name name <$> nameKindGen

resolvedGovGen :: Gen (FQNameRef Name)
resolvedGovGen = FQName <$> fullyQualifiedNameGen

governanceGen :: Gen (Governance Name)
governanceGen = Gen.choice
  [ KeyGov <$> keySetNameGen
  , CapGov <$> resolvedGovGen
  ]

tyPrimGen :: Gen PrimType
tyPrimGen = Gen.choice
  [ pure PrimInt
  , pure PrimDecimal
  , pure PrimBool
  , pure PrimString
  , pure PrimGuard
  , pure PrimTime
  , pure PrimUnit
  ]

fieldGen :: Gen Field
fieldGen = Field <$> identGen

schemaGen :: Gen Schema
schemaGen = do
  qual <- qualifiedNameGen
  elems <- Gen.list (Range.linear 0 10) $ (,) <$> fieldGen <*> typeGen
  pure (Schema qual (fromList elems))

typeGen :: Gen Type
typeGen = Gen.recursive Gen.choice
 [ TyPrim <$> tyPrimGen
 , TyModRef <$> Gen.set (Range.linear 0 10) moduleNameGen
 ]
 [ TyList <$> typeGen
 , TyObject <$> schemaGen
 , TyTable <$> schemaGen
 ]

argGen :: Gen i -> Gen (Arg Type i)
argGen i = do
  name <- identGen
  Arg name <$> Gen.maybe typeGen <*> i

importGen :: Gen Import
importGen = do
  mn <- moduleNameGen
  mh <- Gen.maybe moduleHashGen
  imp <- Gen.maybe (Gen.list (Range.linear 0 10) identGen)
  pure (Import mn mh imp)

infoGen :: Gen SpanInfo
infoGen = pure def

builtinGen :: Gen CoreBuiltin
builtinGen = Gen.element [minBound .. maxBound]

textGen :: Gen Text
textGen = Gen.text (Range.linear 0 100) Gen.unicode

integerGen :: Gen Integer
integerGen = Gen.integral (Range.linear (-1000) 1000)

decimalGen :: Gen Decimal
decimalGen = do
  places <- Gen.word8 Range.linearBounded
  Decimal places <$> integerGen

literalGen :: Gen Literal
literalGen = Gen.choice
  [ LString <$> textGen
  , LInteger <$> integerGen
  , LDecimal <$> decimalGen
  , pure LUnit
  , LBool <$> Gen.bool_ -- no shrinking
  ]

builtinFormGen :: Gen b -> Gen i -> Gen (BuiltinForm (Term Name Type b i))
builtinFormGen b i = Gen.choice
  [ CAnd <$> termGen b i <*> termGen b i
  , COr <$> termGen b i <*> termGen b i
  , CIf <$> termGen b i <*> termGen b i <*> termGen b i
  , CEnforceOne <$> termGen b i <*> Gen.list (Range.linear 0 16) (termGen b i)
  , CEnforce <$> termGen b i <*> termGen b i
  ]

termGen :: Gen b -> Gen i -> Gen (Term Name Type b i)
termGen b i = Gen.recursive Gen.choice
  [ Var <$> nameGen <*> i
  , Builtin <$> b <*> i
  , Constant <$> literalGen <*> i
  ]
  [ Lam <$> Gen.nonEmpty (Range.linear 1 16) (argGen i) <*> termGen b i <*> i
  , Let <$> argGen i <*> termGen b i <*> termGen b i <*> i
  , App <$> termGen b i <*> Gen.list (Range.linear 0 16) (termGen b i) <*> i
  , Sequence <$> termGen b i <*> termGen b i <*> i
  , Nullary <$> termGen b i <*> i
  , Conditional <$> builtinFormGen b i <*> i
  , ListLit <$> Gen.list (Range.linear 0 16) (termGen b i)<*> i
  , Try <$> termGen b i <*> termGen b i <*> i
  , ObjectLit <$> Gen.list (Range.linear 1 16) ((,) <$> fieldGen <*> termGen b i) <*> i
  ]


defunGen :: Gen b -> Gen i -> Gen (Defun Name Type b i)
defunGen b i = do
  args <- Gen.list (Range.linear 0 100) (argGen i)
  term <- termGen b i
  spec <- argGen i
  Defun spec args term <$> i

ifDefunGen ::Gen i -> Gen (IfDefun Type i)
ifDefunGen i = do
  args <- Gen.list (Range.linear 0 100) (argGen i)
  spec <- argGen i
  IfDefun spec args <$> i

defConstGen :: Gen b -> Gen i -> Gen (DefConst Name Type b i)
defConstGen b i = do
  spec <- argGen i
  cval <- constValGen (termGen b i)
  DefConst spec cval <$> i

constValGen :: Gen (Term name ty b i) -> Gen (ConstVal (Term name ty b i))
constValGen t = Gen.choice
  [ TermConst <$> t
  , EvaledConst <$> pactValueGen
  ]

fqNameRefGen :: Gen (FQNameRef Name)
fqNameRefGen = FQName <$> fullyQualifiedNameGen

-- defManagedMetaGen :: Gen name -> Gen (DefManagedMeta name)
-- defManagedMetaGen genName = Gen.choice
--   [ DefManagedMeta <$> liftA2 (,) (Gen.int (Range.linear 0 100)) genText <*> genName
--   , pure AutoManagedMeta
--   ]

defManagedMetaGen :: Gen name -> Gen (DefManagedMeta name)
defManagedMetaGen genName = Gen.choice
  [ DefManagedMeta
    <$> liftA2
          (,)
          (Gen.int (Range.linear 0 100))
          (Gen.text (Range.linear 0 100) Gen.latin1)
    <*> genName
  , pure AutoManagedMeta
  ]

defCapMetaGen :: Gen name -> Gen (DefCapMeta name)
defCapMetaGen genName = Gen.choice
  [ pure DefEvent
  , DefManaged <$> defManagedMetaGen genName
  , pure Unmanaged
  ]

defCapGen :: Gen b -> Gen i -> Gen (DefCap Name Type b i)
defCapGen b i = do
  arity <- Gen.int (Range.linear 0 16)
  args <- Gen.list (Range.singleton arity) (argGen i)
  term <- termGen b i
  meta <- defCapMetaGen fqNameRefGen
  spec <- argGen i
  DefCap spec args term meta <$> i

ifDefCapGen :: Gen i -> Gen (IfDefCap name Type i)
ifDefCapGen i = do
  args <- Gen.list (Range.linear 1 8) (argGen i)
  meta <- defCapMetaGen bareNameGen
  spec <- argGen i
  IfDefCap spec args  meta <$> i

defSchemaGen :: Gen i -> Gen (DefSchema Type i)
defSchemaGen i = do
  name <- identGen
  Schema _ schema <- schemaGen
  DefSchema name schema <$> i

defTableGen :: Gen i -> Gen (DefTable Name i)
defTableGen i = do
  name <- identGen
  schema <- ResolvedTable <$> schemaGen
  DefTable name schema <$> i

stepGen :: Gen b -> Gen i -> Gen (Step Name Type b i)
stepGen b i = Gen.choice
  [ Step <$> termGen b i
  , StepWithRollback <$> termGen b i <*> termGen b i
  ]

defPactGen :: Gen b -> Gen i -> Gen (DefPact Name Type b i)
defPactGen b i = do
  args <- Gen.list (Range.linear 0 16) (argGen i)
  steps <- Gen.nonEmpty (Range.linear 0 16) (stepGen b i)
  spec <- argGen i
  DefPact spec args steps <$> i


ifDefPactGen :: Gen i -> Gen (IfDefPact Type i)
ifDefPactGen i = do
  args <- Gen.list (Range.linear 0 16) (argGen i)
  spec <- argGen i
  IfDefPact spec args <$> i


defGen :: Gen b -> Gen i -> Gen (Def Name Type b i)
defGen b i = Gen.choice
  [ Dfun <$> defunGen b i
  , DConst <$> defConstGen b i
  , DCap <$> defCapGen b i
  , DSchema <$> defSchemaGen i
  , DTable <$> defTableGen i
  , DPact <$> defPactGen b i
  ]


evalModuleGen :: Gen b -> Gen i -> Gen (EvalModule b i)
evalModuleGen b i= do
  name <- moduleNameGen
  gov <- governanceGen
  defs <- Gen.list (Range.linear 0 100) (defGen b i)
  blessed <- Set.fromList <$> Gen.list (Range.linear 0 100) moduleHashGen
  imps <- Gen.list (Range.linear 0 100) importGen
  impl <- Gen.list (Range.linear 0 100) moduleNameGen
  h <- moduleHashGen
  Module name gov defs blessed imps impl h <$> i

ifDefGen :: Gen b -> Gen i -> Gen (IfDef Name Type b i)
ifDefGen b i = Gen.choice
  [ IfDfun <$> ifDefunGen i
  , IfDConst <$> defConstGen b i
  , IfDCap <$> ifDefCapGen i
  , IfDSchema <$> defSchemaGen i
  , IfDPact <$> ifDefPactGen i
  ]

evalInterfaceGen :: Gen b -> Gen i -> Gen (EvalInterface b i)
evalInterfaceGen b i = do
  name <- moduleNameGen
  defs <- Gen.list (Range.linear 0 100) (ifDefGen b i)
  imports <- Gen.list (Range.linear 0 100) (importGen )
  h <- moduleHashGen
  Interface name defs imports h <$> i

moduleDataGen :: Gen b -> Gen i -> Gen (ModuleData b i)
moduleDataGen b i = Gen.choice
  [ ModuleData <$> evalModuleGen b i<*> m
  , InterfaceData <$> evalInterfaceGen b i<*> m
  ]
  where
    m = Gen.map (Range.linear 0 8) $ (,) <$> fullyQualifiedNameGen <*> defGen b i


defPactIdGen :: Gen DefPactId
defPactIdGen = DefPactId <$> identGen

userGuardGen :: Int -> Gen (UserGuard FullyQualifiedName PactValue)
userGuardGen depth = do
  ident <- fullyQualifiedNameGen
  UserGuard ident <$> Gen.list (Range.linear 0 depth) pactValueGen

guardGen :: Int -> Gen n -> Gen (Guard n PactValue)
guardGen depth n
  | depth <= 0 = Gen.choice [gKeySetGen, gKeySetRefGen]
  | otherwise  = Gen.choice [gKeySetGen, gKeySetRefGen]
  where
    gKeySetGen = GKeyset <$> keySetGen n
    gKeySetRefGen = GKeySetRef <$> keySetNameGen
--    gUserGuardGen = GUserGuard <$> userGuardGen (depth - 1)

pactValueGen :: Gen PactValue
pactValueGen = do
  i <- Gen.int (Range.linear 0 8)
  pactValueGen' i

pactValueGen' :: Int ->Gen PactValue
pactValueGen' depth = Gen.choice
  [ PLiteral <$> literalGen
  , PList . Vec.fromList <$> Gen.list (Range.linear 0 depth) (pactValueGen' (depth - 1))
  , PGuard <$> guardGen (depth - 1) qualifiedNameGen
  ]

chainIdGen :: Gen ChainId
chainIdGen = ChainId <$> identGen

provenanceGen :: Gen Provenance
provenanceGen = do
  chainId <- chainIdGen
  Provenance chainId <$> moduleHashGen

yieldGen :: Gen Yield
yieldGen = do
  d <- Gen.map (Range.linear 0 16) ((,) <$> fieldGen <*> pactValueGen)
  p <- Gen.maybe provenanceGen
  Yield d p <$> Gen.maybe chainIdGen

defPactContinuationGen :: Gen (DefPactContinuation QualifiedName PactValue)
defPactContinuationGen = do
  ident <- qualifiedNameGen
  DefPactContinuation ident <$> Gen.list (Range.linear 0 8) pactValueGen

defPactExecGen :: Gen DefPactExec
defPactExecGen = do
  i <- Gen.int (Range.linear 0 3)
  defPactExecGen' i

defPactExecGen' :: Int -> Gen DefPactExec
defPactExecGen' depth = do
  sc <- Gen.int (Range.linear 1 16)
  yield <- Gen.maybe yieldGen
  step <- Gen.int (Range.linear 1 sc)
  dpid <- defPactIdGen
  cont <- defPactContinuationGen
  nested <- if depth <= 0
            then pure Map.empty
            else Gen.map (Range.linear 0 3) genNested
  rb <- Gen.bool
  pure (DefPactExec sc yield step dpid cont rb nested)
  where
    genNested = do
      dpid <- defPactIdGen
      pexec <- defPactExecGen' (depth - 1)
      pure (dpid, pexec)
