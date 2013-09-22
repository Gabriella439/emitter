{-# LANGUAGE Arrows #-}

module Main where

import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow ((>>>), arr)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM (newTVarIO, readTVar, writeTVar, retry)
import qualified Control.Foldl as L
import           Control.Monad (when, unless)
import           Control.Monad.IO.Class (MonadIO(liftIO))
import qualified Control.Monad.Trans.State.Strict as S
import           Control.Monad.Trans.Class (lift)
import           Data.Monoid ((<>))
import           Data.Random.Normal (mkNormals)
import qualified Data.Text as T

import qualified Network.WebSockets as WS

import           Pipes ((>->), (~>), for, (>~), await, yield, runEffect, each)
import           Pipes.Arrow (Edge(Edge, unEdge))
import           Pipes.Core (push)
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
-- TODO: UNPACK stuff
data Param
    = Delay   Double
    | MaxTake Int
    | Start   Double
    | Drift   Double
    | Sigma   Double
    | Dt      Double
    | Ema1    Double
    | Ema2    Double
    deriving (Show)

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

data ButtonIn = Quit | Stop | Go deriving (Show)

data EventIn = Data Double | ButtonIn ButtonIn | Param Param deriving (Show)

data EventOut = Set Double | UnSet | Stream String deriving (Show)

-- Controllers and Views
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
    , "(4)ema1"
    , "(5)ema2"
    ]

stdinEvent :: IO EventIn
stdinEvent = loop
  where
    loop = do
        command <- getLine
        case command of
            "q"      -> return $ ButtonIn Quit
            "s"      -> return $ ButtonIn Stop
            "g"      -> return $ ButtonIn Go
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

user :: IO (Input EventIn)
user = do
    (om, im) <- spawn Unbounded
    a <- async $ runEffect $ lift stdinEvent >~ toOutput om
    link a
    return im

makeEvent :: String -> EventIn
makeEvent "Go"   = ButtonIn Go
makeEvent "Stop" = ButtonIn Stop
makeEvent "Quit" = ButtonIn Quit
makeEvent x      = case words x of
    ["Delay"  , xs] -> Param $ Delay   $ read xs
    ["MaxTake", xs] -> Param $ MaxTake $ read xs
    ["Start"  , xs] -> Param $ Start   $ read xs
    ["Drift"  , xs] -> Param $ Drift   $ read xs
    ["Sigma"  , xs] -> Param $ Sigma   $ read xs
    ["Dt"     , xs] -> Param $ Dt      $ read xs
    ["Ema1"   , xs] -> Param $ Ema1    $ read xs
    ["Ema2"   , xs] -> Param $ Ema2    $ read xs
    _               -> ButtonIn Stop  -- Why not?

wsEvent :: WS.WebSockets WS.Hybi00 EventIn
wsEvent = do
    command <- WS.receiveData
    liftIO $ putStrLn $ "received a command: " ++ T.unpack command
    WS.sendTextData $ T.pack $ "server received event: " ++ T.unpack command
    return $ makeEvent $ T.unpack command

websocket :: IO (Input EventIn)
websocket = do
    (om, im) <- spawn Unbounded
    a <- async $ WS.runServer addr inPort $ \rq -> do
        WS.acceptRequest rq
        liftIO $ putStrLn $ "accepted incoming request"
        WS.sendTextData $ T.pack "server accepted incoming connection"
        runEffect $ lift wsEvent >~ toOutput om
    link a
    return im

responses :: IO (Output EventOut)
responses = do
    (os, is) <- spawn Unbounded
    let m :: WS.Request -> WS.WebSockets WS.Hybi10 ()
        m rq = do
            WS.acceptRequest rq
            liftIO $ putStrLn $ "accepted stream request"
            runEffect $ for (fromInput is) (lift . WS.sendTextData . T.pack)
    a <- async $ WS.runServer addr outPort m
    link a
    return $ Output $ \e -> do
        case e of
            Stream str -> send os str
            _          -> return True

-- The input generates ticks and the output lets you Set or UnSet ticks
ticks :: IO (Input (), Output EventOut)
ticks = do
    (oTick, iTick) <- spawn Unbounded
    tvar   <- newTVarIO Nothing
    let pause = do
            d <- atomically $ do
                x <- readTVar tvar
                case x of
                    Nothing -> retry
                    Just d  -> return d
            threadDelay $ truncate $ 1000000 * d
    a <- async $ runEffect $ lift pause >~ toOutput oTick
    link a
    let oChange = Output $ \e -> do
            case e of
                Set d -> writeTVar tvar (Just d)
                UnSet -> writeTVar tvar  Nothing
                _    -> return ()
            return True
    return (iTick, oChange)

fromList :: [a] -> IO (Input a)
fromList as = do
    (o, i) <- spawn Single
    a <- async $ runEffect $ each as >-> toOutput o
    link a
    return i

-- All the pure logic.  Note that none of these use 'IO'
updateParams :: (Monad m) => Param -> S.StateT Params m ()
updateParams p = do
    ps <- S.get
    let ps' = case p of
            Delay   p' -> ps { delay   = p' }
            MaxTake p' -> ps { maxTake = p' }
            Start   p' -> ps { start   = p' }
            Drift   p' -> ps { drift   = p' }
            Sigma   p' -> ps { sigma   = p' }
            Dt      p' -> ps { dt      = p' }
            Ema1    p' -> ps { ema1    = p' }
            Ema2    p' -> ps { ema2    = p' }
    S.put ps'

takeMax :: (Monad m) => Edge (S.StateT Params m) () a a
takeMax = Edge (takeLoop 0)
  where
    takeLoop count a = do
        m <- lift $ S.gets maxTake
        unless (count >= m) $ do
            yield a
            a2 <- await
            takeLoop (count + 1) a2

-- turns a random stream into a random walk stream
walker :: (Monad m) => Edge (S.StateT Params m) () Double Double
walker = Edge $ push ~> \a -> do
    ps <- lift S.get
    let st = start ps + drift ps * dt ps + sigma ps * sqrt (dt ps) * a
    lift $ updateParams (Start st)
    yield st

scan :: (Monad m) => Edge (S.StateT Params m) r Double (Double, Double)
scan = Edge $ \a -> do
    ps <- lift S.get
    case (,) <$> ema (ema1 ps) <*> ema (ema2 ps) of
        L.Fold step begin done -> push a >-> P.scan step begin done

dataHandler :: (Monad m) => Edge (S.StateT Params m) () Double EventOut
dataHandler =
        walker
    >>> takeMax
    >>> scan
    >>> arr (Stream . show)

buttonHandler :: (Monad m) => Edge (S.StateT Params m) () ButtonIn EventOut
buttonHandler = Edge $ push ~> \b -> case b of
    Quit -> return ()
    Stop -> yield UnSet
    Go   -> do
        ps <- lift S.get
        yield $ Set (delay ps)
    
paramHandler :: (Monad m) => Edge (S.StateT Params m) () Param x
paramHandler = Edge $ push ~> (lift . updateParams)

total :: (Monad m) => Edge (S.StateT Params m) () EventIn EventOut
total = proc e -> do
    case e of
        Data x     -> dataHandler   -< x
        ButtonIn b -> buttonHandler -< b
        Param    p -> paramHandler  -< p
    
main :: IO ()
main = do
    -- Initialize controllers and views
    inWeb  <- websocket
    inCmd  <- user
    outWeb <- responses
    (inTick, outChange) <- ticks
    randomValues <- fromList (mkNormals seed)
    -- Space the random values according to the ticks
    let inData= (\_ a -> Data a) <$> inTick <*> randomValues

    -- 'totalPipe' is the pure kernel of business logic
    let totalPipe = await >>= unEdge total

    -- Go!
    (`S.evalStateT` defaultParams) $ runEffect $
            fromInput (inWeb <> inCmd <> inData)
        >-> totalPipe
        >-> toOutput (outWeb <> outChange)

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
