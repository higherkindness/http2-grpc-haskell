{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Network.GRPC.HTTP2.Proto3Wire where

import           Data.Bifunctor (first)
import           Data.Binary.Builder (fromByteString, singleton, putWord32be)
import           Data.Binary.Get (getByteString, getInt8, getWord32be, runGetIncremental)
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Lazy (toStrict)

import qualified Proto3.Wire.Encode as PBEnc
import qualified Proto3.Wire.Decode as PBDec

import Network.GRPC.HTTP2.Types
import Network.GRPC.HTTP2.Encoding

-- | A proxy type for giving static information about RPCs.
data RPC = RPC { pkg :: ByteString, srv :: ByteString, meth :: ByteString }

instance IsRPC RPC where
  path rpc = "/" <> pkg rpc <> "." <> srv rpc <> "/" <> meth rpc
  {-# INLINE path #-}

class Proto3WireEncoder a where
  proto3WireEncode :: a -> PBEnc.MessageBuilder
  proto3WireDecode :: PBDec.Parser PBDec.RawMessage a

instance (Proto3WireEncoder i) => GRPCInput RPC i where
  encodeInput _ = encode
  decodeInput _ = decoder

instance (Proto3WireEncoder o) => GRPCOutput RPC o where
  encodeOutput _ = encode
  decodeOutput _ = decoder

encode :: Proto3WireEncoder m => Compression -> m -> Builder
encode compression plain =
    mconcat [ singleton (if _compressionByteSet compression then 1 else 0)
            , putWord32be (fromIntegral $ ByteString.length bin)
            , fromByteString bin
            ]
  where
    bin = _compressionFunction compression $ toStrict $ PBEnc.toLazyByteString (proto3WireEncode plain)

decoder :: Proto3WireEncoder a => Compression -> Decoder (Either String a)
decoder compression = runGetIncremental $ do
    isCompressed <- getInt8      -- 1byte
    let decompress = if isCompressed == 0 then pure else _decompressionFunction compression
    n <- getWord32be             -- 4bytes
    first show . PBDec.parse proto3WireDecode <$> (decompress =<< getByteString (fromIntegral n))