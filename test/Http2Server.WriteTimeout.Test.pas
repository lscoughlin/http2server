{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, write timeout, stall, sweep, test, h2c
notes:
  - Live tests for the connection write timeout, with a raw h2c frame
    client in the style of the age tests.
  - The pure WriteStalled decisions run with no socket, so every boundary
    is reached without timing.
  - The waits are bounded polls and never a fixed sleep that decides a result.
  - The close tests fail when the write check is off. A stalled peer then
    stays open, and the WriteStalled tests fail when the function is stubbed
    to a constant.
---
}
/// Live and unit tests for the connection write timeout
unit Http2Server.WriteTimeout.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.base,
  mormot.core.os,
  mormot.net.sock,
  mormot.net.async,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Headers, Http2Server.Config, Http2Server.Config.Limits,
  Http2Server.Seam, Http2Server.Stream, Http2Server.Connection,
  Http2Server.Async, Http2Server.Async.Options, Http2Server.Async.Sweep;

type
  /// the pure decisions of WriteStalled, without sockets
  TWriteStalledTest = class(TTestCase)
  published
    /// a zero timeout never stalls, whatever the backlog and the elapsed time
    procedure TestZeroTimeoutNeverStalls;
    /// an empty backlog never stalls, whatever the timeout and the elapsed time
    procedure TestEmptyBacklogNeverStalls;
    /// an elapsed time below the timeout holds the connection
    procedure TestElapsedBelowTimeoutHolds;
    /// an elapsed time of exactly the timeout stalls the connection
    procedure TestBoundaryElapsedEqualsTimeoutStalls;
    /// an elapsed time above the timeout stalls the connection
    procedure TestElapsedAboveTimeoutStalls;
    /// a progress time at or after now never stalls
    procedure TestProgressAfterNowNeverStalls;
    /// a negative timeout never stalls
    procedure TestNegativeTimeoutNeverStalls;
  end;

  /// the outcome of one burst handler run, shared with the test thread
  TStallOutcome = class
  private
    FLock: TCriticalSection;
    FBurstDone, FDone: Boolean;
    FErrorClass: string;
    FElapsedMs: QWord;
  public
    constructor Create;
    destructor Destroy; override;
    /// record the end of the burst, before the drip or the finish
    procedure SetBurstDone;
    /// true once the burst left the handler
    function BurstDone: Boolean;
    /// record the end of the handler run
    procedure SetResult(const AErrorClass: string; const AElapsedMs: QWord);
    /// true once the handler run ended, with its outcome
    function TryGet(out AErrorClass: string; out AElapsedMs: QWord): Boolean;
  end;

  /// a handler that writes one burst and then drips until the stream is cut
  TStallHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FBurstBytes: Integer;
    FDrip: Boolean;
    FOutcome: TStallOutcome;
  public
    /// ABurstBytes is the burst size; ADrip keeps a slow write after it
    constructor Create(const ABurstBytes: Integer; const ADrip: Boolean;
      const AOutcome: TStallOutcome);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// one raw h2c client over a blocking socket, which keeps every frame
  TStallClient = class
  private
    FSock: TCrtSocket;
    FEnc: THpackCodec;
    FBuf: RawByteString;
    FFrames: TArray<TFrame>;
    procedure Pump(const AWaitMs: Integer);
    procedure Collect(const AWaitMs: Integer);
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// read and discard everything pending, so a FIN behind unread data surfaces
    procedure Drain;
    /// drain everything pending and answer true once the FIN behind it
    /// surfaces, within ATimeoutMs
    function DrainAndWaitClosed(const ATimeoutMs: Integer): Boolean;
    /// send the preface and one SETTINGS frame with a large stream window
    procedure SendPrologue(const AInitialWindow: LongWord);
    /// widen the connection window by AIncrement octets
    procedure SendConnectionWindow(const AIncrement: LongWord);
    /// send one GET request as a HEADERS frame with END_STREAM
    procedure SendGet(const AStreamId: LongWord; const APath: string);
    /// send one PING frame with an eight-octet payload
    procedure SendPing(const APayload: TBytes);
    /// read frames until a DATA frame of AStreamId ends the stream
    function WaitForBody(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out ABody: TBytes): Boolean;
    /// read one socket buffer per pause, so the backlog outlives the timeout
    /// while every read still moves the server forward
    function WaitForBodyPaced(const AStreamId: LongWord;
      const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
    /// true when the peer already closed the socket
    function IsClosed: Boolean;
  end;

  /// the live write-timeout tests of the async server
  TWriteTimeoutTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    FOutcome: TStallOutcome;
    function StartServer(const AHandler: IHttp2Handler;
      const AAgeMs, AWriteMs: Integer): Integer;
    function StartDefaultServer(const AHandler: IHttp2Handler): Integer;
    procedure StopServer;
    /// true once the burst left the handler, within ATimeoutMs
    function WaitBurst(const ATimeoutMs: Integer): Boolean;
    /// true once the handler run ended, within ATimeoutMs
    function WaitOutcome(const ATimeoutMs: Integer; out AErrorClass: string;
      out AElapsedMs: QWord): Boolean;
    /// true once the server holds no live connection
    function ServerSideGone: Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    /// a peer that never reads is closed after the timeout, and the handler
    /// run ends with the cancel error
    procedure TestStalledPeerIsClosedAndHandlerCancelled;
    /// a peer that reads slowly but steadily is not closed
    procedure TestSlowSteadyReaderIsNotClosed;
    /// a peer that pings but never reads is closed
    procedure TestPingingPeerThatNeverReadsIsClosed;
    /// the default settings still run the write check
    procedure TestDefaultSettingsStillRunTheWriteCheck;
    /// a zero age with a zero timeout makes the sweep do nothing
    procedure TestAgeZeroAndTimeoutZeroDoNothing;
    /// a zero timeout never closes, even while the sweep runs for the age
    procedure TestTimeoutZeroNeverCloses;
  end;

implementation

const
  /// the write timeout of the live close tests, in milliseconds
  StallTimeoutMs = 1000;
  /// the burst of every live test: 8 MiB exceed every socket buffer, so the
  /// backlog persists while the peer does not read
  StallBurstBytes = 8388608;
  /// the stream and connection window of every live test, in octets
  StallWindowBytes = 16777216;
  /// the bound of every close poll, in milliseconds
  CloseTimeoutMs = 8000;
  /// the bound of the cancel poll: mORMot2 frees a removed connection
  /// about 10 s after the close, and the cancel arrives with the free
  CancelTimeoutMs = 20000;
  /// the earliest acceptable close: past the timeout, never instant, so a
  /// protocol error cannot pass as a stall close
  CloseFloorMs = 800;
  /// the latest acceptable close: the timeout plus about 3 s, with slack
  CloseCeilingMs = 7000;
  /// the bound of every body poll, in milliseconds
  BodyTimeoutMs = 30000;

/// append B to A and answer the joined array
function StallCat(const A, B: TBytes): TBytes;
begin
  Result := A;
  if Length(B) = 0 then
    exit;
  SetLength(Result, Length(A) + Length(B));
  Move(B[0], Result[Length(A)], Length(B));
end;

/// serialize one frame to its wire bytes
function StallFrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

{ TWriteStalledTest }

procedure TWriteStalledTest.TestZeroTimeoutNeverStalls;
begin
  AssertFalse('a zero timeout stalls',
    WriteStalled(10000, 1000, 0, 1000));
  AssertFalse('a zero timeout stalls far later',
    WriteStalled(1000000, 1000, 0, 1000000));
end;

procedure TWriteStalledTest.TestEmptyBacklogNeverStalls;
begin
  AssertFalse('an empty backlog stalls',
    WriteStalled(10000, 1000, 1000, 0));
  AssertFalse('an empty backlog stalls far later',
    WriteStalled(1000000, 1000, 1000, 0));
end;

procedure TWriteStalledTest.TestElapsedBelowTimeoutHolds;
begin
  AssertFalse('an elapsed time below the timeout stalls',
    WriteStalled(1999, 1000, 1000, 100));
end;

procedure TWriteStalledTest.TestBoundaryElapsedEqualsTimeoutStalls;
begin
  AssertTrue('an elapsed time of exactly the timeout holds',
    WriteStalled(2000, 1000, 1000, 100));
end;

procedure TWriteStalledTest.TestElapsedAboveTimeoutStalls;
begin
  AssertTrue('an elapsed time above the timeout holds',
    WriteStalled(2001, 1000, 1000, 100));
end;

procedure TWriteStalledTest.TestProgressAfterNowNeverStalls;
begin
  AssertFalse('a progress time after now stalls',
    WriteStalled(1000, 2000, 1000, 100));
  AssertFalse('a progress time at now stalls',
    WriteStalled(1000, 1000, 1000, 100));
end;

procedure TWriteStalledTest.TestNegativeTimeoutNeverStalls;
begin
  AssertFalse('a negative timeout stalls',
    WriteStalled(10000, 1000, -1, 1000));
end;

{ TStallOutcome }

constructor TStallOutcome.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TStallOutcome.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TStallOutcome.SetBurstDone;
begin
  FLock.Acquire;
  try
    FBurstDone := True;
  finally
    FLock.Release;
  end;
end;

function TStallOutcome.BurstDone: Boolean;
begin
  FLock.Acquire;
  try
    Result := FBurstDone;
  finally
    FLock.Release;
  end;
end;

procedure TStallOutcome.SetResult(const AErrorClass: string;
  const AElapsedMs: QWord);
begin
  FLock.Acquire;
  try
    FErrorClass := AErrorClass;
    FElapsedMs := AElapsedMs;
    FDone := True;
  finally
    FLock.Release;
  end;
end;

function TStallOutcome.TryGet(out AErrorClass: string;
  out AElapsedMs: QWord): Boolean;
begin
  FLock.Acquire;
  try
    Result := FDone;
    AErrorClass := FErrorClass;
    AElapsedMs := FElapsedMs;
  finally
    FLock.Release;
  end;
end;

{ TStallHandler }

constructor TStallHandler.Create(const ABurstBytes: Integer;
  const ADrip: Boolean; const AOutcome: TStallOutcome);
begin
  inherited Create;
  FBurstBytes := ABurstBytes;
  FDrip := ADrip;
  FOutcome := AOutcome;
end;

procedure TStallHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Chunk: TBytes;
  I, Chunks: Integer;
  Start: QWord;
begin
  SetLength(Chunk, 8192);
  FillChar(Chunk[0], Length(Chunk), 65);
  Start := GetTickCount64;
  try
    AResponse.SendHeaders(200, nil, False);
    Chunks := FBurstBytes div Length(Chunk);
    for I := 1 to Chunks do
      AResponse.Write(Chunk);
    FOutcome.SetBurstDone;
    if FDrip then
      while True do
      begin
        Sleep(50);
        AResponse.Write(Chunk);
      end;
    AResponse.Finish;
    FOutcome.SetResult('', GetTickCount64 - Start);
  except
    on E: Exception do
      FOutcome.SetResult(E.ClassName, GetTickCount64 - Start);
  end;
end;

{ TStallClient }

constructor TStallClient.Create(const APort: Integer);
begin
  inherited Create;
  FEnc := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, 4000);
end;

destructor TStallClient.Destroy;
begin
  FSock.Free;
  FEnc.Free;
  inherited Destroy;
end;

procedure TStallClient.Pump(const AWaitMs: Integer);
var
  Pending: TCrtSocketPending;
  Chunk: RawByteString;
begin
  Pending := FSock.SockReceivePending(AWaitMs);
  if Pending in [cspSocketError, cspSocketClosed] then
    Exit;
  Chunk := FSock.SockReceiveString;
  if Chunk <> '' then
    FBuf := FBuf + Chunk;
end;

procedure TStallClient.Collect(const AWaitMs: Integer);
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
  Frame: TFrame;
  Ack: TBytes;
begin
  Pump(AWaitMs);
  while Length(FBuf) >= FrameHeaderSize do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    N := FrameHeaderSize + Integer(Header.Length);
    if Length(FBuf) < N then
      Exit;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(FBuf[FrameHeaderSize + 1], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    SetLength(FFrames, Length(FFrames) + 1);
    FFrames[High(FFrames)] := Frame;
    FBuf := Copy(FBuf, N + 1, MaxInt);
    // the server settings are acked, as a polite peer does
    if (Header.FrameType = ftSettings) and (not Frame.IsAck) then
    begin
      Ack := StallFrameBytes(BuildSettingsAck);
      FSock.SockSend(@Ack[0], Length(Ack));
      FSock.SockSendFlush();
    end;
  end;
end;

procedure TStallClient.SendPrologue(const AInitialWindow: LongWord);
var
  Wire: TBytes;
  Settings: TConnectionSettings;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Settings := TConnectionSettings.Defaults;
  Settings.InitialWindowSize := AInitialWindow;
  Wire := StallCat(Wire,
    StallFrameBytes(BuildSettingsFrame(Settings)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TStallClient.SendConnectionWindow(const AIncrement: LongWord);
var
  Wire: TBytes;
begin
  Wire := StallFrameBytes(BuildWindowUpdateFrame(0, AIncrement));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TStallClient.SendGet(const AStreamId: LongWord; const APath: string);
var
  Fields: THeaderBlock;
  Wire: TBytes;
begin
  SetLength(Fields, 4);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := 'GET';
  Fields[1].Name := HeaderPath;
  Fields[1].Value := APath;
  Fields[2].Name := HeaderScheme;
  Fields[2].Value := 'http';
  Fields[3].Name := HeaderAuthority;
  Fields[3].Value := '127.0.0.1';
  Wire := StallFrameBytes(
    BuildHeadersFrame(AStreamId, FEnc.Encode(Fields), True, True));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TStallClient.SendPing(const APayload: TBytes);
var
  Wire: TBytes;
begin
  Wire := StallFrameBytes(BuildPingFrame(APayload, False));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

function TStallClient.WaitForBody(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
var
  Deadline: QWord;
  Before, I: Integer;
begin
  Result := False;
  ABody := nil;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Before := Length(FFrames);
    Collect(50);
    for I := Before to High(FFrames) do
      if (FFrames[I].Header.FrameType = ftData) and
        (FFrames[I].Header.StreamId = AStreamId) then
      begin
        ABody := StallCat(ABody, ExtractDataPayload(FFrames[I]));
        if FFrames[I].IsEndStream then
          Exit(True);
      end;
  end;
end;

function TStallClient.WaitForBodyPaced(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
var
  Deadline: QWord;
  Before, I: Integer;
begin
  // one socket buffer per pause: the read of the burst takes several
  // seconds, so the timeout passes twice while the backlog stays positive
  Result := False;
  ABody := nil;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Before := Length(FFrames);
    Collect(50);
    for I := Before to High(FFrames) do
      if (FFrames[I].Header.FrameType = ftData) and
        (FFrames[I].Header.StreamId = AStreamId) then
      begin
        ABody := StallCat(ABody, ExtractDataPayload(FFrames[I]));
        if FFrames[I].IsEndStream then
          Exit(True);
      end;
    Sleep(50);
  end;
end;

function TStallClient.IsClosed: Boolean;
var
  Pending: TCrtSocketPending;
begin
  Pending := FSock.SockReceivePending(100);
  Result := Pending in [cspSocketError, cspSocketClosed,
    cspDataAvailableOnClosedSocket];
end;

procedure TStallClient.Drain;
begin
  while FSock.SockReceivePending(0) = cspDataAvailable do
    FSock.SockReceiveString;
end;

function TStallClient.DrainAndWaitClosed(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Drain;
    if IsClosed then
      Exit(True);
    Sleep(50);
  until GetTickCount64 >= Deadline;
  Drain;
  Result := IsClosed;
end;

{ TWriteTimeoutTest }

function TWriteTimeoutTest.StartServer(const AHandler: IHttp2Handler;
  const AAgeMs, AWriteMs: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(4)
    .WithIOThreads(2)
    .WithIdleTimeout(60000)
    .WithHeaderTimeout(30000)
    .WithMaxConnectionAge(AAgeMs)
    .WithServerLimits(TServerLimits.Create.WithWriteTimeoutMs(AWriteMs));
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  Result := FServer.BoundPort;
end;

function TWriteTimeoutTest.StartDefaultServer(
  const AHandler: IHttp2Handler): Integer;
var
  Factory: THttp2ServerFactory;
begin
  // the age and the write timeout keep their defaults here, so the test
  // proves the behaviour of the default settings
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(4)
    .WithIOThreads(2)
    .WithIdleTimeout(60000)
    .WithHeaderTimeout(30000);
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  Result := FServer.BoundPort;
end;

procedure TWriteTimeoutTest.StopServer;
begin
  FreeAndNil(FServer);
end;

function TWriteTimeoutTest.WaitBurst(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if FOutcome.BurstDone then
      Exit(True);
    Sleep(5);
  until GetTickCount64 >= Deadline;
  Result := FOutcome.BurstDone;
end;

function TWriteTimeoutTest.WaitOutcome(const ATimeoutMs: Integer;
  out AErrorClass: string; out AElapsedMs: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if FOutcome.TryGet(AErrorClass, AElapsedMs) then
      Exit(True);
    Sleep(5);
  until GetTickCount64 >= Deadline;
  Result := FOutcome.TryGet(AErrorClass, AElapsedMs);
end;

function TWriteTimeoutTest.ServerSideGone: Boolean;
begin
  Result := Length(FServer.GetConnectionInstances) = 0;
end;

procedure TWriteTimeoutTest.SetUp;
begin
  inherited SetUp;
  FOutcome := TStallOutcome.Create;
  FServer := nil;
end;

procedure TWriteTimeoutTest.TearDown;
begin
  StopServer;
  FOutcome.Free;
  inherited TearDown;
end;

procedure TWriteTimeoutTest.TestStalledPeerIsClosedAndHandlerCancelled;
var
  Port: Integer;
  Handler: TStallHandler;
  HandlerRef: IHttp2Handler;
  Client: TStallClient;
  Start: QWord;
  ErrorClass: string;
  Elapsed: QWord;
  Deadline: QWord;
begin
  // the peer requests the burst and then never reads, while the handler
  // keeps a slow write: the sweep closes the socket after the timeout
  Handler := TStallHandler.Create(StallBurstBytes, True, FOutcome);
  HandlerRef := Handler;
  Port := StartServer(HandlerRef, 0, StallTimeoutMs);
  Client := TStallClient.Create(Port);
  try
    Start := GetTickCount64;
    Client.SendPrologue(StallWindowBytes);
    Client.SendConnectionWindow(StallWindowBytes);
    Client.SendGet(1, '/burst');
    // the connection registers first; the first sample may race the accept
    Deadline := GetTickCount64 + 5000;
    repeat
      if not ServerSideGone then
        Break;
      Sleep(50);
    until GetTickCount64 >= Deadline;
    AssertFalse('the connection never registered', ServerSideGone);
    Deadline := GetTickCount64 + QWord(CloseTimeoutMs);
    repeat
      if ServerSideGone then
        Break;
      Sleep(50);
    until GetTickCount64 >= Deadline;
    AssertTrue('the stalled peer stayed open past the timeout',
      ServerSideGone);
    AssertTrue('the close came before the timeout passed',
      GetTickCount64 - Start > CloseFloorMs);
    AssertTrue('the close took longer than about 3 s after the timeout',
      GetTickCount64 - Start < CloseCeilingMs);
    // the cancel reaches the handler once mORMot2 frees the instance,
    // about 10 s after the close, so this poll waits longer
    AssertTrue('the handler run never ended',
      WaitOutcome(CancelTimeoutMs, ErrorClass, Elapsed));
    AssertEquals('the handler ends with the cancel error',
      EStreamCancelled.ClassName, ErrorClass);
    AssertTrue('the socket stayed open after the sweep closed it',
      Client.DrainAndWaitClosed(CloseTimeoutMs));
  finally
    Client.Free;
  end;
end;

procedure TWriteTimeoutTest.TestSlowSteadyReaderIsNotClosed;
var
  Port: Integer;
  Handler: TStallHandler;
  HandlerRef: IHttp2Handler;
  Client: TStallClient;
  Body: TBytes;
  Start: QWord;
begin
  // the peer reads one socket buffer per pause: every read moves the
  // backlog, so the sweep never sees a stall although the timeout passes
  Handler := TStallHandler.Create(StallBurstBytes, False, FOutcome);
  HandlerRef := Handler;
  Port := StartServer(HandlerRef, 0, StallTimeoutMs);
  Client := TStallClient.Create(Port);
  try
    Start := GetTickCount64;
    Client.SendPrologue(StallWindowBytes);
    Client.SendConnectionWindow(StallWindowBytes);
    Client.SendGet(1, '/burst');
    AssertTrue('the slow reader never got the whole body',
      Client.WaitForBodyPaced(1, BodyTimeoutMs, Body));
    AssertEquals('the slow reader got a short body',
      StallBurstBytes, Length(Body));
    AssertTrue('the slow reader got a broken body',
      (Body[0] = 65) and (Body[High(Body)] = 65));
    AssertTrue('the paced read ended before the timeout passed twice',
      GetTickCount64 - Start > 2 * StallTimeoutMs);
    AssertFalse('the slow steady reader was closed', Client.IsClosed);
  finally
    Client.Free;
  end;
end;

procedure TWriteTimeoutTest.TestPingingPeerThatNeverReadsIsClosed;
var
  Port: Integer;
  Handler: TStallHandler;
  HandlerRef: IHttp2Handler;
  Client: TStallClient;
  Ping: TBytes;
  Start, Deadline: QWord;
begin
  // the PING frames mark the connection active, so the idle callback
  // misses this peer; only the sweep sees that no octet leaves
  Handler := TStallHandler.Create(StallBurstBytes, False, FOutcome);
  HandlerRef := Handler;
  Port := StartServer(HandlerRef, 0, StallTimeoutMs);
  Client := TStallClient.Create(Port);
  try
    Start := GetTickCount64;
    Client.SendPrologue(StallWindowBytes);
    Client.SendConnectionWindow(StallWindowBytes);
    Client.SendGet(1, '/burst');
    SetLength(Ping, 8);
    FillChar(Ping[0], Length(Ping), 7);
    Deadline := GetTickCount64 + QWord(CloseTimeoutMs);
    while GetTickCount64 < Deadline do
    begin
      try
        Client.SendPing(Ping);
      except
        on ENetSock do
          Break; // the server closed the socket: the wait is over
      end;
      // no drain here: the peer never reads, so a send error or a reset
      // is the close signal
      if Client.IsClosed then
        Break;
      Sleep(200);
    end;
    AssertTrue('the pinging peer that never reads stayed open',
      Client.IsClosed);
    AssertTrue('the close came before the timeout passed',
      GetTickCount64 - Start > CloseFloorMs);
    AssertTrue('the close took longer than about 3 s after the timeout',
      GetTickCount64 - Start < CloseCeilingMs);
  finally
    Client.Free;
  end;
end;

procedure TWriteTimeoutTest.TestDefaultSettingsStillRunTheWriteCheck;
var
  Port: Integer;
  Handler: TStallHandler;
  HandlerRef: IHttp2Handler;
  Client: TStallClient;
  Instances: TAsyncConnectionDynArray;
  Conn: THttp2AsyncConnection;
  Deadline: QWord;
begin
  // the age is off, so only the early return of the sweep decides; the
  // backdated progress stands in for a 60 s wait, and the close then
  // proves that the write check ran
  Handler := TStallHandler.Create(StallBurstBytes, False, FOutcome);
  HandlerRef := Handler;
  Port := StartDefaultServer(HandlerRef);
  AssertEquals('the default maximum age is not 0', 0,
    FServer.Factory.MaxConnectionAgeMs);
  AssertEquals('the default write timeout is not 60000', 60000,
    FServer.Factory.ServerLimits.WriteTimeoutMs);
  Client := TStallClient.Create(Port);
  try
    Client.SendPrologue(StallWindowBytes);
    Client.SendConnectionWindow(StallWindowBytes);
    Client.SendGet(1, '/burst');
    AssertTrue('the burst never left the handler',
      WaitBurst(BodyTimeoutMs));
    Instances := FServer.GetConnectionInstances;
    AssertEquals('the server holds no single connection', 1,
      Length(Instances));
    Conn := THttp2AsyncConnection(Instances[0]);
    Deadline := GetTickCount64 + QWord(CloseTimeoutMs);
    repeat
      // the progress counts uptime, so the backdate takes the mORMot2 tick
      Conn.LastWriteProgressMs := mormot.core.os.GetTickCount64 - 61000;
      if ServerSideGone then
        Break;
      Sleep(100);
    until GetTickCount64 >= Deadline;
    AssertTrue('the write check did not run with the default settings',
      ServerSideGone);
    // the FIN waits behind the unread burst, so the client drains first
    AssertTrue('the socket stayed open after the sweep closed it',
      Client.DrainAndWaitClosed(CloseTimeoutMs));
  finally
    Client.Free;
  end;
end;

procedure TWriteTimeoutTest.TestAgeZeroAndTimeoutZeroDoNothing;
var
  Port: Integer;
  Handler: TStallHandler;
  HandlerRef: IHttp2Handler;
  Client: TStallClient;
  Body: TBytes;
  Deadline: QWord;
begin
  // every limit is off: the burst waits unread for several sweep periods,
  // and the connection still serves it afterwards
  Handler := TStallHandler.Create(StallBurstBytes, False, FOutcome);
  HandlerRef := Handler;
  Port := StartServer(HandlerRef, 0, 0);
  Client := TStallClient.Create(Port);
  try
    Client.SendPrologue(StallWindowBytes);
    Client.SendConnectionWindow(StallWindowBytes);
    Client.SendGet(1, '/burst');
    Deadline := GetTickCount64 + 3500;
    while GetTickCount64 < Deadline do
    begin
      AssertFalse('the sweep closed a connection with every limit off',
        Client.IsClosed);
      Sleep(100);
    end;
    AssertTrue('the held connection no longer serves',
      Client.WaitForBody(1, BodyTimeoutMs, Body));
    AssertEquals('the held connection served a short body',
      StallBurstBytes, Length(Body));
    AssertFalse('the held connection closed after serving', Client.IsClosed);
  finally
    Client.Free;
  end;
end;

procedure TWriteTimeoutTest.TestTimeoutZeroNeverCloses;
var
  Port: Integer;
  Handler: TStallHandler;
  HandlerRef: IHttp2Handler;
  Client: TStallClient;
  Body: TBytes;
  Deadline: QWord;
begin
  // the sweep runs for the age, but the write check is off: the burst
  // waits unread, and the connection still serves it afterwards
  Handler := TStallHandler.Create(StallBurstBytes, False, FOutcome);
  HandlerRef := Handler;
  Port := StartServer(HandlerRef, 30000, 0);
  Client := TStallClient.Create(Port);
  try
    Client.SendPrologue(StallWindowBytes);
    Client.SendConnectionWindow(StallWindowBytes);
    Client.SendGet(1, '/burst');
    Deadline := GetTickCount64 + 3500;
    while GetTickCount64 < Deadline do
    begin
      AssertFalse('a zero write timeout closed the connection',
        Client.IsClosed);
      Sleep(100);
    end;
    AssertTrue('the held connection no longer serves',
      Client.WaitForBody(1, BodyTimeoutMs, Body));
    AssertEquals('the held connection served a short body',
      StallBurstBytes, Length(Body));
    AssertFalse('the held connection closed after serving', Client.IsClosed);
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTest(TWriteStalledTest);
  RegisterTest(TWriteTimeoutTest);

end.
