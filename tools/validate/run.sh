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

# The TLS checks load OpenSSL at run time through mORMot2.  The library
# directory of the development host is the Homebrew one, and a caller that
# names another directory in OPENSSL_LIBPATH keeps it.
if [ -z "${OPENSSL_LIBPATH:-}" ] && [ -d /opt/homebrew/opt/openssl@3/lib ]; then
  OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib
  export OPENSSL_LIBPATH
fi

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

start_interop_server "$root/bin/interop_server" no-http11 || {
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
# The streams in flight are `-c` times `-m`, and the server admits
# `HandlerThreads + Queue.Depth` of them (4 + 64 = 68 in this build).  A
# larger product reaches the bound and the server refuses the excess with
# REFUSED_STREAM, which RFC 9113 section 8.7 permits.  This run stays inside
# the bound, so a refusal is a defect here.
if command -v h2load >/dev/null 2>&1; then
  if h2load -n 200 -c 10 -m 6 "http://127.0.0.1:$INTEROP_PORT/" >/dev/null 2>&1 </dev/null; then
    report_pass "h2load 200 requests, 10 connections, 6 streams each (60 in flight)"
  else
    report_fail "h2load 200 requests, 10 connections, 6 streams each (60 in flight)"
  fi
else
  report_skip h2load "the tool is not installed"
fi

# the checks above used the clear-text server; the TLS check starts its own
stop_interop_server

# --- HTTP/1.1 fallback, clear text ---
# The conformance run above used a server with the fallback off. This server
# keeps the fallback on, and one listener must give the same body on both
# protocols.
if command -v curl >/dev/null 2>&1; then
  if start_interop_server "$root/bin/interop_server"; then
    body1=$(curl -s --http1.1 "http://127.0.0.1:$INTEROP_PORT/" </dev/null)
    body2=$(curl -s --http2-prior-knowledge "http://127.0.0.1:$INTEROP_PORT/" </dev/null)
    if [ -n "$body1" ] && [ "$body1" = "$body2" ]; then
      report_pass "curl --http1.1 and --http2 give the same body (clear text)"
    else
      report_fail "curl --http1.1 and --http2 differ on clear text ('$body1' / '$body2')"
    fi
    stop_interop_server
  else
    report_fail "the fallback server did not report a port"
  fi
fi

# --- TLS and ALPN ---
# One listener serves one transport, so the TLS checks start a second server
# with a certificate.  A certificate that is absent is created here.
if command -v openssl >/dev/null 2>&1; then
  cert_dir=$(ensure_validation_certificate "$root/test/certs")
  if [ -n "$cert_dir" ]; then
    if start_interop_server "$root/bin/interop_server" \
      --cert="$cert_dir/localhost.crt" --key="$cert_dir/localhost.key"; then
      tls_port=$INTEROP_PORT
      alpn=$(echo | openssl s_client -connect "127.0.0.1:$tls_port" -alpn h2 2>/dev/null \
        | sed -n 's/^ *ALPN protocol: *//p' | head -1)
      if [ "$alpn" = "h2" ]; then
        report_pass "openssl s_client negotiates ALPN h2"
      else
        report_fail "openssl s_client ALPN result ($alpn)"
      fi
      if command -v curl >/dev/null 2>&1; then
        tbody1=$(curl -sk -m 10 --http1.1 "https://127.0.0.1:$tls_port/" </dev/null)
        tbody2=$(curl -sk -m 10 --http2 "https://127.0.0.1:$tls_port/" </dev/null)
        if [ -n "$tbody1" ] && [ "$tbody1" = "$tbody2" ]; then
          report_pass "curl --http1.1 and --http2 give the same body (TLS)"
        else
          report_fail "curl --http1.1 and --http2 differ over TLS ('$tbody1' / '$tbody2')"
        fi
        # a request with Connection: close takes the close path of a TLS connection
        tbody3=$(curl -sk -m 10 --http1.1 -H 'Connection: close' "https://127.0.0.1:$tls_port/" </dev/null)
        if [ -n "$tbody3" ] && [ "$tbody3" = "$tbody1" ]; then
          report_pass "curl --http1.1 with Connection: close over TLS"
        else
          report_fail "curl --http1.1 with Connection: close over TLS ('$tbody3')"
        fi
      fi
      stop_interop_server
      # with the fallback off, a client that offers only http/1.1 is refused
      if command -v curl >/dev/null 2>&1 &&
         start_interop_server "$root/bin/interop_server" no-http11 \
           --cert="$cert_dir/localhost.crt" --key="$cert_dir/localhost.key"; then
        if curl -sk -m 10 --http1.1 "https://127.0.0.1:$INTEROP_PORT/" </dev/null >/dev/null 2>&1; then
          report_fail "TLS with the fallback off still served HTTP/1.1"
        elif curl -sk -m 10 --http2 "https://127.0.0.1:$INTEROP_PORT/" </dev/null >/dev/null 2>&1; then
          report_pass "TLS with the fallback off refuses http/1.1 and serves h2"
        else
          report_fail "TLS with the fallback off refused h2 too"
        fi
        stop_interop_server
      fi
    else
      report_fail "the TLS server did not report a port"
    fi
  else
    report_skip openssl "the certificate could not be created"
  fi
else
  report_skip openssl "the tool is not installed"
fi

# --- WebSocket over HTTP/2 (RFC 8441) with h2 and wsproto ---
# WS_PYTHON names a Python that holds the packages h2 and wsproto.
ws_python="${WS_PYTHON:-python3}"
if [ -x "$root/bin/ws_echo" ] && "$ws_python" -c 'import h2, wsproto' >/dev/null 2>&1; then
  ws_out="${TMPDIR:-/tmp}/http2_ws_out.$$"
  ( sleep 60 | "$root/bin/ws_echo" 127.0.0.1 0 >"$ws_out" 2>/dev/null ) &
  ws_pid=$!
  ws_port=''
  i=0
  while [ "$i" -lt 100 ] && [ -z "$ws_port" ]; do
    ws_port=$(sed -n 's#.*127\.0\.0\.1:\([0-9][0-9]*\)/.*#\1#p' "$ws_out" 2>/dev/null | head -1)
    i=$((i + 1))
    sleep 0.1
  done
  if [ -n "$ws_port" ] &&
     "$ws_python" "$here/ws_h2_client.py" 127.0.0.1 "$ws_port" 50 </dev/null >"$ws_out.client" 2>&1; then
    report_pass "WebSocket echo over HTTP/2 with h2 and wsproto (50 messages, clean close)"
  else
    report_fail "WebSocket echo over HTTP/2 with h2 and wsproto"
    cat "$ws_out" "$ws_out.client" 2>/dev/null
  fi
  kill "$ws_pid" 2>/dev/null
  pkill -f "$root/bin/ws_echo" 2>/dev/null
  rm -f "$ws_out" "$ws_out.client"
else
  report_skip "WebSocket over HTTP/2" "ws_echo or the Python packages h2 and wsproto are absent"
fi

exit "$exit_code"
