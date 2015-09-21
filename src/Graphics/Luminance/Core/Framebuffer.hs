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

module Graphics.Luminance.Core.Framebuffer where

import Control.Monad ( unless )
import Control.Monad.Except ( MonadError(..) )
import Control.Monad.IO.Class ( MonadIO(..) )
import Control.Monad.Trans.Resource ( MonadResource, register )
import Data.Bits ( (.|.) )
import Data.Proxy ( Proxy(..) )
import Foreign.Marshal.Alloc ( alloca )
import Foreign.Marshal.Array ( withArrayLen )
import Foreign.Marshal.Utils ( with )
import Foreign.Storable ( peek )
import Graphics.GL
import Graphics.Luminance.Core.Debug
import Graphics.Luminance.Core.Pixel
import Graphics.Luminance.Core.Renderbuffer ( createRenderbuffer, renderbufferID )
import Graphics.Luminance.Core.RW
import Graphics.Luminance.Core.Texture
import Graphics.Luminance.Core.Tuple
import Numeric.Natural ( Natural )

---------------------------------------------------------------------------------
-- Framebuffer ------------------------------------------------------------------

data Framebuffer rw c d = Framebuffer {
    framebufferID :: GLuint
  , framebufferOutput :: Output c d
  }

type ColorFramebuffer rw c = Framebuffer rw c ()
type DepthFramebuffer rw d = Framebuffer rw () d

newtype FramebufferError = IncompleteFramebuffer String deriving (Eq,Show)

class HasFramebufferError a where
  fromFramebufferError :: FramebufferError -> a

createFramebuffer :: forall c d e m rw. (HasFramebufferError e,MonadError e m,MonadIO m,MonadResource m,FramebufferColorAttachment c,FramebufferColorRW rw,FramebufferDepthAttachment d,FramebufferTarget rw)
                  => Natural
                  -> Natural
                  -> Natural
                  -> m (Framebuffer rw c d)
createFramebuffer w h mipmaps = do
  fid <- liftIO . alloca $ \p -> do
    debugGL "createFramebuffer" $ glCreateFramebuffers 1 p
    peek p
  (colorOutputNb,colorTexs) <- addColorOutput fid 0 w h mipmaps (Proxy :: Proxy c)
  (hasDepthOutput,depthTex) <- addDepthOutput fid w h mipmaps (Proxy :: Proxy d)
  setColorBuffers fid colorOutputNb (Proxy :: Proxy rw)
  unless hasDepthOutput $ setDepthRenderbuffer fid w h
  _ <- register . with fid $ glDeleteFramebuffers 1
  status <- glCheckNamedFramebufferStatus fid $ framebufferTarget (Proxy :: Proxy rw)
  if 
    | status == GL_FRAMEBUFFER_COMPLETE -> pure $ Framebuffer fid (Output colorTexs depthTex)
    | otherwise -> throwError . fromFramebufferError . IncompleteFramebuffer $ translateFramebufferStatus status

translateFramebufferStatus :: GLenum -> String
translateFramebufferStatus status = case status of
  GL_FRAMEBUFFER_UNDEFINED                     -> "undefined default read or write framebuffer"
  GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT         -> "incomplete attachment"
  GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT -> "missing image attachment"
  GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER        -> "incomplete draw buffer"
  GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER        -> "incomplete read buffer"
  GL_FRAMEBUFFER_UNSUPPORTED                   -> "unsupported (internal) format(s)"
  GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE        -> "incomplete multisample configuration"
  GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS      -> "layered attachment mismatch"
  _                                            -> "unknown error"

--------------------------------------------------------------------------------
-- Framebuffer attachment ------------------------------------------------------

data Attachment
  = ColorAttachment Natural
  | DepthAttachment
  deriving (Eq,Ord,Show)

fromAttachment :: (Eq a,Num a) => Attachment -> a
fromAttachment a = case a of
  ColorAttachment i -> GL_COLOR_ATTACHMENT0 + fromIntegral i
  DepthAttachment   -> GL_DEPTH_ATTACHMENT

--------------------------------------------------------------------------------
-- Framebuffer color attachment ------------------------------------------------

class FramebufferColorAttachment c where
  addColorOutput :: (MonadIO m,MonadResource m)
                 => GLuint
                 -> Natural
                 -> Natural
                 -> Natural
                 -> Natural
                 -> proxy c
                 -> m (Natural,TexturizeFormat c)

instance FramebufferColorAttachment () where
  addColorOutput _ _ _ _ _ _ = pure (0,())

instance (ColorPixel (Format t c)) => FramebufferColorAttachment (Format t c) where
  addColorOutput fid ca w h mipmaps proxy =
    fmap (1,) $ addOutput fid (ColorAttachment ca) w h mipmaps proxy

instance (ColorPixel a,ColorPixel b,FramebufferColorAttachment a,FramebufferColorAttachment b) => FramebufferColorAttachment (a :. b) where
  addColorOutput fid ca w h mipmaps _ = do
    (d0,tex0) <- addColorOutput fid ca w h mipmaps (Proxy :: Proxy a)
    (d1,tex1) <- addColorOutput fid (succ ca) w h mipmaps (Proxy :: Proxy b)
    pure $ (d0 + d1,tex0 :. tex1)

colorAttachmentsFromMax :: Natural -> [GLenum]
colorAttachmentsFromMax m = [fromAttachment (ColorAttachment a) | a <- [0..m-1]]

setColorBuffers :: forall m proxy rw. (FramebufferColorRW rw,MonadIO m)
                => GLuint 
                -> Natural
                -> proxy rw
                -> m ()
setColorBuffers fid colorOutputNb _ = case colorOutputNb of
  0 -> do
    -- disable color outputs
    debugGL "setColorBuffers 1" $ glNamedFramebufferDrawBuffer fid GL_NONE
    debugGL "setColorBuffers 2" $ glNamedFramebufferReadBuffer fid GL_NONE
  _ -> setFramebufferColorRW fid colorOutputNb (Proxy :: Proxy rw)

--------------------------------------------------------------------------------
-- Framebuffer depth attachment ------------------------------------------------

class FramebufferDepthAttachment d where
  addDepthOutput :: (MonadIO m,MonadResource m)
                 => GLuint
                 -> Natural
                 -> Natural
                 -> Natural
                 -> proxy d
                 -> m (Bool,TexturizeFormat d)

instance FramebufferDepthAttachment () where
  addDepthOutput _ _ _ _ _ = pure (False,())

instance (Pixel (Format t (CDepth d))) => FramebufferDepthAttachment (Format t (CDepth d)) where
  addDepthOutput fid w h mipmaps proxy = fmap (True,) $ addOutput fid DepthAttachment w h mipmaps proxy

setDepthRenderbuffer :: (MonadIO m,MonadResource m)
                     => GLuint
                     -> Natural
                     -> Natural
                     -> m ()
setDepthRenderbuffer fid w h = do
  renderbuffer <- createRenderbuffer w h (Proxy :: Proxy Depth32F)
  debugGL "setDepthRenderBuffer" $ glNamedFramebufferRenderbuffer fid (fromAttachment DepthAttachment) GL_RENDERBUFFER
    (renderbufferID renderbuffer)

--------------------------------------------------------------------------------
-- Framebuffer color read/write configuration ----------------------------------

class FramebufferColorRW rw where
  setFramebufferColorRW :: (MonadIO m) => GLuint -> Natural -> proxy rw -> m ()

instance FramebufferColorRW W where
  setFramebufferColorRW fid nb _ = liftIO $ do
    withArrayLen (colorAttachmentsFromMax nb) $ \n buffers ->
      debugGL "setFramebufferColorRW[W]" $ glNamedFramebufferDrawBuffers fid (fromIntegral n) buffers

instance FramebufferColorRW RW where
  setFramebufferColorRW fid nb _ = liftIO $ do
    withArrayLen (colorAttachmentsFromMax nb) $ \n buffers ->
      debugGL "setFramebufferColorRW[RW]" $ glNamedFramebufferDrawBuffers fid (fromIntegral n) buffers

--------------------------------------------------------------------------------
-- Framebuffer read/write target configuration ---------------------------------

class FramebufferTarget rw where
  framebufferTarget :: proxy rw -> GLenum

instance FramebufferTarget R where
  framebufferTarget _ = GL_READ_FRAMEBUFFER

instance FramebufferTarget W where
  framebufferTarget _ = GL_DRAW_FRAMEBUFFER

instance FramebufferTarget RW where
  framebufferTarget _ = GL_FRAMEBUFFER

--------------------------------------------------------------------------------
-- Framebuffer outputs ---------------------------------------------------------

addOutput :: forall m p proxy. (MonadIO m,MonadResource m,Pixel p)
          => GLuint
          -> Attachment
          -> Natural
          -> Natural
          -> Natural
          -> proxy p
          -> m (Texture2D p)
addOutput fid ca w h mipmaps _ = do
  tex :: Texture2D p <- createTexture w h mipmaps defaultSampling
  debugGL "addOutput" . liftIO $ glNamedFramebufferTexture fid (fromAttachment ca)
    (textureID tex) 0
  pure tex

--------------------------------------------------------------------------------
-- Framebuffer textures accessors ----------------------------------------------

-- FIXME: name
type family TexturizeFormat a :: * where
  TexturizeFormat ()           = ()
  TexturizeFormat (Format t c) = Texture2D (Format t c)
  TexturizeFormat (a :. b)     = TexturizeFormat a :. TexturizeFormat b

-- TODO: use Output c d instead of (TexturizeFormat c,TexturizeFormat d)
data Output c d = Output (TexturizeFormat c) (TexturizeFormat d)

--------------------------------------------------------------------------------
-- Framebuffer blitting --------------------------------------------------------
data FramebufferBlitMask
  = BlitColor
  | BlitDepth
  | BlitBoth
    deriving (Eq,Show)

fromFramebufferBlitMask :: FramebufferBlitMask -> GLbitfield
fromFramebufferBlitMask mask = case mask of
  BlitColor -> GL_COLOR_BUFFER_BIT
  BlitDepth -> GL_DEPTH_BUFFER_BIT
  BlitBoth  -> GL_COLOR_BUFFER_BIT .|. GL_DEPTH_BUFFER_BIT

framebufferBlit :: (MonadIO m,Readable r,Writable w)
                => Framebuffer r c d
                -> Framebuffer w c' d'
                -> Int
                -> Int
                -> Natural
                -> Natural
                -> Int
                -> Int
                -> Natural
                -> Natural
                -> FramebufferBlitMask
                -> Filter
                -> m ()
framebufferBlit src dst srcX srcY srcW srcH dstX dstY dstW dstH mask flt = liftIO . debugGL "blit" $
    glBlitNamedFramebuffer (framebufferID src) (framebufferID dst) srcX0 srcY0 srcX1 srcY1 dstX0
      dstY0 dstX1 dstY1 (fromFramebufferBlitMask mask) (fromFilter flt)
  where
    srcX0 = fromIntegral srcX
    srcY0 = fromIntegral srcY
    srcX1 = srcX0 + fromIntegral srcW
    srcY1 = srcY0 + fromIntegral srcH
    dstX0 = fromIntegral dstX
    dstY0 = fromIntegral dstY
    dstX1 = dstX0 + fromIntegral dstW
    dstY1 = dstY0 + fromIntegral dstH

--------------------------------------------------------------------------------
-- Special framebuffers --------------------------------------------------------

defaultFramebuffer :: Framebuffer RW () ()
defaultFramebuffer = Framebuffer 0 (Output () ())