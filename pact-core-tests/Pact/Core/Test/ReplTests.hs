{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}

module Pact.Core.Test.ReplTests where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Monad(when)
import Data.IORef
import Data.Default
import Data.ByteString(ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.Foldable(traverse_)
import Data.Text.Encoding(decodeUtf8)
import System.Directory
import System.FilePath

import qualified Data.Text as T
import qualified Data.ByteString as B

import Pact.Core.Gas
import Pact.Core.Literal
-- import Pact.Core.Persistence
import Pact.Core.Persistence.MockPersistence
import Pact.Core.Interpreter

import Pact.Core.Repl.Utils
import Pact.Core.Persistence (PactDb(..), Domain(..), readKeySet, readModule, ModuleData(..), readNamespace, readDefPacts
                             ,writeKeySet, writeNamespace, writeDefPacts, writeModule)
import Pact.Core.Persistence.SQLite (withSqlitePactDb)
import Pact.Core.Serialise (PactSerialise(..), serialisePact, Document(LegacyDocument))

import Pact.Core.Info (SpanInfo)
import Pact.Core.Compile
import Pact.Core.IR.Term (Module(..), EvalModule)
import Pact.Core.Builtin (ReplBuiltin)
import Pact.Core.Repl.Compile
import Pact.Core.PactValue
import Pact.Core.Environment
import Pact.Core.Builtin
import Pact.Core.Errors
import Pact.Core.Guards
import Pact.Core.Names
import Pact.Core.IR.Term (EvalModule, Module(..), EvalDef, Def(..))

tests :: IO TestTree
tests = do
  files <- replTestFiles
  pure $ testGroup "Repl Tests"
    [ testGroup "in-memory db" (runFileReplTest mockPactDb <$> files)
    , testGroup "sqlite db" (runFileReplTestSqlite <$> files)
    ]


enhanceModuleData :: ModuleData RawBuiltin () -> ModuleData ReplRawBuiltin SpanInfo
enhanceModuleData = \case
  ModuleData em defs -> undefined
  InterfaceData ifd defs -> undefined

stripModuleData :: ModuleData ReplRawBuiltin SpanInfo -> ModuleData RawBuiltin ()
stripModuleData = \case
  ModuleData em defs -> undefined
  InterfaceData ifd defs -> undefined

enhanceEvalModule :: EvalModule RawBuiltin () -> EvalModule ReplRawBuiltin SpanInfo
enhanceEvalModule Module
  { _mName
  , _mGovernance
  , _mDefs
  , _mBlessed
  , _mImports
  , _mImplements
  , _mHash
  , _mInfo
  } = Module
      { _mName
      , _mGovernance
      , _mDefs = undefined _mDefs
      , _mBlessed
      , _mImports
      , _mImplements
      , _mHash
      , _mInfo = def
      }


replTestDir :: [Char]
replTestDir = "pact-core-tests" </> "pact-tests"

replTestFiles :: IO [FilePath]
replTestFiles = do
  filter (\f -> isExtensionOf "repl" f || isExtensionOf "pact" f) <$> getDirectoryContents replTestDir

runFileReplTest :: IO (PactDb (ReplBuiltin RawBuiltin) SpanInfo) -> TestName -> TestTree
runFileReplTest mkPactDb file = testCase file $ do
  pdb <- mkPactDb
  B.readFile (replTestDir </> file) >>= runReplTest pdb file

-- enhance :: PactDb RawBuiltin () -> PactDb ReplRawBuiltin SpanInfo
-- enhance pdb = PactDb
--   { _pdbPurity = _pdbPurity pdb
--   , _pdbRead  = \case
--       (DUserTables tbl) -> _pdbRead pdb (DUserTables tbl)
--       DKeySets -> readKeySet pdb
--       DModules -> \k -> fmap enhanceModule <$> readModule pdb k
--       DNamespaces -> readNamespace pdb
--       DDefPacts -> readDefPacts pdb
--   , _pdbWrite = \wt -> \case
--       (DUserTables tbl) -> _pdbWrite pdb wt (DUserTables tbl)
--       DKeySets -> writeKeySet pdb wt
--       DModules -> \k v -> writeModule pdb wt k (stripModule v)
--       DNamespaces -> writeNamespace pdb wt
--       DDefPacts -> writeDefPacts pdb wt
--   , _pdbKeys = undefined
--   , _pdbCreateUserTable = _pdbCreateUserTable pdb
--   , _pdbBeginTx = _pdbBeginTx pdb
--   , _pdbCommitTx = _pdbCommitTx pdb
--   , _pdbRollbackTx = _pdbRollbackTx pdb
--   , _pdbTxIds = _pdbTxIds pdb
--   , _pdbGetTxLog = _pdbGetTxLog pdb
--   , _pdbTxId = _pdbTxId pdb
--   }
--   where
--     enhanceModule :: ModuleData RawBuiltin () -> ModuleData ReplRawBuiltin SpanInfo
--     enhanceModule m = m
--       & moduleDataBuiltin %~ RBuiltinWrap
--       & moduleDataInfo %~ const def
      
--     stripModule :: ModuleData ReplRawBuiltin SpanInfo -> ModuleData RawBuiltin ()
--     stripModule m = m
--       & moduleDataInfo %~ const ()
--       & moduleDataBuiltin %~ \(RBuiltinWrap b) -> b

-- deriving instance Read (ModuleData ReplRawBuiltin SpanInfo)
-- deriving instance Read (EvalDef ReplRawBuiltin SpanInfo)
-- deriving instance Read (EvalModule ReplRawBuiltin SpanInfo)
-- deriving instance Read (Governance Name)

-- sillySerialise :: PactSerialise ReplRawBuiltin SpanInfo
-- sillySerialise = serialisePact
--   { _encodeModuleData = BSC.pack . show
--   , _decodeModuleData = Just . LegacyDocument . read . BSC.unpack
--   }

runFileReplTestSqlite :: TestName -> TestTree
runFileReplTestSqlite file = testCase file $ do
  ctnt <- B.readFile (replTestDir </> file)
  withSqlitePactDb undefined ":memory:" $ \pdb -> do
    runReplTest pdb file ctnt

  

runReplTest :: PactDb ReplRawBuiltin SpanInfo -> FilePath -> ByteString -> Assertion
runReplTest pdb file src = do
  gasRef <- newIORef (Gas 0)
  gasLog <- newIORef Nothing
  let ee = defaultEvalEnv pdb replRawBuiltinMap
      source = SourceCode (takeFileName file) src
  let rstate = ReplState
            { _replFlags =  mempty
            , _replEvalState = def
            , _replPactDb = pdb
            , _replGas = gasRef
            , _replEvalLog = gasLog
            , _replCurrSource = source
            , _replEvalEnv = ee
            , _replTx = Nothing
            }
  stateRef <- newIORef rstate
  runReplT stateRef (interpretReplProgram source (const (pure ()))) >>= \case
    Left e -> let
      rendered = replError (ReplSource (T.pack file) (decodeUtf8 src)) e
      in assertFailure (T.unpack rendered)
    Right output -> traverse_ ensurePassing output
  where
  ensurePassing = \case
    RCompileValue (InterpretValue (IPV v i)) -> case v of
      PLiteral (LString msg) -> do
        let render = replError (ReplSource (T.pack file) (decodeUtf8 src)) (PEExecutionError (EvalError msg) i)
        when (T.isPrefixOf "FAILURE:" msg) $ assertFailure (T.unpack render)
      _ -> pure ()
    _ -> pure ()

