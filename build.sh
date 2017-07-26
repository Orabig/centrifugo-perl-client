#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

docker build -t dmon-perl-client $DIR
