module CBT.Backend (Backend(..)) where

import CBT.Environment
import CBT.Prelude
import CBT.Types
import Control.Exception (Exception)
import Control.Monad (unless)
import Data.Maybe (isJust)
import Data.Monoid (mconcat)
import Text.Read (readMaybe)

import qualified CBT.Backend.Tar       as Tar
import qualified CBT.IncrementalState  as IncrementalState
import qualified Colog
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Lazy  as LBS
import qualified Data.List             as List
import qualified Data.Text             as Text
import qualified Data.Text.Encoding    as Text
import qualified System.Exit           as Exit
import qualified System.Path           as Path
import qualified System.Path.Directory as Path
import qualified System.Process.Typed  as Process
import qualified UnliftIO.Exception    as Exception

newtype ContainerRunFailure = ContainerRunFailure
  { containerDefinition :: ContainerDefinition }

instance Exception ContainerRunFailure

instance Show ContainerRunFailure where
  show ContainerRunFailure{..} = "Failed to run container with name: " <> convertText (containerName containerDefinition)

class Backend (b :: Implementation) where
  binaryName        :: String
  getHostPort       :: WithEnv m env => ContainerName -> Port -> m Port
  testImageExists   :: WithEnv m env => BuildDefinition -> m Bool

  available :: WithEnv m env => m Bool
  available = isJust <$> liftIO (Path.findExecutable (binaryName @b))

  buildIfAbsent :: WithEnv m env => BuildDefinition -> m ()
  buildIfAbsent buildDefinition@BuildDefinition{..} = do
    exists <- testImageExists @b buildDefinition

    unless exists (build @b buildDefinition)

  printLogs :: WithEnv m env => ContainerName -> m ()
  printLogs containerName
    = runProcess_
    $ backendProc @b
    [ "container"
    , "logs"
    , convertText containerName
    ]

  commit :: WithEnv m env => ContainerName -> ImageName -> m ()
  commit containerName imageName
    = runProcess_
    $ backendProc @b
    [ "container"
    , "commit"
    , convertText containerName
    , convertText imageName
    ]

  printInspect :: WithEnv m env => ContainerName -> m ()
  printInspect containerName
    = runProcess_
    $ backendProc @b
    [ "container"
    , "inspect"
    , convertText containerName
    ]

  status :: WithEnv m env => ContainerName -> m Status
  status containerName
    = mapStatus <$> runProcess proc
    where
      mapStatus = \case
        Exit.ExitSuccess -> Running
        _                -> Absent

      proc = silenceStdout $ backendProc @b ["container", "inspect", convertText containerName]

  build :: WithEnv m env => BuildDefinition -> m ()
  build BuildDefinition{..}
    = do
      Environment{..} <- getEnvironment
      void
        . IncrementalState.runBuild builds imageName
        . fmap fromExit
        . runProcess
        . setVerbosity verbosity
        . Process.setStdin (Process.byteStringInput . LBS.fromStrict . Text.encodeUtf8 $ toText content)
        $ Process.proc (binaryName @b) ["build", "--tag", convertText imageName, "-"]
    where
      fromExit :: Exit.ExitCode -> Either ImageBuildError ()
      fromExit = \case
        Exit.ExitSuccess -> pure ()
        _                -> Left $ ImageBuildError "process exited with nonzero"

  buildRun :: WithEnv m env => BuildDefinition -> ContainerDefinition -> m ()
  buildRun buildDefinition containerDefinition =
    buildIfAbsent @b buildDefinition >> run @b containerDefinition

  run :: WithEnv m env => ContainerDefinition -> m ()
  run containerDefinition@ContainerDefinition{..} =
    handleFailure @b containerDefinition () =<< runProcess (runProc @b containerDefinition)

  runReadStdout :: WithEnv m env => ContainerDefinition -> m BS.ByteString
  runReadStdout containerDefinition = do
    (exitCode, output) <- readProcessStdout $ runProc @b containerDefinition'
    handleFailure @b containerDefinition (convert output) exitCode
    where
      containerDefinition' = containerDefinition { detach = Foreground }

  readContainerFile
    :: forall m env .WithEnv m env
    => ContainerName
    -> Path.AbsFile -> m BS.ByteString
  readContainerFile containerName path = do
    tar <- readProcessStdout_ proc
    maybe notFound (pure . LBS.toStrict) . Tar.findEntry tar $ Path.takeFileName path
    where
      notFound :: m BS.ByteString
      notFound = liftIO $ fail "Tar from docker did not contain expected entry"

      proc
        = Process.proc (binaryName @b)
        [ "container"
        , "cp"
        , convertText containerName <> ":" <> Path.toString path
        , "-"
        ]

  removeContainer :: WithEnv m env => ContainerName -> m ()
  removeContainer containerName
    = runProcess_
    . silenceStdout
    $ backendProc @b
    [ "container"
    , "rm"
    , convertText containerName
    ]

  stop :: WithEnv m env => ContainerName -> m ()
  stop containerName
    = runProcess_
    . silenceStdout
    $ backendProc @b ["stop", convertText containerName]

  withContainer
    :: (WithEnv m env, MonadUnliftIO m)
    => BuildDefinition
    -> ContainerDefinition
    -> m a
    -> m a
  withContainer buildDefinition containerDefinition@ContainerDefinition{..} =
    Exception.bracket_ (buildRun @b buildDefinition containerDefinition) (stop @b containerName)

  withContainerDefinition
    :: (WithEnv m env, MonadUnliftIO m)
    => ContainerDefinition
    -> m a
    -> m a
  withContainerDefinition containerDefinition@ContainerDefinition{..} =
    Exception.bracket_ (run @b containerDefinition) (stop @b containerName)

backendProc :: forall b . Backend b => [String] -> Proc
backendProc = Process.proc (binaryName @b)

runProc
  :: forall b . Backend b
  => ContainerDefinition
  -> Proc
runProc ContainerDefinition{..} = detachSilence $ backendProc @b containerArguments
  where
    containerArguments :: [String]
    containerArguments = mconcat
      [
        [ "run"
        , "--name", convertText containerName
        , "--workdir", Path.toString workDir
        ]
      , detachFlag
      , mountOptions
      , publishOptions
      , removeFlag
      , [ "--"
        , convertText imageName
        ]
      ] <> [programName] <> programArguments
      where
        publishOptions :: [String]
        publishOptions = mconcat $ mkPublish <$> publishPorts

        mkPublish :: PublishPort -> [String]
        mkPublish PublishPort{..} = ["--publish", "127.0.0.1:" <> hostPort <> ":" <> containerPort]
          where
            hostPort      = maybe "" toPort host
            containerPort = toPort container

            toPort (Port port) = show port

        mountOptions :: [String]
        mountOptions = mconcat $ mkMount <$> mounts

        mkMount :: Mount -> [String]
        mkMount Mount{..} = ["--mount", bindMount]
          where
            bindMount
              = List.intercalate
              ","
              [ "type=bind"
              , "source="      <> Path.toString hostPath
              , "destination=" <> Path.toString containerPath
              ]

        removeFlag :: [String]
        removeFlag = case remove of
          Remove   -> ["--rm"]
          NoRemove -> []

        detachFlag :: [String]
        detachFlag = case detach of
          Detach     -> ["--detach"]
          Foreground -> []

    detachSilence :: Proc -> Proc
    detachSilence =
      case detach of
        Detach -> silenceStdout
        _      -> identity

instance Backend 'Podman where
  binaryName = "podman"

  getHostPort containerName containerPort' = parsePort =<< captureText proc
    where
      proc = Process.proc (binaryName @'Podman)
        [ "container"
        , "inspect"
        , convertText containerName
        , "--format"
        , template
        ]

      template =
        mkTemplate $
          mkField "HostPort" $
            mkIndex "0" $
              mkIndex (show $ (convertText containerPort' :: String) <> "/tcp") $
                mkField "PortBindings" $
                  mkField "HostConfig" ""

  testImageExists BuildDefinition{..} = exitBool <$> runProcess process
    where
      process =
        Process.proc
          (binaryName @'Podman)
          [ "image"
          , "exists"
          , "--"
          , convertText imageName
          ]

instance Backend 'Docker where
  binaryName = "docker"

  getHostPort containerName containerPort' = parsePort =<< captureText proc
    where
      proc = Process.proc (binaryName @'Docker)
        [ "container"
        , "inspect"
        , convertText containerName
        , "--format"
        , template
        ]

      template =
        mkTemplate $
          mkField "HostPort" $
            mkIndex "0" $
              mkIndex (show $ (convertText containerPort' :: String) <> "/tcp") $
                mkField "Ports" $
                  mkField "NetworkSettings" ""

  testImageExists BuildDefinition{..} = exitBool <$> runProcess process
    where
      process
        = silenceStdout
        $ Process.proc (binaryName @'Docker)
        [ "inspect"
        , "--type", "image"
        , "--"
        , convertText imageName
        ]

type Proc = Process.ProcessConfig () () ()

setVerbosity :: Verbosity -> Proc -> Proc
setVerbosity = \case
  Quiet -> silence
  _     -> identity

silenceStderr :: Proc -> Proc
silenceStderr = Process.setStderr Process.nullStream

silenceStdout :: Proc -> Proc
silenceStdout = Process.setStdout Process.nullStream

silence :: Proc -> Proc
silence = silenceStdout . silenceStderr

mkTemplate :: String -> String
mkTemplate exp = mconcat ["{{", exp, "}}"]

mkField :: String -> String -> String
mkField key exp = exp <> ('.':key)

mkIndex :: String -> String -> String
mkIndex index exp = mconcat ["(", "index", " ", exp, " ", index, ")"]

exitBool :: Exit.ExitCode -> Bool
exitBool = \case
  Exit.ExitSuccess -> True
  _                -> False

parsePort :: forall m env a . (WithEnv m env, ToText a, Show a) => a -> m Port
parsePort input = maybe failParse (pure . Port) . readMaybe $ convertText input
  where
    failParse :: m Port
    failParse = liftIO . fail $ "Cannot parse PostgresqlPort from input: " <> show input

runProcess
  :: forall m env stdin stdout stderr . (WithEnv m env)
  => Process.ProcessConfig stdin stdout stderr
  -> m Exit.ExitCode
runProcess proc = procRun proc Process.runProcess

runProcess_
  :: forall m env stdin stdout stderr . (WithEnv m env)
  => Process.ProcessConfig stdin stdout stderr
  -> m ()
runProcess_ proc = procRun proc Process.runProcess_

readProcessStdout_
  :: forall m env stdin stdout stderr . (WithEnv m env)
  => Process.ProcessConfig stdin stdout stderr
  -> m LBS.ByteString
readProcessStdout_ proc = procRun proc Process.readProcessStdout_

readProcessStdout
  :: forall m env stdin stdout stderr . (WithEnv m env)
  => Process.ProcessConfig stdin stdout stderr
  -> m (Exit.ExitCode, LBS.ByteString)
readProcessStdout proc = procRun proc Process.readProcessStdout

procRun
  :: forall m a env stdin stdout stderr . (WithEnv m env)
  => Process.ProcessConfig stdin stdout stderr
  -> (Process.ProcessConfig stdin stdout stderr -> IO a)
  -> m a
procRun proc action = onDebug (Colog.logDebug . convert $ show proc) >> liftIO (action proc)

handleFailure
  :: forall b env m a . (Backend b, WithEnv m env)
  => ContainerDefinition
  -> a
  -> Exit.ExitCode
  -> m a
handleFailure containerDefinition@ContainerDefinition{..} value = \case
  Exit.ExitSuccess -> pure value
  _ -> do
    case (remove, removeOnRunFail) of
      (NoRemove, Remove) -> removeContainer @b containerName
      _                  -> pure ()
    Exception.throwIO $ ContainerRunFailure containerDefinition

captureText
  :: forall m env stdin stdout stderr . (WithEnv m env)
  => Process.ProcessConfig stdin stdout stderr
  -> m Text
captureText proc
  =   Text.strip
  .   Text.decodeUtf8
  .   LBS.toStrict
  <$> readProcessStdout_ proc
