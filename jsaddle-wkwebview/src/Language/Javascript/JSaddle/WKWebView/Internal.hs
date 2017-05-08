{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings #-}
module Language.Javascript.JSaddle.WKWebView.Internal
    ( jsaddleMain
    , jsaddleMainFile
    , WKWebView(..)
    , mainBundleResourcePath
    , AppDelegateConfig (..)
    , boolFromCChar
    , boolToCChar
    ) where

import Control.Monad (void, join)
import Control.Concurrent (forkIO, forkOS)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)

import Data.Default
import Data.Monoid ((<>))
import Data.ByteString (useAsCString, packCString)
import qualified Data.ByteString as BS (ByteString)
import Data.ByteString.Lazy (ByteString, toStrict, fromStrict)
import Data.Aeson (encode, decode)

import Foreign.C.String (CString)
import Foreign.C.Types (CChar (..))
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.StablePtr (StablePtr, newStablePtr, deRefStablePtr)

import Language.Javascript.JSaddle (Results, JSM)
import Language.Javascript.JSaddle.Run (runJavaScript)
import Language.Javascript.JSaddle.Run.Files (initState, runBatch, ghcjsHelpers)

newtype WKWebView = WKWebView (Ptr WKWebView)

foreign export ccall jsaddleStart :: StablePtr (IO ()) -> IO ()
foreign export ccall jsaddleResult :: StablePtr (Results -> IO ()) -> CString -> IO ()
foreign export ccall withWebView :: WKWebView -> StablePtr (WKWebView -> IO ()) -> IO ()
foreign export ccall handlerCString :: CString -> StablePtr (CString -> IO ()) -> IO ()
foreign import ccall addJSaddleHandler :: WKWebView -> StablePtr (IO ()) -> StablePtr (Results -> IO ()) -> IO ()
foreign import ccall loadHTMLString :: WKWebView -> CString -> IO ()
foreign import ccall loadBundleFile :: WKWebView -> CString -> CString -> IO ()
foreign import ccall evaluateJavaScript :: WKWebView -> CString -> IO ()
foreign import ccall mainBundleResourcePathC :: IO CString

-- | Run JSaddle in WKWebView
jsaddleMain :: JSM () -> WKWebView -> IO ()
jsaddleMain f webView = do
    jsaddleMain' f webView $
        useAsCString (toStrict indexHtml) $ loadHTMLString webView

-- | Run JSaddle in a WKWebView first loading the specified file
--   from the mainBundle (relative to the resourcePath).
jsaddleMainFile :: BS.ByteString -- ^ The file to navigate to.
                -> BS.ByteString -- ^ The path to allow read access to.
                -> JSM () -> WKWebView -> IO ()
jsaddleMainFile url allowing f webView = do
    jsaddleMain' f webView $
        useAsCString url $ \u ->
            useAsCString allowing $ \a ->
                loadBundleFile webView u a

jsaddleMain' :: JSM () -> WKWebView -> IO () -> IO ()
jsaddleMain' f webView loadHtml = do
    ready <- newEmptyMVar

    (processResult, start) <- runJavaScript (\batch ->
        useAsCString (toStrict $ "runJSaddleBatch(" <> encode batch <> ");") $
            evaluateJavaScript webView)
        f

    startHandler <- newStablePtr (putMVar ready ())
    resultHandler <- newStablePtr processResult
    addJSaddleHandler webView startHandler resultHandler
    loadHtml
    void . forkOS $ do
        takeMVar ready
        useAsCString (toStrict jsaddleJs) (evaluateJavaScript webView) >> void (forkIO start)

jsaddleStart :: StablePtr (IO ()) -> IO ()
jsaddleStart ptrHandler = join (deRefStablePtr ptrHandler)

jsaddleResult :: StablePtr (Results -> IO ()) -> CString -> IO ()
jsaddleResult ptrHandler s = do
    processResult <- deRefStablePtr ptrHandler
    result <- packCString s
    case decode (fromStrict result) of
        Nothing -> error $ "jsaddle WebSocket decode failed : " <> show result
        Just r  -> processResult r

withWebView :: WKWebView -> StablePtr (WKWebView -> IO ()) -> IO ()
withWebView webView ptrF = do
    f <- deRefStablePtr ptrF
    f webView

handlerCString :: CString -> StablePtr (CString -> IO ()) -> IO ()
handlerCString c fptr = do
  f <- deRefStablePtr fptr
  f c

data AppDelegateConfig = AppDelegateConfig
  { _appDelegateConfig_requestAuthorizationWithOptions :: Bool
  , _appDelegateConfig_registerForRemoteNotifications :: Bool
  , _appDelegateConfig_didRegisterForRemoteNotificationsWithDeviceToken :: CString -> IO ()
  }

instance Default AppDelegateConfig where
  def = AppDelegateConfig
    { _appDelegateConfig_requestAuthorizationWithOptions = False
    , _appDelegateConfig_registerForRemoteNotifications = False
    , _appDelegateConfig_didRegisterForRemoteNotificationsWithDeviceToken = \_ -> return ()
    }

boolToCChar :: Bool -> CChar
boolToCChar a = if a then 1 else 0

boolFromCChar :: CChar -> Bool
boolFromCChar a = a /= 0

jsaddleJs :: ByteString
jsaddleJs = ghcjsHelpers <> "\
    \runJSaddleBatch = (function() {\n\
    \ " <> initState <> "\n\
    \ return function(batch) {\n\
    \ " <> runBatch (\a -> "window.webkit.messageHandlers.jsaddle.postMessage(JSON.stringify(" <> a <> "));") <> "\
    \ };\n\
    \})();\n\
    \"

indexHtml :: ByteString
indexHtml =
    "<!DOCTYPE html>\n\
    \<html>\n\
    \<head>\n\
    \<title>JSaddle</title>\n\
    \</head>\n\
    \<body>\n\
    \</body>\n\
    \</html>"

mainBundleResourcePath :: IO (Maybe BS.ByteString)
mainBundleResourcePath = do
    bs <- mainBundleResourcePathC
    if bs == nullPtr
        then return Nothing
        else Just <$> packCString bs

