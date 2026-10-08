#!/usr/bin/env sh
#
# Run the external HTTP/2 conformance tools against the example server.
#
# The script starts `bin/interop_server` on a free port and runs each tool
# that is present.  A tool that is absent is reported as a skip with its
# name, because the report must state what ran and what did not.
#
# Every tool takes its input from /dev/null, so the script never stops on a
# terminal that stays open.
#
# Usage: run.sh [h2spec-package]
#   The optional argument names the h2spec package to run.  The default is
#   the whole `http2` package.  `fast` runs the two short packages only.

set -u
here=$(dirname "$0")
root=$(cd "$here/../.." && pwd)
. "$here/lib.sh"

report_skip() {
  echo "SKIP  $1: $2"
}

report_pass() {
  echo "PASS  $1"
}

report_fail() {
  echo "FAIL  $1"
  exit_code=1
}

exit_code=0
package="${1:-http2}"

if [ ! -x "$root/bin/interop_server" ]; then
  echo "the example server is absent; run the build first: $root/bin/interop_server"
  exit 2
fi

start_interop_server "$root/bin/interop_server" || {
  echo "the example server did not report a port"
  exit 2
}
trap 'stop_interop_server' EXIT INT TERM
echo "the example server listens on port $INTEROP_PORT"

# --- h2spec ---
if command -v h2spec >/dev/null 2>&1; then
  if [ "$package" = "fast" ]; then
    for pkg in http2/4.2 http2/6.5; do
      if h2spec -h 127.0.0.1 -p "$INTEROP_PORT" "$pkg" >/dev/null 2>&1 </dev/null; then
        report_pass "h2spec $pkg"
      else
        report_fail "h2spec $pkg"
      fi
    done
  else
    if h2spec -h 127.0.0.1 -p "$INTEROP_PORT" "$package" >/dev/null 2>&1 </dev/null; then
      report_pass "h2spec $package"
    else
      report_fail "h2spec $package"
    fi
  fi
else
  report_skip h2spec "the tool is not installed"
fi

# --- nghttp ---
if command -v nghttp >/dev/null 2>&1; then
  if nghttp -n "http://127.0.0.1:$INTEROP_PORT/" >/dev/null 2>&1 </dev/null; then
    report_pass "nghttp GET /"
  else
    report_fail "nghttp GET /"
  fi
else
  report_skip nghttp "the tool is not installed"
fi

# --- curl ---
if command -v curl >/dev/null 2>&1; then
  code=$(curl -s --http2-prior-knowledge -o /dev/null \
    -w '%{http_code}' "http://127.0.0.1:$INTEROP_PORT/" 2>/dev/null </dev/null || echo 000)
  if [ "$code" = "200" ]; then
    report_pass "curl GET / (200)"
  else
    report_fail "curl GET / (code $code)"
  fi
  size=$(curl -s --http2-prior-knowledge -o /dev/null \
    -w '%{size_download}' "http://127.0.0.1:$INTEROP_PORT/large?bytes=8388608" \
    2>/dev/null </dev/null || echo 0)
  if [ "$size" = "8388608" ]; then
    report_pass "curl 8 MiB response (8388608 bytes)"
  else
    report_fail "curl 8 MiB response ($size bytes)"
  fi
else
  report_skip curl "the tool is not installed"
fi

# --- h2load ---
if command -v h2load >/dev/null 2>&1; then
  if h2load -n 200 -c 10 -m 10 "http://127.0.0.1:$INTEROP_PORT/" >/dev/null 2>&1 </dev/null; then
    report_pass "h2load 200 requests, 10 connections, 10 streams each"
  else
    report_fail "h2load 200 requests, 10 connections, 10 streams each"
  fi
else
  report_skip h2load "the tool is not installed"
fi

exit "$exit_code"