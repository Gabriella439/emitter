/*global Rickshaw: false, $: false, MozWebSocket: false, WebSocket: false */

function createWebSocketOut(path) {
    var host = window.location.hostname;
    if(host == '') host = 'localhost';
    var uri = 'ws://' + host + ':3566' + path;
    var Socket = "MozWebSocket" in window ? MozWebSocket : WebSocket;
    return new Socket(uri);
}

function createWebSocketIn(path) {
    var host = window.location.hostname;
    if(host == '') host = 'localhost';
    var uri = 'ws://' + host + ':3567' + path;
    var Socket = "MozWebSocket" in window ? MozWebSocket : WebSocket;
    return new Socket(uri);
}

$(document).ready(function () {
    console.log("document ready");
    var wsout = createWebSocketOut('/');
    var wsin = createWebSocketIn('/');

    var tv = 1000;

    var graph = new Rickshaw.Graph( {
	element: document.getElementById("chart"),
	width: 400,
	height: 200,
	min: 'auto',
	renderer: 'line',
	series: new Rickshaw.Series.FixedDuration(
            [{ name: 'emitter' }],
            undefined, {
		timeInterval: tv,
		maxDataPoints: 100,
		timeBase: new Date().getTime() / 1000
	    })
    });

    graph.render();

    var axes = new Rickshaw.Graph.Axis.Time( { graph: graph } );

    var y_axis = new Rickshaw.Graph.Axis.Y( {
        graph: graph,
        orientation: 'left',
        tickFormat: Rickshaw.Fixtures.Number.formatKMBT,
        element: document.getElementById('y_axis')
    } );

    wsout.onopen = function(event) {
        console.log('out server connection opened');
        $('#spinner').addClass("icon-spin");
    };

    wsout.onclose = function(event) {
        console.log('out server connection closed');
        $('#spinner').removeClass("icon-spin");
    };

    wsout.onmessage = function(event) {
        console.log('message received');
        console.log(event.data);
        //var p = $(document.createElement('p')).text(event.data);
        //$('#responses').text(event.data);
        //$('#responses').append(p);
        //$('#responses').animate({scrollTop: $('#responses')[0].scrollHeight});
    };
    wsin.onmessage = function(event) {
        console.log('message received');
        console.log(event.data);
	$('#stream').text(event.data);
        var split1 = event.data.substring(1,event.data.length-1).split(",");
        var split2 = [];
        for (var i=0; i<split1.length;i++)  {
            split2[i] = parseFloat(split1[i]); }
        var data = { emitter1: split2[0], emitter2: split2[1] };
	graph.series.addData(data);
	graph.render();
    };
    $("#btnGo").click( function() {
        //alert("go clicked");
        wsout.send('Go');
        return false;
    });
    $("#btnStop").click( function() {
        wsout.send('Stop');
        return false;
    });
    $("#btnQuit").click( function() {
        wsout.send('Quit');
        return false;
    });
    $('#paramMaxTake').change(function () {
        var value = $('#paramMaxTake').val();
        //alert("maktake changed to "+value);
        wsout.send('MaxTake ' + value);
        return false;
    });
    $('#paramDelay').change(function () {
        var value = $('#paramDelay').val();
        //alert("delay changed to "+value);
        document.getElementById('textDelay').value=value;
        wsout.send('Delay ' + value);
    });
    $('#textDelay').change(function () {
        var value = $('#textDelay').val();
        //alert("delay changed to "+value);
        document.getElementById('paramDelay').value=value;
        wsout.send('Delay ' + value);
    });

    $('#paramStart').change(function () {
        var value = $('#paramStart').val();
        //alert("delay changed to "+value);
        document.getElementById('textStart').value=value;
        wsout.send('Start ' + value);
    });
    $('#textStart').change(function () {
        var value = $('#textStart').val();
        //alert("delay changed to "+value);
        document.getElementById('paramStart').value=value;
        wsout.send('Start ' + value);
    });

    $('#paramDrift').change(function () {
        var value = $('#paramDrift').val();
        //alert("delay changed to "+value);
        document.getElementById('textDrift').value=value;
        wsout.send('Drift ' + value);
    });
    $('#textDrift').change(function () {
        var value = $('#textDrift').val();
        //alert("delay changed to "+value);
        document.getElementById('paramDrift').value=value;
        wsout.send('Drift ' + value);
    });
    $('#paramSigma').change(function () {
        var value = $('#paramSigma').val();
        //alert("delay changed to "+value);
        document.getElementById('textSigma').value=value;
        wsout.send('Sigma ' + value);
    });
    $('#textSigma').change(function () {
        var value = $('#textSigma').val();
        //alert("delay changed to "+value);
        document.getElementById('paramSigma').value=value;
        wsout.send('Sigma ' + value);
    });
    $('#paramDt').change(function () {
        var value = $('#paramDt').val();
        //alert("delay changed to "+value);
        document.getElementById('textDt').value=value;
        wsout.send('Dt ' + value);
    });
    $('#textDt').change(function () {
        var value = $('#textDt').val();
        //alert("delay changed to "+value);
        document.getElementById('paramDt').value=value;
        wsout.send('Dt ' + value);
    });
    $('#paramEma1').change(function () {
        var value = $('#paramEma1').val();
        //alert("delay changed to "+value);
        document.getElementById('textEma1').value=value;
        wsout.send('Ema1 ' + value);
    });
    $('#textEma1').change(function () {
        var value = $('#textEma1').val();
        //alert("delay changed to "+value);
        document.getElementById('paramEma1').value=value;
        wsout.send('Ema1 ' + value);
    });
    $('#paramEma2').change(function () {
        var value = $('#paramEma2').val();
        //alert("delay changed to "+value);
        document.getElementById('textEma2').value=value;
        wsout.send('Ema2 ' + value);
    });
    $('#textEma2').change(function () {
        var value = $('#textEma2').val();
        //alert("delay changed to "+value);
        document.getElementById('paramEma2').value=value;
        wsout.send('Ema2 ' + value);
    });

});
