#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

DMON_API="$(grep DMON_API /etc/dmon.config | awk -F= '{print $2}')"
CENT_WS="$(grep CENT_WS /etc/dmon.config | awk -F= '{print $2}')"


docker run -it \
   --volume $DIR/src:/src \
   --volume /home/orabig/DEV/centreon-plugins:/var/lib/centreon-plugins \
   --volume $DIR/tmp:/var/lib/centreon/centplugins \
   -e DMON_API=$DMON_API \
   -e CENT_WS=$CENT_WS \
   dmon-perl-client bash
