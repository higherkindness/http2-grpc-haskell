{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
module Network.GRPC.Server.Handlers where

import           Control.Concurrent.Async (concurrently)
import           Control.Monad (void, (>=>))
import           Data.Binary.Get (pushChunk, Decoder(..))
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Lazy (toStrict)
import           Network.GRPC.HTTP2.Encoding
import           Network.GRPC.HTTP2.Types (path, GRPCStatus(..), GRPCStatusCode(..))
import           Network.Wai (Request, getRequestBodyChunk, strictRequestBody)

import Network.GRPC.Server.Wai (WaiHandler, ServiceHandler(..), closeEarly)

-- | Handy type to refer to Handler for 'unary' RPCs handler.
type UnaryHandler i o = Request -> i -> IO o

-- | Handy type for 'server-streaming' RPCs.
--
-- We expect an implementation to:
-- - read the input request
-- - return an initial state and an state-passing action that the server code will call to fetch the output to send to the client (or close an a Nothing)
-- See 'ServerStream' for the type which embodies these requirements.
type ServerStreamHandler i o a = Request -> i -> IO (a, ServerStream o a)

newtype ServerStream o a = ServerStream {
    serverStreamNext :: a -> IO (Maybe (a, o))
  }

-- | Handy type for 'client-streaming' RPCs.
--
-- We expect an implementation to:
-- - acknowledge a the new client stream by returning an initial state and two functions:
-- - a state-passing handler for new client message
-- - a state-aware handler for answering the client when it is ending its stream
-- See 'ClientStream' for the type which embodies these requirements.
type ClientStreamHandler i o a = Request -> IO (a, ClientStream i o a)

data ClientStream i o a = ClientStream {
    clientStreamHandler   :: a -> i -> IO a
  , clientStreamFinalizer :: a -> IO o
  }

-- | Handy type for 'bidirectional-streaming' RPCs.
--
-- We expect an implementation to:
-- - acknowlege a new bidirection stream by returning an initial state and one functions:
-- - a state-passing function that returns a single action step
-- The action may be to
-- - stop immediately
-- - wait and handle some input with a callback and a finalizer (if the client closes the stream on its side) that may change the state
-- - return a value and a new state
--
-- There is no way to stop locally (that would mean sending HTTP2 trailers) and
-- keep receiving messages from the client.
type BiDiStreamHandler i o a = Request -> IO (a, BiDiStream i o a)

data BiDiStep i o a
  = Abort
  | WaitInput !(a -> i -> IO a) !(a -> IO a)
  | WriteOutput !a o

newtype BiDiStream i o a = BiDiStream {
    bidirNextStep :: a -> IO (BiDiStep i o a)
  }

-- | Construct a handler for handling a unary RPC.
unary
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> UnaryHandler i o
  -> ServiceHandler
unary rpc handler =
    ServiceHandler (path rpc) (handleUnary rpc handler)

-- | Construct a handler for handling a server-streaming RPC.
serverStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> ServerStreamHandler i o a
  -> ServiceHandler
serverStream rpc handler =
    ServiceHandler (path rpc) (handleServerStream rpc handler)

-- | Construct a handler for handling a client-streaming RPC.
clientStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> ClientStreamHandler i o a
  -> ServiceHandler
clientStream rpc handler =
    ServiceHandler (path rpc) (handleClientStream rpc handler)

-- | Construct a handler for handling a bidirectional-streaming RPC.
bidiStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> BiDiStreamHandler i o a
  -> ServiceHandler
bidiStream rpc handler =
    ServiceHandler (path rpc) (handleBiDiStream rpc handler)

-- | Construct a handler for handling a bidirectional-streaming RPC.
generalStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> GeneralStreamHandler i o a b
  -> ServiceHandler
generalStream rpc handler =
    ServiceHandler (path rpc) (handleGeneralStream rpc handler)

-- | Handle unary RPCs.
handleUnary
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> UnaryHandler i o
  -> WaiHandler
handleUnary rpc handler decoding encoding req write flush =
    handleRequestChunksLoop (decodeInput rpc $ _getDecodingCompression decoding)
                            handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (handler req >=> reply)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush

-- | Handle Server-Streaming RPCs.
handleServerStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> ServerStreamHandler i o a
  -> WaiHandler
handleServerStream rpc handler decoding encoding req write flush =
    handleRequestChunksLoop (decodeInput rpc $ _getDecodingCompression decoding)
                            handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (handler req >=> replyN)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    replyN (v, sStream) = do
        let go v1 = serverStreamNext sStream v1 >>= \case
                Just (v2, msg) -> do
                    write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush
                    go v2
                Nothing -> pure ()
        go v

-- | Handle Client-Streaming RPCs.
handleClientStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> ClientStreamHandler i o a
  -> WaiHandler
handleClientStream rpc handler0 decoding encoding req write flush =
    handler0 req >>= go
  where
    go (v, cStream) = handleRequestChunksLoop (decodeInput rpc $ _getDecodingCompression decoding)
                                              (handleMsg v) (handleEof v) nextChunk
      where
        nextChunk = getRequestBodyChunk req
        handleMsg v0 dat msg = clientStreamHandler cStream v0 msg >>= \v1 -> loop dat v1
        handleEof v0 = clientStreamFinalizer cStream v0 >>= reply
        reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush
        loop chunk v1 = handleRequestChunksLoop
                          (flip pushChunk chunk $ decodeInput rpc (_getDecodingCompression decoding))
                          (handleMsg v1) (handleEof v1) nextChunk

-- | Handle Bidirectional-Streaming RPCs.
handleBiDiStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> BiDiStreamHandler i o a
  -> WaiHandler
handleBiDiStream rpc handler0 decoding encoding req write flush =
    handler0 req >>= go ""
  where
    nextChunk = getRequestBodyChunk req
    reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush
    go chunk (v0, bStream) = do
        let cont dat v1 = go dat (v1, bStream)
        step <- bidirNextStep bStream v0
        case step of
            WaitInput handleMsg handleEof ->
                handleRequestChunksLoop (flip pushChunk chunk
                                         $ decodeInput rpc
                                         $ _getDecodingCompression decoding)
                                        (\dat msg -> handleMsg v0 msg >>= cont dat)
                                        (handleEof v0 >>= cont "")
                                        nextChunk
            WriteOutput v1 msg -> do
                reply msg
                cont "" v1
            Abort -> return ()

-- | A GeneralStreamHandler combining server and client asynchronous streams.
type GeneralStreamHandler i o a b =
    Request -> IO (a, IncomingStream i a, b, OutgoingStream o b)

-- | Pair of handlers for reacting to incoming messages.
data IncomingStream i a = IncomingStream {
    incomingStreamHandler   :: a -> i -> IO a
  , incomingStreamFinalizer :: a -> IO ()
  }

-- | Handler to decide on the next message (if any) to return.
newtype OutgoingStream o a = OutgoingStream {
    outgoingStreamNext  :: a -> IO (Maybe (a, o))
  }

-- | Handler for the somewhat general case where two threads behave concurrently:
-- - one reads messages from the client
-- - one returns messages to the client
handleGeneralStream
  :: (GRPCInput r i, GRPCOutput r o)
  => r
  -> GeneralStreamHandler i o a b
  -> WaiHandler
handleGeneralStream rpc handler0 decoding encoding req write flush = void $
    handler0 req >>= go
  where
    newDecoder = decodeInput rpc $ _getDecodingCompression decoding
    nextChunk = getRequestBodyChunk req
    reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush

    go (in0, instream, out0, outstream) = concurrently
        (incomingLoop newDecoder in0 instream)
        (replyLoop out0 outstream)

    replyLoop v0 sstream@(OutgoingStream next) =
        next v0 >>= \case
            Nothing          -> return v0
            (Just (v1, msg)) -> reply msg >> replyLoop v1 sstream

    incomingLoop decode v0 cstream = do
        let handleMsg dat msg = do
                v1 <- incomingStreamHandler cstream v0 msg
                incomingLoop (pushChunk newDecoder dat) v1 cstream
        let handleEof = incomingStreamFinalizer cstream v0 >> pure v0
        handleRequestChunksLoop decode handleMsg handleEof nextChunk


-- | Helpers to consume input in chunks.
handleRequestChunksLoop
  :: Decoder (Either String a)
  -- ^ Message decoder.
  -> (ByteString -> a -> IO b)
  -- ^ Handler for a single message.
  -- The ByteString corresponds to leftover data.
  -> IO b
  -- ^ Handler for handling end-of-streams.
  -> IO ByteString
  -- ^ Action to retrieve the next chunk.
  -> IO b
{-# INLINEABLE handleRequestChunksLoop #-}
handleRequestChunksLoop decoder handleMsg handleEof nextChunk =
    case decoder of
        (Done unusedDat _ (Right val)) ->
            handleMsg unusedDat val
        (Done _ _ (Left err)) ->
            closeEarly (GRPCStatus INVALID_ARGUMENT (ByteString.pack $ "done-error: " ++ err))
        (Fail _ _ err)         ->
            closeEarly (GRPCStatus INVALID_ARGUMENT (ByteString.pack $ "fail-error: " ++ err))
        partial@(Partial _)    -> do
            chunk <- nextChunk
            if ByteString.null chunk
            then
                handleEof
            else
                handleRequestChunksLoop (pushChunk partial chunk) handleMsg handleEof nextChunk

-- | Combinator around message handler to error on left overs.
--
-- This combinator ensures that, unless for client stream, an unparsed piece of
-- data with a correctly-read message is treated as an error.
errorOnLeftOver :: (a -> IO b) -> ByteString -> a -> IO b
errorOnLeftOver f rest
  | ByteString.null rest = f
  | otherwise            = const $ closeEarly $ GRPCStatus INVALID_ARGUMENT ("left-overs: " <> rest)
