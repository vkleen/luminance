{-# LANGUAGE CPP #-}

-----------------------------------------------------------------------------
-- |
-- Copyright   : (C) 2015, 2016 Dimitri Sabadie
-- License     : BSD3
--
-- Maintainer  : Dimitri Sabadie <dimitri.sabadie@gmail.com>
-- Stability   : experimental
-- Portability : portable
----------------------------------------------------------------------------

module Graphics.Luminance.Core.Shader.Stage where

import Control.Applicative ( liftA2 )
import Control.Monad ( unless )
import Control.Monad.Except ( MonadError(throwError) )
import Control.Monad.IO.Class ( MonadIO(..) )
import Control.Monad.Trans.Resource ( MonadResource, register )
import Graphics.GL
import Graphics.Luminance.Core.Debug
import Graphics.Luminance.Core.Query ( getGLExtensions )
import Foreign.C.String ( peekCString, withCString )
import Foreign.Marshal.Alloc ( alloca )
import Foreign.Marshal.Array ( allocaArray )
import Foreign.Marshal.Utils ( with )
import Foreign.Ptr ( castPtr, nullPtr )
import Foreign.Storable ( peek )

--------------------------------------------------------------------------------
-- Shader stages ---------------------------------------------------------------

-- |A shader 'Stage'.
newtype Stage = Stage { stageID :: GLuint } deriving (Eq,Show)

-- |A shader 'Stage' type.
data StageType
  = TessControlShader
  | TessEvaluationShader
  | VertexShader
  | GeometryShader
  | FragmentShader
    deriving (Eq,Show)

fromStageType :: StageType -> GLenum
fromStageType st = case st of
  TessControlShader -> GL_TESS_CONTROL_SHADER
  TessEvaluationShader -> GL_TESS_EVALUATION_SHADER
  VertexShader -> GL_VERTEX_SHADER
  GeometryShader -> GL_GEOMETRY_SHADER
  FragmentShader -> GL_FRAGMENT_SHADER

-- |Create a shader stage from a 'String' representation of its source code and its type.
--
-- Note: on some hardware and backends, /tessellation shaders/ aren’t available. That function
-- throws 'UnsupportedStage' error in such cases.
createStage :: (HasStageError e,MonadError e m,MonadResource m)
            => StageType
            -> String
            -> m Stage
createStage stageType src = do
    -- check whether we can create such a stage
    case stageType of
      TessControlShader -> checkTessSupport
      TessEvaluationShader -> checkTessSupport
      _ -> pure ()
    mkShader stageType src
  where
    checkTessSupport = do
      exts <- getGLExtensions
      unless ("GL_ARB_tessellation_shader" `elem` exts) . throwError $
        fromStageError (UnsupportedStage stageType)

-- Create a shader from the kind of shader and its source code 'String' representation.
mkShader :: (HasStageError e,MonadError e m,MonadResource m)
         => StageType 
         -> String
         -> m Stage
mkShader stageType src = do
  (sid,compiled,cl) <- liftIO $ do
    sid <- debugGL $ glCreateShader (fromStageType stageType)
    withCString (prependGLSLPragma src) $ \cstr -> do
      with cstr $ \pcstr -> debugGL $ glShaderSource sid 1 pcstr nullPtr
      debugGL $ glCompileShader sid
      compiled <- isCompiled sid
      ll <- clogLength sid
      cl <- clog ll sid
      pure (sid,compiled,cl)
  unless compiled $ do
    liftIO (glDeleteShader sid)
    throwError . fromStageError . CompilationFailed $ show stageType ++ ": " ++ cl
  _ <- register $ glDeleteShader sid
  pure $ Stage sid

-- Is a shader compiled?
isCompiled :: GLuint -> IO Bool
isCompiled sid = do
  ok <- debugGL . alloca $ liftA2 (*>) (glGetShaderiv sid GL_COMPILE_STATUS) peek
  pure $ ok == GL_TRUE

-- Shader compilation log’s length.
clogLength :: GLuint -> IO Int
clogLength sid =
  fmap fromIntegral . debugGL . alloca $
    liftA2 (*>) (glGetShaderiv sid GL_INFO_LOG_LENGTH) peek

-- Shader compilation log.
clog :: Int -> GLuint -> IO String
clog l sid =
  debugGL . allocaArray l $
    liftA2 (*>) (glGetShaderInfoLog sid (fromIntegral l) nullPtr)
      (peekCString . castPtr)

prependGLSLPragma :: String -> String
prependGLSLPragma src = unlines
  [
#if defined(__GL45)
    "#version 450 core"
#elif defined(__GL33)
    "#version 330 core"
  , "#extension GL_ARB_separate_shader_objects : require"
#endif
#if defined(__GL_BINDLESS_TEXTURES)
  , "#extension GL_ARB_bindless_texture : require"
  , "layout (bindless_sampler) uniform;"
#endif
  , src
  ]

--------------------------------------------------------------------------------
-- Shader stage errors ---------------------------------------------------------

-- |Error type of shaders.
--
-- 'CompilationFailed reason' occurs when a shader fails to compile, and the 'String' 'reason'
-- contains a description of the failure.
--
-- 'UnsupportedStage stage' occurs when you try to create a shader which type is not supported on
-- the current hardware.
data StageError
  = CompilationFailed String 
  | UnsupportedStage StageType
    deriving (Eq,Show)

-- |Types that can handle 'StageError'.
class HasStageError a where
  fromStageError :: StageError -> a
