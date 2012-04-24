#!/bin/sh

/opt/graphite/bin/carbon-cache.py stop

/opt/graphite/bin/carbon-aggregator.py stop

pidfile=/opt/graphite/storage/webapp.pid
pid=`cat $pidfile | tr -d [:cntrl:]`
echo "Sending kill signal to guicorn_django ($pid)"
kill $pid
echo "Deleting $pidfile"
rm $pidfile

exit 0
