{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Test.IO.Mafia.Chaos where

import           Control.Exception (IOException)
import           Control.Monad.Catch (MonadCatch(..), bracket, handle)
import           Control.Monad.IO.Class (MonadIO(..))

import           Disorder.Corpus (muppets, viruses)
import           Disorder.Core.IO (testIO)

import           Data.Char (toUpper)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import           Mafia.Git
import           Mafia.IO
import           Mafia.Path
import           Mafia.Process

import           P

import           System.IO (IO, print)
import           System.IO.Temp (withSystemTempDirectory)

import           Test.QuickCheck (Arbitrary(..), Gen, Property, Testable(..))
import           Test.QuickCheck (forAllProperties)
import qualified Test.QuickCheck as QC

import           X.Control.Monad.Trans.Either (EitherT(..), firstEitherT, hoistEither)

------------------------------------------------------------------------

data ChaosError =
    GitError     GitError
  | ProcessError ProcessError
  | ExpectedBuildFailure
  deriving (Show)

type PackageName   = Text
type SubmoduleName = Text

data Repo = Repo {
    repoFocusPackage  :: PackageDeps
  , repoOtherPackages :: Map PackageName PackageDeps
  } deriving (Eq, Ord, Show)

data PackageDeps = PackageDeps {
    depSubmodules    :: Set SubmoduleName
  , depLocalPackages :: Set PackageName
  } deriving (Eq, Ord, Show)

newtype Actions = Actions { unActions :: [Action] }
  deriving (Eq, Ord, Show)

data Action =
    Build
  | AddLocal     PackageName   PackageName
  | AddSubmodule SubmoduleName PackageName
  | RemoveLocal     PackageName
  | RemoveSubmodule SubmoduleName
  -- Sidestep = temporarily move out the way, try to build, then move back to
  -- the valid location. Useful to test that caching works even across invalid
  -- source states.
  | SidestepLocal     PackageName
  | SidestepSubmodule SubmoduleName
  deriving (Eq, Ord, Show)

repoSubmodules :: Repo -> Set SubmoduleName
repoSubmodules (Repo focus others) =
  let fs = depSubmodules focus
      os = Set.unions (fmap depSubmodules (Map.elems others)) in
  Set.union fs os

emptyRepo :: Repo
emptyRepo = Repo emptyPackageDeps Map.empty

emptyPackageDeps :: PackageDeps
emptyPackageDeps = PackageDeps Set.empty Set.empty

fromTestRun :: [(Action, Repo)] -> [Action]
fromTestRun = fmap fst

fromActions :: [Action] -> Maybe [(Action, Repo)]
fromActions = fromActions' emptyRepo

fromActions' :: Repo -> [Action] -> Maybe [(Action, Repo)]
fromActions' _    []       = Just []
fromActions' repo (a : as) = do
  repo' <- applyAction a repo
  xs    <- fromActions' repo' as
  pure $ (a, repo') : xs

finalRepo :: [(Action, Repo)] -> Repo
finalRepo = \case
  []             -> emptyRepo
  ((_, repo):[]) -> repo
  (_:xs)         -> finalRepo xs

------------------------------------------------------------------------

instance Arbitrary Actions where
  arbitrary =
    fmap (Actions . fromTestRun) . QC.sized $ \n -> do
      k <- QC.choose (0, n)
      genTestRun k

  shrink (Actions as) = Actions <$> do
    as' <- QC.shrinkList shrinkAction as
    case fromActions as' of
      Nothing -> pure []
      Just _  -> pure as'

shrinkAction :: Action -> [Action]
shrinkAction = \case
  AddLocal     dep pkg
   | pkg /= focusPackageName -> [AddLocal     dep focusPackageName]
   | otherwise               -> []
  AddSubmodule dep pkg
   | pkg /= focusPackageName -> [AddSubmodule dep focusPackageName]
   | otherwise               -> []
  Build                      -> []
  RemoveLocal     _          -> []
  RemoveSubmodule _          -> []
  SidestepLocal     _        -> []
  SidestepSubmodule _        -> []

genTestRun :: Int -> Gen [(Action, Repo)]
genTestRun n
  | n <= 0    = pure []
  | otherwise = do
      testRun <- genTestRun (n - 1)

      let repo = finalRepo testRun
      action <- genAction (finalRepo testRun)

      pure . fromMaybe testRun
           . fmap (\r -> testRun <> [(action, r)])
           $ applyAction action repo

genAction :: Repo -> Gen Action
genAction repo@(Repo _ others) = do
  mbLocalPackageNames <- oneOfSet localPackageNames
  mbSubmoduleNames    <- oneOfSet submoduleNames

  let removableLocals = Map.keysSet others
      availableLocals = Set.insert focusPackageName
                      . maybe id Set.delete mbLocalPackageNames
                      $ removableLocals

  mbRemovableLocals     <- oneOfSet removableLocals
  mbAvailableLocals     <- oneOfSet availableLocals
  mbRemovableSubmodules <- oneOfSet (repoSubmodules repo)

  QC.elements $ catMaybes [
      Just Build
    , AddLocal          <$> mbLocalPackageNames <*> mbAvailableLocals
    , AddSubmodule      <$> mbSubmoduleNames    <*> mbAvailableLocals
    , RemoveLocal       <$> mbRemovableLocals
    , RemoveSubmodule   <$> mbRemovableSubmodules
    , SidestepLocal     <$> mbRemovableLocals
    , SidestepSubmodule <$> mbRemovableSubmodules
    ]

focusPackageName :: PackageName
focusPackageName = "chaos-focus"

localPackageNames :: Set PackageName
localPackageNames = Set.fromList (("chaos-" <>) . T.replace " " "-" <$> viruses)

submoduleNames :: Set SubmoduleName
submoduleNames = Set.fromList (T.replace " " "-" <$> muppets)

oneOfSet :: Set a -> Gen (Maybe a)
oneOfSet xs
  | Set.null xs = pure Nothing
  | otherwise   = Just <$> QC.elements (Set.toList xs)

applyAction :: Action -> Repo -> Maybe Repo
applyAction action =
  let mustModify f g repo = if g repo == repo
                            then Nothing
                            else Just (f (repo, g repo))
  in case action of
    Build                     -> Just . id
    AddLocal          dep pkg -> mustModify snd (addLocal        dep pkg)
    AddSubmodule      dep pkg -> mustModify snd (addSubmodule    dep pkg)
    RemoveLocal       dep     -> mustModify snd (removeLocal     dep)
    RemoveSubmodule   dep     -> mustModify snd (removeSubmodule dep)
    SidestepLocal     dep     -> mustModify fst (removeLocal     dep)
    SidestepSubmodule dep     -> mustModify fst (removeSubmodule dep)

addLocal :: PackageName -> PackageName -> Repo -> Repo
addLocal dep pkg repo@(Repo f os)
  | pkgIsFocus = Repo (addLocal' dep f) os'
  | isCircular = repo
  | pkgExists  = Repo f (Map.adjust (addLocal' dep) pkg os')
  | otherwise  = repo
  where
    pkgIsFocus = pkg == focusPackageName
    isCircular = Set.member pkg depDeps
    pkgExists  = Map.member pkg os

    depDeps = fromMaybe Set.empty (recursiveLocals repo <$> Map.lookup dep os')
    os'     = Map.insertWith (\_ old -> old) dep emptyPackageDeps os

addLocal' :: PackageName -> PackageDeps -> PackageDeps
addLocal' dep (PackageDeps ss ls) =
  PackageDeps ss (Set.insert dep ls)

addSubmodule :: SubmoduleName -> PackageName -> Repo -> Repo
addSubmodule dep pkg (Repo f os) =
  if pkg == focusPackageName
  then Repo (addSubmodule' dep f) os
  else Repo f (Map.adjust (addSubmodule' dep) pkg os)

addSubmodule' :: SubmoduleName -> PackageDeps -> PackageDeps
addSubmodule' dep (PackageDeps ss ls) =
  PackageDeps (Set.insert dep ss) ls

recursiveLocals :: Repo -> PackageDeps -> Set PackageName
recursiveLocals repo@(Repo _ os) (PackageDeps _ ls) =
  let lookup name = fromMaybe Set.empty (recursiveLocals repo <$> Map.lookup name os) in
  Set.union (unionMap lookup ls) ls

recursiveSubmodules :: Repo -> PackageDeps -> Set SubmoduleName
recursiveSubmodules repo@(Repo _ os) (PackageDeps ss ls) =
  let lookup name = fromMaybe Set.empty (recursiveSubmodules repo <$> Map.lookup name os) in
  Set.union (unionMap lookup ls) ss

unionMap :: Ord b => (a -> Set b) -> Set a -> Set b
unionMap f = Set.foldl (\xs x -> xs `Set.union` f x) Set.empty

removeLocal :: PackageName -> Repo -> Repo
removeLocal dep (Repo f os) =
  let rm = Map.map (removeLocal' dep) . Map.delete dep in
  Repo (removeLocal' dep f) (rm os)

removeLocal' :: PackageName -> PackageDeps -> PackageDeps
removeLocal' dep (PackageDeps ss ls) =
  PackageDeps ss (Set.delete dep ls)

removeSubmodule :: SubmoduleName -> Repo -> Repo
removeSubmodule dep (Repo f os) =
  let rm = Map.map (removeSubmodule' dep) . Map.delete dep in
  Repo (removeSubmodule' dep f) (rm os)

removeSubmodule' :: SubmoduleName -> PackageDeps -> PackageDeps
removeSubmodule' dep (PackageDeps ss ls) =
  PackageDeps (Set.delete dep ss) ls

------------------------------------------------------------------------

bracketDirectory :: IO a -> IO a
bracketDirectory io = bracket getCurrentDirectory setCurrentDirectory (const io)

withTempDirectory :: Testable a => (Directory -> EitherT ChaosError IO a) -> Property
withTempDirectory io = testIO . bracketDirectory $ do
  result  <- withSystemTempDirectory "mafia.chaos" (runEitherT . io . T.pack)
  case result of
    Left  err -> return (QC.counterexample (show err) False)
    Right x   -> return (property x)

hush :: (MonadIO m, MonadCatch m) => a -> m a -> m a
hush def = handle $ \(_ :: IOException) -> return def

------------------------------------------------------------------------

writeRepo :: (MonadIO m, MonadCatch m) => Directory -> Repo -> m ()
writeRepo dir repo@(Repo focus others) = do
  writePackage dir repo focusPackageName focus
  mapM_ (\(name, pkg) -> writePackage dir repo name pkg) (Map.toList others)

writePackage :: (MonadIO m, MonadCatch m) => Directory -> Repo -> PackageName -> PackageDeps -> m ()
writePackage dir repo name pd@(PackageDeps ss ls) = do
  let deps   = Set.toList (Set.union ss ls)
      locals = Set.toList (recursiveLocals repo pd)
  writeProject (dir </> name) name deps locals

writeProject :: (MonadIO m, MonadCatch m) => Directory -> Text -> [Text] -> [Text] -> m ()
writeProject dir name deps locals = do
  let modName = dromedary name
      cabalFile = dir </> name <> ".cabal"
      subsFile  = dir </> name <> ".submodules"
      hsFile    = dir </> "src" </> modName <> ".hs"

  writeFile cabalFile (cabalText name deps)
  writeFile hsFile    ("module " <> modName <> " where\n")

  if null locals
     then removeFile subsFile `catch` \(_ :: IOException) -> return ()
     else writeFile  subsFile (T.unlines locals)

writeFile :: MonadIO m => Path -> Text -> m ()
writeFile path txt = do
  createDirectoryIfMissing True (takeDirectory path)
  writeText path txt

dromedary :: Text -> Text
dromedary = mconcat . fmap upcase . T.splitOn "-"
  where
    upcase xs | T.null xs = xs
              | otherwise = T.singleton (toUpper (T.head xs)) <> T.tail xs

cabalText :: Text -> [Text] -> Text
cabalText name deps = T.unlines [
    "name:          acme-" <> name
  , "version:       0.0.1"
  , "license:       AllRightsReserved"
  , "author:        Mafia Chaos"
  , "maintainer:    Mafia Chaos"
  , "synopsis:      synopsis"
  , "category:      Development"
  , "cabal-version: >= 1.8"
  , "build-type:    Simple"
  , "description:   description"
  , ""
  , "library"
  , "  hs-source-dirs: src"
  , "  build-depends:"
  , "      base >= 3 && < 5"
  ] <> T.unlines (fmap ("    , acme-" <>) deps)

------------------------------------------------------------------------

git :: (MonadCatch m, MonadIO m, Functor m, ProcessResult a)
    => Directory -> Argument -> [Argument] -> EitherT ChaosError m a
git dir cmd args =
  callFrom ProcessError dir "git" ([cmd] <> args)

createGitHub :: (MonadCatch m, MonadIO m, Functor m) => Path -> EitherT ChaosError m ()
createGitHub dir =
  forM_ submoduleNames $ \name -> do
    let subDir = dir </> name

    createDirectoryIfMissing True subDir

    Hush <- git subDir "init" []
    Hush <- git subDir "config" ["user.name", "Doris"]
    Hush <- git subDir "config" ["user.email", "doris@megacorp.com"]

    writeProject subDir name [] []

    Hush <- git subDir "add" ["-A"]
    Hush <- git subDir "commit" ["-m", "created project"]

    return ()

submoduleExists :: Directory -> EitherT ChaosError IO Bool
submoduleExists sub = do
  subs <- fmap subName <$> firstEitherT GitError getSubmodules
  return (sub `elem` subs)

gitAddSubmodule :: Directory -> Directory -> Path -> EitherT ChaosError IO ()
gitAddSubmodule github repoDir dep = do
  let subDir = "lib" </> dep
  exists <- submoduleExists subDir
  unless exists $ do
    Pass <- git repoDir "submodule" ["add", github </> dep, subDir]
    Pass <- git repoDir "commit" ["-m", "added " <> dep]
    return ()

gitRemoveSubmodule :: Directory -> Path -> EitherT ChaosError IO ()
gitRemoveSubmodule repoDir dep = do
  let subDir = "lib" </> dep
  exists <- submoduleExists subDir
  when exists $ do
    Pass <- git repoDir "rm" ["--cached", subDir]
    Pass <- git repoDir "commit" ["-m", "removed " <> dep]
    return ()

------------------------------------------------------------------------

prop_chaos (Actions actions) = withTempDirectory $ \temp -> do
  liftIO (print actions)

  mafia <- (</> "dist/build/mafia/mafia") <$> getCurrentDirectory

  let githubDir = temp </> "github"
      repoDir   = temp </> "repo"
      focusDir  = repoDir </> focusPackageName

  createGitHub githubDir

  createDirectoryIfMissing False repoDir
  createDirectoryIfMissing False focusDir

  Pass <- git repoDir "init" []
  Pass <- git repoDir "config" ["user.name", "Doris"]
  Pass <- git repoDir "config" ["user.email", "doris@megacorp.com"]

  setCurrentDirectory focusDir
  writeRepo repoDir emptyRepo

  case fromActions actions of
    Nothing -> do
      return (QC.counterexample "Invalid set of actions" (property False))

    Just testRun -> do
      forM_ testRun $ \(action, repo) -> do
        runAction mafia githubDir repoDir repo action
      return (property True)

runAction :: File -> Directory -> Directory -> Repo -> Action -> EitherT ChaosError IO ()
runAction mafia github repoDir repo@(Repo focus _) = \case
  Build -> do
    liftIO (T.putStrLn "$ mafia build")
    expectBuildSuccess mafia

  AddLocal dep pkg -> do
    putAdd (dep <> " -> " <> pkg)
    writeRepo repoDir repo

  AddSubmodule dep pkg -> do
    putAdd ("lib" </> dep <> " -> " <> pkg)
    gitAddSubmodule github repoDir dep
    writeRepo repoDir repo

  RemoveLocal dep -> do
    putRemove dep
    removeDirectoryRecursive (repoDir </> dep)
    writeRepo repoDir repo

  RemoveSubmodule dep -> do
    putRemove ("lib" </> dep)
    gitRemoveSubmodule repoDir dep
    writeRepo repoDir repo

  SidestepLocal dep -> do
    putSidestep dep
    removeDirectoryRecursive (repoDir </> dep)

    if Set.member dep (recursiveLocals repo focus)
    then expectBuildFailure mafia
    else expectBuildSuccess mafia

    writeRepo repoDir repo

  SidestepSubmodule dep -> do
    putSidestep ("lib" </> dep)
    gitRemoveSubmodule repoDir dep

    if Set.member dep (recursiveSubmodules repo focus)
    then expectBuildFailure mafia
    else expectBuildSuccess mafia

    gitAddSubmodule github repoDir dep

expectBuildSuccess :: File -> EitherT ChaosError IO ()
expectBuildSuccess mafia =
  call_ ProcessError mafia ["build"]

expectBuildFailure :: File -> EitherT ChaosError IO ()
expectBuildFailure mafia = do
  result <- liftIO . runEitherT $ call_ id mafia ["build"]
  hoistEither $ case result of
    Left _   -> Right ()
    Right () -> Left ExpectedBuildFailure

putAdd :: MonadIO m => Text -> m ()
putAdd x = liftIO (T.putStrLn ("+ " <> x))

putRemove :: MonadIO m => Text -> m ()
putRemove x = liftIO (T.putStrLn ("- " <> x))

putSidestep :: MonadIO m => Text -> m ()
putSidestep x = liftIO (T.putStrLn ("~ " <> x))

------------------------------------------------------------------------

return []
tests = $forAllProperties $ QC.quickCheckWithResult (QC.stdArgs {QC.maxSuccess = 10})