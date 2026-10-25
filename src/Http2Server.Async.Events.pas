{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, connection events, handler pool, observer, http1, http2
notes:
  - This unit holds the event receivers of a connection. A receiver passes a
    request to the shared handler pool and reports to the observer of the server.
  - The receivers hold method pointers to the server and not the server class, so
    this unit does not depend on the async server unit.
---
}
/// The event receivers of an async connection
unit Http2Server.Async.Events;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils,
  mormot.core.base, mormot.net.sock,
  Http2Server.Limits, Http2Server.Observer, Http2Server.Stream,
  Http2Server.Connection, Http2Server.Admission, Http2Server.HandlerJob,
  Http2Server.Http1.Core, Http2Server.AccessLog, Http2Server.ClientCert;

type
  /// a report to the observer of the server
  TServerNotifyProc = procedure(const AKind: TServerEventKind;
    const AStreamId: LongWord; const ALimit: TLimitKind;
    const ADetail: string) of object;

  /// a counter bump of the server
  TServerCountProc = procedure of object;

/// the peer address text of the access log
// - mORMot2 answers an empty text for the loopback address of IPv4, so the
//   packed address AIp4 restores '127.0.0.1'
function PeerAddressText(const ARemoteIp: RawUtf8; const AIp4: Cardinal): string;

type

  /// the events of one HTTP/2 connection, wired to the shared handler pool
  THttp2ConnectionEvents = class(TInterfacedObject, IConnectionEvents)
  private
    FPool: THandlerPool;
    FNotify: TServerNotifyProc;
    FOnReset: TServerCountProc;
    FOnTrip: TServerCountProc;
    FRemote: string;
    FCert: IClientCertificate;
  public
    constructor Create(const APool: THandlerPool; const ANotify: TServerNotifyProc;
      const AOnReset, AOnTrip: TServerCountProc; const ARemote: string;
      const ACert: IClientCertificate);
    procedure RequestReady(const AStream: TServerStream);
    procedure StreamReset(const AStream: TServerStream);
    procedure ConnectionClosing;
    procedure LimitTripped(const AKind: TLimitKind);
  end;

  /// the events of an HTTP/1.1 connection: a request enters the shared queue
  THttp1ConnectionEvents = class(TInterfacedObject, IH1Events)
  private
    FPool: THandlerPool;
    FRemote: string;
    FCert: IClientCertificate;
  public
    constructor Create(const APool: THandlerPool; const ARemote: string;
      const ACert: IClientCertificate);
    procedure Admit(const AJob: IHandlerJob);
  end;

implementation

function PeerAddressText(const ARemoteIp: RawUtf8; const AIp4: Cardinal): string;
begin
  if ARemoteIp <> '' then
    Result := string(ARemoteIp)
  else if AIp4 = cLocalhost32 then
    Result := cLocalhost
  else
    Result := '';
end;

{ THttp2ConnectionEvents }

constructor THttp2ConnectionEvents.Create(const APool: THandlerPool;
  const ANotify: TServerNotifyProc; const AOnReset, AOnTrip: TServerCountProc;
  const ARemote: string; const ACert: IClientCertificate);
begin
  inherited Create;
  FRemote := ARemote;
  FCert := ACert;
  FPool := APool;
  FNotify := ANotify;
  FOnReset := AOnReset;
  FOnTrip := AOnTrip;
end;

procedure THttp2ConnectionEvents.RequestReady(const AStream: TServerStream);
begin
  if AStream <> nil then
  begin
    AStream.RemoteAddress := FRemote;
    AStream.ClientCertificate := FCert;
    FNotify(seStreamOpened, AStream.StreamId, lkReset, 'the request is complete');
  end;
  if FPool <> nil then
    FPool.Admit(AStream);
end;

procedure THttp2ConnectionEvents.StreamReset(const AStream: TServerStream);
begin
  // the stream is cancelled inside the core; the pool removes a queued entry
  if AStream <> nil then
  begin
    FNotify(seStreamReset, AStream.StreamId, lkReset, 'the stream reset');
    if Assigned(FOnReset) then
      FOnReset;
  end;
  if FPool <> nil then
    FPool.RemoveStream(AStream.StreamId);
end;

procedure THttp2ConnectionEvents.ConnectionClosing;
begin
  // the IO thread closes the socket after the output drains
end;

procedure THttp2ConnectionEvents.LimitTripped(const AKind: TLimitKind);
begin
  if Assigned(FOnTrip) then
    FOnTrip;
  FNotify(seBucketTripped, 0, AKind, 'a token bucket tripped');
end;

{ THttp1ConnectionEvents }

constructor THttp1ConnectionEvents.Create(const APool: THandlerPool;
  const ARemote: string;
  const ACert: IClientCertificate);
begin
  inherited Create;
  FCert := ACert;
  FPool := APool;
  FRemote := ARemote;
end;

procedure THttp1ConnectionEvents.Admit(const AJob: IHandlerJob);
var
  Sink: IAccessLogRemoteSink;
  CertSink: IClientCertificateSink;
begin
  if (FCert <> nil) and Supports(AJob, IClientCertificateSink, CertSink) then
    CertSink.SetClientCertificate(FCert);
  if Supports(AJob, IAccessLogRemoteSink, Sink) then
    Sink.SetLoggedRemoteAddress(FRemote);
  // the pool answers a refusal through AJob.Refuse
  FPool.AdmitJob(AJob);
end;

end.
