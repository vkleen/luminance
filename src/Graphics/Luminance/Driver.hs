{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}

-----------------------------------------------------------------------------
-- |
-- Copyright   : (C) 2015, 2016 Dimitri Sabadie
-- License     : BSD3
--
-- Maintainer  : Dimitri Sabadie <dimitri.sabadie@gmail.com>
-- Stability   : experimental
-- Portability : portable
--
-----------------------------------------------------------------------------

module Graphics.Luminance.Driver where

import Control.Monad.Except ( MonadError )
import Data.Semigroup ( Semigroup )
import Graphics.Luminance.Core.RW ( Writable )
import Graphics.Luminance.Core.Shader.Program ( HasProgramError )
import Graphics.Luminance.Core.Shader.Stage ( HasStageError, StageType )
import Graphics.Luminance.BufferDriver
import Graphics.Luminance.FramebufferDriver
import Graphics.Luminance.GeometryDriver
import Graphics.Luminance.PixelDriver
import Graphics.Luminance.TextureDriver

-- |A driver to implement to be considered as a luminance backend.
class (BufferDriver m, FramebufferDriver m,GeometryDriver m,PixelDriver m,TextureDriver m) => Driver m where

  -- shader stages
  -- |A shader stage.
  type Stage m :: *
  -- |Create a shader stage from a 'String' representation of its source code and its type.
  --
  -- Note: on some hardware and backends, /tessellation shaders/ aren’t available. That function
  -- throws 'UnsupportedStage' error in such cases.
  createStage :: (HasStageError e,MonadError e m)
              => StageType
              -> String
              -> m (Stage m)
  -- |Shader program.
  type Program m :: * -> *
  -- |Encode all possible ways to name uniform values.
  type UniformName m :: * -> *
  -- |A special closed, monadic type in which one can create new uniforms.
  type UniformInterface m :: * -> *
  -- |A shader uniform. @'U' a@ doesn’t hold any value. It’s more like a mapping between the host
  -- code and the shader the uniform was retrieved from.
  type U m :: * -> *
  -- |Type-erased 'U'. Used to update uniforms with the 'updateUniforms' function.
  type U' m :: *
  -- |Create a new shader 'Program'.
  --
  -- That function takes a list of 'Stage's and a uniform interface builder function and yields a
  -- 'Program' and the interface.
  --
  -- The builder function takes a function you can use to retrieve uniforms. You can pass
  -- values of type 'UniformName' to identify the uniform you want to retrieve. If the uniform can’t
  -- be retrieved, throws 'InactiveUniform'.
  --
  -- In the end, you get the new 'Program' and a polymorphic value you can choose the type of in
  -- the function you pass as argument. You can use that value to gather uniforms for instance.
  createProgram :: (HasProgramError e,MonadError e m)
                => [Stage m]
                -> ((forall a. UniformName m a -> UniformInterface m (U m a)) -> UniformInterface m i)
                -> m (Program m i)
  -- |Update uniforms in a 'Program'. That function enables you to update only the uniforms you want
  -- and not necessarily the whole.
  --
  -- If you want to update several uniforms (not only one), you can use the 'Semigroup' instance
  -- (use '(<>)' or 'sconcat' for instance).
  updateUniforms :: (Semigroup (U' m)) => Program m a -> (a -> U' m) -> m ()

  -- draw
  -- |Draw output.
  type Output m :: * -> * -> *
  type RenderCommand m :: * -> *
  -- |Issue a draw command to the GPU. Don’t be afraid of the type signature. Let’s explain it.
  --
  -- The first parameter is the framebuffer you want to perform the rendering in. It must be
  -- writable.
  --
  -- The second parameter is a list of /shading commands/. A shading command is composed of three
  -- parts:
  --
  -- * a 'Program' used for shading;
  -- * a @(a -> 'U'')@ uniform sink used to update uniforms in the program passed as first value;
  --   this is useful if you want to update uniforms only once per draw or for all render
  --   commands, like time, user event, etc.;
  -- * a list of /render commands/ function; that function enables you to update uniforms via the
  --   @(a -> 'U'')@ uniform sink for each render command that follows.
  --
  -- This function outputs yields a value of type @'Output' m c d'@, which represents the output of
  -- the render – typically, textures or '()'.
  draw :: (Monoid (U' m),Writable w) => Framebuffer m w c d -> [(Program m a,a -> U' m,[a -> (U' m,RenderCommand m (Geometry m))])] -> m (Output m c d)
