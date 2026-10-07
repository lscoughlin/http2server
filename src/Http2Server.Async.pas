{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, io pool, tls, wake-up
notes:
  - This unit runs the connection core on the mORMot2 async IO classes.
  - THttp2AsyncConnection owns one TServerConnectionCore.  Its OnRead feeds
    the decrypted bytes that mORMot2 already placed in the read buffer, and
    after the call it moves the core output to the mORMot2 write buffer.
  - THttp2AsyncServer builds the connection class, applies the factory values
    for the IO thread count, the backlog and the timeouts, and starts and
    stops the pools.
  - The wake-up follows the mORMot2 pattern: one edge-triggered flag and one
    retry after a failed acquisition, so a wake-up is never lost.
  - The IO callbacks mark their thread, so a handler that runs on an IO
    thread fails at once.
---
}
/// The mORMot2 async subclasses of the HTTP/2 server
// - THttp2AsyncConnection is the per-connection object of the async server.
//   mORMot2 already moves the socket bytes into fRd and out of fWr, so this
//   unit only bridges the core to those two buffers.
// - THttp2AsyncServer is the listener.  It takes every value from the
//   factory record and holds no limit literal of its own.
// - a handler thread never enters the IO callbacks.  Http2IoThreadEnter marks
//   the IO thread, and Http2AssertHandlerThread raises when a handler runs on
//   a marked thread.
unit Http2Server.Async;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.threads,
  mormot.net.sock,
  mormot.net.async,
  Http2Server.Errors,
  Http2Server.Config,
  Http2Server.Connection,
  Http2Server.Limits,
  Http2Server.Output,
  Http2Server.Seam,
  Http2Server.Stream,
  Http2Server.Tls,
  Http2Server.Admission;

type
  THttp2AsyncServer = class;
  THttp2AsyncConnection = class;

  /// the write waker of one connection
  ///
  /// A handler thread calls Signal after it queues output.  The waker drains
  /// the core and hands the bytes to the mORMot2 write path, which sends at
  /// once when the socket is ready and subscribes for the write event when it
  /// is not.  The connection carries the edge-triggered flag, so Signal takes
  /// effect once per transition from "no output" to "output".
  THttp2ConnectionWaker = class(TInterfacedObject, IWriteWaker)
  private
    FConnection: THttp2AsyncConnection;   // weak reference
  public
    constructor Create(const AConnection: THttp2AsyncConnection);
    procedure Signal;
  end;

  /// the events of one connection, wired to the shared handler pool
  THttp2ConnectionEvents = class(TInterfacedObject, IConnectionEvents)
  private
    FPool: THandlerPool;
  public
    constructor Create(const APool: THandlerPool);
    procedure RequestReady(const AStream: TServerStream);
    procedure StreamReset(const AStream: TServerStream);
    procedure ConnectionClosing;
    procedure LimitTripped(const AKind: TLimitKind);
  end;

  /// one connection of the HTTP/2 async server
  ///
  /// The object owns one TServerConnectionCore.  The core holds its own lock,
  /// and every stream takes that lock too, so a handler buffer operation never
  /// races the IO thread.
  THttp2AsyncConnection = class(TAsyncConnection)
  private
    FServer: THttp2AsyncServer;   // weak reference; the owner frees this
    FCore: TServerConnectionCore;
    FEvents: IConnectionEvents;
    FWaker: IWriteWaker;
    /// the monotonic second at which the first header block must have ended
    // - zero once the first request reached the core
    FHeaderDeadlineSec: TAsyncConnectionSec;
    /// guards the write path against its own nested AfterWrite callback
    // - fOwner.Write may call AfterWrite before it returns, so this flag keeps
    //   one send loop per connection
    FInSend: Boolean;
    /// a wake-up that arrived while the send loop ran
    // - the outer loop repeats when this flag is set, so a wake-up that
    //   loses the race to the loop exit is never lost
    FSendRequested: Boolean;
    /// guards the two send flags
    FSendLock: TCriticalSection;
  protected
    procedure AfterCreate; override;
    procedure BeforeDestroy; override;
    /// run the TLS handshake with the factory deadline on the accepted socket
    function OnFirstRead(aOwner: TPollAsyncSockets): boolean; override;
    function OnRead: TPollAsyncSocketOnReadWrite; override;
    function AfterWrite: TPollAsyncSocketOnReadWrite; override;
    function OnLastOperationIdle(nowsec: TAsyncConnectionSec): boolean; override;
    procedure OnClose; override;
  public
    /// encode the pending headers, drain the stream buffers and queue the
    /// frames for the socket
    function SendPendingOutput: Boolean;
    /// the connection core (test and observer seam)
    property Core: TServerConnectionCore read FCore;
    /// the write waker of this connection
    property Waker: IWriteWaker read FWaker;
  end;

  /// the HTTP/2 async server
  ///
  /// The record form of the factory is copied at Create time.  The server owns
  /// the handler pool, because the pool and its queue are shared by every
  /// connection.
  THttp2AsyncServer = class(TAsyncServer)
  private
    FFactory: THttp2ServerFactory;
    FHandlers: THandlerPool;
    FPolicy: TTlsPolicy;
    FCoreOptions: TConnectionCoreOptions;
    FControlBucket: TTokenBucketOptions;
    FStarted: Boolean;
    function BuildPolicy: TTlsPolicy;
    function BuildCoreOptions: TConnectionCoreOptions;
    function LeastControlBucket: TTokenBucketOptions;
  public
    /// create the listener from the factory
    // - the factory must pass Validate before this call
    constructor Create(const AFactory: THttp2ServerFactory); reintroduce;
    destructor Destroy; override;

    /// bind, then install the server TLS context and the ALPN callback
    procedure Start;
    /// stop the handler pool and shut the IO pools down
    procedure Stop;

    /// the handler pool that serves every connection
    property Handlers: THandlerPool read FHandlers;
    /// the TLS policy the server applies to the listening socket
    property Policy: TTlsPolicy read FPolicy;
    /// the core options every connection uses
    property CoreOptions: TConnectionCoreOptions read FCoreOptions;
    /// the single control-frame bucket the core charges
    property ControlBucket: TTokenBucketOptions read FControlBucket;
    /// the TCP port the listening socket holds, after Start
    function BoundPort: Integer;
    /// the factory the server was built from
    property Factory: THttp2ServerFactory read FFactory;
  end;

implementation

const
  /// the seconds WaitStarted waits for the bind to complete
  cBindWaitSeconds = 5;
  /// the write timeout a handler-thread wake-up tolerates, in milliseconds
  cWriteTimeoutMs = 1000;

{ THttp2ConnectionWaker }

constructor THttp2ConnectionWaker.Create(const AConnection: THttp2AsyncConnection);
begin
  inherited Create;
  FConnection := AConnection;
end;

procedure THttp2ConnectionWaker.Signal;
begin
  if FConnection = nil then
    exit;
  // the first check is the edge-triggered flag inside the core, which keeps
  // one wake-up per transition.  SendPendingOutput performs the drain and the
  // mORMot2 write, and it retries once when the write lock went to the IO
  // thread, which is the second check of the wake-up pattern
  FConnection.SendPendingOutput;
end;

{ THttp2ConnectionEvents }

constructor THttp2ConnectionEvents.Create(const APool: THandlerPool);
begin
  inherited Create;
  FPool := APool;
end;

procedure THttp2ConnectionEvents.RequestReady(const AStream: TServerStream);
begin
  if FPool <> nil then
    FPool.Admit(AStream);
end;

procedure THttp2ConnectionEvents.StreamReset(const AStream: TServerStream);
begin
  // the stream is cancelled inside the core; the pool removes a queued entry
  if FPool <> nil then
    FPool.RemoveStream(AStream.StreamId);
end;

procedure THttp2ConnectionEvents.ConnectionClosing;
begin
  // the IO thread closes the socket after the output drains
end;

procedure THttp2ConnectionEvents.LimitTripped(const AKind: TLimitKind);
begin
  // the observer of the server receives this event once it exists
end;

{ THttp2AsyncConnection }

procedure THttp2AsyncConnection.AfterCreate;
var
  Options: TConnectionCoreOptions;
  Limits: TConnectionLimits;
begin
  FServer := THttp2AsyncServer(fOwner);
  FHeaderDeadlineSec := TAsyncConnectionSec(
    (GetTickCount64 div 1000) + cardinal(FServer.Factory.HeaderTimeoutMs div 1000));
  Options := FServer.CoreOptions;
  // TConnectionLimits holds one reset bucket and one control bucket, while the
  // factory offers a bucket per control kind.  The reset bucket is the bucket
  // that the rapid-reset defence rests on, and the control bucket is the most
  // conservative of the five
  Limits := TConnectionLimits.Create(FServer.Factory.Clock,
    FServer.Factory.ResetBucket, FServer.ControlBucket);
  FEvents := THttp2ConnectionEvents.Create(FServer.Handlers);
  FCore := TServerConnectionCore.Create(Options, FEvents, Limits,
    FServer.Factory.Clock);
  FWaker := THttp2ConnectionWaker.Create(Self);
  FCore.SetWriteWaker(FWaker);
  FSendLock := TCriticalSection.Create;
end;

procedure THttp2AsyncConnection.BeforeDestroy;
begin
  FSendLock.Free;
  FCore.Free;
  FCore := nil;
  FWaker := nil;
  FEvents := nil;
end;

function THttp2AsyncConnection.OnFirstRead(aOwner: TPollAsyncSockets): boolean;
var
  Ms: LongWord;
begin
  // the accepted socket is blocking while TLS is on, so the socket deadline
  // and the mORMot2 SSL_accept deadline together bound the handshake.  A
  // client that stalls therefore holds its IO thread for a bounded time only
  Ms := EffectiveHandshakeTimeoutMs(FServer.Policy.HandshakeTimeoutMs);
  if Ms > 0 then
  begin
    fSocket.SetReceiveTimeout(Integer(Ms));
    fSocket.SetSendTimeout(Integer(Ms));
  end;
  result := inherited OnFirstRead(aOwner);
  if not result then
    exit;
  // a TLS connection that did not negotiate h2 is refused, so no HTTP/1.1
  // request ever reaches the HTTP/2 state machine
  if (fSecure <> nil) and not NegotiatedH2(fSecure) then
    result := false;
end;

function THttp2AsyncConnection.OnRead: TPollAsyncSocketOnReadWrite;
var
  Data: TBytes;
begin
  Http2IoThreadEnter;
  try
    result := soContinue;
    if FCore = nil then
      exit(soClose);
    if fRd.Len > 0 then
    begin
      SetLength(Data, fRd.Len);
      Move(fRd.Buffer^, Data[0], fRd.Len);
      fRd.Reset;
      FCore.Feed(Data);
      if FCore.LastProcessedStreamId <> 0 then
        // the first header block arrived, so the header deadline is met
        FHeaderDeadlineSec := 0;
    end;
    if FCore.GoAwaySent and (FCore.OpenStreams = 0) then
      exit(soClose);
    SendPendingOutput;
  finally
    Http2IoThreadLeave;
  end;
end;

function THttp2AsyncConnection.AfterWrite: TPollAsyncSocketOnReadWrite;
begin
  Http2IoThreadEnter;
  try
    // the write buffer drained.  The send loop of SendPendingOutput carries
    // the next pull, because fOwner.Write calls this method before it
    // returns, so a pull here would recurse into the same write path
    result := soContinue;
  finally
    Http2IoThreadLeave;
  end;
end;

function THttp2AsyncConnection.SendPendingOutput: Boolean;
var
  Data: TBytes;
  Again: Boolean;
begin
  result := False;
  if (FCore = nil) or IsClosed then
    exit;
  // a wake-up that arrives while the loop runs is recorded and not dropped,
  // because the outer loop repeats once the flag is set.  The lock closes the
  // race between the loop exit and the last wake-up
  FSendLock.Acquire;
  try
    FSendRequested := True;
    if FInSend then
      exit;   // the running loop owns the send path and will repeat
    FInSend := True;
  finally
    FSendLock.Release;
  end;
  try
    repeat
      FSendLock.Acquire;
      try
        FSendRequested := False;
      finally
        FSendLock.Release;
      end;
      // the drain turns the handler buffers into DATA frames.  It runs under
      // the core lock, which every stream also takes, so the HPACK encoder
      // keeps one owner per connection
      FCore.DrainPending;
      while FCore.TakeOutput(Data) do
      begin
        // the mORMot2 write path takes the connection write lock, sends at
        // once when it can, and otherwise subscribes for the write event.  A
        // false answer means the lock went to the IO thread, so one retry runs
        // the second check of the mORMot2 wake-up pattern
        if not fOwner.Write(Self, pointer(Data), Length(Data),
             cWriteTimeoutMs) then
          fOwner.Write(Self, pointer(Data), Length(Data), cWriteTimeoutMs);
        result := True;
      end;
      FSendLock.Acquire;
      try
        Again := FSendRequested;
      finally
        FSendLock.Release;
      end;
      // the loop repeats for a late wake-up or for output a handler just made
    until (not Again) and (not FCore.HasOutput);
  finally
    FSendLock.Acquire;
    try
      FInSend := False;
    finally
      FSendLock.Release;
    end;
  end;
end;

function THttp2AsyncConnection.OnLastOperationIdle(
  nowsec: TAsyncConnectionSec): boolean;
begin
  result := false;
  if (FCore <> nil) and (FHeaderDeadlineSec <> 0) and
     (nowsec > FHeaderDeadlineSec) then
  begin
    // the first header block did not complete within the header timeout
    fOwner.ConnectionRemove(Handle);
    Exit(True);
  end;
  if FCore = nil then
    exit;
  // an idle connection with no stream and no queued output is closed, so an
  // idle client does not hold a socket for ever
  if (FCore.OpenStreams = 0) and not FCore.HasOutput then
  begin
    fOwner.ConnectionRemove(Handle);
    Result := True;
  end;
end;

procedure THttp2AsyncConnection.OnClose;
begin
  inherited OnClose;
end;

{ THttp2AsyncServer }

constructor THttp2AsyncServer.Create(const AFactory: THttp2ServerFactory);
var
  Options: TAsyncConnectionsOptions;
begin
  FFactory := AFactory;
  FPolicy := BuildPolicy;
  FCoreOptions := BuildCoreOptions;
  FControlBucket := LeastControlBucket;
  FHandlers := THandlerPool.Create(AFactory);
  Options := ASYNC_OPTION_PROD;
  if AFactory.Tls.CertificateFile <> '' then
    include(Options, acoEnableTls);
  inherited Create(IntToStr(AFactory.Port), nil, nil, THttp2AsyncConnection,
    'http2', nil, Options, AFactory.IOThreads);
  // the backlog of the factory reaches bind() through this mORMot2 global
  // (mormot.net.sock.pas:3470, 8623, read 2026-10-07)
  DefaultListenBacklog := AFactory.Backlog;
  MaxConnections := MaxInt;
end;

destructor THttp2AsyncServer.Destroy;
begin
  Stop;
  FHandlers.Free;
  FHandlers := nil;
  inherited Destroy;
end;

function THttp2AsyncServer.BuildPolicy: TTlsPolicy;
begin
  result.CertificateFile := FFactory.Tls.CertificateFile;
  result.KeyFile := FFactory.Tls.KeyFile;
  result.KeyPassword := FFactory.Tls.KeyPassword;
  result.HandshakeTimeoutMs := LongWord(FFactory.Tls.HandshakeTimeoutMs);
  result.AllowClearText := FFactory.ClearTextAllowed;
  result.AllowHttp11 := False;
  result.IgnoreCertificateErrors := True;
end;

function THttp2AsyncServer.BuildCoreOptions: TConnectionCoreOptions;
begin
  result.ConnectionWindow := LongInt(FFactory.InitialConnectionWindow);
  result.InitialStreamWindow := LongInt(FFactory.InitialStreamWindow);
  result.MaxConcurrentStreams := FFactory.MaxConcurrentStreams;
  result.MaxFrameSize := FFactory.MaxFrameSize;
  result.MaxHeaderListSize := FFactory.MaxHeaderListSize;
  result.MaxHeaderTableSize := FFactory.HeaderTableSize;
  result.MaxContinuations := FFactory.MaxContinuationFrames;
  // the header block bound is twice the header list bound, so one block that
  // meets the list limit always fits
  result.MaxHeaderBlockBytes := FFactory.MaxHeaderListSize * 2;
  // the inbound buffer is the initial stream window, so a peer cannot buffer
  // more than the server granted it
  result.InboundBufferLimit := Integer(FFactory.InitialStreamWindow);
  result.OutboundBufferLimit := Integer(FFactory.InitialStreamWindow);
  result.ConnectionUpdateThreshold := FFactory.InitialConnectionWindow div 2;
  result.StreamUpdateThreshold := FFactory.InitialStreamWindow div 2;
end;

function THttp2AsyncServer.LeastControlBucket: TTokenBucketOptions;

  function Least(const A, B: TTokenBucketOptions): TTokenBucketOptions;
  begin
    if B.Capacity < A.Capacity then
      result := B
    else
      result := A;
  end;

begin
  // the core holds one control bucket for every non-reset limit kind, while
  // the factory offers five.  The least capacity is the conservative choice:
  // the server enforces the strictest of the five configured control limits
  result := Least(Least(FFactory.PingBucket, FFactory.SettingsBucket),
    Least(FFactory.EmptyDataBucket, FFactory.WindowUpdateBucket));
  result := Least(result, FFactory.ContinuationBucket);
end;

procedure THttp2AsyncServer.Start;
begin
  if FStarted then
    exit;
  // Execute binds the port on its own thread; WaitStarted returns once the
  // socket is bound, and it raises when the bind failed
  WaitStarted(cBindWaitSeconds);
  if FPolicy.CertificateFile <> '' then
    if not ApplyTls(Server, FPolicy) then
      raise EHttpConnectionError.Create(
        'the server TLS context could not be created');
  FStarted := True;
end;

procedure THttp2AsyncServer.Stop;
begin
  if FHandlers <> nil then
    FHandlers.Stop;
  Shutdown;
end;

function THttp2AsyncServer.BoundPort: Integer;
var
  Addr: TNetAddr;
begin
  // a factory port of 0 asks the operating system for a free port, so the
  // bound port must be read back from the socket itself
  result := StrToIntDef(Server.Port, 0);
  if (result = 0) and (Server <> nil) and (Server.Sock <> nil) then
    if Server.Sock.GetName(Addr) = nrOk then
      result := Addr.Port;
end;

end.
