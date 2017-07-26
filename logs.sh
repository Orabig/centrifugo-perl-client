#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

docker logs -f dmon-perl-client
