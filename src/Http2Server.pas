{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, facade
notes:
  - This unit is the public facade of the HTTP/2 server library.
  - A caller adds only this unit to the uses clause.  Every public type of
    the library is visible through the aliases of this unit.
  - The facade holds no logic.  It re-exports the units that hold the
    server, the settings, the handler contract and the observation events.
---
}
/// Public facade of the HTTP/2 server library
// - this unit is the entry point of the library; a caller adds only this
//   unit to the uses clause
// - THttp2ServerFactory.Build answers a running-capable IHttp2Server
unit Http2Server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  Http2Server.Errors,
  Http2Server.Frames,
  Http2Server.Hpack,
  Http2Server.Limits,
  Http2Server.Observer,
  Http2Server.Seam,
  Http2Server.Config,
  Http2Server.Server;

type
  /// the server lifecycle
  IHttp2Server = Http2Server.Server.IHttp2Server;
  /// the server that runs on the async IO pool
  THttp2Server = Http2Server.Server.THttp2Server;
  /// the entry point helper that turns a factory into a server
  // - a type helper is not a type itself; a caller reaches Build through a
  //   THttp2ServerFactory value

  /// the server factory and its option records
  THttp2ServerFactory = Http2Server.Config.THttp2ServerFactory;
  TTlsServerOptions = Http2Server.Config.TTlsServerOptions;
  TQueueOptions = Http2Server.Config.TQueueOptions;
  TQueueRefusalMode = Http2Server.Config.TQueueRefusalMode;
  TTokenBucketOptions = Http2Server.Limits.TTokenBucketOptions;

  /// the handler contract
  IHttp2Handler = Http2Server.Seam.IHttp2Handler;
  IServerRequest = Http2Server.Seam.IServerRequest;
  IServerResponse = Http2Server.Seam.IServerResponse;
  IBodyWriter = Http2Server.Seam.IBodyWriter;
  IStreamWaiter = Http2Server.Seam.IStreamWaiter;
  TCancelHook = Http2Server.Seam.TCancelHook;
  TWaitResult = Http2Server.Seam.TWaitResult;

  /// the observation contract and the counters
  IHttp2ServerObserver = Http2Server.Observer.IHttp2ServerObserver;
  TNullServerObserver = Http2Server.Observer.TNullServerObserver;
  TServerEvent = Http2Server.Observer.TServerEvent;
  TServerEventKind = Http2Server.Observer.TServerEventKind;
  TServerStats = Http2Server.Observer.TServerStats;

  /// the error classes and the error codes
  EHttpError = Http2Server.Errors.EHttpError;
  EServerConfigError = Http2Server.Errors.EServerConfigError;
  EServerStopped = Http2Server.Errors.EServerStopped;
  THttp2ErrorCode = Http2Server.Errors.THttp2ErrorCode;

  /// the header list of a request and a response
  THeaderBlock = Http2Server.Hpack.THeaderBlock;
  THttpHeaderField = Http2Server.Hpack.THttpHeaderField;
  THpackCodec = Http2Server.Hpack.THpackCodec;

  /// the entry point that turns a factory into a server
  ///
  /// Build validates the settings, then returns a server that the caller
  /// starts.  A problem in the settings raises EServerConfigError, and the
  /// message holds every problem, one per line.
  THttp2ServerFactoryHelper = type helper for THttp2ServerFactory
    function Build: IHttp2Server; overload;
    function Build(const AObserver: IHttp2ServerObserver): IHttp2Server; overload;
    /// the problems of the settings, one per line; '' when none
    function ProblemText: string;
  end;

const
  // an enum type alias does not carry the enum values, so every value of
  // TServerEventKind appears here as a constant
  seConnectionAccepted = Http2Server.Observer.seConnectionAccepted;
  seConnectionClosed = Http2Server.Observer.seConnectionClosed;
  seStreamOpened = Http2Server.Observer.seStreamOpened;
  seStreamRefused = Http2Server.Observer.seStreamRefused;
  seStreamReset = Http2Server.Observer.seStreamReset;
  seStreamCompleted = Http2Server.Observer.seStreamCompleted;
  seQueueFull = Http2Server.Observer.seQueueFull;
  seRequestTimedOut = Http2Server.Observer.seRequestTimedOut;
  seBucketTripped = Http2Server.Observer.seBucketTripped;
  seGoAwaySent = Http2Server.Observer.seGoAwaySent;
  seHandlerException = Http2Server.Observer.seHandlerException;

implementation

{ THttp2ServerFactoryHelper }

function THttp2ServerFactoryHelper.ProblemText: string;
var
  Problems: TArray<string>;
  I: Integer;
begin
  Result := '';
  if Self.Validate(Problems) then
    Exit;
  for I := 0 to High(Problems) do
  begin
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + Problems[I];
  end;
end;

function THttp2ServerFactoryHelper.Build: IHttp2Server;
begin
  Result := Build(nil);
end;

function THttp2ServerFactoryHelper.Build(
  const AObserver: IHttp2ServerObserver): IHttp2Server;
var
  Text: string;
  Settings: THttp2ServerFactory;
begin
  Text := ProblemText;
  if Text <> '' then
    raise EServerConfigError.Create('the server settings are not valid:' +
      LineEnding + Text);
  Settings := Self;
  Result := THttp2Server.Create(Settings, AObserver);
end;

end.
