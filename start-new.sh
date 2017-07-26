#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

DMON_API="$(grep DMON_API /etc/dmon.config | awk -F= '{print $2}')"
CENT_WS="$(grep CENT_WS /etc/dmon.config | awk -F= '{print $2}')"

docker run -d \
   --volume $DIR/src:/src \
   -e DMON_API=$DMON_API \
   -e CENT_WS=$CENT_WS \
   dmon-perl-client perl /src/run.pl
