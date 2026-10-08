{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, lifecycle, observer, stats
notes:
  - Tests for the public server lifecycle in Http2Server.Server.
  - The lifecycle tests start a real cleartext server on a loopback port and
    speak h2c with the copied frame builders.
  - A collect observer records every event it receives.  The observer counters
    and the server statistics are checked against the events that the server
    raises.
  - Build with invalid settings raises EServerConfigError and names every
    problem in one message.
---
}
/// Lifecycle tests for Http2Server.Server and Http2Server.Observer
unit Http2Server.Server.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.base,
  mormot.core.os,
  mormot.net.sock,
  Http2Server,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Headers;

type
  /// a handler that answers every request with one body
  TServerTestHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// an observer that keeps every event it receives
  TCollectObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FEvents: TList<TServerEvent>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    /// how many events of AKind the observer received
    function CountOf(const AKind: TServerEventKind): Integer;
    /// the whole event list, copied under the lock
    function Snapshot: TArray<TServerEvent>;
  end;

  /// a raw h2c client over a blocking socket
  TLifecycleClient = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
    FBuf: RawByteString;
    procedure Pump(const AWaitMs: Integer);
    function TakeFrame(out AFrame: TFrame): Boolean;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    procedure SendGet(const AStreamId: LongWord; const APath: string);
    function WaitForResponse(const AStreamId: LongWord;
      const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
    /// TRUE once the peer closed the socket within ATimeoutMs
    function PeerClosed(const ATimeoutMs: Integer): Boolean;
    /// wait for an RST_STREAM on AStreamId, and answer its error code
    // - FALSE means no reset arrived within the deadline
    function WaitForReset(const AStreamId: LongWord;
      const ATimeoutMs: Integer; out AErrorCode: THttp2ErrorCode): Boolean;
  end;

  /// the lifecycle tests of the public server
  TServerLifecycleTest = class(TTestCase)
  published
    /// Start twice and Stop twice are safe
    procedure TestStartAndStopAreIdempotent;
    /// a request is served on a started server, and Stop ends it
    procedure TestServeThenStop;
    /// a factory port of 0 answers the bound port
    procedure TestPortZeroAnswersBoundPort;
    /// the observer receives the connection, stream and completion events
    procedure TestObserverReceivesLifecycleEvents;
    /// the observer receives the refusal event on a full queue
    procedure TestObserverReceivesQueueRefusal;
    /// a refused request is answered with RST_STREAM/REFUSED_STREAM
    procedure TestQueueRefusalSendsRstStream;
    /// the statistics answer a truthful gauge and the totals
    procedure TestStatsCounters;
    /// Build with invalid settings raises and names every problem
    procedure TestBuildWithInvalidSettingsRaises;
    /// a stopped server raises on a second Start
    procedure TestStartAfterStopRaises;
  end;

implementation

const
  ResponseBody = 'the lifecycle response';
  ResponseTimeoutMs = 5000;
  IoTimeoutMs = 4000;

/// the raw bytes of a text literal, in the default code page
function BytesOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

/// the text of a byte array, in the default code page
function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

/// append B to A and answer the joined array
function ConcatBytes(const A, B: TBytes): TBytes;
begin
  Result := A;
  if Length(B) = 0 then
    Exit;
  SetLength(Result, Length(A) + Length(B));
  Move(B[0], Result[Length(A)], Length(B));
end;

/// serialize one frame to the wire bytes of the frame
function FrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

{ TServerTestHandler }

procedure TServerTestHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(BytesOf(ResponseBody));
  AResponse.Finish;
end;

{ TCollectObserver }

constructor TCollectObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEvents := TList<TServerEvent>.Create;
end;

destructor TCollectObserver.Destroy;
begin
  FEvents.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TCollectObserver.OnEvent(const AEvent: TServerEvent);
begin
  // the observer runs on the thread that raised the event, so the list needs
  // its own lock
  FLock.Acquire;
  try
    FEvents.Add(AEvent);
  finally
    FLock.Release;
  end;
end;

function TCollectObserver.CountOf(const AKind: TServerEventKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to FEvents.Count - 1 do
      if FEvents[I].Kind = AKind then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TCollectObserver.Snapshot: TArray<TServerEvent>;
begin
  Result := nil;
  FLock.Acquire;
  try
    Result := FEvents.ToArray;
  finally
    FLock.Release;
  end;
end;

{ TLifecycleClient }

constructor TLifecycleClient.Create(const APort: Integer);
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, IoTimeoutMs);
end;

destructor TLifecycleClient.Destroy;
begin
  FSock.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure TLifecycleClient.Pump(const AWaitMs: Integer);
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

function TLifecycleClient.TakeFrame(out AFrame: TFrame): Boolean;
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
begin
  Result := False;
  if Length(FBuf) < FrameHeaderSize then
    Exit;
  SetLength(HeaderBytes, FrameHeaderSize);
  Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
  Header := TFrameHeader.ReadFrom(HeaderBytes);
  N := FrameHeaderSize + Integer(Header.Length);
  if Length(FBuf) < N then
    Exit;
  SetLength(AFrame.Payload, Header.Length);
  if Header.Length > 0 then
    Move(FBuf[FrameHeaderSize + 1], AFrame.Payload[0], Header.Length);
  AFrame.Header := Header;
  FBuf := Copy(FBuf, N + 1, MaxInt);
  Result := True;
end;

procedure TLifecycleClient.SendGet(const AStreamId: LongWord;
  const APath: string);
var
  Wire: TBytes;
  Fields: THeaderBlock;
  Encoded: TBytes;
  Bytes: TBytes;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Bytes := FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults));
  Wire := ConcatBytes(Wire, Bytes);
  SetLength(Fields, 4);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := 'GET';
  Fields[1].Name := HeaderPath;
  Fields[1].Value := APath;
  Fields[2].Name := HeaderScheme;
  Fields[2].Value := 'http';
  Fields[3].Name := HeaderAuthority;
  Fields[3].Value := '127.0.0.1';
  Encoded := FCodec.Encode(Fields);
  Bytes := FrameBytes(BuildHeadersFrame(AStreamId, Encoded, True, True));
  Wire := ConcatBytes(Wire, Bytes);
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

function TLifecycleClient.WaitForResponse(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
  Got: TBytes;
begin
  Result := False;
  ABody := nil;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Pump(50);
    while TakeFrame(Frame) do
      if (Frame.Header.FrameType = ftData) and
         (Frame.Header.StreamId = AStreamId) then
      begin
        Got := ExtractDataPayload(Frame);
        if Length(Got) > 0 then
        begin
          ABody := ConcatBytes(ABody, Got);
          if Frame.IsEndStream then
            Exit(True);
        end
        else if Frame.IsEndStream then
          Exit(Length(ABody) > 0);
      end;
  end;
end;

function TLifecycleClient.WaitForReset(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out AErrorCode: THttp2ErrorCode): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
  Code: THttp2ErrorCode;
begin
  Result := False;
  AErrorCode := ecNoError;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Pump(50);
    while TakeFrame(Frame) do
      if (Frame.Header.FrameType = ftRstStream) and
         (Frame.Header.StreamId = AStreamId) then
      begin
        ParseRstStream(Frame, Code);
        AErrorCode := Code;
        Exit(True);
      end;
  end;
end;

function TLifecycleClient.PeerClosed(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Pending: TCrtSocketPending;
begin
  Result := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Pending := FSock.SockReceivePending(100);
    if Pending in [cspSocketError, cspSocketClosed,
       cspDataAvailableOnClosedSocket] then
      Exit(True);
    Sleep(50);
  end;
end;

{ TServerLifecycleTest }

/// the cleartext factory that every test starts from
function CleartextFactory(const AHandler: IHttp2Handler): THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500);
end;

procedure TServerLifecycleTest.TestStartAndStopAreIdempotent;
var
  Server: IHttp2Server;
begin
  Server := CleartextFactory(TServerTestHandler.Create).Build;
  Server.Start;
  Server.Start;
  AssertTrue('the server runs after two starts', Server.IsRunning);
  Server.Stop;
  Server.Stop;
  AssertFalse('the server is stopped after two stops', Server.IsRunning);
end;

procedure TServerLifecycleTest.TestServeThenStop;
var
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Port: Integer;
  Body: TBytes;
begin
  Server := CleartextFactory(TServerTestHandler.Create).Build;
  Server.Start;
  Port := Server.Port;
  Client := TLifecycleClient.Create(Port);
  try
    Client.SendGet(1, '/life');
    AssertTrue('the response did not arrive',
      Client.WaitForResponse(1, ResponseTimeoutMs, Body));
    AssertEquals(ResponseBody, TextOf(Body));
  finally
    Client.Free;
  end;
  Server.Stop;
end;

procedure TServerLifecycleTest.TestPortZeroAnswersBoundPort;
var
  Server: IHttp2Server;
begin
  Server := CleartextFactory(TServerTestHandler.Create).Build;
  Server.Start;
  AssertTrue('a factory port of 0 answers a real port', Server.Port > 0);
  Server.Stop;
end;

procedure TServerLifecycleTest.TestObserverReceivesLifecycleEvents;
var
  Observer: TCollectObserver;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
begin
  Observer := TCollectObserver.Create;
  Server := CleartextFactory(TServerTestHandler.Create).Build(Observer);
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/events');
    Client.WaitForResponse(1, ResponseTimeoutMs, Body);
    // the completion happens on a handler thread, so give it a moment
    Sleep(200);
    AssertTrue('the accepted event did not arrive',
      Observer.CountOf(seConnectionAccepted) >= 1);
    AssertTrue('the stream-opened event did not arrive',
      Observer.CountOf(seStreamOpened) >= 1);
    AssertTrue('the completion event did not arrive',
      Observer.CountOf(seStreamCompleted) >= 1);
  finally
    Client.Free;
  end;
  Server.Stop;
  AssertTrue('the GOAWAY event did not arrive',
    Observer.CountOf(seGoAwaySent) >= 1);
end;

procedure TServerLifecycleTest.TestObserverReceivesQueueRefusal;
var
  Observer: TCollectObserver;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Refused: Boolean;
  Kind: TServerEventKind;
  Events: TArray<TServerEvent>;
  I: Integer;
begin
  Observer := TCollectObserver.Create;
  // depth 0 refuses every request at once, so the refusal event is certain
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TServerTestHandler.Create)
    .WithHandlerThreads(2)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .Build(Observer);
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/refused');
    Sleep(400);
  finally
    Client.Free;
  end;
  Server.Stop;
  Events := Observer.Snapshot;
  Refused := False;
  for I := 0 to High(Events) do
  begin
    Kind := Events[I].Kind;
    if (Kind = seQueueFull) or (Kind = seStreamRefused) then
      Refused := True;
  end;
  AssertTrue('the refusal event did not arrive', Refused);
end;

procedure TServerLifecycleTest.TestQueueRefusalSendsRstStream;
var
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Code: THttp2ErrorCode;
begin
  // depth 0 refuses every request, so the RST_STREAM is certain.  A refusal
  // event alone does not prove that the peer learned of the refusal, so this
  // test reads the frame itself.
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TServerTestHandler.Create)
    .WithHandlerThreads(2)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/refused');
    AssertTrue('the refused stream got no RST_STREAM',
      Client.WaitForReset(1, 2000, Code));
    AssertTrue('the reset names the wrong error code',
      Code = ecRefusedStream);
  finally
    Client.Free;
  end;
  Server.Stop;
end;

procedure TServerLifecycleTest.TestStatsCounters;
var
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Stats: TServerStats;
  Body: TBytes;
begin
  Server := CleartextFactory(TServerTestHandler.Create).Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/stats');
    AssertTrue('the response did not arrive',
      Client.WaitForResponse(1, ResponseTimeoutMs, Body));
    Stats := Server.Stats;
    AssertTrue('one connection is open', Stats.OpenConnections >= 1);
    AssertEquals('a served request refused nothing', 0, Stats.RefusedTotal);
  finally
    Client.Free;
  end;
  // Stop closes every connection, so the gauge is readable with no wait on
  // the idle sweep of the library
  Server.Stop;
  Stats := Server.Stats;
  AssertEquals('no connection is open after a stop', 0,
    Stats.OpenConnections);
  AssertEquals('no stream is open after a stop', 0, Stats.OpenStreams);
  AssertEquals('no handler runs after a stop', 0, Stats.BusyHandlers);
  AssertEquals('the queue is empty after a stop', 0, Stats.QueueLength);
end;

procedure TServerLifecycleTest.TestBuildWithInvalidSettingsRaises;
var
  Factory: THttp2ServerFactory;
  Raised: Boolean;
  Text: string;
begin
  Factory := THttp2ServerFactory.Create
    .WithPort(-1)
    .WithIOThreads(0)
    .WithHandlerThreads(0);
  Raised := False;
  Text := '';
  try
    Factory.Build;
  except
    on E: EServerConfigError do
    begin
      Raised := True;
      Text := E.Message;
    end;
  end;
  AssertTrue('invalid settings did not raise', Raised);
  AssertTrue('the port problem is named', Pos('port', Text) > 0);
  AssertTrue('the IO thread problem is named', Pos('IO thread', Text) > 0);
  AssertTrue('the handler thread problem is named',
    Pos('handler thread', Text) > 0);
end;

procedure TServerLifecycleTest.TestStartAfterStopRaises;
var
  Server: IHttp2Server;
  Raised: Boolean;
begin
  Server := CleartextFactory(TServerTestHandler.Create).Build;
  Server.Start;
  Server.Stop;
  Raised := False;
  try
    Server.Start;
  except
    on E: EServerStopped do
      Raised := True;
  end;
  AssertTrue('a start after a stop did not raise', Raised);
end;

initialization
  RegisterTest(TServerLifecycleTest);

end.
