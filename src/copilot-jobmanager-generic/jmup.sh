#!/bin/sh

JM_UP_LOG="/var/log/jmup.log";

exec &>$JM_UP_LOG 2>&1

DATE=`date +%Y%m%d-%H%M%S`
JM="copilot-jobmanager-generic";


JM_UP=`ps -ef|grep perl|grep $JM`

if [ "x$JM_UP" != "x" ]; then
    echo "$DATE copilot-jobmanager-generic is up."
    echo $DATE $JM_UP
else
    echo $DATE "Got a problem" > "$JM_LOG""_err"
    screen -dmS "jm-$DATE" /usr/bin/copilot-jobmanager-generic
fi
