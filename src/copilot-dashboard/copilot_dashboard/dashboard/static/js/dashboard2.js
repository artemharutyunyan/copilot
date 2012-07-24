(function () {

Function.prototype.bind = function (context) {
  return $.proxy(this, context);
};

if(!("console" in this) || !("log" in console))
  console = {log: function () {}};

window.Dashboard = {
  dataMode: 'realtime',

  init: function () {
    this.loadConfig();
  },

  loadConfig: function () {
    var configFile = window.location.hash.slice(1).split('/')[0];
    configFile = configFile.length ? configFile : "default";

    console.log("Using " + configFile + ".config");
    $('body').addClass('config-' + configFile);
    $.getJSON('js/' + configFile + '.config.js?r='+Math.random(), this.parseConfig.bind(this));
  },

  parseConfig: function (config) {
    this.config = config;
    console.log('Loaded configuration file', config);

    this.initLayout(config.layout);
    this.initGraphs(config.graphs);
  },

  initLayout: function (layout) {
    var dash = $('#dashboard').detach(),
        graphs = this.config.graphs,
        rowConfig, graphIds, graphsCount,
        group, i, ii, j, jj, k, kk, gid;

    for(i = 0, ii = layout.length; i < ii; i++) {
      rowConfig = layout[i][0];
      graphIds = layout[i].slice(1);

      for(j = 0, jj = rowConfig.length; j < jj; j++) {
        group = $('<div class="group grid_' + rowConfig[j] +'"/>');

        for(k = 0, kk = graphIds[j].length; k < kk; k++) {
          gid = graphIds[j][k];
          group.append('<div id="g-' + gid + '" class="graph ' + type(gid) + '"/>');
          if(k !== kk - 1) group.append('<hr/>');
        }

        dash.append(group);
      }

      dash.append('<div class="clear"/>');
    }


    dash.append('<div style="height:20px"/>');
    $('body').append(dash);

    $('#switcher').on('click', function (e) {
      Dashboard.switchDataMode(e.target.value.toLowerCase());
    });

    function type(id) {
      var n = graphs.length;
      while(n--) if(graphs[n].id === id) return graphs[n].type;
      return false;
    }
  },

  initGraphs: function (graphs) {
    var n = graphs.length - 1, g;
    this.graphs = new Array(n);

    this._loadNext = function () {
      if(n === -1) return;
      g = graphs[n];
      Dashboard.graphs[n] = g.type === "map" ? new Map(g) : new Graph(g);
      n--;
    };

    this._loadNext();
  },

  switchDataMode: function (mode) {
    $('#switcher input').removeClass('active');
    $('#switcher input[value=' + fcupper(mode) + ']').addClass('active');

    this.dataMode = mode;
    this.refreshGraphs();
  },

  refreshGraphs: function () {
    var graphs = this.graphs,
        configs = this.config.graphs,
        n = graphs.length,
        graph, config, metrics, m;

    while(n--) {
      config = $.extend(true, {}, configs[n]);
      config.range = Dashboard.adjustRangeForMode(config.range, config.type === 'map');
      if(Dashboard.dataMode !== "realtime") config.refreshRate = 0;
      if(config.type !== "map") {
        metrics = config.metrics;
        m = metrics.length;
        while(m--) {
          metrics[m] = Dashboard.adjustPathForMode(metrics[m], config.sumWith);
        }
      }

      graphs[n].clear();
      graphs[n] = null;
      graphs[n] = config.type === "map" ? new Map(config) : new Graph(config);
    }
  },

  adjustPathForMode: function (path, sumMethod) {
    var mode = this.dataMode;
    if(mode === 'realtime') return path;

    var sum_by;
    if(mode === 'hourly') sumBy = '1h';
    else if(mode === 'daily')  sumBy = '1d';
    else if(mode === 'weekly') sumBy = '1week';

    return "summarize(" + path + ",'" + sumBy + "','" + (sumMethod || "sum") + "')";
  },

  adjustRangeForMode: function (range, absolute) {
    var mode = this.dataMode;
    if(mode === 'realtime')    return range;

    var now = utcnow(), day = 24*60*60*1000;
    if(mode === 'hourly')      return absolute ? now - day : '-1day';
    else if(mode === 'daily')  return absolute ? now - 7*day : '-1week';
    else if(mode === 'weekly') return absolute ? now - 31*day : '-1month';
  }
};

function Graph(options) {
  this.options = options;
  this.id = options.id || Graph.COUNT++;

  this._el = $('#g-' + this.id);
  if(!this._el.length) {
    setTimeout(Dashboard._loadNext, 1);
    return;
  }

  var chartOptions = {
    chart: {
      renderTo: 'g-' + this.id,
      defaultSeriesType: options.type,
      events: {
        load: this.refresh.bind(this)
      },
      zoomType: 'x',
      backgroundColor: 'transparent'
    },
    credits: {enabled: false},
    labels: {
      style: {color: '#fff'}
    },
    title: {text: null},
    xAxis: {},
    yAxis: {
      title: {text: null},
      gridLineColor: '#2F333E'
    },
    plotOptions: {
      series: {
        allowPointSelect: true,
        marker: {
          enabled: options.type === 'scatter',
          radius: 2,
          states: {hover: {enabled: true}}
        }
      }
    },
    legend: {
      enabled: false,
      borderWidth: 0
    },
    series: []
  };

  if('minValue' in options)
    chartOptions.yAxis.min = options.minValue;

  if(options.type === 'pie') {
    chartOptions.plotOptions.series.dataLabels = {enabled: false};
    chartOptions.plotOptions.series.showInLegend = true;
    chartOptions.legend.enabled = true;
    chartOptions.tooltip = {
      formatter: function () { return Highcharts.numberFormat(this.y*100, 2) + '%' }
    };
  } else if(options.type === 'column') {
    chartOptions.plotOptions.series.pointWidth = 10;
  } else {
    chartOptions.xAxis.type = 'datetime';
    chartOptions.plotOptions.line = {lineWidth: 2};
    chartOptions.plotOptions.series.shadow = false;
  }
  if(options.stacking)
    chartOptions.plotOptions.series.stacking = options.stacking;

  var metrics = [];
  for(var metric in options.labels) {
    chartOptions.series.push({
      'name': options.labels[metric],
      data: []
    });
    metrics.push(metric);
  }
  this._metrics = metrics;

  this.g = new Highcharts.Chart(chartOptions);
  this._el.prepend('<span class="title">' + options.title + '</span>');

  //setTimeout(function () { Dashboard._loadNext(); }, 1);

  return this;
}

Graph.COUNT = 0;

Graph.prototype = {
  buildQuery: function () {
    var metrics = this.options.metrics,
        n = metrics.length,
        q = [],
        m;

    while(n--) {
      m = metrics[n];
      q.push('target=' + encodeURIComponent(m));
    }

    var from = Dashboard.adjustRangeForMode(this._lastUpdate ? this._lastUpdate : this.options.range);
    q.push('from=' + from);

    return q.join('&');
  },
  patternForPath: function (path) {
    var metrics = this.options.metrics, n = metrics.length;
    if(metrics.length === 1) return metrics[0];

    path = path.split('.');
    patternLoop:
    while(n--) {
      var pattern = metrics[n].split('.'),
          m = pattern.length;

      if(path.length !== m) continue;

      while(m--)
        if(pattern[m] !== '*' && pattern[m] !== path[m])
          continue patternLoop;

      return metrics[n];
    }
  },
  path2index: function (path) {
    return this._metrics.indexOf(path);
  },
  stripFunctions: function (path) {
    if(path.indexOf('(') === -1) return path;

    var parts = path.split('(');
    return parts[parts.length-1].split(',')[0];
  },
  addSeries: function (path) {
    var options = {data: []};
    if(this.options.type !== 'pie')
      options.name = mapPath(this.patternForPath(path), path, this.options.labelPattern);

    this.g.addSeries(options, false, false);
    return this._metrics.push(path) - 1;
  },
  refresh: function () {
    var q = this.buildQuery();
    Buffer.getJSON('/api/stats?' + q, this.parseResponse.bind(this));

    if(this.options.refreshRate !== 0)
      this._refreshTimeout = setTimeout(this.refresh.bind(this), (this.options.refreshRate || 60) * 1000);
  },
  clear: function () {
    clearTimeout(this._refreshTimeout);
    this.g.destroy();
  },
  parseResponse: function (data) {
    setTimeout(Dashboard._loadNext, 10 + Math.random());

    // A line looks like:
    // graph.path,start timestamp,end timestamp,time delta|value1,value2,None,value3\n
    var line, meta, values, path, ts, delta,
        m, midx, v, shift,

        lu      = this._lastUpdate,
        first   = !lu,
        pie     = this.options.type == 'pie',
        delta   = this.options.refreshRate * 1000,
        series  = data,
        n       = series.length;

    if(pie) {
      var updates = [], sum = 0,
          labelPattern = this.options.labelPattern,
          labels = this.options.labels,
          pattern, label;

      while(n--) {
        line    = series[n];
        if(!line) continue;
        path    = this.stripFunctions(line.target);
        values  = line.datapoints;
        m       = values.length;

        while(m--) {
          v = values[m][0];
          if(v !== null) break;
        }

        // if there were no updates
        if(v < 0 || isNaN(v)) return;

        if(this.path2index(path) === -1) this.addSeries(path);
        pattern = this.patternForPath(path);

        label = labelPattern ? mapPath(pattern, path, this.options.labelPattern) : labels[path];
        updates.push([label, v]);
        sum += v;

        if(first) this._lastUpdate = +line[2];
      }

      n = updates.length;
      if(!n) return; // the first update might be screwed up
      while(n--) {
        v = Math.round(updates[n][1]/sum*1000)/1000;
        if(!isNaN(v)) updates[n][1] = v;
        else return;
      }
      this.g.series[0].setData(updates);

      return;
    }

    // all other charts except the pie chart
    while(n--) {
      line = series[n];
      if(!line) continue;

      values = line.datapoints.reverse();
      this._lastUpdate = values[0][1];
      m = values.length;
      midx = this.path2index(line.target);
      if(midx == -1) midx = this.addSeries(line.target);
      while(m--) {
        v = values[m];
        if((m == 0 && v[0] === null) || v[1] < lu) continue;
        this.g.series[midx].addPoint([v[1]*1000, v[0]], false, !first);
      }

      this.g.redraw();
    }
  }
};

var MAP_INFO_CACHE = {};
function Map(config) {
  this.config = config;
  this.id = config.id;
  this._lastUpdate = 0;

  this._el = document.getElementById('g-' + this.id);
  if(!this._el) {
    setTimeout(Dashboard._loadNext, 1);
    return;
  }

  var mapOptions = {
      center: new google.maps.LatLng(35.61373, 21.03124),
      zoom: 1,
      mapTypeId: google.maps.MapTypeId.ROADMAP,
      panControl: false,
      rotateControl: false,
      streetViewControl: false
    },
    markerOptions = {
      styles:  [{
                  url: 'img/map/m1.png',
                  height: 53,
                  width: 52,
                  textColor: 'black',
                  textSize: 12,
                  anchor: [30, 28]
                },
                {
                  url: 'img/map/m2.png',
                  height: 56,
                  width: 55,
                  textColor: 'black',
                  textSize: 11,
                  anchor: [31, 22]
                },
                {
                  url: 'img/map/m3.png',
                  height: 78,
                  width: 77,
                  textColor: 'black',
                  textSize: 11,
                  anchor: [43, 30]
                },
                {
                  url: 'img/map/m4.png',
                  height: 90,
                  width: 89,
                  textColor: 'black',
                  textSize: 11,
                  anchor: [50, 33]
                },
                {
                  url: 'img/map/m5.png',
                  height: 90,
                  width: 89,
                  textColor: 'black',
                  textSize: 11,
                  anchor: [50, 33]
                }
             ]
    };

  this.m = new google.maps.Map(this._el, mapOptions);
  this.mc = new MarkerClusterer(this.m, [], markerOptions);
  this._infoWindow = new google.maps.InfoWindow({content: "x"});
  this._clients = [];

  this.refresh();
  setTimeout(Dashboard._loadNext, 10 + Math.random());
};

Map.prototype = {
  refresh: function () {
    var today = utcnow(),
        from = Dashboard.adjustRangeForMode(this._lastUpdate ? this._lastUpdate : this.config.range, true),
        all = (Dashboard.dataMode == "realtime" && !this._lastUpdate) ? "&allactive=true" : "";

    Buffer.getJSON(this.config.source + "?from=" + from + all, this.parseResponse.bind(this));

    if(this.config.refreshRate !== 0)
      this._refreshTimeout = setTimeout(this.refresh.bind(this), 60 * 1000);
  },
  clear: function () {
    this.mc.clearMarkers();
    this._clients = [];
    clearTimeout(this._refreshTimeout);
  },
  parseResponse: function (data) {
    var n = data.length,
        markers = [],
        c = this._clients,
        marker, id;

    MAP_INFO_CACHE = {};

    while(n--) {
      id = data[n]._id;
      if(c.indexOf(id) !== -1) {
        continue;
      }

      marker = new google.maps.Marker({
        position: new google.maps.LatLng(data[n].loc[1], data[n].loc[0]),
        title: id,
        clickable: true,
        icon: 'img/map/m0.png'
      });
      markers.push(marker);
      this._clients.push(id);
      this._attachMarkerEvents(marker);
    }

    this.mc.addMarkers(markers);
    this._lastUpdate = +utcnow();
  },
  _attachMarkerEvents: function (marker) {
    google.maps.event.addListener(marker, 'click', function () { this.showConnectionInfo(marker) }.bind(this));
  },
  showConnectionInfo: function (marker) {
    var info = this._infoWindow;
    info.close();
    info.setContent('Loading...');
    info.open(this.m, marker);

    this.getConnectionInfo(marker.getTitle(), function (data) {
      var display = '<table class="mapinfo">',
          total_jobs = data.succeeded_jobs + data.failed_jobs,
          formatted = {
                    'Status': data.connected ? 'Online' : 'Offline',
                    'Last seen': data.updated_at,
                 };

      if(data.agent_data.component == 'agent') {
        formatted['Completed jobs'] = total_jobs;
        formatted['Contributed CPUs'] = data.agent_data.cpus || "Unknown";
        formatted['Succeeded jobs'] = '0 (0%)';

        if(total_jobs > 0)
          formatted['Succeeded jobs'] = data.succeeded_jobs + ' (' + Math.round((total_jobs/data.succeeded_jobs)*10000)/100 + '%)';
      } else {
        formatted['Component'] = data.agent_data.component;
      }

      for(var field in formatted)
        display += "<tr><td>" + field + ":</td><td> " + formatted[field] + "</td></tr>";

      display += "</table>";
      info.setContent(display);
    });
  },
  getConnectionInfo: function (id, cb) {
    if(id in MAP_INFO_CACHE)
      return cb(MAP_INFO_CACHE[id]);

    Buffer.getJSON(this.config.detail + id, function (data) {
      cb(MAP_INFO_CACHE[id] = data);
    });
  }
};

var Buffer = {
  config: {inParallel: 2},
  _active: 0,
  _requests: [],

  getJSON: function (url, cb) {
    if(this._active <= this.config.inParallel)
      return this._fireRequest(url, cb)
    else
      return this._requests.push(arguments);
  },

  _fireRequest: function (url, cb) {
    this._active++;
    console.log('GET', url);
    return $.getJSON(url, function (resp) { Buffer._next(Buffer._active--); cb(resp); },
                          function () { Buffer._next(Buffer._active--); });
  },

  _next: function () {
    if(!this._requests.length) return;
    this._fireRequest.apply(this, this._requests.shift());
  }
};

function fcupper (str) {
  return str.charAt(0).toUpperCase() + str.slice(1);
}

function utcnow () {
  var now = new Date();
  return new Date(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),  now.getUTCHours(), now.getUTCMinutes(), now.getUTCSeconds());
}

// mapPath('copilot.jobmanager.generic.*.system.disk.*.hda1', 'copilot.jobmanager.generic.default.system.disk.available.hda1', 'JM {0}: {1} disk space');
// => 'JM default: available disk space'
var _replaceRegex = /\{(\d+)\}/g;
function mapPath(pattern, path, str) {
  pattern = pattern.split('.');
  path = path.split('.');

  var mapping = {},
      x = pattern.length, n, m = 0;

  for(n = 0; n < x; n++)
    if(pattern[n] === '*')
      mapping[m++] = path[n];

  return str.replace(_replaceRegex, function (match, idx) { return mapping[idx]; });
}


$(function () {
  Highcharts.setOptions({useUTC: true});
  Dashboard.init();
});

})();
