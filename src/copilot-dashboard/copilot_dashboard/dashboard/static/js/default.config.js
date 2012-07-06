{
  "graphs": [
    {
      "title": "Job queues",
      "id": "queues-total",
      "metrics": ["copilot.jobmanager.generic.*.queuedJobs"],
      "labelPattern": "Number of queued jobs on {0}",
      "range": "-1h",
      "type": "area",
      "sumWith": "avg",
      "refreshRate": 60
    },

    {
      "title": "Connected users",
      "id": "machines",
      "metrics": ["copilot.ejabberd.*.connected"],
      "labelPattern": "Connected users",
      "range": "-1h",
      "type": "scatter",
      "sumWith": "avg",
      "minValue": 0,
      "refreshRate": 60
    },

    {
      "title": "Connected users",
      "id": "machines-map",
      "type": "map",
      "source": "/api/connections",
      "detail": "/api/connections/"
    },

    {
      "title": "System load",
      "id": "system-load-combined",
      "metrics": ["copilot.jobmanager.generic.*.system.load.1min"],
      "labelPattern": "JM {0}",
      "range": "-1h",
      "type": "line",
      "sumWith": "avg",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Available memory",
      "id": "mem-usage-combined",
      "metrics": ["copilot.jobmanager.generic.*.system.ram.available.mem"],
      "labelPattern": "JM {0}",
      "range": "-1h",
      "type": "line",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Available swap",
      "id": "swap-usage-combined",
      "metrics": ["copilot.jobmanager.generic.*.system.ram.available.swap"],
      "labelPattern": "JM {0}",
      "range": "-1h",
      "type": "line",
      "sumWith": "avg",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Network traffic",
      "id": "net-io-combined",
      "metrics": ["copilot.jobmanager.generic.*.system.net.*.eth0"],
      "labelPattern": "eth0 {1} (JM {0})",
      "range": "-1h",
      "type": "line",
      "sumWith": "avg",
      "refreshRate": 60
    },

    {
      "title": "Disk usage",
      "id": "disk-usage-combined",
      "metrics": ["copilot.jobmanager.generic.*.system.disk.*.*"],
      "labelPattern": "{1} space on disk {2} (JM {0})",
      "type": "line",
      "range": "-1h",
      "sumWith": "avg",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Memory usage",
      "id": "mem-usage-overview",
      "metrics": ["copilot.aggregate.jobmanager.generic.mem.*"],
      "labelPattern": "{0}",
      "type": "pie",
      "range": "-1h",
      "sumWith": "avg",
      "refreshRate": 60
    },

    {
      "title": "Disk usage",
      "id": "disk-usage-overview",
      "metrics": ["copilot.jobmanager.generic.*.system.disk.*.hda1"],
      "labelPattern": "{0}",
      "type": "pie",
      "range": "-1h",
      "refreshRate": 60
    },

    {
      "title": "Job rates",
      "id": "jobs",
      "metrics": ["copilot.aggregate.jobmanager.generic.rt.totalJobs",
                  "copilot.aggregate.jobmanager.generic.rt.job.succeeded.count"],
      "labels": {
        "copilot.aggregate.jobmanager.generic.rt.totalJobs": "total",
        "copilot.aggregate.jobmanager.generic.rt.job.succeeded.count": "succeeded"
      },
      "type": "area",
      "stacking": "percent",
      "range": "-1h",
      "refreshRate": 3600,
      "minValue": 0
    },

    {
      "title": "Job duration",
      "id": "jobs-duration-combined",
      "metrics": ["copilot.aggregate.jobmanager.generic.rt.job.*.avg"],
      "labelPattern": "Average duration of a {0} job",
      "type": "scatter",
      "range": "-1h",
      "sumWith": "avg",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Errors",
      "id": "errors-combined",
      "metrics": ["copilot.jobmanager.generic.*.error.*"],
      "labelPattern": "{1} (JM {0})",
      "range": "-1h",
      "type": "scatter",
      "refreshRate": 60,
      "minValue": 0
    }
  ],

  "layout": [
    [[12],   ["jobs", "queues-total"]],
    [[12],   ["machines-map", "machines"]],

    [[6, 6], ["errors-combined"],  ["jobs-duration-combined"]],

    [[3, 9], ["mem-usage-overview", "disk-usage-overview"],
             ["system-load-combined", "mem-usage-combined", "swap-usage-combined", "net-io-combined", "disk-usage-combined"]]
  ]
}
