module Main where

import           Control.Applicative
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async)
import           Control.Concurrent.STM (retry)
import qualified Control.Foldl as L
import           Control.Monad (forever, unless)
import           Data.Random.Normal (mkNormals)
import qualified Data.Text as T

import qualified Network.WebSockets as WS

import           Pipes
import           Pipes.Concurrent
import qualified Pipes.Prelude as P

-- constants
seed :: Int
seed = 42

inPort :: Int
inPort = 3566

outPort :: Int
outPort = 3567

addr :: String
addr = "0.0.0.0"

-- data types
type Stream = String

data Button = Go
            | Stop
            | Quit
            deriving (Show, Eq)

data Param = Delay   Double
           | MaxTake Int
           | Start   Double
           | Drift   Double
           | Sigma   Double
           | Dt      Double
           | Ema1    Double
           | Ema2    Double
           deriving (Show, Eq)

data Params = Params
              { delay   :: Double
              , maxTake :: Int
              , start   :: Double
              , drift   :: Double
              , sigma   :: Double
              , dt      :: Double
              , ema1    :: Double
              , ema2    :: Double
              } deriving Show

defaultParams :: Params
defaultParams = Params
	      { delay   = 1.0  -- delay in seconds
	      , maxTake = 1000 -- maximum number of stream elements
              , start   = 0    -- random walk start
              , drift   = 0    -- random walk drift
              , sigma   = 1    -- volatility
              , dt      = 1    -- time grain
              , ema1    = 0    -- ema parameter (0=latest, 1=average)
              , ema2    = 0.5  -- ema parameter
              }

data Message = Button Button
             | Param Param
             deriving (Show, Eq)

makeMessage :: Stream -> Message
makeMessage "Go"   = Button Go
makeMessage "Stop" = Button Stop
makeMessage "Quit" = Button Quit
makeMessage x      = case words x of
    ["Delay",xs]   -> Param $ Delay   $ read xs
    ["MaxTake",xs] -> Param $ MaxTake $ read xs
    ["Start",xs]   -> Param $ Start   $ read xs
    ["Drift",xs]   -> Param $ Drift   $ read xs
    ["Sigma",xs]   -> Param $ Sigma   $ read xs
    ["Dt",xs]      -> Param $ Dt      $ read xs
    ["Ema1",xs]    -> Param $ Ema1    $ read xs
    ["Ema2",xs]    -> Param $ Ema2    $ read xs

help :: IO ()
help = putStrLn "(g)o (s)top (q)uit (d)elay (0)start (1)drift (2)sigma (3)dt 4(ema1) 5(ema2)"

stdinMessage :: IO Message
stdinMessage = loop
  where
    loop = do
        command <- getLine
        case command of
            "q" -> return $ Button Quit
            "s" -> return $ Button Stop
            "g" -> return $ Button Go
            ('d':xs) -> return $ Param $ Delay   $ read xs
            ('m':xs) -> return $ Param $ MaxTake $ read xs
            ('0':xs) -> return $ Param $ Start   $ read xs
            ('1':xs) -> return $ Param $ Drift   $ read xs
            ('2':xs) -> return $ Param $ Sigma   $ read xs
            ('3':xs) -> return $ Param $ Dt      $ read xs
            ('4':xs) -> return $ Param $ Ema1    $ read xs
            ('5':xs) -> return $ Param $ Ema2    $ read xs
            _ -> do
                help
                loop

updateParams :: Input Params -> Output Params -> Consumer Param IO ()
updateParams ips ops = forever $ do
    p <- await
    Just ps <- liftIO $ atomically $ recv ips
    -- lift $ print ps
    case p of
        Delay   p' -> runEffect $
                     yield (ps{ delay = p' }) >->
                     toOutput ops
        MaxTake p' -> runEffect $
                     yield (ps{ maxTake = p' }) >->
                     toOutput ops
        Start   p' -> runEffect $
                     yield (ps{ start = p' }) >->
                     toOutput ops
        Drift   p' -> runEffect $
                     yield (ps{ drift = p' }) >->
                     toOutput ops
        Sigma   p' -> runEffect $
                     yield (ps{ sigma = p' }) >->
                     toOutput ops
        Dt      p' -> runEffect $
                     yield (ps{ dt = p' }) >->
                     toOutput ops
        Ema1    p' -> runEffect $
                     yield (ps{ ema1 = p' }) >->
                     toOutput ops
        Ema2    p' -> runEffect $
                     yield (ps{ ema2 = p' }) >->
                     toOutput ops
    return ()


splitMessage :: Output Button
             -> Input Params
             -> Output Params
             -> Consumer Message IO ()
splitMessage ob ips ops = forever $ do
    k <- await
    case k of
        Button b -> runEffect $ yield b >-> toOutput ob
        Param p  -> lift $ runEffect $ yield p >-> updateParams ips ops
    return ()

-- who doesn't hate typing liftIO?
logger :: (MonadIO m) => String -> m ()
logger = liftIO . putStrLn

-- websocket server for commands
serveFrom :: Output Message -> IO ()
serveFrom o = WS.runServer addr inPort $ fromWs o

-- accept connection request and pipe to Output Message
fromWs :: Output Message
       -> WS.Request
       -> WS.WebSockets WS.Hybi00 ()
fromWs o rq = do
    WS.acceptRequest rq
    logger "accepted incoming request"
    WS.sendTextData $ T.pack "server accepted incoming connection"
    runEffect $ wsMessage >-> hoist liftIO (toOutput o)

wsMessage :: Producer Message (WS.WebSockets WS.Hybi00) ()
wsMessage = forever $ do
    command <- lift WS.receiveData
    lift $ logger $ "received a command: " ++ T.unpack command
    lift $ WS.sendTextData $
        T.pack $ "server received event: " ++ T.unpack command
    yield $ makeMessage $ T.unpack command

-- websocket server for stream
serveTo :: Input Stream -> IO ()
serveTo i = WS.runServer addr outPort $ toWs i

-- emitter stream to websocket
toWs :: Input Stream
     -> WS.Request
     -> WS.WebSockets WS.Hybi00 ()
toWs i rq = do
    WS.acceptRequest rq
    logger "accepted stream request"
    runEffect $ hoist liftIO (fromInput i) >-> wsSend

-- send text to ws
wsSend :: Consumer Stream (WS.WebSockets WS.Hybi00) ()
wsSend = forever $ do
    s <- await
    lift $ WS.sendTextData $
        T.pack s

-- button handling
-- Input + retry to prevent spinning
checkButton :: Input Button -> Pipe a a IO ()
checkButton i = do
    b <- liftIO $ atomically $ do
        b' <- recv i
        case b' of
            Just Stop -> retry
            _ -> return b'
    case b of
        Just Quit -> return ()
        _         -> await >>= yield >> checkButton i

-- pipes with effectful parameters
get :: Input Params -> IO Params
get i = do
    Just ps <- liftIO $ atomically $ recv i
    return ps

delayer :: Input Params -> Pipe a a IO ()
delayer i = forever $ do
    a <- await
    ps <- lift $ get i
    lift $ threadDelay $ floor $ 1000000 * delay ps
    yield a

takeMax :: Input Params -> Pipe a a IO ()
takeMax i = takeLoop 0
  where
    takeLoop count = do
        a <- await
        ps <- lift $ get i
        unless (count >= maxTake ps) $ do
            yield a
            takeLoop $ count + 1

-- turns a random stream into a random walk stream
walker :: Input Params -> Output Params -> Pipe Double Double IO ()
walker i o = forever $ do
    a <- await
    ps <- lift $ get i
    let st = start ps + drift ps * dt ps + sigma ps * sqrt (dt ps) * a
    yield st
    lift $ runEffect $ yield (Start st) >-> updateParams i o

-- exponential moving average
data Ema = Ema
       { numerator   :: {-# UNPACK #-} !Double
       , denominator :: {-# UNPACK #-} !Double
       }

ema :: Double -> L.Fold Double Double
ema alpha = L.Fold step (Ema 0 0) (\(Ema n d) -> n / d)
  where
    step (Ema n d) n' = Ema ((1 - alpha) * n + n') ((1 - alpha) * d + 1)

emaSq :: Double -> L.Fold Double Double
emaSq alpha = L.Fold step (Ema 0 0) (\(Ema n d) -> n / d)
  where
    step (Ema n d) n' = Ema ((1 - alpha) * n + n' * n') ((1 - alpha) * d + 1)

estd :: Double -> L.Fold Double Double
estd alpha = (\s ss -> sqrt (ss - s**2)) <$> ema alpha <*> emaSq alpha

scan :: Input Params -> Pipe Double (Double,Double) IO r
scan ip = forever $ do
    ps <- lift $ get ip
    let f = (,) <$> ema (ema1 ps) <*> ema (ema2 ps)
    case f of
        (L.Fold step begin done) -> P.scan step begin done

stream :: Input Params
       -> Output Params
       -> Input Button
       -> Output Stream
       -> IO ()
stream ips ops ib os = runEffect $
         each (mkNormals seed :: [Double])     >->
         walker ips ops   >->
         takeMax ips      >->
         delayer ips      >->
         checkButton ib   >->
         scan ips         >->
         P.tee P.print    >->
         P.map show       >->
         toOutput os


pipe :: IO ()
pipe = do
    (om,im)   <- spawn Unbounded
    (ob,ib)   <- spawn (Latest Stop)
    (ops,ips) <- spawn (Latest defaultParams)
    (os,is)   <- spawn Unbounded
    _ <- async $ runEffect $ lift stdinMessage >~ toOutput om
    _ <- async $ serveFrom om
    _ <- async $ serveTo is
    _ <- async $ runEffect $ fromInput im >-> splitMessage ob ips ops
    stream ips ops ib os

main :: IO ()
main = pipe
