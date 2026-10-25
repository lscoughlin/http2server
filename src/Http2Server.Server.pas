{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, lifecycle, public api, stats
notes:
  - This unit holds the public server interface and its implementation.
  - Build returns a server that a caller starts, stops and observes.  The
    server binds its port on Start and returns at once.
  - Stop is graceful and idempotent.  It ends acceptance, waits for the open
    streams up to the graceful timeout, then ends the pools.
  - The statistics come from the live counters of the handler pool and the
    async server.  No number is guessed.
---
}
/// The HTTP/2 server lifecycle
// - THttp2ServerFactory.Build returns an IHttp2Server.  The caller starts it,
//   stops it and reads its statistics.
// - The observer receives connection, stream, queue, bucket and GOAWAY
//   events on the thread that raised them.
unit Http2Server.Server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils,
  Http2Server.Errors,
  Http2Server.Observer,
  Http2Server.Duplex,
  Http2Server.Config,
  Http2Server.Async,
  Http2Server.Ws.Environment;

type
  /// one running server
  ///
  /// Start binds the port and returns.  Stop is graceful and idempotent.
  /// Port answers the bound port, which a factory port of 0 leaves to the
  /// operating system.
  IHttp2Server = interface
    ['{7E1F0C11-0008-4A11-9C72-000000000508}']
    /// bind the port, start the IO pool and the handler pool, and return
    procedure Start;
    /// end acceptance, drain the open streams up to the graceful timeout,
    /// then stop the pools; a second call does nothing
    procedure Stop;
    /// the port the server holds; a value after Start for a factory port of 0
    function Port: Integer;
    /// the live counters of the server
    function Stats: TServerStats;
    /// true while the server accepts new connections
    function IsRunning: Boolean;
  end;

  /// the server that runs on the mORMot2 async IO pool
  THttp2Server = class(TInterfacedObject, IHttp2Server)
  private
    FAsync: THttp2AsyncServer;
    /// the WebSocket environment: options, counters, watchdog
    FWsEnv: TWsEnvironment;
    FWsEnvRef: IInterface;
    FObserver: IHttp2ServerObserver;
    FGracefulStopMs: Integer;
    FStarted: Boolean;
    FStopped: Boolean;
    /// 1 once a Stop call took the stop
    FStopFlag: LongInt;
    /// wait for the open streams, up to the graceful stop timeout
    procedure WaitForStreams;
  public
    /// build the server from a factory that already passed Validate
    constructor Create(const AFactory: THttp2ServerFactory;
      const AObserver: IHttp2ServerObserver);
    destructor Destroy; override;

    procedure Start;
    procedure Stop;
    function Port: Integer;
    function Stats: TServerStats;
    function IsRunning: Boolean;

    /// the async listener under this server (test and wire-up seam)
    property Async: THttp2AsyncServer read FAsync;
  end;

implementation

const
  /// the wait for a handler that was cancelled, after the graceful drain
  cCancelWaitMs = 1000;

{ THttp2Server }

constructor THttp2Server.Create(const AFactory: THttp2ServerFactory;
  const AObserver: IHttp2ServerObserver);
begin
  inherited Create;
  FObserver := AObserver;
  FGracefulStopMs := AFactory.GracefulStopTimeoutMs;
  FAsync := THttp2AsyncServer.Create(AFactory);
  FAsync.Observer := FObserver;
  FAsync.Handlers.Observer := FObserver;
  FWsEnv := TWsEnvironment.Create(AFactory.WebSockets, AFactory.Clock, FAsync.Notify);
  FWsEnvRef := FWsEnv;
  FAsync.Channels.SetWsEnvironment(FWsEnvRef);
end;

destructor THttp2Server.Destroy;
begin
  Stop;
  // the watchdog of the WebSocket environment ends before the server it calls
  FWsEnv.Stop;
  FAsync.Free;
  FAsync := nil;
  FWsEnvRef := nil;
  inherited Destroy;
end;

procedure THttp2Server.Start;
begin
  if FStopped then
    raise EServerStopped.Create('the server is stopped; it is built again, ' +
      'not started again');
  if FStarted then
    Exit;
  try
    FAsync.Start;
  except
    // a failed start leaves nothing bound: the stop path frees the port and
    // the threads, and the server is spent like a stopped one
    FStopped := True;
    FAsync.Stop(0);
    raise;
  end;
  FStarted := True;
end;

procedure THttp2Server.WaitForStreams;
var
  Deadline: QWord;
begin
  // the graceful wait ends early once every stream is done, so a quiet
  // server stops at once and a busy one gets the full timeout
  if FGracefulStopMs <= 0 then
    Exit;
  Deadline := GetTickCount64 + QWord(FGracefulStopMs);
  // a detached stream counts as open until its channel is released, on HTTP/1.1
  // too, and a WebSocket session ends its closing handshake in this time
  while ((FAsync.OpenStreamTotal > 0) or (FAsync.Channels.Count > 0)) and
        (GetTickCount64 < Deadline) do
    Sleep(20);
end;

procedure THttp2Server.Stop;
begin
  // two Stop calls at once run the stop once
  if InterlockedExchange(FStopFlag, 1) <> 0 then
    Exit;
  FStopped := True;
  if FAsync = nil then
    Exit;
  // new connections close at once and each HTTP/1.1 connection closes after
  // its request; the GOAWAY tells every HTTP/2 peer that no new stream is
  // served, the bounded wait drains the open work, and the pool stop cancels
  // the rest
  FAsync.BeginDrain;
  FAsync.BroadcastGoAway(ecNoError);
  // a detached stream never ends by itself, so its owner is told to close it;
  // the queued bytes and END_STREAM still leave within the bounded wait
  FAsync.CloseChannels(ccGraceful);
  WaitForStreams;
  // the drain used the graceful time; the cancel wait is short
  FAsync.Stop(cCancelWaitMs);
end;

function THttp2Server.Port: Integer;
begin
  if FAsync = nil then
    Exit(0);
  Result := FAsync.BoundPort;
end;

function THttp2Server.Stats: TServerStats;
begin
  Result.BusyHandlers := 0;
  Result.QueueLength := 0;
  Result.OpenConnections := 0;
  Result.OpenStreams := 0;
  Result.RefusedTotal := 0;
  Result.TimedOutTotal := 0;
  Result.ResetTotal := 0;
  Result.TrippedTotal := 0;
  Result.DetachedStreams := 0;
  Result.TlsHandshakeFailedTotal := 0;
  FWsEnv.FillStats(Result);
  if FAsync = nil then
    Exit;
  if FAsync.Handlers <> nil then
  begin
    Result.BusyHandlers := FAsync.Handlers.BusyHandlers;
    Result.QueueLength := FAsync.Handlers.QueueLength;
    Result.RefusedTotal := FAsync.Handlers.RefusedTotal;
    Result.TimedOutTotal := FAsync.Handlers.TimedOutTotal;
  end;
  Result.OpenConnections := FAsync.Counters.Connections;
  Result.OpenStreams := FAsync.OpenStreamTotal;
  Result.ResetTotal := FAsync.Counters.Resets;
  Result.TrippedTotal := FAsync.Counters.Trips;
  Result.TlsHandshakeFailedTotal := FAsync.Counters.TlsFailedTotal;
  if FAsync.Channels <> nil then
    Result.DetachedStreams := FAsync.Channels.Count;
end;

function THttp2Server.IsRunning: Boolean;
begin
  Result := FStarted and not FStopped;
end;

end.
