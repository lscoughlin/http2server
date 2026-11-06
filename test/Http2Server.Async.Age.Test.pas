{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, age, lifetime, test, h2c
notes:
  - Live tests for the maximum connection age of story 4, with a raw h2c
    frame client and a raw HTTP/1.1 client in the style of the idle tests.
  - The pure AgeExpired decisions run with no socket, so every boundary of
    the effective age and the jitter rule is reached without timing.
  - The waits are bounded polls and never a fixed sleep that decides a result,
    except for the explicit grace windows of the WebSocket exemption tests.
  - The live tests fail with the age sweep disabled. An idle HTTP/2
    connection then gets no GOAWAY, and the AgeExpired tests fail when the
    function is stubbed to a constant.
---
}
/// Live and unit tests for the maximum connection age
unit Http2Server.Async.Age.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.base,
  mormot.net.sock,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Headers, Http2Server.Config, Http2Server.Seam,
  Http2Server.Async, Http2Server.Async.Options,
  Http2Server.Observer, Http2Server.Ws.Types, Http2Server.Ws.Options,
  Http2Server.Ws.Environment, Http2Server.Http1.RawClient,
  Http2Server.Async.Test,
  Http2Server.Ws.TestKit, Http2Server.Ws.Http1.Test;

type
  /// the pure decisions of AgeExpired, without sockets
  TAgeExpiredTest = class(TTestCase)
  published
    /// a zero limit turns the check off, and a negative limit never expires
    procedure TestZeroLimitNeverExpires;
    /// the age equal to the effective age expires, one less does not
    procedure TestBoundaryWithoutJitter;
    /// an accept time after now never expires
    procedure TestAcceptAfterNowNeverExpires;
    /// jitter 0 keeps the setting as the effective age
    procedure TestJitterZeroKeepsTheSetting;
    /// jitter 100 cuts the effective age to 90 percent of the setting
    procedure TestJitterHundredCutsTenPercent;
    /// the effective age never passes the setting, for every jitter draw
    procedure TestEffectiveAgeNeverPassesTheSetting;
    /// one age expires for a high draw and holds for a low draw
    procedure TestJitterSpreadsTheAges;
  end;

  /// a handler that waits for the release of the test before it answers
  TAgeBlockingHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FRelease: TEvent;
    FStarted: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    procedure Release;
    /// true once a handler entered the block
    function IsStarted: Boolean;
  end;

  /// one raw h2c client over a blocking socket, which keeps every frame
  TAgeH2Client = class
  private
    FSock: TCrtSocket;
    FEnc, FDec: THpackCodec;
    FBuf: RawByteString;
    FFrames: TArray<TFrame>;
    procedure Pump(const AWaitMs: Integer);
    procedure Collect(const AWaitMs: Integer);
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// send the preface and one empty SETTINGS frame
    procedure SendPrologue;
    /// send one GET request as a HEADERS frame with END_STREAM
    procedure SendGet(const AStreamId: LongWord; const APath: string);
    /// send one WebSocket CONNECT without END_STREAM, so the stream stays open
    procedure SendConnect(const AStreamId: LongWord; const APath: string);
    /// send one RST_STREAM frame
    procedure SendRst(const AStreamId: LongWord; const ACode: THttp2ErrorCode);
    /// true once a GOAWAY frame arrived, with its last id and error code
    function WaitForGoAway(const ATimeoutMs: Integer; out ALastId: LongWord;
      out ACode: LongWord): Boolean;
    /// true when a GOAWAY frame arrived already
    function GoAwaySeen(out ALastId: LongWord; out ACode: LongWord): Boolean;
    /// read frames until a DATA frame of AStreamId ends the stream
    function WaitForBody(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out ABody: TBytes): Boolean;
    /// read frames until a HEADERS frame of AStreamId arrives, decoded
    function WaitForHeaders(const AStreamId: LongWord;
      const ATimeoutMs: Integer; out AFields: THeaderBlock): Boolean;
    /// true once the peer closed the socket, within ATimeoutMs
    function WaitClosed(const ATimeoutMs: Integer): Boolean;
    /// true when the peer already closed the socket
    function IsClosed: Boolean;
  end;

  /// the observer recording of one test
  TAgeRecordingObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FEvents: TArray<TServerEvent>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    /// the events of one kind seen so far
    function EventsOf(const AKind: TServerEventKind): TArray<TServerEvent>;
  end;

  /// the live age tests of the async server
  TConnectionAgeTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FWsEnv: TWsEnvironment;
    FWsEnvRef: IInterface;
    function StartAgeServer(const AHandler: IHttp2Handler;
      const AAgeMs, AGraceMs: Integer): Integer;
    function StartWsServer(const AAgeMs, AGraceMs: Integer): Integer;
    procedure StopServer;
    function WaitFor(const ACondition: TWaitFn;
      const ATimeoutMs: Integer): Boolean;
  protected
    procedure TearDown; override;
  published
    /// an idle HTTP/2 connection gets GOAWAY(NO_ERROR) and then closes
    procedure TestIdleH2GetsGoAwayThenCloses;
    /// a slow handler still completes its stream, then the socket closes
    procedure TestSlowH2CompletesThenCloses;
    /// a handler past the grace time is cut by a forced close
    procedure TestBlockingH2IsForceClosedPastGrace;
    /// an idle HTTP/1.1 connection is closed after the age
    procedure TestIdleH1IsClosedAfterTheAge;
    /// a response in flight at the age carries Connection: close
    procedure TestSlowH1AnswersConnectionClose;
    /// with the age off, an old connection stays open
    procedure TestAgeZeroStaysOpen;
    /// the retire raises one seConnectionRetired and one seGoAwaySent
    procedure TestRetireRaisesTheObserverEvents;
    /// an HTTP/1.1 WebSocket older than the age and the grace stays open
    procedure TestH1WebSocketStaysOpenPastAgeAndGrace;
    /// an HTTP/2 WebSocket stream stays open past age and grace, then retires
    procedure TestH2WebSocketStaysOpenThenRetires;
  end;

implementation

const
  AgeMs = 1000;
  GraceMs = 1500;
  BodyTimeoutMs = 10000;
  CloseTimeoutMs = 8000;

/// send raw octets over a raw HTTP client, for a masked WebSocket frame
procedure AgeSendFrame(const AClient: TRawHttp; const AData: TBytes);
var
  Raw: RawByteString;
begin
  SetLength(Raw, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Raw[1], Length(AData));
  AClient.Send(Raw);
end;

function AgeFrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

{ TAgeExpiredTest }

procedure TAgeExpiredTest.TestZeroLimitNeverExpires;
begin
  AssertFalse('a zero limit expires', AgeExpired(2000, 1000, 0, 0));
  AssertFalse('a zero limit expires far later',
    AgeExpired(1000000, 1000, 0, 100));
  AssertFalse('a negative limit expires', AgeExpired(2000, 1000, -1, 0));
end;

procedure TAgeExpiredTest.TestBoundaryWithoutJitter;
begin
  AssertTrue('the age at the limit expires',
    AgeExpired(2000, 1000, 1000, 0));
  AssertFalse('the age below the limit holds',
    AgeExpired(1999, 1000, 1000, 0));
end;

procedure TAgeExpiredTest.TestAcceptAfterNowNeverExpires;
begin
  AssertFalse('an accept after now expires', AgeExpired(1000, 2000, 1000, 0));
  AssertFalse('an accept at now expires', AgeExpired(1000, 1000, 1000, 0));
end;

procedure TAgeExpiredTest.TestJitterZeroKeepsTheSetting;
begin
  AssertTrue('jitter 0 expires at the setting',
    AgeExpired(6000, 1000, 5000, 0));
  AssertFalse('jitter 0 holds below the setting',
    AgeExpired(5999, 1000, 5000, 0));
end;

procedure TAgeExpiredTest.TestJitterHundredCutsTenPercent;
begin
  AssertTrue('jitter 100 expires at 90 percent',
    AgeExpired(1900, 1000, 1000, 100));
  AssertFalse('jitter 100 holds below 90 percent',
    AgeExpired(1899, 1000, 1000, 100));
end;

procedure TAgeExpiredTest.TestEffectiveAgeNeverPassesTheSetting;
const
  MaxAges: array[0..4] of Integer = (1, 7, 100, 1000, 100000);
var
  MaxAge, Jitter, I: Integer;
begin
  // the effective age never passes the setting: an age of exactly the
  // setting already expired, whatever the draw
  for I := 0 to High(MaxAges) do
  begin
    MaxAge := MaxAges[I];
    for Jitter := 0 to 100 do
      AssertTrue('the setting holds for draw ' + IntToStr(Jitter),
        AgeExpired(QWord(1000000 + MaxAge), 1000000, MaxAge, Jitter));
  end;
  // a draw outside the range is clamped into it
  AssertTrue('a negative draw behaves as 0',
    AgeExpired(2000, 1000, 1000, -5));
  AssertFalse('a negative draw keeps the setting',
    AgeExpired(1999, 1000, 1000, -5));
  AssertFalse('a draw past 100 behaves as 100',
    AgeExpired(1899, 1000, 1000, 50000));
end;

procedure TAgeExpiredTest.TestJitterSpreadsTheAges;
begin
  // the same age of 9500 against a setting of 10000 holds for draw 0 and
  // expires for draw 100, so the draws spread the retire times
  AssertFalse('draw 0 holds at 9500', AgeExpired(10500, 1000, 10000, 0));
  AssertTrue('draw 100 expires at 9500', AgeExpired(10500, 1000, 10000, 100));
end;

{ TAgeBlockingHandler }

constructor TAgeBlockingHandler.Create;
begin
  inherited Create;
  FRelease := TEvent.Create(nil, False, False, '');
end;

destructor TAgeBlockingHandler.Destroy;
begin
  FRelease.Free;
  inherited Destroy;
end;

procedure TAgeBlockingHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  InterlockedIncrement(FStarted);
  FRelease.WaitFor(30000);
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(BytesOf('late echo'));
  AResponse.Finish;
end;

procedure TAgeBlockingHandler.Release;
begin
  FRelease.SetEvent;
end;

function TAgeBlockingHandler.IsStarted: Boolean;
begin
  Result := FStarted > 0;
end;

{ TAgeH2Client }

constructor TAgeH2Client.Create(const APort: Integer);
begin
  inherited Create;
  FEnc := THpackCodec.Create;
  FDec := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, 4000);
end;

destructor TAgeH2Client.Destroy;
begin
  FSock.Free;
  FDec.Free;
  FEnc.Free;
  inherited Destroy;
end;

procedure TAgeH2Client.Pump(const AWaitMs: Integer);
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

procedure TAgeH2Client.Collect(const AWaitMs: Integer);
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
      Ack := AgeFrameBytes(BuildSettingsAck);
      FSock.SockSend(@Ack[0], Length(Ack));
      FSock.SockSendFlush();
    end;
  end;
end;

procedure TAgeH2Client.SendPrologue;
var
  Wire: TBytes;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Wire := Cat(Wire,
    AgeFrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TAgeH2Client.SendGet(const AStreamId: LongWord; const APath: string);
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
  Wire := AgeFrameBytes(
    BuildHeadersFrame(AStreamId, FEnc.Encode(Fields), True, True));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TAgeH2Client.SendConnect(const AStreamId: LongWord;
  const APath: string);
var
  Fields: THeaderBlock;
  Wire: TBytes;
begin
  SetLength(Fields, 6);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := 'CONNECT';
  Fields[1].Name := HeaderScheme;
  Fields[1].Value := 'http';
  Fields[2].Name := HeaderAuthority;
  Fields[2].Value := '127.0.0.1';
  Fields[3].Name := HeaderPath;
  Fields[3].Value := APath;
  Fields[4].Name := ':protocol';
  Fields[4].Value := 'websocket';
  Fields[5].Name := 'sec-websocket-version';
  Fields[5].Value := '13';
  Wire := AgeFrameBytes(
    BuildHeadersFrame(AStreamId, FEnc.Encode(Fields), True, False));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TAgeH2Client.SendRst(const AStreamId: LongWord;
  const ACode: THttp2ErrorCode);
var
  Wire: TBytes;
begin
  Wire := AgeFrameBytes(BuildRstStreamFrame(AStreamId, ACode));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

function TAgeH2Client.GoAwaySeen(out ALastId: LongWord;
  out ACode: LongWord): Boolean;
var
  I: Integer;
  P: TBytes;
begin
  for I := 0 to High(FFrames) do
    if FFrames[I].Header.FrameType = ftGoAway then
    begin
      P := FFrames[I].Payload;
      if Length(P) >= 8 then
      begin
        ALastId := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or
          (LongWord(P[2]) shl 8) or LongWord(P[3]);
        ALastId := ALastId and LongWord(MaxStreamId);
        ACode := (LongWord(P[4]) shl 24) or (LongWord(P[5]) shl 16) or
          (LongWord(P[6]) shl 8) or LongWord(P[7]);
        Exit(True);
      end;
    end;
  ALastId := 0;
  ACode := 0;
  Result := False;
end;

function TAgeH2Client.WaitForGoAway(const ATimeoutMs: Integer;
  out ALastId: LongWord; out ACode: LongWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Collect(50);
    if GoAwaySeen(ALastId, ACode) then
      Exit(True);
  until GetTickCount64 >= Deadline;
  Result := GoAwaySeen(ALastId, ACode);
end;

function TAgeH2Client.WaitForBody(const AStreamId: LongWord;
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
        ABody := Cat(ABody, ExtractDataPayload(FFrames[I]));
        if FFrames[I].IsEndStream then
          Exit(True);
      end;
  end;
end;

function TAgeH2Client.WaitForHeaders(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out AFields: THeaderBlock): Boolean;
var
  Deadline: QWord;
  Before, I: Integer;
begin
  Result := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Before := Length(FFrames);
    Collect(50);
    for I := Before to High(FFrames) do
      if (FFrames[I].Header.FrameType = ftHeaders) and
        (FFrames[I].Header.StreamId = AStreamId) then
      begin
        AFields := FDec.Decode(FFrames[I].Payload);
        Exit(True);
      end;
  end;
end;

function TAgeH2Client.IsClosed: Boolean;
var
  Pending: TCrtSocketPending;
begin
  Pending := FSock.SockReceivePending(100);
  Result := Pending in [cspSocketError, cspSocketClosed,
    cspDataAvailableOnClosedSocket];
end;

function TAgeH2Client.WaitClosed(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if IsClosed then
      Exit(True);
    Sleep(50);
  until GetTickCount64 >= Deadline;
  Result := IsClosed;
end;


{ TAgeRecordingObserver }

constructor TAgeRecordingObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TAgeRecordingObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TAgeRecordingObserver.OnEvent(const AEvent: TServerEvent);
begin
  FLock.Acquire;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := AEvent;
  finally
    FLock.Release;
  end;
end;

function TAgeRecordingObserver.EventsOf(
  const AKind: TServerEventKind): TArray<TServerEvent>;
var
  I: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    for I := 0 to High(FEvents) do
      if FEvents[I].Kind = AKind then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FEvents[I];
      end;
  finally
    FLock.Release;
  end;
end;

{ TConnectionAgeTest }

function TConnectionAgeTest.StartAgeServer(const AHandler: IHttp2Handler;
  const AAgeMs, AGraceMs: Integer): Integer;
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
    .WithGracefulStopTimeout(AGraceMs)
    .WithMaxConnectionAge(AAgeMs);
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  Result := FServer.BoundPort;
end;

function TConnectionAgeTest.StartWsServer(const AAgeMs,
  AGraceMs: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  // the recording lives on its interfaces, as in the WebSocket suites, and
  // the teardown only drops the references
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRecording.Echo := True;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(FRouterRef)
    .WithHandlerThreads(4)
    .WithIOThreads(2)
    .WithIdleTimeout(60000)
    .WithHeaderTimeout(30000)
    .WithGracefulStopTimeout(AGraceMs)
    .WithMaxConnectionAge(AAgeMs)
    .WithWebSockets(TWsOptions.Create.WithQueuedMessages(256));
  FServer := THttp2AsyncServer.Create(Factory);
  // the WebSocket sessions need their environment, as on the facade server
  FWsEnv := TWsEnvironment.Create(Factory.WebSockets, Factory.Clock,
    FServer.Notify);
  FWsEnvRef := FWsEnv;
  FServer.Channels.SetWsEnvironment(FWsEnvRef);
  FServer.Start;
  Result := FServer.BoundPort;
end;

procedure TConnectionAgeTest.StopServer;
begin
  // the watchdog of the WebSocket environment ends before the server it calls
  if FWsEnv <> nil then
    FWsEnv.Stop;
  FreeAndNil(FServer);
  FWsEnvRef := nil;
  FWsEnv := nil;
end;

function TConnectionAgeTest.WaitFor(const ACondition: TWaitFn;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if ACondition() then
      Exit(True);
    Sleep(5);
  until GetTickCount64 >= Deadline;
  Result := ACondition();
end;

procedure TConnectionAgeTest.TearDown;
begin
  StopServer;
  if FRouter <> nil then
    FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
  FRouter := nil;
  FRecording := nil;
end;

procedure TConnectionAgeTest.TestIdleH2GetsGoAwayThenCloses;
var
  Port: Integer;
  Client: TAgeH2Client;
  LastId, Code: LongWord;
begin
  // the idle timeout of 60 s never fires here, so only the age sweep of
  // 1000 ms can retire the connection
  Port := StartAgeServer(TEchoHandler.Create, AgeMs, 10000);
  Client := TAgeH2Client.Create(Port);
  try
    Client.SendPrologue;
    AssertTrue('the server sent no GOAWAY after the age',
      Client.WaitForGoAway(CloseTimeoutMs, LastId, Code));
    AssertEquals('the GOAWAY carries NO_ERROR', 0, LongInt(Code));
    AssertTrue('the socket did not close after the GOAWAY',
      Client.WaitClosed(CloseTimeoutMs));
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestSlowH2CompletesThenCloses;
var
  Port: Integer;
  Client: TAgeH2Client;
  Body: TBytes;
  LastId, Code: LongWord;
begin
  // the handler answers after 2500 ms, so the sweep retires the connection
  // first and the stream still completes
  Port := StartAgeServer(TSlowHandler.Create(2500), AgeMs, 15000);
  Client := TAgeH2Client.Create(Port);
  try
    Client.SendPrologue;
    Client.SendGet(1, '/slow');
    AssertTrue('the slow stream never completed',
      Client.WaitForBody(1, BodyTimeoutMs, Body));
    AssertTrue('the slow stream ended empty', Length(Body) > 0);
    AssertTrue('the server sent no GOAWAY for the retired connection',
      Client.WaitForGoAway(CloseTimeoutMs, LastId, Code));
    AssertEquals('the GOAWAY carries NO_ERROR', 0, LongInt(Code));
    AssertTrue('the socket did not close after the stream',
      Client.WaitClosed(CloseTimeoutMs));
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestBlockingH2IsForceClosedPastGrace;
var
  Port: Integer;
  Handler: TAgeBlockingHandler;
  HandlerRef: IHttp2Handler;
  Client: TAgeH2Client;
  Body: TBytes;
  LastId, Code: LongWord;
begin
  // the handler never answers, so the sweep retires the connection and the
  // forced close ends it past the grace time of 1500 ms
  Handler := TAgeBlockingHandler.Create;
  HandlerRef := Handler;
  Port := StartAgeServer(HandlerRef, AgeMs, GraceMs);
  Client := TAgeH2Client.Create(Port);
  try
    Client.SendPrologue;
    Client.SendGet(1, '/block');
    AssertTrue('the blocking handler never started',
      WaitFor(Handler.IsStarted, 5000));
    AssertTrue('the server sent no GOAWAY before the forced close',
      Client.WaitForGoAway(CloseTimeoutMs, LastId, Code));
    AssertTrue('the socket was not force-closed past the grace time',
      Client.WaitClosed(10000));
    AssertFalse('a cut stream must not complete',
      Client.WaitForBody(1, 500, Body));
  finally
    Client.Free;
    Handler.Release;
  end;
end;

procedure TConnectionAgeTest.TestIdleH1IsClosedAfterTheAge;
var
  Port: Integer;
  Client: TRawHttp;
  R: TRawResponse;
begin
  Port := StartAgeServer(TEchoHandler.Create, AgeMs, 10000);
  Client := TRawHttp.Create(Port);
  try
    Client.Send('GET /echo HTTP/1.1'#13#10'Host: 127.0.0.1'#13#10 +
      'Connection: keep-alive'#13#10#13#10);
    AssertTrue('the first keep-alive answer never arrived',
      Client.ReadResponse(False, BodyTimeoutMs, R));
    AssertEquals('the first answer is no 200', 200, R.Status);
    // the sweep drains the idle connection past the age, so a second
    // request gets no answer instead of waiting for the idle timeout
    Sleep(3000);
    Client.Send('GET /echo HTTP/1.1'#13#10'Host: 127.0.0.1'#13#10 +
      'Connection: keep-alive'#13#10#13#10);
    AssertFalse('the idle socket stayed open past the age',
      Client.ReadResponse(False, CloseTimeoutMs, R));
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestSlowH1AnswersConnectionClose;
var
  Port: Integer;
  Client: TRawHttp;
  R: TRawResponse;
begin
  // the handler answers after 2500 ms, so the sweep drains the connection
  // first and the response carries Connection: close
  Port := StartAgeServer(TSlowHandler.Create(2500), AgeMs, 15000);
  Client := TRawHttp.Create(Port);
  try
    Client.Send('GET /slow HTTP/1.1'#13#10'Host: 127.0.0.1'#13#10 +
      'Connection: keep-alive'#13#10#13#10);
    AssertTrue('the slow answer never arrived',
      Client.ReadResponse(False, BodyTimeoutMs, R));
    AssertEquals('the answer is no 200', 200, R.Status);
    AssertTrue('the answer carries no Connection: close',
      SameText(R.Header('connection'), 'close'));
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestAgeZeroStaysOpen;
var
  Port: Integer;
  Client: TAgeH2Client;
  Body: TBytes;
  I: Integer;
begin
  // the sweep returns at once with the age off, so a connection older than
  // the whole test period still serves
  Port := StartAgeServer(TEchoHandler.Create, 0, 10000);
  Client := TAgeH2Client.Create(Port);
  try
    Client.SendPrologue;
    for I := 1 to 6 do
      Sleep(500);
    Client.SendGet(1, '/echo');
    AssertTrue('the old connection no longer serves',
      Client.WaitForBody(1, BodyTimeoutMs, Body));
    AssertFalse('a connection with the age off must not close',
      Client.IsClosed);
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestRetireRaisesTheObserverEvents;
var
  Port: Integer;
  Client: TAgeH2Client;
  Observer: TAgeRecordingObserver;
  ObserverRef: IHttp2ServerObserver;
  LastId, Code: LongWord;
  Retired: TArray<TServerEvent>;
  GoAways: TArray<TServerEvent>;
  Deadline: QWord;
begin
  Port := StartAgeServer(TEchoHandler.Create, AgeMs, 10000);
  Observer := TAgeRecordingObserver.Create;
  ObserverRef := Observer;
  FServer.Observer := ObserverRef;
  Client := TAgeH2Client.Create(Port);
  try
    Client.SendPrologue;
    AssertTrue('the server sent no GOAWAY after the age',
      Client.WaitForGoAway(CloseTimeoutMs, LastId, Code));
    Deadline := GetTickCount64 + 10000;
    repeat
      Retired := Observer.EventsOf(seConnectionRetired);
      GoAways := Observer.EventsOf(seGoAwaySent);
      if (Length(Retired) = 1) and (Length(GoAways) >= 1) then
        Break;
      Sleep(50);
    until GetTickCount64 >= Deadline;
    Retired := Observer.EventsOf(seConnectionRetired);
    GoAways := Observer.EventsOf(seGoAwaySent);
    AssertEquals('one retire event per connection', 1, Length(Retired));
    AssertEquals('the retire names stream zero', 0, Retired[0].StreamId);
    AssertEquals('the detail names the maximum age', RetireDetailMaxAge,
      Retired[0].Detail);
    AssertTrue('no seGoAwaySent beside the retire', Length(GoAways) >= 1);
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestH1WebSocketStaysOpenPastAgeAndGrace;
var
  Port: Integer;
  Client: TRawHttp;
  R: TRawResponse;
begin
  // the upgraded connection is exempt: it stays open past the age of
  // 1000 ms and past the grace time of 1500 ms
  Port := StartWsServer(AgeMs, GraceMs);
  Client := TRawHttp.Create(Port);
  try
    Client.Send('GET /ws HTTP/1.1'#13#10'Host: localhost'#13#10 +
      'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='#13#10 +
      'Sec-WebSocket-Version: 13'#13#10#13#10);
    AssertTrue('the upgrade never answered 101',
      Client.ReadHead(5000, R));
    AssertEquals('the answer is no 101', 101, R.Status);
    AgeSendFrame(Client, ClientText('hello'));
    AssertTrue('the session never saw the first message',
      WaitUntilText(FRecording, 'msg T hello'));
    Sleep(6000);
    AgeSendFrame(Client, ClientText('again'));
    AssertTrue('the session ended past age and grace',
      WaitUntilText(FRecording, 'msg T again'));
  finally
    Client.Free;
  end;
end;

procedure TConnectionAgeTest.TestH2WebSocketStaysOpenThenRetires;
var
  Port: Integer;
  Client: TAgeH2Client;
  Fields: THeaderBlock;
  LastId, Code: LongWord;
  I: Integer;
  Status: string;
begin
  // the open WebSocket stream owns the connection past the age and past
  // the grace time; after the stream ends the sweep retires it
  Port := StartWsServer(AgeMs, GraceMs);
  Client := TAgeH2Client.Create(Port);
  try
    Client.SendPrologue;
    Client.SendConnect(1, '/ws');
    AssertTrue('the handshake never answered',
      Client.WaitForHeaders(1, 5000, Fields));
    Status := '';
    for I := 0 to High(Fields) do
      if Fields[I].Name = ':status' then
        Status := Fields[I].Value;
    AssertEquals('the handshake answers 200', '200', Status);
    Sleep(6000);
    AssertFalse('the server retired the open WebSocket stream',
      Client.GoAwaySeen(LastId, Code));
    AssertFalse('the exempt connection closed past age and grace',
      Client.IsClosed);
    Client.SendRst(1, ecCancel);
    AssertTrue('the server sent no GOAWAY after the stream ended',
      Client.WaitForGoAway(CloseTimeoutMs, LastId, Code));
    AssertEquals('the GOAWAY carries NO_ERROR', 0, LongInt(Code));
    AssertTrue('the socket did not close after the stream ended',
      Client.WaitClosed(CloseTimeoutMs));
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTest(TAgeExpiredTest);
  RegisterTest(TConnectionAgeTest);

end.
