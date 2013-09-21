module Main where

import           Control.Applicative
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM (retry)
import qualified Control.Foldl as L
import           Control.Monad (forever, unless)
import           Data.Monoid ((<>))
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

data Button = Go | Stop | Quit deriving (Show, Eq)

data Param
    = Delay   Double
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
    } deriving (Show)

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

data Message = Button Button | Param Param deriving (Show, Eq)

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

help :: IO ()
help = putStrLn $ unwords
    [ "(g)o"
    , "(s)top"
    , "(q)uit"
    , "(d)elay"
    , "(0)start"
    , "(1)drift"
    , "(2)sigma"
    , "(3)dt"
    , "4(ema1)"
    , "5(ema2)"
    ]

stdinMessage :: IO Message
stdinMessage = loop
  where
    loop = do
        command <- getLine
        case command of
            "q"      -> return $ Button Quit
            "s"      -> return $ Button Stop
            "g"      -> return $ Button Go
            ('d':xs) -> return $ Param $ Delay   $ read xs
            ('m':xs) -> return $ Param $ MaxTake $ read xs
            ('0':xs) -> return $ Param $ Start   $ read xs
            ('1':xs) -> return $ Param $ Drift   $ read xs
            ('2':xs) -> return $ Param $ Sigma   $ read xs
            ('3':xs) -> return $ Param $ Dt      $ read xs
            ('4':xs) -> return $ Param $ Ema1    $ read xs
            ('5':xs) -> return $ Param $ Ema2    $ read xs
            _         -> do
                help
                loop

user :: IO (Input Message)
user = do
    (om, im) <- spawn Unbounded
    a <- async $ runEffect $ lift stdinMessage >~ toOutput om
    link a
    return im

makeMessage :: Stream -> Message
makeMessage "Go"   = Button Go
makeMessage "Stop" = Button Stop
makeMessage "Quit" = Button Quit
makeMessage x      = case words x of
    ["Delay"  , xs] -> Param $ Delay   $ read xs
    ["MaxTake", xs] -> Param $ MaxTake $ read xs
    ["Start"  , xs] -> Param $ Start   $ read xs
    ["Drift"  , xs] -> Param $ Drift   $ read xs
    ["Sigma"  , xs] -> Param $ Sigma   $ read xs
    ["Dt"     , xs] -> Param $ Dt      $ read xs
    ["Ema1"   , xs] -> Param $ Ema1    $ read xs
    ["Ema2"   , xs] -> Param $ Ema2    $ read xs

wsMessage :: WS.WebSockets WS.Hybi00 Message
wsMessage = do
    command <- WS.receiveData
    liftIO $ putStrLn $ "received a command: " ++ T.unpack command
    WS.sendTextData $ T.pack $ "server received event: " ++ T.unpack command
    return $ makeMessage $ T.unpack command

messages :: IO (Input Message)
messages = do
    (om, im) <- spawn Unbounded
    a <- async $ WS.runServer addr inPort $ \rq -> do
        WS.acceptRequest rq
        liftIO $ putStrLn $ "accepted incoming request"
        WS.sendTextData $ T.pack "server accepted incoming connection"
        runEffect $ lift wsMessage >~ toOutput om
    link a
    return im

responses :: IO (Output Stream)
responses = do
    (os, is) <- spawn Unbounded
    let m :: WS.Request -> WS.WebSockets WS.Hybi10 ()
        m rq = do
            WS.acceptRequest rq
            liftIO $ putStrLn $ "accepted stream request"
            runEffect $ for (fromInput is) (lift . WS.sendTextData . T.pack)
    a <- async $ WS.runServer addr outPort m
    link a
    return os

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

updateParams :: Input Params -> Output Params -> Param -> STM ()
updateParams ips ops p = do
    Just ps <- recv ips
    let ps' = case p of
            Delay   p' -> ps { delay   = p' }
            MaxTake p' -> ps { maxTake = p' }
            Start   p' -> ps { start   = p' }
            Drift   p' -> ps { drift   = p' }
            Sigma   p' -> ps { sigma   = p' }
            Dt      p' -> ps { dt      = p' }
            Ema1    p' -> ps { ema1    = p' }
            Ema2    p' -> ps { ema2    = p' }
    send ops ps' >> return ()

splitMessage :: Output Button -> Input Params -> Output Params -> Consumer Message IO ()
splitMessage ob ips ops = forever $ do
    k <- await
    liftIO $ atomically $ case k of
        Button b -> send ob b >> return ()
        Param  p -> updateParams ips ops p

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
    liftIO $ atomically $ updateParams i o (Start st)

scan :: Input Params -> Pipe Double (Double,Double) IO r
scan ip = forever $ do
    ps <- lift $ get ip
    case (,) <$> ema (ema1 ps) <*> ema (ema2 ps) of
        L.Fold step begin done -> P.scan step begin done

stream
    :: Input Params
    -> Output Params
    -> Input Button
    -> Output Stream
    -> IO ()
stream ips ops ib os = runEffect $
        each (mkNormals seed :: [Double])
    >-> walker ips ops
    >-> takeMax ips
    >-> delayer ips
    >-> checkButton ib
    >-> scan ips
    >-> P.tee P.print
    >-> P.map show
    >-> toOutput os

main :: IO ()
main = do
    im1 <- messages
    im2 <- user
    os  <- responses
    (ob , ib ) <- spawn (Latest Stop)
    (ops, ips) <- spawn (Latest defaultParams)
    _ <- async $ runEffect $ fromInput (im1 <> im2) >-> splitMessage ob ips ops
    stream ips ops ib os
