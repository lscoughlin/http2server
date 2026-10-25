{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
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
  - The wake-up follows the mORMot2 pattern. It uses one edge-triggered flag
    and one retry after a failed acquisition, so a wake-up is never lost.
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
  SysUtils, Classes, SyncObjs, {$IFDEF UNIX}Sockets,{$ENDIF}
  mormot.core.base,
  mormot.core.os,
  mormot.core.threads,
  mormot.net.sock,
  mormot.net.async,
  Http2Server.Errors,
  Http2Server.Config,
  Http2Server.Connection,
  Http2Server.Limits,
  Http2Server.Observer,
  Http2Server.Output,
  Http2Server.Seam,
  Http2Server.Duplex,
  Http2Server.StreamPool,
  Http2Server.Stream,
  Http2Server.Tls,
  Http2Server.Admission,
  Http2Server.HandlerJob,
  Http2Server.Http1.Limits,
  Http2Server.Http1.Select,
  Http2Server.Http1.Core,
  Http2Server.Http1.Driver,
  Http2Server.ClientCert,
  Http2Server.Mtls.Types,
  Http2Server.Async.Events,
  Http2Server.Async.Options,
  Http2Server.Async.Counters,
  Http2Server.Async.Waker;

const
  /// the time a staged close waits for the peer to close first, in seconds
  cDrainSeconds = 2;
  /// the how argument of shutdown that closes the write side
  cShutWrite = 1;

type
  THttp2AsyncServer = class;
  THttp2AsyncConnection = class;

  /// the protocol that a connection speaks, once it is known
  TConnectionMode = (cmUndecided, cmHttp2, cmHttp1);

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
    FMethodWaker: TMethodWaker;
    /// the protocol of the connection; undecided until the first octets
    FMode: TConnectionMode;
    /// the verified client certificate of this connection; nil when none
    FClientCert: IClientCertificate;
    /// the HTTP/1.1 core; nil on an HTTP/2 connection
    FH1: TH1Driver;
    FH1Events: IH1Events;
    /// the second at which a staged close ends; 0 while the connection serves
    /// the monotonic second at which the first header block must have ended
    // - zero once the first request reached the core
    FHeaderDeadlineSec: TAsyncConnectionSec;
    /// the idle period of this connection, in seconds
    // - taken from the factory; zero disables the idle close
    FIdleSeconds: cardinal;
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
    procedure StartHttp2;
    procedure StartHttp1;
    /// the method the waker calls: drain the core and write
    procedure WakeOutput;
    function OnReadHttp1: TPollAsyncSocketOnReadWrite;
    function PendingWriteBytes: Int64;
    function PullOutput(out AData: TBytes): Boolean;
    function OutputPending: Boolean;
    procedure ApplyClosePhase;
    /// drop the state of the connection that ended: both cores, the waker and the lock
    procedure ReleaseState;
  protected
    procedure AfterCreate; override;
    procedure BeforeDestroy; override;
    /// mORMot2 reuses the instance of a closed connection and calls this method, not
    /// BeforeDestroy, so the state of the old connection must go here
    procedure Recycle(const aRemoteIP: TNetAddr); override;
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
    property H1: TH1Driver read FH1;
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
    /// the registry of detached streams: the limit, the list, the queue sizes
    FChannels: IChannelRegistry;
    /// the same object as FChannels, kept to set its provider and settings
    FChannelImpl: TChannelRegistry;
    /// the streaming pool: the application work of detached streams
    FStreamPool: TStreamPool;
    FPolicy: TTlsPolicy;
    FCoreOptions: TConnectionCoreOptions;
    FControlBucket: TTokenBucketOptions;
    FStarted: Boolean;
    /// Stop began: new connections close at once
    FDraining: Boolean;
    /// the observer of the server; nil when the caller set none
    FObserver: IHttp2ServerObserver;
    /// the connection, reset, trip and handshake counters
    FCounters: TServerCounters;
  protected
    /// the idle period before OnLastOperationIdle runs, in seconds
    // - the base class returns zero, which disables the event, so the server
    //   enables it with the factory idle timeout
    function GetLastOperationIdleSeconds: cardinal; override;
  public
    /// create the listener from the factory
    // - the factory must pass Validate before this call
    constructor Create(const AFactory: THttp2ServerFactory); reintroduce;
    destructor Destroy; override;

    /// bind, then install the server TLS context and the ALPN callback
    procedure Start;
    /// stop the handler pool and shut the IO pools down
    // - AWaitMs bounds each wait of the handler pool; -1 uses the graceful timeout
    procedure Stop(const AWaitMs: Integer = -1);

    /// the handler pool that serves every connection
    property Handlers: THandlerPool read FHandlers;
    /// the registry of the detached streams of the server
    property Channels: IChannelRegistry read FChannels;
    /// the streaming pool
    property StreamPool: TStreamPool read FStreamPool;
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
    /// the observer of the server
    // - the observer runs on the thread that raised the event, so it must be
    //   set before Start and never changed while the server runs
    property Observer: IHttp2ServerObserver read FObserver write FObserver;
    /// the counters of the server; they live as long as the server object
    property Counters: TServerCounters read FCounters;
    /// count one accepted connection and tell the observer, on the IO thread
    procedure ConnectionOpened;
    /// count one closed connection and tell the observer, on the IO thread
    procedure ConnectionClosed;
    /// send one event to the observer, on the thread that raised it
    procedure Notify(const AEvent: TServerEvent); overload;
    procedure Notify(const AKind: TServerEventKind; const AStreamId: LongWord;
      const ALimit: TLimitKind; const ADetail: string); overload;
    /// queue a GOAWAY frame on every open connection, then wake its output
    // - the last stream identifier that the core processed goes into the
    //   frame, so a peer keeps the streams below it
    procedure BroadcastGoAway(const AErrorCode: THttp2ErrorCode);
    /// refuse new connections and tell every HTTP/1.1 connection to close after
    /// the request it serves
    procedure BeginDrain;
    property Draining: Boolean read FDraining;
    /// close every detached stream: the graceful form sends the queued bytes
    /// and END_STREAM, the abort form resets the stream
    procedure CloseChannels(const AMode: TChannelClose);
    /// the streams that are open on every connection now
    function OpenStreamTotal: Integer;
    /// count one failed handshake and tell the observer, on the IO thread
    procedure TlsHandshakeFailed(const ADetail: string);
  end;

implementation

const
  /// the seconds WaitStarted waits for the bind to complete
  cBindWaitSeconds = 5;
  /// the write timeout a handler-thread wake-up tolerates, in milliseconds
  cWriteTimeoutMs = 1000;

{ THttp2AsyncConnection }

procedure THttp2AsyncConnection.WakeOutput;
begin
  SendPendingOutput;
end;

procedure THttp2AsyncConnection.AfterCreate;
begin
  FServer := THttp2AsyncServer(fOwner);
  FHeaderDeadlineSec := TAsyncConnectionSec(GetTickCount64 div 1000);
  if FServer.Factory.HeaderTimeoutMs > 0 then
    FHeaderDeadlineSec := FHeaderDeadlineSec + TAsyncConnectionSec(
      cardinal((FServer.Factory.HeaderTimeoutMs + 999) div 1000));
  FIdleSeconds := cardinal(FServer.Factory.IdleTimeoutMs div 1000);
  FSendLock := TCriticalSection.Create;
  FMode := cmUndecided;
  FServer.ConnectionOpened;
end;

procedure THttp2AsyncConnection.StartHttp2;
var
  Options: TConnectionCoreOptions;
  Limits: TConnectionLimits;
begin
  Options := FServer.CoreOptions;
  // every control kind carries its own bucket.  The kinds differ in their
  // legitimate rate: a WINDOW_UPDATE accompanies each window a peer refills,
  // so a large body needs thousands of them, while a CONTINUATION frame
  // follows only a header block that already passed the frame size.  One
  // shared bucket of the least capacity would trip on a legitimate large body
  Limits := TConnectionLimits.CreateByKind(FServer.Factory.Clock,
    FServer.Factory.ResetBucket, FServer.ControlBucket,
    [TControlBucketOption.Create(lkPing, FServer.Factory.PingBucket),
     TControlBucketOption.Create(lkSettings, FServer.Factory.SettingsBucket),
     TControlBucketOption.Create(lkEmptyData,
       FServer.Factory.EmptyDataBucket),
     TControlBucketOption.Create(lkWindowUpdate,
       FServer.Factory.WindowUpdateBucket),
     TControlBucketOption.Create(lkContinuation,
       FServer.Factory.ContinuationBucket)]);
  FEvents := THttp2ConnectionEvents.Create(FServer.Handlers, FServer.Notify,
    FServer.Counters.StreamResetted, FServer.Counters.BucketTripped,
    PeerAddressText(RemoteIP, fRemoteIP4), FClientCert);
  FCore := TServerConnectionCore.Create(Options, FEvents, Limits,
    FServer.Factory.Clock);
  FMethodWaker := TMethodWaker.Create(WakeOutput);
  FWaker := FMethodWaker;
  FCore.SetWriteWaker(FWaker);
  FMode := cmHttp2;
end;

procedure THttp2AsyncConnection.StartHttp1;
var
  Options: TH1CoreOptions;
  Core: TH1Core;
begin
  Options.Limits := FServer.Factory.Http11;
  if fSecure <> nil then
    Options.Scheme := 'https'
  else
    Options.Scheme := 'http';
  Options.OutboundLimit := FServer.Factory.ChannelQueueLimit;
  Options.WriteStallMs := FServer.Factory.IdleTimeoutMs;
  FH1Events := THttp1ConnectionEvents.Create(FServer.Handlers,
    PeerAddressText(RemoteIP, fRemoteIP4), FClientCert);
  Core := TH1Core.Create(Options, FH1Events);
  FMethodWaker := TMethodWaker.Create(WakeOutput);
  FWaker := FMethodWaker;
  Core.SetWriteWaker(FWaker);
  Core.SetPendingProbe(PendingWriteBytes);
  // a TLS connection cannot close its write side alone, so it closes at once
  FH1 := TH1Driver.Create(Core, fSecure = nil);
  FMode := cmHttp1;
end;

procedure THttp2AsyncConnection.ReleaseState;
begin
  // a handler thread must not call into this connection while it is freed
  if FMethodWaker <> nil then
    FMethodWaker.Detach;
  if FCore <> nil then
    FCore.ReleaseHost;
  if FH1 <> nil then
    FH1.Core.ReleaseHost;
  if FServer <> nil then
    FServer.ConnectionClosed;
  FreeAndNil(FSendLock);
  FreeAndNil(FCore);
  FreeAndNil(FH1);
  FH1Events := nil;
  FWaker := nil;
  FMethodWaker := nil;
  FEvents := nil;
  FInSend := False;
  FSendRequested := False;
  FClientCert := nil;
  FMode := cmUndecided;
  FServer := nil;
end;

procedure THttp2AsyncConnection.BeforeDestroy;
begin
  ReleaseState;
end;

procedure THttp2AsyncConnection.Recycle(const aRemoteIP: TNetAddr);
begin
  // the instance of a closed connection serves the next one. Without this reset the
  // new connection keeps the HTTP/1.1 core of the old one, PullOutput reads that
  // core, and the output of the new connection never leaves
  ReleaseState;
  inherited Recycle(aRemoteIP);
end;

function THttp2AsyncConnection.OnFirstRead(aOwner: TPollAsyncSockets): boolean;
begin
  // The mORMot2 read path calls this method and never catches what it
  // raises: an exception here reaches TAsyncConnectionsThread.DoExecute,
  // whose handler ends the pool thread for ever
  // (mormot.net.async.pas:2354 calls OnFirstRead, :2811 runs the pool loop,
  // :4474 catches the escape; read 2026-10-08).  A dead pool thread reads no
  // socket again, so one fault would stop the whole server while the
  // listener stays bound.  Every failure below is therefore reported as a
  // refusal, and a refused connection is closed by the caller.
  result := false;
  try
    // a server that stops accepts no new connection
    if FServer.Draining then
      exit;
    // the accepted socket is blocking while TLS is on, so the socket deadline
    // and the mORMot2 SSL_accept deadline together bound the handshake.  A
    // client that stalls holds its IO thread for a bounded time only
    SetHandshakeDeadline(fSocket, FServer.Policy.HandshakeTimeoutMs);
    result := inherited OnFirstRead(aOwner);
    if not result then
    begin
      if FServer.Policy.ClientTrust.Mode <> ccmNone then
        FServer.TlsHandshakeFailed('the TLS handshake failed');
      exit;
    end;
    // the identity is read once, after the handshake, from the SSL object of
    // this connection. It never changes after this line
    if (fSecure <> nil) and (FServer.Policy.ClientTrust.Mode <> ccmNone) then
      FClientCert := ReadClientCertificate(fSecure,
        FServer.Policy.ClientTrust.Principal);
    // a TLS connection that negotiated h2 speaks HTTP/2. Any other TLS
    // connection speaks HTTP/1.1 when the fallback is on, and is refused when it
    // is off, so no HTTP/1.1 request reaches the HTTP/2 state machine. A cleartext
    // connection is decided by its first octets in OnRead
    if fSecure <> nil then
      if NegotiatedH2(fSecure) then
        StartHttp2
      else if FServer.Factory.Http11Fallback then
        StartHttp1
      else
        result := false;
  except
    on E: Exception do
      // an unreadable socket is refused, and the refusal keeps the read
      // thread alive, which is worth more than any one connection
    begin
      result := false;
      if FServer.Policy.ClientTrust.Mode <> ccmNone then
        FServer.TlsHandshakeFailed(E.Message);
    end;
  end;
end;

function THttp2AsyncConnection.OnRead: TPollAsyncSocketOnReadWrite;
var
  Data: TBytes;
begin
  Http2IoThreadEnter;
  try
    result := soContinue;
    if FMode = cmUndecided then
    begin
      if fRd.Len = 0 then
        exit;
      case SelectCleartextProtocol(fRd.Buffer^, fRd.Len) of
        pcNeedMore:
          begin
            // the octets so far could be the HTTP/2 preface; the header
            // deadline bounds the wait
            if (FHeaderDeadlineSec <> 0) and
               (TAsyncConnectionSec(GetTickCount64 div 1000) > FHeaderDeadlineSec) then
              exit(soClose);
            exit;
          end;
        pcHttp2:
          StartHttp2;
      else
        if FServer.Factory.Http11Fallback then
          StartHttp1
        else
          exit(soClose);
      end;
    end;
    if FMode = cmHttp1 then
      exit(OnReadHttp1);
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
      // a header block that arrives one byte at a time keeps the connection
      // busy, so the idle check never runs.  The deadline is judged here,
      // on every read, and a block that missed it ends the connection.
      if (FHeaderDeadlineSec <> 0) and
         (TAsyncConnectionSec(GetTickCount64 div 1000) > FHeaderDeadlineSec)
      then
        exit(soClose);
    end;
    SendPendingOutput;
    if FCore.Aborted then
      exit(soClose);
    // The GOAWAY frame of a trip or a graceful stop must reach the peer, so
    // the close waits for the whole output drain.  A close before the drain
    // drops the queued GOAWAY and the peer never learns why the socket ended.
    if FCore.IsClosing and (FCore.OpenStreams = 0) and
       (not FCore.HasOutput) and (PendingWrite = 0) then
      exit(soClose);
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
    if FMode = cmHttp1 then
    begin
      FH1.Core.NotifyDrain;
      ApplyClosePhase;
      exit;
    end;
    if FCore = nil then
      exit;
    // A GOAWAY trip or a graceful stop closes the connection once the last
    // frame left the socket.  OnRead cannot make that decision after the last
    // stream ends, because the trip already drained it, so the decision runs
    // here too: the close waits for the frames, and the peer learns why the
    // socket ended.
    if FCore.IsClosing and (FCore.OpenStreams = 0) and
       (not FCore.HasOutput) and (PendingWrite = 0) then
      result := soClose;
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
  if ((FCore = nil) and (FH1 = nil)) or IsClosed then
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
    Again := True;
    while Again do
    begin
      FSendLock.Acquire;
      try
        FSendRequested := False;
      finally
        FSendLock.Release;
      end;
      // the drain turns the handler buffers into DATA frames.  It runs under
      // the core lock, which every stream also takes, so the HPACK encoder
      // keeps one owner per connection
      if FCore <> nil then
      begin
        FCore.DrainPending;
        // the output queue passed its cap: the peer does not read, so the
        // connection ends at once and the queued bytes are dropped
        if FCore.Aborted then
        begin
          fOwner.ConnectionRemove(Handle);
          exit;
        end;
      end;
      while PullOutput(Data) do
      begin
        // the mORMot2 write path takes the connection write lock, sends at
        // once when it can, and otherwise subscribes for the write event.  A
        // false answer means the lock went to the IO thread, so one retry runs
        // the second check of the mORMot2 wake-up pattern
        if not fOwner.Write(Self, pointer(Data), Length(Data),
             cWriteTimeoutMs) then
          if not fOwner.Write(Self, pointer(Data), Length(Data),
               cWriteTimeoutMs) then
          begin
            // the bytes did not reach the write path. A stream with a hole in it
            // cannot continue, so the connection ends
            fOwner.ConnectionRemove(Handle);
            exit;
          end;
        result := True;
        // the bytes that mORMot2 holds for the socket count against the cap too
        if (FServer.CoreOptions.MaxOutputBytes > 0) and
           (PendingWriteBytes > Int64(FServer.CoreOptions.MaxOutputBytes)) then
        begin
          fOwner.ConnectionRemove(Handle);
          exit;
        end;
      end;
      // The exit decision and the FInSend clear share one lock hold.  A
      // handler that writes during the drain finds FInSend true and only
      // records FSendRequested, so the clear must re-read that flag in the
      // same hold that ends the loop.  A clear in a later hold would drop the
      // record, and the handler would wait for a drain that never comes.
      FSendLock.Acquire;
      try
        if FSendRequested or OutputPending then
          Again := True
        else
        begin
          FInSend := False;
          Again := False;
        end;
      finally
        FSendLock.Release;
      end;
      // the loop repeats for a late wake-up or for output a handler just made
    end;
  finally
    FSendLock.Acquire;
    try
      FInSend := False;
    finally
      FSendLock.Release;
    end;
  end;
  // the close decision of an HTTP/1.1 exchange can come after the last write,
  // so the end of every send loop looks at it too
  if FMode = cmHttp1 then
  begin
    FH1.Core.NotifyDrain;
    ApplyClosePhase;
  end;
end;

function THttp2AsyncConnection.OnLastOperationIdle(
  nowsec: TAsyncConnectionSec): boolean;
begin
  result := false;
  if FMode = cmHttp1 then
  begin
    case FH1.IdleAction(nowsec, fLastOperation, FIdleSeconds, GetTickCount64,
      FServer.Factory.HeaderTimeoutMs) of
      iaFlush:
        SendPendingOutput;
      iaClose:
        begin
          fOwner.ConnectionRemove(Handle);
          exit(True);
        end;
    end;
    exit;
  end;
  if FMode = cmUndecided then
  begin
    // no octet decided the protocol within the header timeout
    if (FHeaderDeadlineSec <> 0) and (nowsec > FHeaderDeadlineSec) then
    begin
      fOwner.ConnectionRemove(Handle);
      exit(True);
    end;
    // a connection that never sent an octet is idle
    if (FIdleSeconds <> 0) and (nowsec - fLastOperation >= FIdleSeconds) then
    begin
      fOwner.ConnectionRemove(Handle);
      exit(True);
    end;
    exit;
  end;
  if FCore = nil then
    exit;
  // the first header block did not complete within the header timeout
  if (FHeaderDeadlineSec <> 0) and (nowsec > FHeaderDeadlineSec) then
  begin
    fOwner.ConnectionRemove(Handle);
    Exit(True);
  end;
  // an idle connection with no stream and no queued output is closed, so an
  // idle client does not hold a socket for ever
  if (FIdleSeconds <> 0) and (nowsec - fLastOperation >= FIdleSeconds) and
     (FCore.OpenStreams = 0) and not FCore.HasOutput then
  begin
    fOwner.ConnectionRemove(Handle);
    Result := True;
  end;
end;

procedure THttp2AsyncConnection.OnClose;
begin
  // the socket is gone: cancel the streams, so that a waiting handler and the
  // sink of a detached stream learn it now and not at their next timeout
  if FCore <> nil then
    FCore.ConnectionLost;
  if FH1 <> nil then
    FH1.Core.ConnectionLost;
  inherited OnClose;
end;

function THttp2AsyncConnection.PullOutput(out AData: TBytes): Boolean;
begin
  if FH1 <> nil then
    Result := FH1.Core.TakeOutput(AData)
  else
    Result := FCore.TakeOutput(AData);
end;

function THttp2AsyncConnection.OutputPending: Boolean;
begin
  if FH1 <> nil then
    Result := FH1.Core.HasOutput
  else
    Result := FCore.HasOutput;
end;

function THttp2AsyncConnection.PendingWriteBytes: Int64;
begin
  Result := PendingWrite;
end;

procedure THttp2AsyncConnection.ApplyClosePhase;
begin
  case FH1.ClosePhase(PendingWrite, TAsyncConnectionSec(GetTickCount64 div 1000),
    cDrainSeconds) of
    cpHalfClose:
      begin
        // The response left the socket. A close while the peer still sends would
        // reset the connection and could destroy the response in the buffer of
        // the peer, so the write side closes first and the octets that still
        // arrive are dropped (RFC 9112 section 9.6)
        {$IFDEF UNIX}Sockets.fpshutdown(LongInt(fSocket.Socket), cShutWrite);{$ENDIF}
      end;
    cpCloseNow:
      fOwner.ConnectionRemove(Handle);
  end;
end;

function THttp2AsyncConnection.OnReadHttp1: TPollAsyncSocketOnReadWrite;
var
  Data: TBytes;
begin
  result := soContinue;
  Data := nil;
  if fRd.Len > 0 then
  begin
    SetLength(Data, fRd.Len);
    Move(fRd.Buffer^, Data[0], fRd.Len);
    fRd.Reset;
  end;
  FH1.Received(Data, FServer.Factory.HeaderTimeoutMs);
  SendPendingOutput;
  ApplyClosePhase;
end;

{ THttp2AsyncServer }

constructor THttp2AsyncServer.Create(const AFactory: THttp2ServerFactory);
var
  Options: TAsyncConnectionsOptions;
begin
  FFactory := AFactory;
  FPolicy := BuildTlsPolicy(FFactory);
  FCoreOptions := BuildConnectionCoreOptions(FFactory);
  FControlBucket := LeastControlBucket(FFactory);
  FCounters := TServerCounters.Create;
  FHandlers := THandlerPool.Create(AFactory);
  FChannelImpl := TChannelRegistry.Create(AFactory.MaxDetachedStreams,
    AFactory.ChannelQueueLimit, AFactory.ChannelLowWater);
  FChannelImpl.KeepAliveMs := AFactory.SseKeepAliveMs;
  FChannelImpl.StallTimeoutMs := AFactory.SseStallTimeoutMs;
  FChannels := FChannelImpl;
  FHandlers.ChannelRegistry := FChannels;
  FStreamPool := TStreamPool.Create(AFactory.StreamPoolSize);
  FChannelImpl.SourceProvider := FStreamPool.NewSource;
  FObserver := nil;
  Options := ASYNC_OPTION_PROD;
  if AFactory.Tls.CertificateFile <> '' then
    include(Options, acoEnableTls);
  inherited Create(IntToStr(AFactory.Port), nil, nil, THttp2AsyncConnection,
    'http2', nil, Options, AFactory.IOThreads);
  // the backlog of the factory reaches bind() through this mORMot2 global
  // (mormot.net.sock.pas:3495, 8715, read 2026-10-07)
  DefaultListenBacklog := AFactory.Backlog;
  MaxConnections := MaxInt;
end;

destructor THttp2AsyncServer.Destroy;
begin
  Stop;
  FHandlers.Free;
  FHandlers := nil;
  FChannelImpl.SourceProvider := nil;
  FStreamPool.Free;
  FStreamPool := nil;
  FChannels := nil;
  FChannelImpl := nil;
  inherited Destroy;
  // the connections close inside the inherited destructor and still count
  FCounters.Free;
  FCounters := nil;
end;

function THttp2AsyncServer.GetLastOperationIdleSeconds: cardinal;
var
  Ms: Integer;

  function Seconds(const AValue: Integer): cardinal;
  begin
    if AValue <= 0 then
      exit(0);
    // the base class compares in 32-bit seconds, so a sub-second timeout is
    // rounded up to one second
    result := cardinal(AValue div 1000);
    if result = 0 then
      result := 1;
  end;

begin
  // the idle callback is the one place that both timeouts are checked, so the
  // callback runs at the earlier of the two: an idle close uses the idle
  // timeout, and a first-header-block close uses the header timeout
  result := Seconds(FFactory.IdleTimeoutMs);
  if (FFactory.HeaderTimeoutMs > 0) and
     ((result = 0) or
      (Seconds(FFactory.HeaderTimeoutMs) < result)) then
    result := Seconds(FFactory.HeaderTimeoutMs);
end;

procedure THttp2AsyncServer.ConnectionOpened;
begin
  FCounters.ConnectionOpened;
  Notify(seConnectionAccepted, 0, lkReset, 'the socket is accepted');
end;

procedure THttp2AsyncServer.ConnectionClosed;
begin
  FCounters.ConnectionClosed;
  Notify(seConnectionClosed, 0, lkReset, 'the connection ended');
end;

procedure THttp2AsyncServer.Notify(const AEvent: TServerEvent);
begin
  if FObserver <> nil then
  try
    FObserver.OnEvent(AEvent);
  except
    // an observer must not end an IO thread; its exception is dropped
  end;
end;

procedure THttp2AsyncServer.TlsHandshakeFailed(const ADetail: string);
begin
  FCounters.TlsFailed;
  Notify(seTlsHandshakeFailed, 0, lkReset, ADetail);
end;

procedure THttp2AsyncServer.BeginDrain;
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  Conn: THttp2AsyncConnection;
begin
  FDraining := True;
  Instances := GetConnectionInstances;
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

procedure THttp2AsyncServer.BroadcastGoAway(
  const AErrorCode: THttp2ErrorCode);
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  Conn: THttp2AsyncConnection;
begin
  // GetConnectionInstances copies the live instances and protects each one
  // from recycling for a short moment, so a short call on the instance is
  // safe without the main connection lock
  Instances := GetConnectionInstances;
  for I := 0 to High(Instances) do
  begin
    Conn := THttp2AsyncConnection(Instances[I]);
    if (Conn = nil) or (Conn.Core = nil) then
      continue;
    Conn.Core.GracefulGoAway(Conn.Core.LastProcessedStreamId, AErrorCode);
    Conn.Waker.Signal;
  end;
  Notify(seGoAwaySent, 0, lkReset,
    'the server sends GOAWAY on every connection');
end;

function THttp2AsyncServer.OpenStreamTotal: Integer;
var
  Instances: TAsyncConnectionDynArray;
  I: Integer;
  Conn: THttp2AsyncConnection;
begin
  Result := 0;
  Instances := GetConnectionInstances;
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

procedure THttp2AsyncServer.Notify(const AKind: TServerEventKind;
  const AStreamId: LongWord; const ALimit: TLimitKind; const ADetail: string);
var
  Event: TServerEvent;
begin
  if FObserver = nil then
    exit;
  Event.Kind := AKind;
  Event.StreamId := AStreamId;
  Event.LimitKind := ALimit;
  Event.ErrorCode := ecNoError;
  Event.Detail := ADetail;
  try
    FObserver.OnEvent(Event);
  except
    // an observer must not end an IO thread; its exception is dropped
  end;
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

procedure THttp2AsyncServer.CloseChannels(const AMode: TChannelClose);
begin
  if FChannels <> nil then
    FChannels.CloseAll(AMode);
end;

procedure THttp2AsyncServer.Stop(const AWaitMs: Integer);
begin
  FDraining := True;
  // the channels that are still open end first, so no stream outlives its
  // handler pool; a channel that already ended is not touched twice
  if FChannels <> nil then
    FChannels.CloseAll(ccAbort);
  if FHandlers <> nil then
    FHandlers.Stop(AWaitMs);
  Shutdown;
  if FStreamPool <> nil then
    FStreamPool.Stop;
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
