{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
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
  SysUtils,
  Http2Server.Errors,
  Http2Server.AccessLog,
  Http2Server.Frames,
  Http2Server.Hpack,
  Http2Server.Duplex,
  Http2Server.Limits,
  Http2Server.Http1.Limits,
  Http2Server.Observer,
  Http2Server.Seam,
  Http2Server.Mtls.Types,
  Http2Server.ClientCert,
  Http2Server.Config,
  Http2Server.Encoding,
  Http2Server.Server,
  Http2Server.Sse.Encoder,
  Http2Server.Sse,
  Http2Server.Ws.Origin,
  Http2Server.Ws.Options,
  Http2Server.Ws.Types,
  Http2Server.Ws.Frames,
  Http2Server.Ws.Accept;

type
  /// the server lifecycle
  IHttp2Server = Http2Server.Server.IHttp2Server;
  /// the server that runs on the async IO pool
  THttp2Server = Http2Server.Server.THttp2Server;

  /// the server factory and its option records
  THttp2ServerFactory = Http2Server.Config.THttp2ServerFactory;
  TTlsServerOptions = Http2Server.Config.TTlsServerOptions;
  TQueueOptions = Http2Server.Config.TQueueOptions;
  TQueueRefusalMode = Http2Server.Config.TQueueRefusalMode;
  TTokenBucketOptions = Http2Server.Limits.TTokenBucketOptions;

  /// mutual TLS: the modes, the principal setting and the client identity
  TClientCertMode = Http2Server.Mtls.Types.TClientCertMode;
  TClientCertPrincipal = Http2Server.Mtls.Types.TClientCertPrincipal;
  IClientCertificate = Http2Server.ClientCert.IClientCertificate;

  /// the handler contract
  IHttp2Handler = Http2Server.Seam.IHttp2Handler;
  IServerRequest = Http2Server.Seam.IServerRequest;
  IServerResponse = Http2Server.Seam.IServerResponse;
  IBodyWriter = Http2Server.Seam.IBodyWriter;
  IStreamWaiter = Http2Server.Seam.IStreamWaiter;
  TCancelHook = Http2Server.Seam.TCancelHook;
  TWaitResult = Http2Server.Seam.TWaitResult;

  /// the access log: the record, the writer contract and the default writer
  TAccessLogRecord = Http2Server.AccessLog.TAccessLogRecord;
  IAccessLogWriter = Http2Server.AccessLog.IAccessLogWriter;
  TStdOutAccessLogWriter = Http2Server.AccessLog.TStdOutAccessLogWriter;

  /// the detached stream: bytes in both directions without a handler thread
  IDuplexChannel = Http2Server.Duplex.IDuplexChannel;
  IChannelSink = Http2Server.Duplex.IChannelSink;
  TSendResult = Http2Server.Duplex.TSendResult;
  TChannelClose = Http2Server.Duplex.TChannelClose;
  TChannelState = Http2Server.Duplex.TChannelState;
  EDetachRefused = Http2Server.Duplex.EDetachRefused;

  /// WebSocket: the settings, the origin policy, the session and the handler
  TWsOptions = Http2Server.Ws.Options.TWsOptions;
  TWsOriginPolicy = Http2Server.Ws.Origin.TWsOriginPolicy;
  IWsSession = Http2Server.Ws.Types.IWsSession;
  IWsHandler = Http2Server.Ws.Types.IWsHandler;
  TWsInitResult = Http2Server.Ws.Types.TWsInitResult;

  /// server-sent events
  ISseStream = Http2Server.Sse.ISseStream;
  TSseEvent = Http2Server.Sse.Encoder.TSseEvent;
  ESseError = Http2Server.Sse.Encoder.ESseError;

  /// the observation contract and the counters
  IHttp2ServerObserver = Http2Server.Observer.IHttp2ServerObserver;
  TNullServerObserver = Http2Server.Observer.TNullServerObserver;
  TServerEvent = Http2Server.Observer.TServerEvent;
  TServerEventKind = Http2Server.Observer.TServerEventKind;
  TServerStats = Http2Server.Observer.TServerStats;

  /// the settings of the HTTP/1.1 parser, the clock and the limit kinds
  THttp11Limits = Http2Server.Http1.Limits.THttp11Limits;
  IMonotonicClock = Http2Server.Limits.IMonotonicClock;
  TLimitKind = Http2Server.Limits.TLimitKind;

  /// the error classes and the error codes
  EHttpError = Http2Server.Errors.EHttpError;
  EHttpTimeout = Http2Server.Errors.EHttpTimeout;
  EHttpConnectionError = Http2Server.Errors.EHttpConnectionError;
  EStreamCancelled = Http2Server.Errors.EStreamCancelled;
  EStreamReset = Http2Server.Errors.EStreamReset;
  EServerConfigError = Http2Server.Errors.EServerConfigError;
  EServerStopped = Http2Server.Errors.EServerStopped;
  THttp2ErrorCode = Http2Server.Errors.THttp2ErrorCode;

  /// the header list of a request and a response
  THeaderBlock = Http2Server.Hpack.THeaderBlock;
  THttpHeaderField = Http2Server.Hpack.THttpHeaderField;
  THpackCodec = Http2Server.Hpack.THpackCodec;

  /// the content codings a handler can put on a response body
  ///
  /// A handler reads `accept-encoding` from the request, negotiates a coding,
  /// and either writes the coded bytes itself or hands a
  /// TCompressingBodyWriter to IServerResponse.SetBodyWriter.
  TContentEncoding = Http2Server.Encoding.TContentEncoding;
  TCompressingBodyWriter = Http2Server.Encoding.TCompressingBodyWriter;

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
  // the values of TQueueRefusalMode, for the same reason as the event kinds below
  rmRefuseStream = Http2Server.Config.rmRefuseStream;
  rmHttp503 = Http2Server.Config.rmHttp503;

  // the values of TLimitKind
  lkReset = Http2Server.Limits.lkReset;
  lkPing = Http2Server.Limits.lkPing;
  lkSettings = Http2Server.Limits.lkSettings;
  lkEmptyData = Http2Server.Limits.lkEmptyData;
  lkWindowUpdate = Http2Server.Limits.lkWindowUpdate;
  lkContinuation = Http2Server.Limits.lkContinuation;

  // the values of THttp2ErrorCode (RFC 9113 section 7)
  ecNoError = Http2Server.Errors.ecNoError;
  ecProtocolError = Http2Server.Errors.ecProtocolError;
  ecInternalError = Http2Server.Errors.ecInternalError;
  ecFlowControlError = Http2Server.Errors.ecFlowControlError;
  ecSettingsTimeout = Http2Server.Errors.ecSettingsTimeout;
  ecStreamClosed = Http2Server.Errors.ecStreamClosed;
  ecFrameSizeError = Http2Server.Errors.ecFrameSizeError;
  ecRefusedStream = Http2Server.Errors.ecRefusedStream;
  ecCancel = Http2Server.Errors.ecCancel;
  ecCompressionError = Http2Server.Errors.ecCompressionError;
  ecConnectError = Http2Server.Errors.ecConnectError;
  ecEnhanceYourCalm = Http2Server.Errors.ecEnhanceYourCalm;
  ecInadequateSecurity = Http2Server.Errors.ecInadequateSecurity;
  ecHttp11Required = Http2Server.Errors.ecHttp11Required;

  // the values of TClientCertMode and TClientCertPrincipal
  ccmNone = Http2Server.Mtls.Types.ccmNone;
  ccmOptional = Http2Server.Mtls.Types.ccmOptional;
  ccmRequired = Http2Server.Mtls.Types.ccmRequired;
  ccpNone = Http2Server.Mtls.Types.ccpNone;
  ccpSubjectDn = Http2Server.Mtls.Types.ccpSubjectDn;
  ccpCommonName = Http2Server.Mtls.Types.ccpCommonName;

  // an enum type alias does not carry the enum values, so every value of
  // TServerEventKind appears here as a constant
  seConnectionAccepted = Http2Server.Observer.seConnectionAccepted;
  seTlsHandshakeFailed = Http2Server.Observer.seTlsHandshakeFailed;
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
  seStreamDetached = Http2Server.Observer.seStreamDetached;
  seStreamDetachRefused = Http2Server.Observer.seStreamDetachRefused;

  /// the origin policies
  opSameOrAbsent = Http2Server.Ws.Origin.opSameOrAbsent;
  opAllowList = Http2Server.Ws.Origin.opAllowList;
  opAllowListOnly = Http2Server.Ws.Origin.opAllowListOnly;
  opAny = Http2Server.Ws.Origin.opAny;
  opNone = Http2Server.Ws.Origin.opNone;

  /// the observer events of WebSocket
  seWsOpened = Http2Server.Observer.seWsOpened;
  seWsRejected = Http2Server.Observer.seWsRejected;
  seWsClosed = Http2Server.Observer.seWsClosed;
  seWsFailed = Http2Server.Observer.seWsFailed;
  seWsBucketTripped = Http2Server.Observer.seWsBucketTripped;

  /// the close codes of RFC 6455 section 7.4.1 that a server sends
  WsCloseNormal = Http2Server.Ws.Frames.WsCloseNormal;
  WsCloseGoingAway = Http2Server.Ws.Frames.WsCloseGoingAway;
  WsCloseProtocolError = Http2Server.Ws.Frames.WsCloseProtocolError;
  WsCloseUnsupported = Http2Server.Ws.Frames.WsCloseUnsupported;
  WsCloseBadData = Http2Server.Ws.Frames.WsCloseBadData;
  WsClosePolicy = Http2Server.Ws.Frames.WsClosePolicy;
  WsCloseTooBig = Http2Server.Ws.Frames.WsCloseTooBig;
  WsCloseInternal = Http2Server.Ws.Frames.WsCloseInternal;

  /// the constants of the channel types
  srQueued = Http2Server.Duplex.srQueued;
  srFull = Http2Server.Duplex.srFull;
  srClosed = Http2Server.Duplex.srClosed;
  ccGraceful = Http2Server.Duplex.ccGraceful;
  ccAbort = Http2Server.Duplex.ccAbort;
  csPending = Http2Server.Duplex.csPending;
  csActive = Http2Server.Duplex.csActive;
  csClosed = Http2Server.Duplex.csClosed;

/// accept the WebSocket upgrade of this request and serve it with AHandler
/// - true: the session started and the handler returns; IWsHandler.Init decides
/// - false: an error response was sent; the handler returns
function AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AHandler: IWsHandler): Boolean;

/// answer a request with an event stream and detach it
/// - see Http2Server.Sse.StartSse
function StartSse(const ARequest: IServerRequest;
  const AResponse: IServerResponse;
  const AExtraHeaders: THeaderBlock = nil): ISseStream;

/// the coding to answer a request with, given its `accept-encoding` value
/// - an absent or empty value yields ceIdentity, so a peer that offered no
///   coding is never sent one
function NegotiateEncoding(const AAcceptEncoding: string): TContentEncoding;

/// the token to put in `content-encoding` for ACoding ('' for identity)
function EncodingToken(const ACoding: TContentEncoding): string;

/// true when the coding codes the body rather than passing it through
function IsEncoded(const ACoding: TContentEncoding): Boolean;

/// compact AData for ACoding, or return AData when the coding is identity
function CompressFor(const ACoding: TContentEncoding;
  const AData: TBytes): TBytes;

/// the Apache Common Log Format line of a record
// - see Http2Server.AccessLog.FormatCommonLog
function FormatCommonLog(const ARecord: TAccessLogRecord): string;

/// the user name of a Basic `authorization` header, or '' when none
// - see Http2Server.AccessLog.BasicAuthUser
function BasicAuthUser(const AHeaders: THeaderBlock): string;

/// the first value of AName in AHeaders, or '' when the name is absent
///
/// Header names are compared without case, as RFC 9113 section 8.2 requires.
/// A handler uses this to read `accept-encoding` from a request.
function HeaderValueOf(const AHeaders: THeaderBlock;
  const AName: string): string;

/// compress AData into a gzip container
function GzipCompress(const AData: TBytes): TBytes;
/// compress AData into a zlib container
function DeflateCompress(const AData: TBytes): TBytes;
/// decompress a gzip container
function GzipDecompress(const AData: TBytes): TBytes;
/// decompress a deflate body, zlib-wrapped or bare
function DeflateDecompress(const AData: TBytes): TBytes;

implementation

function AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AHandler: IWsHandler): Boolean;
begin
  Result := Http2Server.Ws.Accept.AcceptWebSocket(ARequest, AResponse, AHandler);
end;

function StartSse(const ARequest: IServerRequest;
  const AResponse: IServerResponse;
  const AExtraHeaders: THeaderBlock): ISseStream;
begin
  Result := Http2Server.Sse.StartSse(ARequest, AResponse, AExtraHeaders);
end;

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

function NegotiateEncoding(const AAcceptEncoding: string): TContentEncoding;
begin
  Result := Http2Server.Encoding.NegotiateEncoding(AAcceptEncoding);
end;

function EncodingToken(const ACoding: TContentEncoding): string;
begin
  Result := Http2Server.Encoding.EncodingToken(ACoding);
end;

function IsEncoded(const ACoding: TContentEncoding): Boolean;
begin
  Result := Http2Server.Encoding.IsEncoded(ACoding);
end;

function CompressFor(const ACoding: TContentEncoding;
  const AData: TBytes): TBytes;
begin
  Result := Http2Server.Encoding.CompressFor(ACoding, AData);
end;

function FormatCommonLog(const ARecord: TAccessLogRecord): string;
begin
  Result := Http2Server.AccessLog.FormatCommonLog(ARecord);
end;

function BasicAuthUser(const AHeaders: THeaderBlock): string;
begin
  Result := Http2Server.AccessLog.BasicAuthUser(AHeaders);
end;

function HeaderValueOf(const AHeaders: THeaderBlock;
  const AName: string): string;
begin
  Result := Http2Server.Encoding.HeaderValueOf(AHeaders, AName);
end;

function GzipCompress(const AData: TBytes): TBytes;
begin
  Result := Http2Server.Encoding.GzipCompress(AData);
end;

function DeflateCompress(const AData: TBytes): TBytes;
begin
  Result := Http2Server.Encoding.DeflateCompress(AData);
end;

function GzipDecompress(const AData: TBytes): TBytes;
begin
  Result := Http2Server.Encoding.GzipDecompress(AData);
end;

function DeflateDecompress(const AData: TBytes): TBytes;
begin
  Result := Http2Server.Encoding.DeflateDecompress(AData);
end;

end.
