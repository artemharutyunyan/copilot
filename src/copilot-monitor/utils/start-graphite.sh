#!/bin/sh

/opt/graphite/bin/carbon-cache.py start

/opt/graphite/bin/carbon-aggregator.py start

echo "Starting Graphite on 0.0.0.0:8000..."
gunicorn_django --daemon \
--workers=2 \
--bind=0.0.0.0 \
--pid=/opt/graphite/storage/webapp.pid \
--log-level=info \
--log-file=/opt/graphite/storage/log/webapp/gunicorn.log \
/opt/graphite/webapp/graphite/settings.py

echo "Done."
exit 0
