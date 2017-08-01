#!/bin/sh
docker rm -f $(docker ps | grep dmon-perl-client | awk '{print $1}')
