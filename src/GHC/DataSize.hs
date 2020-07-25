{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE UnliftedFFITypes #-}

{- |
   Module      : GHC.DataSize
   Copyright   : (c) Dennis Felsing
   License     : 3-Clause BSD-style
   Maintainer  : dennis@felsin9.de
 -}
module GHC.DataSize (
  closureSize,
  recursiveSize,
  recursiveSizeNF
  )
  where

import Control.DeepSeq (NFData, force)

import GHC.Exts
import GHC.Arr
import GHC.Exts.Heap hiding (size)
import qualified Data.HashSet as H
import Data.IORef
import Data.Hashable

import Control.Monad

import System.Mem

foreign import prim "aToWordzh" aToWord# :: Any -> Word#

closureSize :: a -> IO Int
closureSize x = return (I# (closureSize# (unsafeCoerce# x)))

foreign import prim "unpackClosurePtrs"
  unpackClosurePtrs# :: Any -> Array# b

getClosures :: a -> IO (Array Int Box)
getClosures x = case unpackClosurePtrs# (unsafeCoerce# x) of
    pointers ->
      let nelems = I# (sizeofArray# pointers)
      in pure (fmap Box $ Array 0 (nelems - 1) nelems pointers)

-- | Calculate the recursive size of GHC objects in Bytes. Note that the actual
--   size in memory is calculated, so shared values are only counted once.
--
--   Call with
--   @
--    recursiveSize $! 2
--   @
--   to force evaluation to WHNF before calculating the size.
--
--   Call with
--   @
--    recursiveSize $!! \"foobar\"
--   @
--   ($!! from Control.DeepSeq) to force full evaluation before calculating the
--   size.
--
--   A garbage collection is performed before the size is calculated, because
--   the garbage collector would make heap walks difficult.
--
--   This function works very quickly on small data structures, but can be slow
--   on large and complex ones. If speed is an issue it's probably possible to
--   get the exact size of a small portion of the data structure and then
--   estimate the total size from that.
recursiveSize :: a -> IO Int
recursiveSize x = performGC >> recursiveSizeNoGC x

recursiveSizeNoGC :: a -> IO Int
recursiveSizeNoGC x = do
  state <- newIORef (0, H.empty)
  go state (asBox x)

  fst <$> readIORef state
  where
    go :: IORef (Int, H.HashSet HashableBox) -> Box -> IO ()
    go state b@(Box y) = do
      (_, closuresSeen) <- readIORef state

      when (not $ H.member (HashableBox b) closuresSeen) $ do
        thisSize <- closureSize y
        modifyIORef state $ \(size, _) ->
          (size + thisSize, H.insert (HashableBox b) closuresSeen)

        mapM_ (go state) =<< getClosures y

-- | Calculate the recursive size of GHC objects in Bytes after calling
-- Control.DeepSeq.force on the data structure to force it into Normal Form.
-- Using this function requires that the data structure has an `NFData`
-- typeclass instance.

recursiveSizeNF :: NFData a => a -> IO Int
recursiveSizeNF = recursiveSize . force

newtype HashableBox = HashableBox Box
    deriving newtype Show

-- | Pointer Equality
instance Eq HashableBox where
    (HashableBox (Box a1)) == (HashableBox (Box a2)) =
        W# (aToWord# a1) == W# (aToWord# a2)

-- | Pointer hash
instance Hashable HashableBox where
    hashWithSalt n (HashableBox (Box a)) = hashWithSalt n (W# (aToWord# a))
