{
  "graphs": [
    {
      "title": "CPU",
      "id": "cpu",
      "metrics": ["carbon.agents.*.cpuUsage"],
      "labelPattern": "CPU Usage",
      "range": "-30min",
      "type": "line",
      "sumWith": "avg",
      "refreshRate": 60
    },

    {
      "title": "Metrics",
      "id": "metrics-in",
      "metrics": ["carbon.agents.*.metricsReceived"],
      "labelPattern": "In",
      "range": "-30min",
      "type": "column",
      "refreshRate": 60
    },

    {
      "title": "Memory",
      "id": "mem",
      "metrics": ["carbon.*.*.memUsage"],
      "labelPattern": "{0} MB",
      "range": "-30min",
      "type": "line",
      "refreshRate": 60
    },

    {
      "title": "Machines",
      "id": "machines-map",
      "type": "map",
      "source": "/api/connections",
      "detail": "/api/connections/"
    }
  ],

  "layout": [
    [[12],   ["machines-map"]],
    [[12],   ["cpu", "metrics-in", "mem"]]
  ]
}
