{-# LANGUAGE UndecidableInstances #-}

-----------------------------------------------------------------------------
-- |
-- Copyright   : (C) 2015 Dimitri Sabadie
-- License     : BSD3
--
-- Maintainer  : Dimitri Sabadie <dimitri.sabadie@gmail.com>
-- Stability   : experimental
-- Portability : portable
-----------------------------------------------------------------------------

module Graphics.Luminance.Framebuffer where

import Control.Monad.IO.Class ( MonadIO(..) )
import Control.Monad.Trans.Resource ( MonadResource, register )
import Foreign.Marshal.Alloc ( alloca )
import Foreign.Marshal.Utils ( with )
import Foreign.Storable ( peek )
import Graphics.GL
import Graphics.Luminance.Pixel ( Format(..), Pixel )
import Graphics.Luminance.Texture ( Texture2D(textureID), createTexture )
import Numeric.Natural ( Natural )

data Framebuffer rw c d = Framebuffer {
    framebufferID :: GLint
  , framebufferW  :: Natural
  , framebufferH  :: Natural
  , framebufferMM :: Natural
  } deriving (Eq,Show)

type ColorFramebuffer rw c = Framebuffer rw c ()
type DepthFramebuffer rw d = Framebuffer rw () d

-- |A chain of types, right-associated.
data a :. b = a :. b deriving (Eq,Functor,Ord,Show)

infixr 6 :.

data Attachment
  = ColorAttachment Natural
  | DepthAttachment
  deriving (Eq,Ord,Show)

fromAttachment :: (Eq a,Num a) => Attachment -> a
fromAttachment a = case a of
  ColorAttachment i -> GL_TEXTURE0 + fromIntegral i
  DepthAttachment   -> GL_DEPTH_ATTACHMENT

createFramebuffer :: forall c d m rw. (MonadIO m,MonadResource m,FramebufferAttachment c,FramebufferAttachment d)
                  => Natural
                  -> Natural
                  -> Natural
                  -> m (Framebuffer rw c d)
createFramebuffer w h mipmaps = do
  fid <- liftIO . alloca $ \p -> do
    glCreateFramebuffers 1 p
    peek p
  hasColor <- createFramebufferTexture (ColorAttachment 0) (undefined :: c) fid w h mipmaps
  hasDepth <- createFramebufferTexture DepthAttachment (undefined :: d) fid w h mipmaps
  _ <- register . with fid $ glDeleteFramebuffers 1
  pure $ Framebuffer (fromIntegral fid) w h mipmaps

class FramebufferAttachment a where
  createFramebufferTexture :: (MonadIO m,MonadResource m)
                           => Attachment
                           -> a
                           -> GLuint
                           -> Natural
                           -> Natural
                           -> Natural
                           -> m Bool

instance FramebufferAttachment () where
  createFramebufferTexture _ _ _ _ _ _ = pure False

instance (Pixel (Format t c)) => FramebufferAttachment (Format t c) where
  createFramebufferTexture ca _ fid w h mipmaps = do
    tex :: Texture2D (Format t c) <- createTexture w h mipmaps
    liftIO $ glNamedFramebufferTexture fid (fromAttachment ca)
      (textureID tex) 0
    pure True

instance (FramebufferAttachment a,FramebufferAttachment b) => FramebufferAttachment (a :. b) where
  createFramebufferTexture ca _ fid w h mipmaps = case ca of
    ColorAttachment i -> do
      _ <- createFramebufferTexture ca (undefined :: a) fid w h mipmaps
      createFramebufferTexture (ColorAttachment $ succ i) (undefined :: b) fid w h mipmaps
    _ -> pure False
