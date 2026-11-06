{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, options, tls policy, connection core, handshake deadline
notes:
  - This unit turns the factory into the option records that the async server
    hands to the TLS layer and to each connection core.
  - The functions read the factory and hold no state, so the async server unit
    stays under the file size limit.
  - The unit also holds the pure per-connection decisions of the idle callback
    and the age sweep for the same reason.
---
}
/// The option records of the async server, built from the factory
unit Http2Server.Async.Options;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils,
  mormot.core.base, mormot.net.sock, mormot.net.async,
  mormot.lib.openssl11,
  Http2Server.Config, Http2Server.Config.Tls, Http2Server.Connection,
  Http2Server.Tls,
  Http2Server.Errors, Http2Server.Limits, Http2Server.Observer,
  Http2Server.Async.Counters,
  Http2Server.Http1.Core, Http2Server.Http1.Driver;

/// the address text that mORMot2 binds: the host, a colon and the port
// - an empty host binds every IPv4 address
function BindAddressText(const AHost: string; const APort: Integer): RawUtf8;

/// the period of the idle callback, in whole seconds
// - the callback is the one place that checks both timeouts, so it runs at the
//   earlier of the two. A sub-second timeout rounds up to one second, because
//   the base class compares in 32-bit seconds. 0 means no check
function IdleCheckSeconds(const AIdleMs, AHeaderMs: Integer): Cardinal;

/// the TLS policy of the listener, with the client certificate settings
function BuildTlsPolicy(const AFactory: THttp2ServerFactory): TTlsPolicy;

/// the options that every connection core of the server uses
function BuildConnectionCoreOptions(
  const AFactory: THttp2ServerFactory): TConnectionCoreOptions;

/// the options of one HTTP/1.1 core, from the factory
// - ATls is true on a TLS connection, which serves the https scheme
function BuildH1CoreOptions(const AFactory: THttp2ServerFactory;
  const ATls: Boolean): TH1CoreOptions;

/// the control buckets of one HTTP/2 core, from the factory
function BuildConnectionLimits(
  const AFactory: THttp2ServerFactory): TConnectionLimits;

/// true when the age of a connection reached its limit
// - a zero limit turns the check off. The jitter is a reduction of up to 10
//   percent of the limit, drawn once per connection at accept, so the
//   effective age never passes the limit. AJitterPermille holds permille of
//   the limit, from 0 to 100
function AgeExpired(const ANowMs, AAcceptedMs: QWord; const AMaxAgeMs: Integer;
  const AJitterPermille: Integer): Boolean;

/// true when a connection that never chose a protocol is closed for idleness
// - either the header deadline passed or the idle period ended
function IdleUndecidedClose(const ANowSec, AHeaderDeadlineSec,
  ALastOpSec, AIdleSeconds: TAsyncConnectionSec): Boolean;

/// true when an HTTP/2 connection is closed for idleness
// - either the header deadline passed or the connection is idle with no open
//   stream and no queued output
function IdleHttp2Close(const ANowSec, AHeaderDeadlineSec,
  ALastOpSec, AIdleSeconds: TAsyncConnectionSec;
  const AOpenStreams: Integer; const AHasOutput: Boolean): Boolean;

type
  /// what the age sweep of the server does with one connection
  TAgeAction = (
    /// nothing: the age did not pass or the connection is exempt
    aaNone,
    /// close at once: an undecided connection past its age, or a retired
    /// connection past its grace time
    aaCloseNow,
    /// retire the HTTP/2 core with the warning GOAWAY
    aaRetireH2,
    /// queue the final GOAWAY of a drained HTTP/2 connection
    aaFinalizeH2,
    /// drain the HTTP/1.1 core with `Connection: close`
    aaDrainH1);

/// the age-sweep decision for one HTTP/1.1 connection, without sockets
// - a nil driver, an upgraded connection and a connection inside its age all
//   answer aaNone. ARetireDeadlineMs is set once the sweep drains the
//   connection; past it the answer is aaCloseNow
function Http1AgeAction(const ADriver: TH1Driver;
  const ANowMs, AAcceptedMs: QWord; const AMaxAgeMs, AJitterPermille: Integer;
  const ARetireDeadlineMs: QWord): TAgeAction;

/// the age-sweep decision for one HTTP/2 connection, without sockets
// - a nil core and a connection with an open WebSocket stream answer aaNone.
//   A retired connection answers aaFinalizeH2 once it holds no open stream
//   and no queued output, and aaCloseNow past ARetireDeadlineMs
function Http2AgeAction(const ACore: TServerConnectionCore;
  const ANowMs, AAcceptedMs: QWord; const AMaxAgeMs, AJitterPermille: Integer;
  const APendingWrite: Int64; const ARetireDeadlineMs: QWord): TAgeAction;

/// true when a closing HTTP/2 connection drained every stream and frame
// - the socket closes once the peer holds no open stream and the whole
//   output, with the GOAWAY among it, left the server
function Http2Drained(const ACore: TServerConnectionCore;
  const APendingWrite: Int64): Boolean;

/// raise one event on the observer of the server
// - an observer must not end an IO thread, so its exception is dropped. The
//   reporting helpers live here so the async server unit stays under the
//   file size limit
procedure ReportEvent(const AObserver: IHttp2ServerObserver;
  const AEvent: TServerEvent);
procedure ReportEventKind(const AObserver: IHttp2ServerObserver;
  const AKind: TServerEventKind; const AStreamId: LongWord;
  const ALimit: TLimitKind; const ADetail: string);

/// count one accepted connection and tell the observer
procedure ReportOpened(const ACounters: TServerCounters;
  const AObserver: IHttp2ServerObserver);

/// count one closed connection and tell the observer
procedure ReportClosed(const ACounters: TServerCounters;
  const AObserver: IHttp2ServerObserver);

/// count one failed handshake and tell the observer
procedure ReportTlsFailed(const ACounters: TServerCounters;
  const AObserver: IHttp2ServerObserver; const ADetail: string);

/// the single control bucket that the core charges for every non-reset kind
// - the factory offers five control buckets. The least capacity is the
//   conservative choice: the server enforces the strictest of the five
function LeastControlBucket(
  const AFactory: THttp2ServerFactory): TTokenBucketOptions;

/// set the socket deadlines of the handshake, after the mORMot2 bound
// - a deadline is a convenience: Darwin answers EINVAL for SO_RCVTIMEO on a
//   socket whose peer already sent RST, so a failure here forbids no valid
//   connection and never raises
procedure SetHandshakeDeadline(const ASocket: TNetSocket;
  const ARequestedMs: LongWord);

/// the second by which the first header block must have ended
// - zero marks a met deadline. A sub-second timeout rounds up to one second,
//   and a zero timeout leaves the accept second itself as the deadline
function HeaderDeadlineSec(const ANowMs: QWord;
  const AHeaderTimeoutMs: Integer): TAsyncConnectionSec;

implementation

function IdleCheckSeconds(const AIdleMs, AHeaderMs: Integer): Cardinal;

  function Seconds(const AValue: Integer): Cardinal;
  begin
    if AValue <= 0 then
      exit(0);
    result := Cardinal(AValue div 1000);
    if result = 0 then
      result := 1;
  end;

begin
  result := Seconds(AIdleMs);
  if (AHeaderMs > 0) and ((result = 0) or (Seconds(AHeaderMs) < result)) then
    result := Seconds(AHeaderMs);
end;

function BindAddressText(const AHost: string; const APort: Integer): RawUtf8;
var
  Host: string;
begin
  Host := AHost;
  if Host = '' then
    Host := '0.0.0.0';
  // mORMot2 splits the text at the last colon, so an IPv6 host needs no bracket
  result := RawUtf8(Host + ':' + IntToStr(APort));
end;

function BuildTlsPolicy(const AFactory: THttp2ServerFactory): TTlsPolicy;
begin
  result.CertificateFile := AFactory.Tls.CertificateFile;
  result.KeyFile := AFactory.Tls.KeyFile;
  result.KeyPassword := AFactory.Tls.KeyPassword;
  result.HandshakeTimeoutMs := LongWord(AFactory.Tls.HandshakeTimeoutMs);
  result.AllowClearText := AFactory.ClearTextAllowed;
  result.AllowHttp11 := AFactory.Http11Fallback;
  result.IgnoreCertificateErrors := True;
  result.ClientTrust := AFactory.Tls.ClientTrust;
  case AFactory.Tls.MinTlsVersion of
    tvTls12: result.MinProtocol := TLS1_2_VERSION;
    tvTls13: result.MinProtocol := TLS1_3_VERSION;
  end;
  case AFactory.Tls.MaxTlsVersion of
    tvTls12: result.MaxProtocol := TLS1_2_VERSION;
    tvTls13: result.MaxProtocol := TLS1_3_VERSION;
  end;
end;

function BuildConnectionCoreOptions(
  const AFactory: THttp2ServerFactory): TConnectionCoreOptions;
begin
  result.ConnectionWindow := LongInt(AFactory.InitialConnectionWindow);
  result.InitialStreamWindow := LongInt(AFactory.InitialStreamWindow);
  result.MaxConcurrentStreams := AFactory.MaxConcurrentStreams;
  result.MaxFrameSize := AFactory.MaxFrameSize;
  result.MaxHeaderListSize := AFactory.MaxHeaderListSize;
  result.MaxHeaderTableSize := AFactory.HeaderTableSize;
  result.MaxContinuations := AFactory.MaxContinuationFrames;
  // the header block bound is twice the header list bound, so one block that
  // meets the list limit always fits
  result.MaxHeaderBlockBytes := AFactory.MaxHeaderListSize * 2;
  // the inbound buffer is the initial stream window, so a peer cannot buffer
  // more than the server granted it
  result.InboundBufferLimit := Integer(AFactory.InitialStreamWindow);
  result.OutboundBufferLimit := Integer(AFactory.InitialStreamWindow);
  result.ConnectionUpdateThreshold := AFactory.InitialConnectionWindow div 2;
  result.StreamUpdateThreshold := AFactory.InitialStreamWindow div 2;
  result.ConnectProtocol := AFactory.WebSocketsEnabled;
  result.MaxOutputBytes := LongWord(AFactory.MaxOutputQueueBytes);
  result.MaxStreams := LongWord(AFactory.MaxStreamsPerConnection);
  result.MaxOutboundFrames :=
    LongWord(AFactory.ServerLimits.MaxOutboundFrames);
  result.MaxOutboundControlFrames :=
    LongWord(AFactory.ServerLimits.MaxOutboundControlFrames);
  result.MaxDataFrameSizeOut :=
    LongWord(AFactory.ServerLimits.MaxDataFrameSizeOut);
  result.StreamReadTimeoutMs := AFactory.ServerLimits.StreamReadTimeoutMs;
  result.StreamWriteTimeoutMs := AFactory.ServerLimits.StreamWriteTimeoutMs;
end;

function BuildH1CoreOptions(const AFactory: THttp2ServerFactory;
  const ATls: Boolean): TH1CoreOptions;
begin
  Result.Limits := AFactory.Http11;
  if ATls then
    Result.Scheme := 'https'
  else
    Result.Scheme := 'http';
  Result.OutboundLimit := AFactory.ChannelQueueLimit;
  Result.MaxRequests := AFactory.MaxStreamsPerConnection;
  // the write timeout alone bounds a stalled write
  Result.WriteStallMs := AFactory.ServerLimits.WriteTimeoutMs;
end;

function BuildConnectionLimits(
  const AFactory: THttp2ServerFactory): TConnectionLimits;
begin
  // every control kind carries its own bucket.  The kinds differ in their
  // legitimate rate: a WINDOW_UPDATE accompanies each window a peer refills,
  // so a large body needs thousands of them, while a CONTINUATION frame
  // follows only a header block that already passed the frame size.  One
  // shared bucket of the least capacity would trip on a legitimate large body
  Result := TConnectionLimits.CreateByKind(AFactory.Clock,
    AFactory.ResetBucket, LeastControlBucket(AFactory),
    [TControlBucketOption.Create(lkPing, AFactory.PingBucket),
     TControlBucketOption.Create(lkSettings, AFactory.SettingsBucket),
     TControlBucketOption.Create(lkEmptyData,
       AFactory.EmptyDataBucket),
     TControlBucketOption.Create(lkWindowUpdate,
       AFactory.WindowUpdateBucket),
     TControlBucketOption.Create(lkContinuation,
       AFactory.ContinuationBucket)]);
end;

function AgeExpired(const ANowMs, AAcceptedMs: QWord; const AMaxAgeMs: Integer;
  const AJitterPermille: Integer): Boolean;
var
  Jitter, Effective: Int64;
begin
  if AMaxAgeMs <= 0 then
    Exit(False);
  if ANowMs <= AAcceptedMs then
    Exit(False);
  Jitter := AJitterPermille;
  if Jitter < 0 then
    Jitter := 0
  else if Jitter > 100 then
    Jitter := 100;
  Effective := Int64(AMaxAgeMs) - (Int64(AMaxAgeMs) * Jitter) div 1000;
  Result := Int64(ANowMs - AAcceptedMs) >= Effective;
end;

function IdleUndecidedClose(const ANowSec, AHeaderDeadlineSec,
  ALastOpSec, AIdleSeconds: TAsyncConnectionSec): Boolean;
begin
  // no octet decided the protocol within the header timeout
  if (AHeaderDeadlineSec <> 0) and (ANowSec > AHeaderDeadlineSec) then
    Exit(True);
  // a connection that never sent an octet is idle
  Result := (AIdleSeconds <> 0) and (ANowSec - ALastOpSec >= AIdleSeconds);
end;

function IdleHttp2Close(const ANowSec, AHeaderDeadlineSec,
  ALastOpSec, AIdleSeconds: TAsyncConnectionSec;
  const AOpenStreams: Integer; const AHasOutput: Boolean): Boolean;
begin
  // the first header block did not complete within the header timeout
  if (AHeaderDeadlineSec <> 0) and (ANowSec > AHeaderDeadlineSec) then
    Exit(True);
  // an idle connection with no stream and no queued output is closed, so an
  // idle client does not hold a socket for ever
  Result := (AIdleSeconds <> 0) and (ANowSec - ALastOpSec >= AIdleSeconds) and
    (AOpenStreams = 0) and (not AHasOutput);
end;

function Http1AgeAction(const ADriver: TH1Driver;
  const ANowMs, AAcceptedMs: QWord; const AMaxAgeMs, AJitterPermille: Integer;
  const ARetireDeadlineMs: QWord): TAgeAction;
begin
  Result := aaNone;
  if ADriver = nil then
    Exit;
  // an upgraded connection keeps itself alive with the heartbeat of its
  // session, so the age never retires it
  if ADriver.Core.Upgraded then
    Exit;
  if ARetireDeadlineMs <> 0 then
  begin
    if ANowMs >= ARetireDeadlineMs then
      Result := aaCloseNow;
    Exit;
  end;
  if AgeExpired(ANowMs, AAcceptedMs, AMaxAgeMs, AJitterPermille) then
    Result := aaDrainH1;
end;

function Http2AgeAction(const ACore: TServerConnectionCore;
  const ANowMs, AAcceptedMs: QWord; const AMaxAgeMs, AJitterPermille: Integer;
  const APendingWrite: Int64; const ARetireDeadlineMs: QWord): TAgeAction;
begin
  Result := aaNone;
  if ACore = nil then
    Exit;
  // an open WebSocket stream owns the life of the connection past the age,
  // and the forced close never cuts it
  if ACore.OpenWebSocketStreams > 0 then
    Exit;
  if ACore.Retired then
  begin
    if (ARetireDeadlineMs <> 0) and (ANowMs >= ARetireDeadlineMs) then
      Result := aaCloseNow
    else if Http2Drained(ACore, APendingWrite) then
      Result := aaFinalizeH2;
    Exit;
  end;
  if AgeExpired(ANowMs, AAcceptedMs, AMaxAgeMs, AJitterPermille) then
    Result := aaRetireH2;
end;

function Http2Drained(const ACore: TServerConnectionCore;
  const APendingWrite: Int64): Boolean;
begin
  Result := ACore.IsClosing and (ACore.OpenStreams = 0) and
    (not ACore.HasOutput) and (APendingWrite = 0);
end;

procedure ReportEvent(const AObserver: IHttp2ServerObserver;
  const AEvent: TServerEvent);
begin
  if AObserver <> nil then
  try
    AObserver.OnEvent(AEvent);
  except
    // an observer must not end an IO thread; its exception is dropped
  end;
end;

procedure ReportEventKind(const AObserver: IHttp2ServerObserver;
  const AKind: TServerEventKind; const AStreamId: LongWord;
  const ALimit: TLimitKind; const ADetail: string);
var
  Event: TServerEvent;
begin
  if AObserver = nil then
    Exit;
  Event.Kind := AKind;
  Event.StreamId := AStreamId;
  Event.LimitKind := ALimit;
  Event.ErrorCode := ecNoError;
  Event.Detail := ADetail;
  try
    AObserver.OnEvent(Event);
  except
    // an observer must not end an IO thread; its exception is dropped
  end;
end;

procedure ReportOpened(const ACounters: TServerCounters;
  const AObserver: IHttp2ServerObserver);
begin
  ACounters.ConnectionOpened;
  ReportEventKind(AObserver, seConnectionAccepted, 0, lkReset,
    'the socket is accepted');
end;

procedure ReportClosed(const ACounters: TServerCounters;
  const AObserver: IHttp2ServerObserver);
begin
  ACounters.ConnectionClosed;
  ReportEventKind(AObserver, seConnectionClosed, 0, lkReset,
    'the connection ended');
end;

procedure ReportTlsFailed(const ACounters: TServerCounters;
  const AObserver: IHttp2ServerObserver; const ADetail: string);
begin
  ACounters.TlsFailed;
  ReportEventKind(AObserver, seTlsHandshakeFailed, 0, lkReset, ADetail);
end;

function LeastControlBucket(
  const AFactory: THttp2ServerFactory): TTokenBucketOptions;

  function Least(const A, B: TTokenBucketOptions): TTokenBucketOptions;
  begin
    if B.Capacity < A.Capacity then
      result := B
    else
      result := A;
  end;

begin
  result := Least(Least(AFactory.PingBucket, AFactory.SettingsBucket),
    Least(AFactory.EmptyDataBucket, AFactory.WindowUpdateBucket));
  result := Least(result, AFactory.ContinuationBucket);
end;

function HeaderDeadlineSec(const ANowMs: QWord;
  const AHeaderTimeoutMs: Integer): TAsyncConnectionSec;
begin
  Result := TAsyncConnectionSec(ANowMs div 1000);
  if AHeaderTimeoutMs > 0 then
    Result := Result + TAsyncConnectionSec(
      cardinal((AHeaderTimeoutMs + 999) div 1000));
end;

procedure SetHandshakeDeadline(const ASocket: TNetSocket;
  const ARequestedMs: LongWord);
var
  Ms: LongWord;
begin
  Ms := EffectiveHandshakeTimeoutMs(ARequestedMs);
  if Ms = 0 then
    exit;
  try
    ASocket.SetReceiveTimeout(Integer(Ms));
    ASocket.SetSendTimeout(Integer(Ms));
  except
    on ENetSock do
      ;   // no deadline is set; the connection still proceeds
  end;
end;

end.
