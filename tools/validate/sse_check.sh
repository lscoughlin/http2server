#!/usr/bin/env sh
#
# Read the 1000 events of examples/sse_replay on both protocols, check their
# order, and check the replay after a Last-Event-ID header.
#
# Usage: sse_check.sh HOST PORT
# The exit code is 0 when every check passed.

host=$1
port=$2
status=0

check() {
  # $1 name, $2 curl protocol option, $3 first event expected, $4 count expected
  # the extra arguments of curl follow
  name=$1; opt=$2; first=$3; count=$4
  shift 4
  ids=$(curl -sN -m 20 $opt "$@" "http://$host:$port/events" </dev/null | sed -n 's/^id: //p')
  got=$(printf '%s\n' "$ids" | grep -c .)
  want=$(seq "$first" 1000)
  if [ "$got" -eq "$count" ] && [ "$ids" = "$want" ]; then
    echo "PASS  $name ($got events in order)"
  else
    echo "FAIL  $name (got $got events, wanted $count from $first)"
    status=1
  fi
}

check "SSE 1000 events over HTTP/1.1" --http1.1 1 1000
check "SSE 1000 events over HTTP/2" --http2-prior-knowledge 1 1000
check "SSE replay after Last-Event-ID 990 over HTTP/1.1" --http1.1 991 10 -H 'Last-Event-ID: 990'
check "SSE replay after Last-Event-ID 400 over HTTP/2" --http2-prior-knowledge 401 600 -H 'Last-Event-ID: 400'
exit $status
