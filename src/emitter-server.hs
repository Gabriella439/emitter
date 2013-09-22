module Main where

{-# LANGUAGE Arrows #-}

import           Control.Applicative
import           Control.Arrow
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM
import qualified Control.Foldl as L
import           Control.Lens hiding (each)
import           Control.Monad (forever, when, unless)
import           Control.Monad.Trans.State.Strict (StateT, get)
import           Data.Monoid ((<>))
import           Data.Random.Normal (mkNormals)
import qualified Data.Text as T

import qualified Network.WebSockets as WS

import           Pipes
import           Pipes.Arrow
import           Pipes.Core (push, (/>/))
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
    deriving (Show, Eq)

data Params = Params
    { _delay   :: Double
    , _maxTake :: Int
    , _start   :: Double
    , _drift   :: Double
    , _sigma   :: Double
    , _dt      :: Double
    , _ema1    :: Double
    , _ema2    :: Double
    } deriving (Show)

delay :: Lens' Params Double
delay f p = fmap (\x -> p { _delay = x }) (f (_delay p))

maxTake :: Lens' Params Int
maxTake f p = fmap (\x -> p { _maxTake = x }) (f (_maxTake p))

start :: Lens' Params Double
start f p = fmap (\x -> p { _start = x }) (f (_start p))

drift :: Lens' Params Double
drift f p = fmap (\x -> p { _drift = x }) (f (_drift p))

sigma :: Lens' Params Double
sigma f p = fmap (\x -> p { _sigma = x }) (f (_sigma p))

dt :: Lens' Params Double
dt f p = fmap (\x -> p { _dt = x }) (f (_dt p))

ema1 :: Lens' Params Double
ema1 f p = fmap (\x -> p { _ema1 = x }) (f (_ema1 p))

ema2 :: Lens' Params Double
ema2 f p = fmap (\x -> p { _ema2 = x }) (f (_ema2 p))

defaultParams :: Params
defaultParams = Params
    { _delay   = 1.0  -- delay in seconds
    , _maxTake = 1000 -- maximum number of stream elements
    , _start   = 0    -- random walk start
    , _drift   = 0    -- random walk drift
    , _sigma   = 1    -- volatility
    , _dt      = 1    -- time grain
    , _ema1    = 0    -- ema parameter (0=latest, 1=average)
    , _ema2    = 0.5  -- ema parameter
    }

data ButtonIn = Quit | Stop | Go
    deriving (Show)

data EventIn = Tick | Data Double | ButtonIn ButtonIn | Param Param
    deriving (Show)

data EventOut = Set Double | UnSet | Stream String
    deriving (Show)

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

frames :: IO (Input EventIn, Output EventOut)
frames = do
    (oTick, iTick) <- spawn Unbounded
    tvar   <- newTVarIO Nothing
    let pause = do
            d <- atomically $ do
                x <- readTVar tvar
                case x of
                    Nothing -> retry
                    Just d  -> return d
            threadDelay $ truncate $ 1000000 * d
            return Tick
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

updateParams :: (Monad m) => Param -> StateT Params m ()
updateParams p = case p of
    Delay   p' -> delay   .= p'
    MaxTake p' -> maxTake .= p'
    Start   p' -> start   .= p'
    Drift   p' -> drift   .= p'
    Sigma   p' -> sigma   .= p'
    Dt      p' -> dt      .= p'
    Ema1    p' -> ema1    .= p'
    Ema2    p' -> ema2    .= p'

takeMax :: (Monad m) => Edge (StateT Params m) () a a
takeMax = Edge (takeLoop 0)
  where
    takeLoop count a = do
        m <- use maxTake
        unless (count >= m) $ do
            yield a
            a <- await
            takeLoop (count + 1) a

-- turns a random stream into a random walk stream
walker :: (Monad m) => Edge (StateT Params m) () Double Double
walker = Edge $ push />/ \a -> do
    ps <- lift get
    let st = ps^.start + ps^.drift * ps^.dt + ps^.sigma * sqrt (ps^.dt) * a
    lift $ updateParams (Start st)
    yield st

scan :: (Monad m) => Edge (StateT Params m) r Double (Double, Double)
scan = Edge $ \a -> do
    ps <- lift get
    case (,) <$> ema (ps^.ema1) <*> ema (ps^.ema2) of
        L.Fold step begin done -> push a >-> P.scan step begin done

toOutput' :: (MonadIO m) => Output a -> Edge m () a x
toOutput' o = Edge go
  where
    go a = do
        alive <- liftIO $ atomically $ send o a
        when alive $ do
            a2 <- await
            go a2

stream :: (Monad m) => Edge (StateT Params m) () Double EventOut
stream =
        walker
    >>> takeMax
    >>> scan
    >>> arr (Stream . show)

total = proc e -> do
    case e of
        Tick -> stream
data EventIn = Tick | Data Double | ButtonIn ButtonIn | Param Param
    deriving (Show)

data EventOut = Set Double | UnSet | Stream String
    deriving (Show)

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

frames :: IO (Input EventIn, Output EventOut)
frames = do
    (oTick, iTick) <- spawn Unbounded
    tvar   <- newTVarIO Nothing
    let pause = do
            d <- atomically $ do
                x <- readTVar tvar
                case x of
                    Nothing -> retry
                    Just d  -> return d
            threadDelay $ truncate $ 1000000 * d
            return Tick
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

updateParams :: (Monad m) => Param -> StateT Params m ()
updateParams p = case p of
    Delay   p' -> delay   .= p'
    MaxTake p' -> maxTake .= p'
    Start   p' -> start   .= p'
    Drift   p' -> drift   .= p'
    Sigma   p' -> sigma   .= p'
    Dt      p' -> dt      .= p'
    Ema1    p' -> ema1    .= p'
    Ema2    p' -> ema2    .= p'

takeMax :: (Monad m) => Edge (StateT Params m) () a a
takeMax = Edge (takeLoop 0)
  where
    takeLoop count a = do
        m <- use maxTake
        unless (count >= m) $ do
            yield a
            a <- await
            takeLoop (count + 1) a

-- turns a random stream into a random walk stream
walker :: (Monad m) => Edge (StateT Params m) () Double Double
walker = Edge $ push />/ \a -> do
    ps <- lift get
    let st = ps^.start + ps^.drift * ps^.dt + ps^.sigma * sqrt (ps^.dt) * a
    lift $ updateParams (Start st)
    yield st

scan :: (Monad m) => Edge (StateT Params m) r Double (Double, Double)
scan = Edge $ \a -> do
    ps <- lift get
    case (,) <$> ema (ps^.ema1) <*> ema (ps^.ema2) of
        L.Fold step begin done -> push a >-> P.scan step begin done

toOutput' :: (MonadIO m) => Output a -> Edge m () a x
toOutput' o = Edge go
  where
    go a = do
        alive <- liftIO $ atomically $ send o a
        when alive $ do
            a2 <- await
            go a2

stream :: (Monad m) => Edge (StateT Params m) () Double EventOut
stream =
        walker
    >>> takeMax
    >>> scan
    >>> arr (Stream . show)

total = proc e -> do
    case e of
        

{-
main :: IO ()
main = do
    inWeb  <- websocket
    inCmd  <- user
    outWeb <- responses
    (inTick, outChange) <- frames
    {-
    (ops, ips) <- spawn (Latest defaultParams)
    _ <- async $ runEffect $ for (fromInput (im1 <> im2)) $ \msg ->
        case msg of
            Button b -> button .= b
            Param  p -> lift $ updateParams p
    -}
    stream (inWeb <> inCmd <> inTick) (outWeb <> outChange)
-}

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

{-
main :: IO ()
main = do
    inWeb  <- websocket
    inCmd  <- user
    outWeb <- responses
    (inTick, outChange) <- frames
    {-
    (ops, ips) <- spawn (Latest defaultParams)
    _ <- async $ runEffect $ for (fromInput (im1 <> im2)) $ \msg ->
        case msg of
            Button b -> button .= b
            Param  p -> lift $ updateParams p
    -}
    stream (inWeb <> inCmd <> inTick) (outWeb <> outChange)
-}

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
