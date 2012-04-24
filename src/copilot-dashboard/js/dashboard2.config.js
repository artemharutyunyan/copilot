{
  "graphs": [
    {
      "title": "Job Queues",
      "id": "queues-total",
      "metrics": ["copilot.jobmanager.generic.*.queuedJobs"],
      "labelPattern": "Number of queued jobs on {0}",
      "range": "-6h",
      "type": "area",
      "refreshRate": 60
    },
  
    {
      "title": "System load",
      "id": "system-load-combined", 
      "metrics": ["copilot.jobmanager.generic.*.system.load.1min"],
      "labelPattern": "JM {0}",
      "range": "-6h",
      "type": "line",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Available memory",
      "id": "mem-usage-combined", 
      "metrics": ["copilot.jobmanager.generic.*.system.ram.available.mem"],
      "labelPattern": "JM {0}",
      "range": "-6h",
      "type": "line",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Available swap",
      "id": "swap-usage-combined", 
      "metrics": ["copilot.jobmanager.generic.*.system.ram.available.swap"],
      "labelPattern": "JM {0}",
      "range": "-6h",
      "type": "line",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Network traffic",
      "id": "net-io-combined", 
      "metrics": ["copilot.jobmanager.generic.*.system.net.*.eth0"],
      "labelPattern": "eth0 {1} (JM {0})",
      "range": "-6h",
      "type": "line",
      "refreshRate": 60
    },

    {
      "title": "Disk usage",
      "id": "disk-usage-combined",
      "metrics": ["copilot.jobmanager.generic.*.system.disk.*.sda1"],
      "labelPattern": "{1} space on disk sda1 (JM {0})",
      "type": "line",
      "range": "-6h",
      "refreshRate": 60,
      "minValue": 0
    },

    {
      "title": "Memory usage",
      "id": "mem-usage-overview",
      "metrics": ["copilot.aggregate.jobmanager.generic.mem.*"],
      "labelPattern": "{0}",
      "type": "pie",
      "range": "-3min",
      "refreshRate": 60
    },

    {
      "title": "Disk usage",
      "id": "disk-usage-overview",
      "metrics": ["copilot.aggregate.jobmanager.generic.disk.*"],
      "labelPattern": "{0}",
      "type": "pie",
      "range": "-3min",
      "refreshRate": 60
    },
    
    
    {
      "title": "Jobs rates (last week)",
      "id": "jobs-last-week-combined",
      "metrics": ["summarize(copilot.aggregate.jobmanager.generic.rt.totalJobs, \"1h\")",
                  "summarize(copilot.aggregate.jobmanager.generic.rt.job.succeeded.count, \"1h\")"],
      "labels": {
        "summarize(copilot.aggregate.jobmanager.generic.rt.totalJobs, \"1h\")": "total",
        "summarize(copilot.aggregate.jobmanager.generic.rt.job.succeeded.count, \"1h\")": "succeeded"
      },
      "type": "area",
      "stacking": "percent",
      "range": "-1week",
      "refreshRate": 3600,
      "minValue": 0
    },
    
    {
      "title": "Jobs rates (last 6 hours)",
      "id": "jobs-recent-combined",
      "metrics": ["copilot.aggregate.jobmanager.generic.rt.totalJobs",
                  "copilot.aggregate.jobmanager.generic.rt.job.succeeded.count"],
      "labels": {
        "copilot.aggregate.jobmanager.generic.rt.totalJobs": "total",
        "copilot.aggregate.jobmanager.generic.rt.job.succeeded.count": "succeeded"
      },
      "type": "area",
      "stacking": "percent",
      "range": "-6h",
      "refreshRate": 10,
      "minValue": 0
    },
    
    {
      "title": "Job duration",
      "id": "jobs-duration-combined",
      "metrics": ["copilot.aggregate.jobmanager.generic.rt.job.*.avg"],
      "labelPattern": "Average duration of a {0} job",
      "type": "scatter",
      "range": "-6h",
      "refreshRate": 10,
      "minValue": 0
    },
    
    {
      "title": "Errors",
      "id": "errors-combined",
      "metrics": ["copilot.jobmanager.generic.*.error.*"],
      "labelPattern": "{1} (JM {0})",
      "range": "-6h",
      "type": "scatter",
      "refreshRate": 10,
      "minValue": 0
    }
  ],

  "layout": [
    [[12],   ["queues-total"]],

    [[3, 9], ["mem-usage-overview", "disk-usage-overview"],
             ["system-load-combined", "mem-usage-combined", "swap-usage-combined", "net-io-combined", "disk-usage-combined"]],
    
    [[12],   ["jobs-last-week-combined", "jobs-recent-combined"]],

    [[6, 6], ["errors-combined"],  ["jobs-duration-combined"]]
  ]
}
