(function () {

Function.prototype.bind = function (context) {
  return $.proxy(this, context);
};

if(!("log" in console))
  console = {log: function () {}};

window.Dashboard = {
  init: function () {
    console.log('init');
    this.loadConfig();

    this._clock = $('#clock')[0];
    this.updateClock();
    setInterval(this.updateClock.bind(this), 60*1000);
  },
  
  loadConfig: function () {
    console.log('Loading config');
    $.getJSON('js/dashboard2.config.js?r='+Math.random(), this.parseConfig.bind(this));
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
          group.append('<div id="g-' + gid + '" class="graph ' + (isItAPie(gid) ? 'pie' : '') + '"/>');
          if(k !== kk - 1) group.append('<hr/>');
        }

        dash.append(group);
      }

      dash.append('<div class="clear"/>');
    }


    dash.append('<div style="height:20px"/>');
    $('html').append(dash);

    function isItAPie(id) {
      var n = graphs.length;
      while(n--) if(graphs[n].id === id) return graphs[n].type === 'pie';
      return false;
    }
  },

  initGraphs: function (graphs) {
    var n = graphs.length - 1;

    this._loadNext = function () {
      if(n === -1) return;
      graphs[n] = new Graph(graphs[n]);
      n -= 1;
    };
    
    this._loadNext();
  },

  updateClock: function () {
    var date = new Date();
    this._clock.innerText = Highcharts.dateFormat('%H:%M', +date);
  }
};

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

function Graph(options) {
  this.options = options;
  this.id = options.id || Graph.COUNT++;
  console.log('Initialising new graph', options);
  
  this._el = $(document.getElementById('g-' + this.id));
  if(!this._el.length) {
    setTimeout(function () { Dashboard._loadNext() }, 1);
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
      backgroundColor: 'transparent',

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
    var q = [
              'rawData=1',
              this.options.metrics.map(function (x) { return 'target=' + encodeURIComponent(x) }).join('&'),
              'uniq=' + Math.random()
            ];
    
    if(this._lastUpdate)
      q.push('from=' + this._lastUpdate, 'until=now');
    else
      q.push('from=' + this.options.range, 'until=now');
    
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
  addSeries: function (path) {
    var options = {data: []};
    if(this.options.type !== 'pie')
      options.name = mapPath(this.patternForPath(path), path, this.options.labelPattern);

    this.g.addSeries(options, false, false);    
    return this._metrics.push(path) - 1;
  },
  path2index: function (path) {
    return this._metrics.indexOf(path);
  },
  refresh: function () {
    var q = this.buildQuery();
    console.log('GET /render?' + q);
    $.get('/render?' + q, this.parseResponse.bind(this));
    setTimeout(this.refresh.bind(this), (this.options.refreshRate || 60) * 1000);
  },
  parseResponse: function (data) {
    setTimeout(function () { Dashboard._loadNext(); }, 1);

    // A line looks like:
    // graph.path,start timestamp,end timestamp,time delta|value1,value2,None,value3\n
    var line, meta, values, path, ts, delta,
        m, midx, v, shift,

        first   = !this._lastUpdate,
        pie     = this.options.type == 'pie',
        delta   = this.options.refreshRate * 1000,
        series  = data.split('\n'),
        n       = series.length;
    
    if(pie) {
      var updates = [], sum = 0, 
          labelPattern = this.options.labelPattern,
          labels = this.options.labels,
          pattern, label;

      while(n--) {
        line    = this.parseLine(series[n]);
        if(!line) continue;
        path    = line[0];
        values  = line[4];
        m       = values.length;

        while(m--) {
          v = values[m];
          v = v[0] === 'N' ? null : +v;
          if(v === null) continue;
          else           break;
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
      line = this.parseLine(series[n]);
      if(!line) continue;
      path        = line[0];
      if(line[1] === line[2]) continue; // no updates were made and graphite sends us a bunch of None values
      ts          = +line[1] * 1000;
      delta       = +line[3] * 1000;
      midx        = this.path2index(path);
      if(midx === -1) midx = this.addSeries(path);
      values      = line[4].reverse();
      m           = values.length;

      if(first) this._lastUpdate = +line[2];

      // Converts the value into a Number, and adds it to the chart
      // Chart is re-rendered after all points have been added.
      // Depending on the timing, the last value can be often 'None',
      // which is why we're discarding it
      while(m--) {
        v = values[m];
        v = v[0] === 'N' ? null : +v;
        if(m === 0 && v === null) continue;
        shift = this.g.series[midx].data.length > 20;
        this.g.series[midx].addPoint([ts += delta, v], false, !first);
      }
      this.g.redraw();
    }
  },
  parseLine: function (line) {
    var meta, path, ts, delta, values;
    line = line.split('|');
    if(line.length === 1) return false;

    meta = line[0];
    values = [line[1].split(',')];

    // if the metric has a function applied, like:
    // summarize(x.y.z, "1day")
    //                ^ this will pose problems
    if(meta.indexOf(')') !== -1) {
      var lastIndex = meta.lastIndexOf(')') + 1;
      path = meta.slice(0, lastIndex);
      meta = meta.slice(lastIndex + 1).split(',');

      return [path].concat(meta, values);
    } else
      return [].concat(meta.split(','), values);
  }
};

$(function () {
  Highcharts.setOptions({useUTC: true});
  Dashboard.init();
});

})();
