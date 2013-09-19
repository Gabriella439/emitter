emitter
=======

## haskell pipes example

This is a work-in-progress example app for the haskell pipes and pipes-concurrent libraries.

## install

1. Build the library

```
cabal configure && cabal build && cabal install
```

2. Fire up the server:

```
emitter-server
```

3. Open the client.html page

4. Click and slide the not very pretty controllers


## the basics

The emitter:
 - sets up a stream in a typically `pipe`sish fashion.
 - listens for stdin and browser controls (via a websocket).
 - sends the end result of a stream to the browser via websockets and charts the result using the js `rickshaw` library.

## design ideas

### websockets

The emitter highjacks the haskell `websocket` library. Most of the websocket code is lifted straight from example code in that library with the exception of this line in `fromWs`:

```
runEffect $ wsMessage >-> hoist liftIO (toOutput o)
```

`hoist liftIO` lifts the `Output` mailbox containing messages in the `IO` monad to the websocket monad - `WS.WebSockets WS.Hybi00`.

The very nice thing about web sockets is that it's a fully bi-directional socket system - no Ajax, no JSON and no callbacks required!

### separable effects

The parameters (`Param` and `Params`) and controllers (`Button`) are plumbed in as separable effects that can be modified mid-stream.

As a result, the emitter-server can be run as a stand-alone executable using stdin and stdout as the controller and view, allowing for separate debugging and development of lovely haskell from icky stuff like javascript.

### separable views

`pipes`-style development allows the free mixing and matching of computational niceties and use of sugary-sweet front-ends like css/js/html5 and awesome chart packages like `rickshaw`.

### ema

Along the pipe, there is an experiment of using a monoidal exponential moving average calculation to smooth the random stream.

### pipes-concurrent

`spawn (Latest defaultParams)` is an example of using pipes-concurrent to hold state as an alternative to using MVar, TVar, StateT, IORef and all the others. 

## looking forward

### parameter boiler-plate
Around half the code consists of boiler-plate surrounding the specification of various ways you can input, output and modify parameters.  Much of this can be abstracted away I'm sure.

### arrows

"Push-based pipes are also Arrows".  Once I work out what Arrows are and how pipes are arrows, much of the parameter and controller plumbing just might disappear.  

### Controller/Model/View

`emitter` has been crafted with half an eye on Gabriel's upcoming mvc package.  The end result could be a complete and accurate separation of all computations into pure haskell and controller/view effects.  Stay tuned.

### javascript

It would be nice to replace the basic and sucky javascript with something like fay.  Ditto for the html5 elements.

## bugz

- an initial tuple (NaN,NaN) seems to sneak in, probably before buttonCheck is set up to stop it.
- ema1 and ema2 are not effectful, because scan initialises a pipe that then chugs away forever. It is unknown whether an effectful ema parameter is possible without destroying the monoidal nature of the computation.
- start is also not effectful, probably because of a race condition between the various ways Latest Params can be modified.

