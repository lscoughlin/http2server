#!/usr/bin/env sh
#
# Start the validation server on a free port and print the port.
#
# The caller sources this file.  The function `start_interop_server` starts
# `bin/interop_server` with port zero, reads the port the program printed,
# and leaves the process id in the variable INTEROP_PID.  The function
# `stop_interop_server` ends the program.  The program stops when its
# standard input closes, so the shell holds a pipe open to it.

INTEROP_PID=''

# start_interop_server [binary]
# Start the server and set INTEROP_PID and INTEROP_PORT.
# A missing binary is not an error here; the caller checks the result.
start_interop_server() {
  interop_bin="${1:-bin/interop_server}"
  if [ ! -x "$interop_bin" ]; then
    return 1
  fi
  interop_out="${TMPDIR:-/tmp}/http2_interop_out.$$"
  # a long sleep holds the standard input of the server open; the pipe ends
  # when the sleep ends or when the process group is killed
  ( sleep 3600 | "$interop_bin" 0 >"$interop_out" 2>/dev/null ) &
  INTEROP_PID=$!
  # wait for the port line, at most ten seconds
  i=0
  INTEROP_PORT=''
  while [ "$i" -lt 100 ]; do
    if [ -s "$interop_out" ]; then
      INTEROP_PORT=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$interop_out" | head -1)
      if [ -n "$INTEROP_PORT" ]; then
        break
      fi
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if [ -z "$INTEROP_PORT" ]; then
    stop_interop_server
    return 1
  fi
  return 0
}

# stop_interop_server
# End the server and its pipe holder.  A call with no live process is safe.
stop_interop_server() {
  if [ -n "$INTEROP_PID" ]; then
    # the process id names the subshell that holds the pipe; kill the group
    kill "$INTEROP_PID" 2>/dev/null || true
    wait "$INTEROP_PID" 2>/dev/null || true
    INTEROP_PID=''
  fi
}