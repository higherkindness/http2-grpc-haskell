{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Module for GRPC binary encoding/decoding from and to binary messages.
--
-- So far, only "pure" compression algorithms are supported as we rely on
-- 'Decoder' (resp. 'Builder') which run with no interleaved side-effects.
module Network.GRPC.HTTP2.Encoding (
  -- * Encoding and decoding.
    GRPCInput(..)
  , GRPCOutput(..)
  , Builder
  , Decoder
  , fromBuilder
  , fromDecoder
  -- * Compression.
  , Compression(..)
  , Encoding(..)
  , Decoding(..)
  , grpcCompressionHV
  , uncompressed
  , gzip
  ) where

import qualified Codec.Compression.GZip as GZip
import           Data.Binary.Builder (toLazyByteString, Builder)
import           Data.Binary.Get (Decoder(..), Get)
import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Lazy (fromStrict, toStrict)

import           Network.GRPC.HTTP2.Types

class IsRPC r => GRPCInput r i where
  encodeInput :: r -> Compression -> i -> Builder
  decodeInput :: r -> Compression -> Decoder (Either String i)

class IsRPC r => GRPCOutput r o where
  encodeOutput :: r -> Compression -> o -> Builder
  decodeOutput :: r -> Compression -> Decoder (Either String o)

-- | Finalizes a Builder.
fromBuilder :: Builder -> ByteString
fromBuilder = toStrict . toLazyByteString

-- | Tries finalizing a Decoder.
fromDecoder :: Decoder (Either String a) -> Either String a
fromDecoder (Fail _ _ msg) = Left msg
fromDecoder (Partial _)    = Left "got only a subet of the message"
fromDecoder (Done _ _ val) = val

-- | Opaque type for handling compression.
--
-- So far, only "pure" compression algorithms are supported.
-- TODO: suport IO-based compression implementations once we move from 'Builder'.
data Compression = Compression {
    _compressionName       :: ByteString
  , _compressionByteSet    :: Bool
  , _compressionFunction   :: ByteString -> ByteString
  , _decompressionFunction :: ByteString -> Get ByteString
  }

-- | Compression for Encoding.
newtype Encoding = Encoding { _getEncodingCompression :: Compression }

-- | Compression for Decoding.
newtype Decoding = Decoding { _getDecodingCompression :: Compression }


grpcCompressionHV :: Compression -> HeaderValue
grpcCompressionHV = _compressionName

-- | Do not compress.
uncompressed :: Compression
uncompressed = Compression "identity" False id (\_ -> fail "decoder uninstalled")

-- | Use gzip as compression.
gzip :: Compression
gzip = Compression "gzip" True
     (toStrict . GZip.compress . fromStrict)
     (pure . toStrict . GZip.decompress . fromStrict)
