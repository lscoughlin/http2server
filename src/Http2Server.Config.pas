{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, factory, options, tls, queue
notes:
  - This unit holds the server factory and its option records.
  - Every setting of the server goes through the factory.  A server unit
    reads its limits from the settings it is given and holds no limit of
    its own.
  - The factory is an immutable record.  Every WithX method returns a new
    record with one field changed, so a stored factory is safe to reuse and
    to fork.
  - The defaults appear once, in Create.  The load runs set the buckets, the
    queue depth and the IO thread count; the section "Default limits" of
    doc/design/limits.md names the measurement of each one.
  - Validate collects every problem of the settings into one list, so a
    caller sees all problems in one call.
---
}
/// Server factory and configuration options for the HTTP/2 server
// - THttp2ServerFactory is the one place where a server setting is set and
//   where a server default lives
// - the factory builds a running server through Http2Server.Server, which
//   holds the IHttp2Server type that Build returns
// - the settings are read-only to the caller
unit Http2Server.Config;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Http2Server.Errors,
  Http2Server.Frames,
  Http2Server.FlowControl,
  Http2Server.Limits,
  Http2Server.Seam;

type
  /// the action of the server when the request queue is full
  TQueueRefusalMode = (
    /// reset the stream with REFUSED_STREAM
    rmRefuseStream,
    /// answer HTTP 503
    rmHttp503);

  /// the TLS settings of the listener
  ///
  /// A record is a value, so a copy of the factory holds its own TLS
  /// settings.  The certificate file and the key file are paths on disk.
  /// The key password is empty for an unencrypted key.
  TTlsServerOptions = record
  private
    FCertificateFile: string;
    FKeyFile: string;
    FKeyPassword: string;
    FAlpnProtocols: TArray<string>;
    FHandshakeTimeoutMs: Integer;
  public
    /// the defaults of the TLS settings
    class function Create: TTlsServerOptions; static;
    /// the path of the certificate file, in PEM form
    function WithCertificateFile(const AValue: string): TTlsServerOptions;
    /// the path of the private key file, in PEM form
    function WithKeyFile(const AValue: string): TTlsServerOptions;
    /// the password of an encrypted key, or an empty string
    function WithKeyPassword(const AValue: string): TTlsServerOptions;
    /// the ALPN protocol names the server offers, in preference order
    function WithAlpnProtocols(
      const AValue: TArray<string>): TTlsServerOptions;
    /// the time a TLS handshake may take, in milliseconds
    function WithHandshakeTimeoutMs(
      const AValue: Integer): TTlsServerOptions;

    property CertificateFile: string read FCertificateFile;
    property KeyFile: string read FKeyFile;
    property KeyPassword: string read FKeyPassword;
    property AlpnProtocols: TArray<string> read FAlpnProtocols;
    property HandshakeTimeoutMs: Integer read FHandshakeTimeoutMs;
  end;

  /// the request queue settings
  ///
  /// A record is a value, so a copy of the factory holds its own queue
  /// settings.  Depth 0 keeps no request waiting, so every request beyond
  /// the free handlers is refused at once.
  TQueueOptions = record
  private
    FDepth: Integer;
    FMaxWaitMs: Integer;
    FRefusalMode: TQueueRefusalMode;
  public
    /// the defaults of the queue settings
    class function Create: TQueueOptions; static;
    /// the greatest number of requests that wait for a handler
    function WithDepth(const AValue: Integer): TQueueOptions;
    /// the greatest wait of a queued request, in milliseconds
    function WithMaxWaitMs(const AValue: Integer): TQueueOptions;
    /// the action of the server when the queue is full
    function WithRefusalMode(const AValue: TQueueRefusalMode): TQueueOptions;

    property Depth: Integer read FDepth;
    property MaxWaitMs: Integer read FMaxWaitMs;
    property RefusalMode: TQueueRefusalMode read FRefusalMode;
  end;

  /// the server factory
  ///
  /// Create returns the record with the chosen defaults.  Every WithX
  /// method returns a new record with one field changed, so the original
  /// record keeps its value.  Validate collects every problem of the
  /// settings into one list and returns False when the list is not empty.
  THttp2ServerFactory = record
  private
    FHost: string;
    FPort: Integer;
    FBacklog: Integer;
    FClearTextAllowed: Boolean;
    FTls: TTlsServerOptions;
    FIOThreads: Integer;
    FHandlerThreads: Integer;
    FCancelWorkerThreads: Integer;
    FQueue: TQueueOptions;
    FMaxConcurrentStreams: LongWord;
    FInitialStreamWindow: LongWord;
    FInitialConnectionWindow: LongWord;
    FMaxFrameSize: LongWord;
    FMaxHeaderListSize: LongWord;
    FMaxContinuationFrames: LongWord;
    FHeaderTableSize: LongWord;
    FResetBucket: TTokenBucketOptions;
    FPingBucket: TTokenBucketOptions;
    FSettingsBucket: TTokenBucketOptions;
    FEmptyDataBucket: TTokenBucketOptions;
    FWindowUpdateBucket: TTokenBucketOptions;
    FContinuationBucket: TTokenBucketOptions;
    FIdleTimeoutMs: Integer;
    FHeaderTimeoutMs: Integer;
    FGracefulStopTimeoutMs: Integer;
    FHandler: IHttp2Handler;
    FClock: IMonotonicClock;
  public
    /// the record with the chosen defaults
    class function Create: THttp2ServerFactory; static;

    // ---- listener ----

    /// the address of the listener, such as '0.0.0.0' or '::1'
    function WithHost(const AValue: string): THttp2ServerFactory;
    /// the TCP port of the listener; 0 asks the operating system for a free
    /// port
    function WithPort(const AValue: Integer): THttp2ServerFactory;
    /// the length of the listen backlog
    function WithBacklog(const AValue: Integer): THttp2ServerFactory;
    /// allow cleartext HTTP/2 (h2c prior knowledge); default off
    function WithClearTextAllowed(const AValue: Boolean): THttp2ServerFactory;

    // ---- TLS ----

    /// the TLS settings of the listener
    function WithTls(
      const AOptions: TTlsServerOptions): THttp2ServerFactory;

    // ---- IO pool ----

    /// the number of IO pool threads
    function WithIOThreads(const AValue: Integer): THttp2ServerFactory;

    // ---- handler pool ----

    /// the number of handler pool threads
    function WithHandlerThreads(const AValue: Integer): THttp2ServerFactory;
    /// the number of cancel-worker threads that run the cancel hooks
    function WithCancelWorkerThreads(
      const AValue: Integer): THttp2ServerFactory;

    // ---- queue ----

    /// the request queue settings
    function WithQueue(const AOptions: TQueueOptions): THttp2ServerFactory;

    // ---- streams ----

    /// SETTINGS_MAX_CONCURRENT_STREAMS of one connection
    function WithMaxConcurrentStreams(
      const AValue: LongWord): THttp2ServerFactory;
    /// SETTINGS_INITIAL_WINDOW_SIZE of every new stream
    function WithInitialStreamWindow(
      const AValue: LongWord): THttp2ServerFactory;
    /// the initial flow-control window of the connection
    function WithInitialConnectionWindow(
      const AValue: LongWord): THttp2ServerFactory;
    /// SETTINGS_MAX_FRAME_SIZE that the server accepts
    function WithMaxFrameSize(const AValue: LongWord): THttp2ServerFactory;
    /// SETTINGS_MAX_HEADER_LIST_SIZE that the server accepts
    function WithMaxHeaderListSize(
      const AValue: LongWord): THttp2ServerFactory;
    /// the greatest number of CONTINUATION frames in one header block
    function WithMaxContinuationFrames(
      const AValue: LongWord): THttp2ServerFactory;
    /// SETTINGS_HEADER_TABLE_SIZE of the HPACK codecs
    function WithHeaderTableSize(
      const AValue: LongWord): THttp2ServerFactory;

    // ---- bucket limits ----

    /// the token bucket that limits stream resets
    function WithResetBucket(
      const AOptions: TTokenBucketOptions): THttp2ServerFactory;
    /// the token bucket that limits PING frames
    function WithPingBucket(
      const AOptions: TTokenBucketOptions): THttp2ServerFactory;
    /// the token bucket that limits SETTINGS frames
    function WithSettingsBucket(
      const AOptions: TTokenBucketOptions): THttp2ServerFactory;
    /// the token bucket that limits empty DATA frames
    function WithEmptyDataBucket(
      const AOptions: TTokenBucketOptions): THttp2ServerFactory;
    /// the token bucket that limits WINDOW_UPDATE frames
    function WithWindowUpdateBucket(
      const AOptions: TTokenBucketOptions): THttp2ServerFactory;
    /// the token bucket that limits CONTINUATION frames
    function WithContinuationBucket(
      const AOptions: TTokenBucketOptions): THttp2ServerFactory;

    // ---- timeouts ----

    /// the time an idle connection stays open, in milliseconds
    function WithIdleTimeout(const AValue: Integer): THttp2ServerFactory;
    /// the time the header block of a request may take, in milliseconds
    function WithHeaderTimeout(const AValue: Integer): THttp2ServerFactory;
    /// the time a graceful stop waits for the open streams, in milliseconds
    function WithGracefulStopTimeout(
      const AValue: Integer): THttp2ServerFactory;

    // ---- wiring ----

    /// the handler that serves every request; required
    function WithHandler(const AValue: IHttp2Handler): THttp2ServerFactory;
    /// the clock of the token buckets and of the timeouts
    function WithClock(const AValue: IMonotonicClock): THttp2ServerFactory;

    /// collect every problem of the settings
    // - the answer is False and AProblems holds one message per problem
    //   when a setting is wrong
    // - the answer is True and AProblems is empty when every setting is
    //   correct
    function Validate(out AProblems: TArray<string>): Boolean;

    // ---- listener ----

    property Host: string read FHost;
    property Port: Integer read FPort;
    property Backlog: Integer read FBacklog;
    property ClearTextAllowed: Boolean read FClearTextAllowed;

    // ---- TLS ----

    property Tls: TTlsServerOptions read FTls;

    // ---- IO pool ----

    property IOThreads: Integer read FIOThreads;

    // ---- handler pool ----

    property HandlerThreads: Integer read FHandlerThreads;
    property CancelWorkerThreads: Integer read FCancelWorkerThreads;

    // ---- queue ----

    property Queue: TQueueOptions read FQueue;

    // ---- streams ----

    property MaxConcurrentStreams: LongWord read FMaxConcurrentStreams;
    property InitialStreamWindow: LongWord read FInitialStreamWindow;
    property InitialConnectionWindow: LongWord read FInitialConnectionWindow;
    property MaxFrameSize: LongWord read FMaxFrameSize;
    property MaxHeaderListSize: LongWord read FMaxHeaderListSize;
    property MaxContinuationFrames: LongWord read FMaxContinuationFrames;
    property HeaderTableSize: LongWord read FHeaderTableSize;

    // ---- bucket limits ----

    property ResetBucket: TTokenBucketOptions read FResetBucket;
    property PingBucket: TTokenBucketOptions read FPingBucket;
    property SettingsBucket: TTokenBucketOptions read FSettingsBucket;
    property EmptyDataBucket: TTokenBucketOptions read FEmptyDataBucket;
    property WindowUpdateBucket: TTokenBucketOptions read FWindowUpdateBucket;
    property ContinuationBucket: TTokenBucketOptions read FContinuationBucket;

    // ---- timeouts ----

    property IdleTimeoutMs: Integer read FIdleTimeoutMs;
    property HeaderTimeoutMs: Integer read FHeaderTimeoutMs;
    property GracefulStopTimeoutMs: Integer read FGracefulStopTimeoutMs;

    // ---- wiring ----

    property Handler: IHttp2Handler read FHandler;
    property Clock: IMonotonicClock read FClock;
  end;

implementation

{ TTlsServerOptions }

class function TTlsServerOptions.Create: TTlsServerOptions;
begin
  Result.FCertificateFile := '';
  Result.FKeyFile := '';
  Result.FKeyPassword := '';
  // a dynamic-array field needs an explicit empty value before SetLength
  Result.FAlpnProtocols := nil;
  SetLength(Result.FAlpnProtocols, 1);
  Result.FAlpnProtocols[0] := 'h2';
  Result.FHandshakeTimeoutMs := 10000;
end;

function TTlsServerOptions.WithCertificateFile(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FCertificateFile := AValue;
end;

function TTlsServerOptions.WithKeyFile(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FKeyFile := AValue;
end;

function TTlsServerOptions.WithKeyPassword(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FKeyPassword := AValue;
end;

function TTlsServerOptions.WithAlpnProtocols(
  const AValue: TArray<string>): TTlsServerOptions;
begin
  Result := Self;
  Result.FAlpnProtocols := AValue;
end;

function TTlsServerOptions.WithHandshakeTimeoutMs(
  const AValue: Integer): TTlsServerOptions;
begin
  Result := Self;
  Result.FHandshakeTimeoutMs := AValue;
end;

{ TQueueOptions }

class function TQueueOptions.Create: TQueueOptions;
begin
  // the queue depth comes from the seam run: a client that carried 50
  // streams at once saw every stream answered, and the queue holds 64 more
  // requests behind the 4 handler threads of that run, so the bound of the
  // streams in flight is 68 (doc/verification/validation.md)
  Result.FDepth := 64;
  Result.FMaxWaitMs := 5000;
  Result.FRefusalMode := rmRefuseStream;
end;

function TQueueOptions.WithDepth(const AValue: Integer): TQueueOptions;
begin
  Result := Self;
  Result.FDepth := AValue;
end;

function TQueueOptions.WithMaxWaitMs(const AValue: Integer): TQueueOptions;
begin
  Result := Self;
  Result.FMaxWaitMs := AValue;
end;

function TQueueOptions.WithRefusalMode(
  const AValue: TQueueRefusalMode): TQueueOptions;
begin
  Result := Self;
  Result.FRefusalMode := AValue;
end;

{ THttp2ServerFactory }

class function THttp2ServerFactory.Create: THttp2ServerFactory;
begin
  // the defaults of the server.  The buckets come from the load runs, and
  // the section "The default limits" of doc/design/limits.md names the
  // measurement of each one.  The listener, stream and timeout values are
  // the chosen protocol and operational bounds: RFC 9113 section 6.5.2 sets
  // 100 concurrent streams as the customary value, 16384 is the frame size
  // that RFC 9113 section 4.2 recommends, and the timeouts bound a stalled
  // peer without a measurement of their own.
  Result.FHost := '0.0.0.0';
  Result.FPort := 8443;
  Result.FBacklog := 128;
  Result.FClearTextAllowed := False;
  Result.FTls := TTlsServerOptions.Create;
  Result.FIOThreads := 4;
  Result.FHandlerThreads := 8;
  Result.FCancelWorkerThreads := 2;
  Result.FQueue := TQueueOptions.Create;
  Result.FMaxConcurrentStreams := 100;
  Result.FInitialStreamWindow := 65535;
  Result.FInitialConnectionWindow := 65535;
  Result.FMaxFrameSize := DefaultMaxFrameSize;
  Result.FMaxHeaderListSize := 65536;
  Result.FMaxContinuationFrames := 16;
  Result.FHeaderTableSize := 4096;
  Result.FResetBucket := TTokenBucketOptions.Create
    .WithCapacity(1000)
    .WithRefillPerSecond(100)
    .WithCostBeforeDispatch(1)
    .WithCostAfterDispatch(5);
  Result.FPingBucket := TTokenBucketOptions.Create
    .WithCapacity(100)
    .WithRefillPerSecond(10);
  Result.FSettingsBucket := TTokenBucketOptions.Create
    .WithCapacity(100)
    .WithRefillPerSecond(10);
  Result.FEmptyDataBucket := TTokenBucketOptions.Create
    .WithCapacity(100)
    .WithRefillPerSecond(10);
  // a peer sends one WINDOW_UPDATE for each window that it refills, so a
  // large body needs thousands of them: a measurement of a 100 MB body sent
  // 6102 frames, and the steady rate was 2450 frames in one second
  // (doc/verification/validation.md).  The capacity admits a whole burst of
  // a few megabytes with no refill, and the refill rate sits above the
  // measured rate with headroom
  Result.FWindowUpdateBucket := TTokenBucketOptions.Create
    .WithCapacity(10000)
    .WithRefillPerSecond(4000);
  Result.FContinuationBucket := TTokenBucketOptions.Create
    .WithCapacity(100)
    .WithRefillPerSecond(10);
  Result.FIdleTimeoutMs := 60000;
  Result.FHeaderTimeoutMs := 30000;
  Result.FGracefulStopTimeoutMs := 10000;
  Result.FHandler := nil;
  Result.FClock := TMonotonicClock.Create;
end;

function THttp2ServerFactory.WithHost(
  const AValue: string): THttp2ServerFactory;
begin
  Result := Self;
  Result.FHost := AValue;
end;

function THttp2ServerFactory.WithPort(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FPort := AValue;
end;

function THttp2ServerFactory.WithBacklog(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FBacklog := AValue;
end;

function THttp2ServerFactory.WithClearTextAllowed(
  const AValue: Boolean): THttp2ServerFactory;
begin
  Result := Self;
  Result.FClearTextAllowed := AValue;
end;

function THttp2ServerFactory.WithTls(
  const AOptions: TTlsServerOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FTls := AOptions;
end;

function THttp2ServerFactory.WithIOThreads(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FIOThreads := AValue;
end;

function THttp2ServerFactory.WithHandlerThreads(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FHandlerThreads := AValue;
end;

function THttp2ServerFactory.WithCancelWorkerThreads(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FCancelWorkerThreads := AValue;
end;

function THttp2ServerFactory.WithQueue(
  const AOptions: TQueueOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FQueue := AOptions;
end;

function THttp2ServerFactory.WithMaxConcurrentStreams(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FMaxConcurrentStreams := AValue;
end;

function THttp2ServerFactory.WithInitialStreamWindow(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FInitialStreamWindow := AValue;
end;

function THttp2ServerFactory.WithInitialConnectionWindow(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FInitialConnectionWindow := AValue;
end;

function THttp2ServerFactory.WithMaxFrameSize(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FMaxFrameSize := AValue;
end;

function THttp2ServerFactory.WithMaxHeaderListSize(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FMaxHeaderListSize := AValue;
end;

function THttp2ServerFactory.WithMaxContinuationFrames(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FMaxContinuationFrames := AValue;
end;

function THttp2ServerFactory.WithHeaderTableSize(
  const AValue: LongWord): THttp2ServerFactory;
begin
  Result := Self;
  Result.FHeaderTableSize := AValue;
end;

function THttp2ServerFactory.WithResetBucket(
  const AOptions: TTokenBucketOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FResetBucket := AOptions;
end;

function THttp2ServerFactory.WithPingBucket(
  const AOptions: TTokenBucketOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FPingBucket := AOptions;
end;

function THttp2ServerFactory.WithSettingsBucket(
  const AOptions: TTokenBucketOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FSettingsBucket := AOptions;
end;

function THttp2ServerFactory.WithEmptyDataBucket(
  const AOptions: TTokenBucketOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FEmptyDataBucket := AOptions;
end;

function THttp2ServerFactory.WithWindowUpdateBucket(
  const AOptions: TTokenBucketOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FWindowUpdateBucket := AOptions;
end;

function THttp2ServerFactory.WithContinuationBucket(
  const AOptions: TTokenBucketOptions): THttp2ServerFactory;
begin
  Result := Self;
  Result.FContinuationBucket := AOptions;
end;

function THttp2ServerFactory.WithIdleTimeout(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FIdleTimeoutMs := AValue;
end;

function THttp2ServerFactory.WithHeaderTimeout(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FHeaderTimeoutMs := AValue;
end;

function THttp2ServerFactory.WithGracefulStopTimeout(
  const AValue: Integer): THttp2ServerFactory;
begin
  Result := Self;
  Result.FGracefulStopTimeoutMs := AValue;
end;

function THttp2ServerFactory.WithHandler(
  const AValue: IHttp2Handler): THttp2ServerFactory;
begin
  Result := Self;
  Result.FHandler := AValue;
end;

function THttp2ServerFactory.WithClock(
  const AValue: IMonotonicClock): THttp2ServerFactory;
begin
  Result := Self;
  Result.FClock := AValue;
end;

function THttp2ServerFactory.Validate(out AProblems: TArray<string>): Boolean;
var
  Problems: TArray<string>;

  procedure Add(const AProblem: string);
  var
    Count: Integer;
  begin
    Count := Length(Problems) + 1;
    SetLength(Problems, Count);
    Problems[Count - 1] := AProblem;
  end;

begin
  Problems := nil;

  if (FPort < 0) or (FPort > High(Word)) then
    Add('the port ' + IntToStr(FPort) + ' is outside 0 to ' +
      IntToStr(High(Word)));
  if FBacklog < 1 then
    Add('the listen backlog is below 1');
  if FIOThreads < 1 then
    Add('the IO thread count is below 1');
  if FHandlerThreads < 1 then
    Add('the handler thread count is below 1');
  if FCancelWorkerThreads < 1 then
    Add('the cancel worker thread count is below 1');
  if FQueue.Depth < 0 then
    Add('the queue depth is below 0');
  if FQueue.MaxWaitMs < 0 then
    Add('the maximum queue wait is below 0');
  if not FClearTextAllowed then
  begin
    if FTls.CertificateFile = '' then
      Add('the TLS certificate file is empty while cleartext is off');
    if FTls.KeyFile = '' then
      Add('the TLS key file is empty while cleartext is off');
  end;
  if (FMaxFrameSize < MinAllowedFrameSize) or
     (FMaxFrameSize > MaxAllowedFrameSize) then
    Add('the maximum frame size is outside ' + IntToStr(MinAllowedFrameSize) +
      ' to ' + IntToStr(MaxAllowedFrameSize));
  if FInitialStreamWindow > LongWord(MaxWindowSize) then
    Add('the initial stream window is above ' + IntToStr(MaxWindowSize));
  if FInitialConnectionWindow > LongWord(MaxWindowSize) then
    Add('the initial connection window is above ' + IntToStr(MaxWindowSize));
  if FHandler = nil then
    Add('the handler is not assigned');

  AProblems := Problems;
  Result := Length(AProblems) = 0;
end;

end.
