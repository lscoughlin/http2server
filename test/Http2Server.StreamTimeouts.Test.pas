{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream, timeout, test, fpcunit
notes:
  - Tests for the stream read and write timeouts of the server.
  - The factory maps both timeouts to the connection core options, and each
    new stream of a connection takes them from the options.
  - The live tests use the real clock with a wide margin and a poll, never a
    fixed sleep.
---
}
/// Stream timeout tests for Http2Server.Async.Options and NewStream
unit Http2Server.StreamTimeouts.Test;

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
  Http2Server.Headers, Http2Server.Config, Http2Server.Config.Limits,
  Http2Server.Seam, Http2Server.Stream, Http2Server.Connection,
  Http2Server.Connection.Core,
  Http2Server.Async, Http2Server.Async.Options;

type
  /// the outcome of one handler run, shared with the test thread
  TTimeoutOutcome = class
  private
    FLock: TCriticalSection;
    FDone: Boolean;
    FErrorClass: string;
    FElapsedMs: QWord;
  public
    constructor Create;
    destructor Destroy; override;
    /// record the end of the handler run
    procedure SetResult(const AErrorClass: string; const AElapsedMs: QWord);
    /// true once the handler run ended, with its outcome
    function TryGet(out AErrorClass: string; out AElapsedMs: QWord): Boolean;
  end;

  /// a handler that reads the whole request body and records the outcome
  TTimeoutReadHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FOutcome: TTimeoutOutcome;
  public
    constructor Create(const AOutcome: TTimeoutOutcome);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a handler that writes a large body and records the outcome
  TTimeoutWriteHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FOutcome: TTimeoutOutcome;
  public
    constructor Create(const AOutcome: TTimeoutOutcome);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// one raw h2c client over a blocking socket
  TTimeoutClient = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// send the preface and one SETTINGS frame with the given window
    procedure SendPreface(const AInitialWindow: LongWord);
    /// send one HEADERS frame on AStreamId
    procedure SendHeaders(const AStreamId: LongWord; const AMethod,
      APath: string; const AEndStream: Boolean);
  end;

  /// the stream timeout tests of the server
  TStreamTimeoutsTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    FOutcome: TTimeoutOutcome;
    function StartServer(const AHandler: IHttp2Handler;
      const AReadMs, AWriteMs: Integer): Integer;
    procedure StopServer;
    /// true once the handler run ended, within ATimeoutMs
    function WaitOutcome(const ATimeoutMs: Integer; out AErrorClass: string;
      out AElapsedMs: QWord): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFactoryMapsStreamTimeouts;
    procedure TestBareStreamDefaultsMatchFactory;
    procedure TestReadTimeoutFires;
    procedure TestWriteTimeoutFires;
  end;

implementation

const
  /// the timeout both live tests configure, in milliseconds
  cLiveTimeoutMs = 200;
  /// the lowest elapsed time that still counts as "about 200 ms"
  cElapsedFloorMs = 100;
  /// the highest elapsed time that still counts; the old default of 30000
  /// lies far above it, so a missed mapping fails here
  cElapsedCeilingMs = 10000;

{ TTimeoutOutcome }

constructor TTimeoutOutcome.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TTimeoutOutcome.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TTimeoutOutcome.SetResult(const AErrorClass: string;
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

function TTimeoutOutcome.TryGet(out AErrorClass: string;
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

{ TTimeoutReadHandler }

constructor TTimeoutReadHandler.Create(const AOutcome: TTimeoutOutcome);
begin
  inherited Create;
  FOutcome := AOutcome;
end;

procedure TTimeoutReadHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: array[0..8191] of Byte;
  Start: QWord;
begin
  Start := GetTickCount64;
  try
    while ARequest.Read(Buf, SizeOf(Buf)) > 0 do
      ;
    FOutcome.SetResult('', GetTickCount64 - Start);
  except
    on E: Exception do
      FOutcome.SetResult(E.ClassName, GetTickCount64 - Start);
  end;
end;

{ TTimeoutWriteHandler }

constructor TTimeoutWriteHandler.Create(const AOutcome: TTimeoutOutcome);
begin
  inherited Create;
  FOutcome := AOutcome;
end;

procedure TTimeoutWriteHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Chunk: TBytes;
  I: Integer;
  Start: QWord;
begin
  SetLength(Chunk, 8192);
  FillChar(Chunk[0], Length(Chunk), 65);
  Start := GetTickCount64;
  try
    AResponse.SendHeaders(200, nil, False);
    // 64 chunks of 8 KB far exceed the 65535-byte stream buffer, so one
    // write blocks once the peer grants no window
    for I := 1 to 64 do
      AResponse.Write(Chunk);
    AResponse.Finish;
    FOutcome.SetResult('', GetTickCount64 - Start);
  except
    on E: Exception do
      FOutcome.SetResult(E.ClassName, GetTickCount64 - Start);
  end;
end;

{ TTimeoutClient }

constructor TTimeoutClient.Create(const APort: Integer);
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, 5000);
end;

destructor TTimeoutClient.Destroy;
begin
  FSock.Free;
  FCodec.Free;
  inherited Destroy;
end;

/// append B to A and answer the joined array
function TimeoutConcat(const A, B: TBytes): TBytes;
begin
  Result := A;
  if Length(B) = 0 then
    exit;
  SetLength(Result, Length(A) + Length(B));
  Move(B[0], Result[Length(A)], Length(B));
end;

/// serialize one frame to its wire bytes
function TimeoutFrameBytes(const AFrame: TFrame): TBytes;
begin
  Result := nil;
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize],
      Length(AFrame.Payload));
end;

procedure TTimeoutClient.SendPreface(const AInitialWindow: LongWord);
var
  Wire: TBytes;
  Settings: TConnectionSettings;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Settings := TConnectionSettings.Defaults;
  Settings.InitialWindowSize := AInitialWindow;
  Wire := TimeoutConcat(Wire, TimeoutFrameBytes(
    BuildSettingsFrame(Settings)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TTimeoutClient.SendHeaders(const AStreamId: LongWord;
  const AMethod, APath: string; const AEndStream: Boolean);
var
  Fields: THeaderBlock;
  Encoded, Wire: TBytes;
begin
  SetLength(Fields, 4);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := AMethod;
  Fields[1].Name := HeaderPath;
  Fields[1].Value := APath;
  Fields[2].Name := HeaderScheme;
  Fields[2].Value := 'http';
  Fields[3].Name := HeaderAuthority;
  Fields[3].Value := '127.0.0.1';
  Encoded := FCodec.Encode(Fields);
  Wire := TimeoutFrameBytes(BuildHeadersFrame(AStreamId, Encoded, True,
    AEndStream));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

{ TStreamTimeoutsTest }

procedure TStreamTimeoutsTest.SetUp;
begin
  inherited SetUp;
  FOutcome := TTimeoutOutcome.Create;
  FServer := nil;
end;

procedure TStreamTimeoutsTest.TearDown;
begin
  StopServer;
  FOutcome.Free;
  inherited TearDown;
end;

function TStreamTimeoutsTest.StartServer(const AHandler: IHttp2Handler;
  const AReadMs, AWriteMs: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithServerLimits(TServerLimits.Create
      .WithStreamReadTimeoutMs(AReadMs)
      .WithStreamWriteTimeoutMs(AWriteMs));
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  Result := FServer.BoundPort;
end;

procedure TStreamTimeoutsTest.StopServer;
begin
  FreeAndNil(FServer);
end;

function TStreamTimeoutsTest.WaitOutcome(const ATimeoutMs: Integer;
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
  Result := False;
end;

procedure TStreamTimeoutsTest.TestFactoryMapsStreamTimeouts;
var
  Factory: THttp2ServerFactory;
  Options: TConnectionCoreOptions;
begin
  Factory := THttp2ServerFactory.Create
    .WithHandler(TTimeoutReadHandler.Create(FOutcome))
    .WithClearTextAllowed(True)
    .WithServerLimits(TServerLimits.Create
      .WithStreamReadTimeoutMs(200)
      .WithStreamWriteTimeoutMs(400));
  Options := BuildConnectionCoreOptions(Factory);
  AssertEquals('the read timeout reaches the core', 200,
    Options.StreamReadTimeoutMs);
  AssertEquals('the write timeout reaches the core', 400,
    Options.StreamWriteTimeoutMs);
  Factory := THttp2ServerFactory.Create
    .WithHandler(TTimeoutReadHandler.Create(FOutcome))
    .WithClearTextAllowed(True);
  Options := BuildConnectionCoreOptions(Factory);
  AssertEquals('the default read timeout is 30000', 30000,
    Options.StreamReadTimeoutMs);
  AssertEquals('the default write timeout is 30000', 30000,
    Options.StreamWriteTimeoutMs);
end;

procedure TStreamTimeoutsTest.TestBareStreamDefaultsMatchFactory;
var
  Lock: TCriticalSection;
  Stream: TServerStream;
  Limits: TServerLimits;
begin
  // a bare stream keeps the stream constants, and the factory keeps its own
  // defaults; the two agree, so a unit test sees the same deadlines as a
  // server with default settings
  Limits := TServerLimits.Create;
  Lock := TCriticalSection.Create;
  try
    Stream := TServerStream.Create(1, Lock, nil, 65536, 65536);
    try
      AssertEquals('the bare read deadline matches the factory default',
        Limits.StreamReadTimeoutMs, Stream.ReadTimeoutMs);
      AssertEquals('the bare write deadline matches the factory default',
        Limits.StreamWriteTimeoutMs, Stream.WriteTimeoutMs);
    finally
      Stream.Free;
    end;
  finally
    Lock.Free;
  end;
end;

procedure TStreamTimeoutsTest.TestReadTimeoutFires;
var
  Port: Integer;
  Client: TTimeoutClient;
  ErrorClass: string;
  Elapsed: QWord;
begin
  Port := StartServer(TTimeoutReadHandler.Create(FOutcome),
    cLiveTimeoutMs, 30000);
  Client := TTimeoutClient.Create(Port);
  try
    // a POST without END_STREAM and without a body: the handler read waits
    // for octets that never arrive, and the socket stays open, so no
    // cancellation ends the wait before the deadline
    Client.SendPreface(65535);
    Client.SendHeaders(1, 'POST', '/upload', False);
    AssertTrue('the handler read ended within the poll time',
      WaitOutcome(15000, ErrorClass, Elapsed));
    AssertEquals('the read ends with EHttpTimeout', 'EHttpTimeout',
      ErrorClass);
    AssertTrue('the read waited about 200 ms, not 0 ms (' +
      IntToStr(Elapsed) + ' ms)', Elapsed >= cElapsedFloorMs);
    AssertTrue('the read waited about 200 ms, not 30000 ms (' +
      IntToStr(Elapsed) + ' ms)', Elapsed <= cElapsedCeilingMs);
  finally
    Client.Free;
  end;
end;

procedure TStreamTimeoutsTest.TestWriteTimeoutFires;
var
  Port: Integer;
  Client: TTimeoutClient;
  ErrorClass: string;
  Elapsed: QWord;
begin
  Port := StartServer(TTimeoutWriteHandler.Create(FOutcome),
    30000, cLiveTimeoutMs);
  Client := TTimeoutClient.Create(Port);
  try
    // a peer window of 0: the client grants no stream window and sends no
    // WINDOW_UPDATE, so the stream buffer never drains and one handler
    // write waits past the deadline
    Client.SendPreface(0);
    Client.SendHeaders(1, 'GET', '/large', True);
    AssertTrue('the handler write ended within the poll time',
      WaitOutcome(15000, ErrorClass, Elapsed));
    AssertEquals('the write ends with EHttpTimeout', 'EHttpTimeout',
      ErrorClass);
    AssertTrue('the write waited about 200 ms, not 0 ms (' +
      IntToStr(Elapsed) + ' ms)', Elapsed >= cElapsedFloorMs);
    AssertTrue('the write waited about 200 ms, not 30000 ms (' +
      IntToStr(Elapsed) + ' ms)', Elapsed <= cElapsedCeilingMs);
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTest(TStreamTimeoutsTest);

end.
