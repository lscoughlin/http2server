{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, sweep, live connections, age, goaway, drain
notes:
  - This unit sweeps the live connections of the async server.
  - The interface takes the mORMot2 connection pool, so it names no server
    class. The implementation uses the async server unit for the cast to the
    connection class.
---
}
/// The sweep over the live connections of the async server
// - each routine copies the live instances once and applies one action
// - a short call on a copied instance is safe without the main lock
unit Http2Server.Async.Sweep;

{$mode delphi}{$H+}

interface

uses
  mormot.net.async,
  Http2Server.Errors;

/// true when queued output made no progress for the write timeout
// - the timeout is above 0, the backlog is above 0, and the time since the
//   last progress is at least the timeout. A busy connection is judged here,
//   because the idle callback misses it
function WriteStalled(const ANowMs, ALastProgressMs: QWord;
  const ATimeoutMs: Integer; const ABacklog: Int64): Boolean;

/// retire the connections past their maximum age, and close the ones whose
/// writes stalled
// - a zero age limit turns the age part off, and a zero write timeout turns
//   the stall part off. A busy connection is judged here, because the idle
//   callback misses it
procedure SweepAgedConnections(const AServer: TAsyncConnections;
  const AMaxAgeMs, AGraceMs, AWriteTimeoutMs: Integer);

/// tell every HTTP/1.1 connection to close after the request it serves
procedure DrainH1Connections(const AServer: TAsyncConnections);

/// queue a GOAWAY frame on every open HTTP/2 connection, then wake its output
// - the last stream identifier that the core processed goes into the frame,
//   so a peer keeps the streams below it
procedure GoAwayAllConnections(const AServer: TAsyncConnections;
  const AErrorCode: THttp2ErrorCode);

/// the streams that are open on every connection now
function CountOpenStreams(const AServer: TAsyncConnections): Integer;

implementation

uses
  SysUtils,
  mormot.core.os,
  Http2Server.Async;

function WriteStalled(const ANowMs, ALastProgressMs: QWord;
  const ATimeoutMs: Integer; const ABacklog: Int64): Boolean;
begin
  if ATimeoutMs <= 0 then
    Exit(False);
  if ABacklog <= 0 then
    Exit(False);
  if ANowMs < ALastProgressMs then
    Exit(False);
  Result := ANowMs - ALastProgressMs >= QWord(ATimeoutMs);
end;

procedure SweepAgedConnections(const AServer: TAsyncConnections;
  const AMaxAgeMs, AGraceMs, AWriteTimeoutMs: Integer);
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  NowMs: QWord;
begin
  // the idle callback misses busy connections. A drained connection closes
  // on its write completion, never on the idle timer
  Instances := AServer.GetConnectionInstances;
  // the SysUtils tick follows the wall clock on Darwin, while the accept
  // time and the write progress count uptime, so the sweep takes the
  // mORMot2 tick that the connections use
  NowMs := mormot.core.os.GetTickCount64;
  for I := 0 to High(Instances) do
    if Instances[I] <> nil then
    begin
      THttp2AsyncConnection(Instances[I]).CheckAge(NowMs,
        AMaxAgeMs, AGraceMs);
      THttp2AsyncConnection(Instances[I]).CheckWriteStall(NowMs,
        AWriteTimeoutMs);
    end;
end;

procedure DrainH1Connections(const AServer: TAsyncConnections);
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  Conn: THttp2AsyncConnection;
begin
  Instances := AServer.GetConnectionInstances;
  for I := 0 to High(Instances) do
  begin
    Conn := THttp2AsyncConnection(Instances[I]);
    if (Conn <> nil) and (Conn.H1 <> nil) then
    begin
      Conn.H1.Core.BeginDrain;
      Conn.Waker.Signal;
    end;
  end;
end;

procedure GoAwayAllConnections(const AServer: TAsyncConnections;
  const AErrorCode: THttp2ErrorCode);
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  Conn: THttp2AsyncConnection;
begin
  // GetConnectionInstances copies the live instances and protects each one
  // from recycling for a short moment, so a short call on the instance is
  // safe without the main connection lock
  Instances := AServer.GetConnectionInstances;
  for I := 0 to High(Instances) do
  begin
    Conn := THttp2AsyncConnection(Instances[I]);
    if (Conn = nil) or (Conn.Core = nil) then
      continue;
    Conn.Core.GracefulGoAway(Conn.Core.LastProcessedStreamId, AErrorCode);
    Conn.Waker.Signal;
  end;
end;

function CountOpenStreams(const AServer: TAsyncConnections): Integer;
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  Conn: THttp2AsyncConnection;
begin
  Result := 0;
  Instances := AServer.GetConnectionInstances;
  for I := 0 to High(Instances) do
  begin
    Conn := THttp2AsyncConnection(Instances[I]);
    if (Conn <> nil) and (Conn.Core <> nil) then
      Inc(Result, Conn.Core.OpenStreams)
    else if (Conn <> nil) and (Conn.H1 <> nil) and Conn.H1.Core.Busy then
      // a request that runs on an HTTP/1.1 connection counts as one open stream
      Inc(Result);
  end;
end;

end.
