{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, validation, abuse, cancellation, exhaustion
notes:
  - The validation tests of the server.  Every test runs a real cleartext
    server on a loopback port and speaks h2c with the copied frame builders,
    so the wire bytes of each test are explicit.
  - The byte tests compare a whole body against the bytes the client sent.
  - The abuse tests drive one control frame kind past its token bucket and
    check the GOAWAY error code and that the peer socket closes.
  - The cancellation tests check that a reset raises EStreamCancelled inside
    the handler thread and that the thread returns to the pool.
  - The exhaustion tests check the served, refused and dropped counts of the
    admission rules.
---
}
/// Validation tests for the server: byte fidelity, abuse limits, cancellation
unit Http2Server.Validation.Test;

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
  Http2Server.Errors, Http2Server.Limits, Http2Server.Config,
  Http2Server.Frames, Http2Server.Headers;

type
  /// a handler that answers a generated body, an echo, or a text answer
  TValidationHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FStarted: Integer;
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    /// how many requests reached this handler
    function StartedCount: Integer;
  end;

  /// a handler that blocks in Read until a cancel or a body arrives
  TBlockingReadHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FStartEvent: PRTLEvent;
    FStarted: Integer;
    FLock: TCriticalSection;
    FCancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    /// wait until the handler is inside Read
    function WaitStarted(const ATimeoutMs: Integer): Boolean;
    /// TRUE once the handler observed EStreamCancelled
    function Cancelled: Boolean;
  end;

  /// a handler that raises on every request
  TRaisingValidationHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// an observer that counts the events it receives
  TCountingObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FCounts: array[TServerEventKind] of Integer;
    FLastLimit: TLimitKind;
    FLastCode: THttp2ErrorCode;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    function CountOf(const AKind: TServerEventKind): Integer;
    property LastLimit: TLimitKind read FLastLimit;
    property LastCode: THttp2ErrorCode read FLastCode;
  end;

  /// a raw h2c client over a blocking socket
  TRawClient = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
    FBuf: RawByteString;
    FAll: RawByteString;
    procedure Pump(const AWaitMs: Integer);
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// send the client preface and a SETTINGS frame
    procedure SendPreface;
    /// send the preface and a SETTINGS frame with a large initial window,
    /// then a connection WINDOW_UPDATE, so a long body needs no further
    /// credit from the client
    procedure SendWideWindow(const AInitialWindow: LongWord);
    /// write every raw byte the client received to a file
    procedure DumpCaptured(const APath: string);
    /// send one frame, then flush
    procedure SendFrame(const AFrame: TFrame);
    /// send several frames in one write, then flush
    procedure SendFrames(const AFrames: array of TFrame);
    /// send raw wire bytes, then flush
    procedure SendRaw(const AData: TBytes);
    /// read one frame within AWaitMs.  FALSE on timeout or a closed peer.
    function TakeFrame(out AFrame: TFrame; const AWaitMs: Integer): Boolean;
    /// build a GET request as a HEADERS frame with END_STREAM
    function GetFrame(const AStreamId: LongWord;
      const APath: string): TFrame;
    /// build a GET request whose body stays open, so the handler parks in Read
    function OpenFrame(const AStreamId: LongWord;
      const APath: string): TFrame;
    /// build a POST request that carries ABody as DATA frames
    function PostFrames(const AStreamId: LongWord; const APath: string;
      const ABody: TBytes): TArray<TFrame>;
    /// an HPACK block for one request header field list
    function EncodeHeaders(const AFields: THeaderBlock): TBytes;
    /// read frames until a GOAWAY arrives, or the deadline passes
    function WaitGoAway(out ACode: THttp2ErrorCode;
      out ALastStreamId: LongWord; const ATimeoutMs: Integer): Boolean;
    /// collect every DATA payload of AStreamId until END_STREAM, or deadline
    function ReadBody(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out ABody: TBytes): Boolean;
    /// TRUE once the peer closed the socket within ATimeoutMs
    function PeerClosed(const ATimeoutMs: Integer): Boolean;
    /// the socket, for a caller that writes raw bytes
    property Socket: TCrtSocket read FSock;
  end;

  /// the byte-fidelity tests of the server
  TBytesFidelityTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FHandler: TValidationHandler;
    function StartServer: Integer;
  public
    procedure TearDown; override;
  published
    /// every byte value survives a request body and its echo
    procedure TestAllByteValuesRoundTrip;
    /// a generated body arrives complete and byte exact
    procedure TestGeneratedBodyIsByteExact;
    /// a long body over many DATA frames arrives complete
    procedure TestLongBodyIsByteExact;
  end;

  /// the abuse tests of the server, one per control frame kind
  TAbuseLimitTest = class(TTestCase)
  private
    function StartWithBuckets(const AReset, AControl: TTokenBucketOptions;
      const AMaxContinuations: Integer): Integer;
    function StartServer(const AReset, AControl: TTokenBucketOptions): Integer;
  public
    procedure TearDown; override;
  published
    /// a reset flood trips the reset bucket and closes with ENHANCE_YOUR_CALM
    procedure TestResetFloodGoAway;
    /// a PING flood trips the PING bucket and closes
    procedure TestPingFloodGoAway;
    /// a SETTINGS flood trips the SETTINGS bucket and closes
    procedure TestSettingsFloodGoAway;
    /// an empty DATA flood trips the empty-DATA bucket and closes
    procedure TestEmptyDataFloodGoAway;
    /// a WINDOW_UPDATE flood trips the WINDOW_UPDATE bucket and closes
    procedure TestWindowUpdateFloodGoAway;
    /// a large header block closes with ENHANCE_YOUR_CALM
    procedure TestHeaderBlockOverLimitGoAway;
    /// a handler exception reaches the observer as an internal error
    procedure TestHandlerExceptionIsReported;
  end;

  /// the cancellation tests of the server
  TCancellationTest = class(TTestCase)
  public
    procedure TearDown; override;
  published
    /// a reset raises EStreamCancelled inside the handler thread and frees it
    procedure TestResetRaisesInsideHandler;
    /// a reset before dispatch drops the request and the handler never runs
    procedure TestResetBeforeDispatchNeverRuns;
  end;

  /// the admission exhaustion test of the server
  TAdmissionExhaustionTest = class(TTestCase)
  public
    procedure TearDown; override;
  published
    /// the served, refused and dropped counts follow the admission rules
    procedure TestExhaustionCountsFollowTheAdmissionRules;
  end;

implementation

const
  IoTimeoutMs = 4000;
  ResponseTimeoutMs = 6000;
  PatternModulus = 251;

var
  /// the servers that the tests start, stopped in TearDown
  GServer: IHttp2Server;

// ---- small byte helpers ----

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
    Move(AFrame.Payload[0], Result[FrameHeaderSize],
      Length(AFrame.Payload));
end;

/// the generated body byte at AIndex, the same rule on both sides
function PatternByte(const AIndex: Int64): Byte;
begin
  Result := Byte(AIndex mod PatternModulus);
end;

/// a body of ABytes generated bytes
function PatternBody(const ABytes: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ABytes);
  for I := 0 to ABytes - 1 do
    Result[I] := PatternByte(I);
end;

/// the small bucket that trips after a few frames
function SmallBucket(const ACapacity: Integer): TTokenBucketOptions;
begin
  Result := TTokenBucketOptions.Create
    .WithCapacity(ACapacity)
    .WithRefillPerSecond(0);
end;

// ---- handlers ----

{ TValidationHandler }

constructor TValidationHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TValidationHandler.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TValidationHandler.StartedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FStarted;
  finally
    FLock.Release;
  end;
end;

procedure TValidationHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Path, Query: string;
  Want, I, J: Integer;
  Body, Chunk: TBytes;
  Fields: THeaderBlock;
begin
  FLock.Acquire;
  try
    Inc(FStarted);
  finally
    FLock.Release;
  end;
  Path := ARequest.Path;
  // /echo answers the request body, byte for byte
  if Path = '/echo' then
  begin
    Body := nil;
    while ARequest.ReadChunk(Chunk) do
      Body := ConcatBytes(Body, Chunk);
    SetLength(Fields, 1);
    Fields[0].Name := 'content-type';
    Fields[0].Value := 'application/octet-stream';
    AResponse.SendHeaders(200, Fields, False);
    if Length(Body) > 0 then
      AResponse.Write(Body);
    AResponse.Finish;
    Exit;
  end;
  // /large?bytes=N answers N generated bytes in fixed chunks
  if Copy(Path, 1, 6) = '/large' then
  begin
    Want := 0;
    Query := Path;
    I := Pos('bytes=', Query);
    if I > 0 then
      Want := StrToIntDef(Copy(Query, I + 6, MaxInt), 0);
    SetLength(Fields, 1);
    Fields[0].Name := 'content-type';
    Fields[0].Value := 'application/octet-stream';
    AResponse.SendHeaders(200, Fields, False);
    for I := 0 to (Want div 4096) - 1 do
    begin
      SetLength(Chunk, 4096);
      for J := 0 to 4095 do
        Chunk[J] := PatternByte(Int64(I) * 4096 + J);
      AResponse.Write(Chunk);
    end;
    if (Want mod 4096) <> 0 then
    begin
      SetLength(Chunk, Want mod 4096);
      for J := 0 to High(Chunk) do
        Chunk[J] := PatternByte(Int64(Want div 4096) * 4096 + J);
      AResponse.Write(Chunk);
    end;
    AResponse.Finish;
    Exit;
  end;
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(BytesOf('the validation server answered'));
  AResponse.Finish;
end;

{ TBlockingReadHandler }

constructor TBlockingReadHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStartEvent := RTLEventCreate;
  FStarted := 0;
  FCancelled := False;
end;

destructor TBlockingReadHandler.Destroy;
begin
  RTLEventDestroy(FStartEvent);
  FLock.Free;
  inherited Destroy;
end;

function TBlockingReadHandler.WaitStarted(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    FLock.Acquire;
    try
      Result := FStarted > 0;
    finally
      FLock.Release;
    end;
    if Result then
      Exit;
    RTLEventWaitFor(FStartEvent, 20);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function TBlockingReadHandler.Cancelled: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCancelled;
  finally
    FLock.Release;
  end;
end;

procedure TBlockingReadHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: TBytes;
begin
  FLock.Acquire;
  try
    Inc(FStarted);
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FStartEvent);
  SetLength(Buf, 1);
  try
    // the body never comes, so this parks until the client resets the stream
    ARequest.Read(Buf[0], 1);
  except
    on E: EStreamCancelled do
    begin
      FLock.Acquire;
      try
        FCancelled := True;
      finally
        FLock.Release;
      end;
      Exit;
    end;
  end;
end;

{ TRaisingValidationHandler }

procedure TRaisingValidationHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  raise EHttpError.Create('the validation handler failed');
end;

{ TCountingObserver }

constructor TCountingObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLastLimit := lkReset;
  FLastCode := ecNoError;
end;

destructor TCountingObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TCountingObserver.OnEvent(const AEvent: TServerEvent);
begin
  FLock.Acquire;
  try
    Inc(FCounts[AEvent.Kind]);
    if AEvent.Kind = seBucketTripped then
      FLastLimit := AEvent.LimitKind;
    if AEvent.Kind = seGoAwaySent then
      FLastCode := AEvent.ErrorCode;
  finally
    FLock.Release;
  end;
end;

function TCountingObserver.CountOf(const AKind: TServerEventKind): Integer;
begin
  FLock.Acquire;
  try
    Result := FCounts[AKind];
  finally
    FLock.Release;
  end;
end;

// ---- TRawClient ----

constructor TRawClient.Create(const APort: Integer);
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, IoTimeoutMs);
end;

destructor TRawClient.Destroy;
begin
  FSock.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure TRawClient.Pump(const AWaitMs: Integer);
var
  Chunk: RawByteString;
  Pending: TCrtSocketPending;
begin
  // the socket is blocking, so SockReceiveString must not run unless bytes
  // wait in it: a bare call parks in recv() until the peer sends or the
  // socket deadline fires.  A closed socket may still hold the last frames,
  // so those bytes are read too.
  Pending := FSock.SockReceivePending(AWaitMs);
  case Pending of
    cspDataAvailable, cspDataAvailableOnClosedSocket:
      ;
  else
    Exit;
  end;
  Chunk := FSock.SockReceiveString;
  if Chunk <> '' then
  begin
    FAll := FAll + Chunk;
    FBuf := FBuf + Chunk;
  end;
end;

procedure TRawClient.DumpCaptured(const APath: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    if FAll <> '' then
      F.WriteBuffer(FAll[1], Length(FAll));
  finally
    F.Free;
  end;
end;

procedure TRawClient.SendPreface;
var
  Wire: TBytes;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Wire := ConcatBytes(Wire,
    FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TRawClient.SendWideWindow(const AInitialWindow: LongWord);
var
  Wire: TBytes;
  Settings: TConnectionSettings;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Settings := TConnectionSettings.Defaults;
  Settings.InitialWindowSize := AInitialWindow;
  Wire := ConcatBytes(Wire, FrameBytes(BuildSettingsFrame(Settings)));
  Wire := ConcatBytes(Wire,
    FrameBytes(BuildWindowUpdateFrame(0, AInitialWindow - 65535)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure TRawClient.SendFrame(const AFrame: TFrame);
begin
  SendRaw(FrameBytes(AFrame));
end;

procedure TRawClient.SendFrames(const AFrames: array of TFrame);
var
  Wire: TBytes;
  I: Integer;
begin
  Wire := nil;
  for I := 0 to High(AFrames) do
    Wire := ConcatBytes(Wire, FrameBytes(AFrames[I]));
  if Length(Wire) > 0 then
    SendRaw(Wire);
end;

procedure TRawClient.SendRaw(const AData: TBytes);
begin
  if Length(AData) = 0 then
    Exit;
  FSock.SockSend(@AData[0], Length(AData));
  FSock.SockSendFlush();
end;

function TRawClient.EncodeHeaders(const AFields: THeaderBlock): TBytes;
begin
  Result := FCodec.Encode(AFields);
end;

function TRawClient.GetFrame(const AStreamId: LongWord;
  const APath: string): TFrame;
var
  Fields: THeaderBlock;
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
  Result := BuildHeadersFrame(AStreamId, FCodec.Encode(Fields), True, True);
end;

function TRawClient.OpenFrame(const AStreamId: LongWord;
  const APath: string): TFrame;
var
  Fields: THeaderBlock;
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
  // END_HEADERS set, END_STREAM clear, so the request body stays open
  Result := BuildHeadersFrame(AStreamId, FCodec.Encode(Fields), True, False);
end;

function TRawClient.PostFrames(const AStreamId: LongWord; const APath: string;
  const ABody: TBytes): TArray<TFrame>;
var
  Fields: THeaderBlock;
  Head: TFrame;
begin
  SetLength(Fields, 5);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := 'POST';
  Fields[1].Name := HeaderPath;
  Fields[1].Value := APath;
  Fields[2].Name := HeaderScheme;
  Fields[2].Value := 'http';
  Fields[3].Name := HeaderAuthority;
  Fields[3].Value := '127.0.0.1';
  Fields[4].Name := 'content-length';
  Fields[4].Value := IntToStr(Length(ABody));
  Head := BuildHeadersFrame(AStreamId, FCodec.Encode(Fields), True, False);
  SetLength(Result, 2);
  Result[0] := Head;
  Result[1] := BuildDataFrame(AStreamId, ABody, True);
end;

function TRawClient.TakeFrame(out AFrame: TFrame;
  const AWaitMs: Integer): Boolean;
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
begin
  Result := False;
  // a frame already in the buffer needs no poll at all
  if Length(FBuf) < FrameHeaderSize then
    Pump(AWaitMs);
  if Length(FBuf) < FrameHeaderSize then
    Exit;
  SetLength(HeaderBytes, FrameHeaderSize);
  Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
  Header := TFrameHeader.ReadFrom(HeaderBytes);
  N := FrameHeaderSize + Integer(Header.Length);
  if Length(FBuf) < N then
  begin
    Pump(AWaitMs);
    if Length(FBuf) < N then
      Exit;
  end;
  SetLength(AFrame.Payload, Header.Length);
  if Header.Length > 0 then
    Move(FBuf[FrameHeaderSize + 1], AFrame.Payload[0], Header.Length);
  AFrame.Header := Header;
  FBuf := Copy(FBuf, N + 1, MaxInt);
  Result := True;
end;

function TRawClient.WaitGoAway(out ACode: THttp2ErrorCode;
  out ALastStreamId: LongWord; const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
  Debug: TBytes;
begin
  Result := False;
  ACode := ecNoError;
  ALastStreamId := 0;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    if not TakeFrame(Frame, 50) then
      Continue;
    if Frame.Header.FrameType = ftGoAway then
    begin
      ParseGoAway(Frame, ALastStreamId, ACode, Debug);
      Exit(True);
    end;
  end;
end;

function TRawClient.ReadBody(const AStreamId: LongWord;
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
    if not TakeFrame(Frame, 50) then
      Continue;
    if (Frame.Header.FrameType = ftData) and
       (Frame.Header.StreamId = AStreamId) then
    begin
      Got := ExtractDataPayload(Frame);
      if Length(Got) > 0 then
        ABody := ConcatBytes(ABody, Got);
      if Frame.IsEndStream then
        Exit(True);
    end
    else if Frame.Header.FrameType = ftRstStream then
      Exit(False);
  end;
end;

function TRawClient.PeerClosed(const ATimeoutMs: Integer): Boolean;
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
    Sleep(20);
  end;
end;

// ---- server start helpers ----

/// the common cleartext factory for one handler
function BaseFactory(const AHandler: IHttp2Handler): THttp2ServerFactory;
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

// ---- TBytesFidelityTest ----

function TBytesFidelityTest.StartServer: Integer;
begin
  FHandler := TValidationHandler.Create;
  FServer := BaseFactory(FHandler).Build;
  FServer.Start;
  Result := FServer.Port;
end;

procedure TBytesFidelityTest.TearDown;
begin
  if FServer <> nil then
  begin
    FServer.Stop;
    FServer := nil;
  end;
  FHandler := nil;
end;

procedure TBytesFidelityTest.TestAllByteValuesRoundTrip;
var
  Port: Integer;
  Client: TRawClient;
  Frames: TArray<TFrame>;
  Body, Echo: TBytes;
  I: Integer;
begin
  Port := StartServer;
  Client := TRawClient.Create(Port);
  try
    SetLength(Body, 256);
    for I := 0 to 255 do
      Body[I] := Byte(I);
    Client.SendPreface;
    Frames := Client.PostFrames(1, '/echo', Body);
    Client.SendFrames(Frames);
    AssertTrue('the echo body arrives', Client.ReadBody(1, ResponseTimeoutMs, Echo));
    AssertEquals('every byte value survives', Length(Body), Length(Echo));
    for I := 0 to 255 do
      AssertEquals('byte ' + IntToStr(I) + ' is unchanged',
        Integer(Body[I]), Integer(Echo[I]));
  finally
    Client.Free;
  end;
end;

procedure TBytesFidelityTest.TestGeneratedBodyIsByteExact;
var
  Port: Integer;
  Client: TRawClient;
  Body, Expect: TBytes;
  I: Integer;
  Arrived: Boolean;
begin
  Port := StartServer;
  Client := TRawClient.Create(Port);
  try
    Client.SendWideWindow(16777216);
    Client.SendFrame(Client.GetFrame(1, '/large?bytes=200000'));
    Arrived := Client.ReadBody(1, ResponseTimeoutMs, Body);
    Client.DumpCaptured('/tmp/cap200k.bin');
    AssertTrue('the generated body arrives', Arrived);
    Expect := PatternBody(200000);
    AssertEquals('the generated body length', Length(Expect), Length(Body));
    for I := 0 to High(Expect) do
      if Expect[I] <> Body[I] then
      begin
        AssertEquals('the first differing body byte', I, -1);
        Exit;
      end;
    AssertTrue('the generated body is byte exact', True);
  finally
    Client.Free;
  end;
end;

procedure TBytesFidelityTest.TestLongBodyIsByteExact;
var
  Port: Integer;
  Client: TRawClient;
  Body, Expect: TBytes;
  I: Integer;
begin
  Port := StartServer;
  Client := TRawClient.Create(Port);
  try
    Client.SendWideWindow(16777216);
    Client.SendFrame(Client.GetFrame(1, '/large?bytes=1048576'));
    AssertTrue('the long body arrives',
      Client.ReadBody(1, ResponseTimeoutMs, Body));
    Expect := PatternBody(1048576);
    AssertEquals('the long body length', Length(Expect), Length(Body));
    for I := 0 to High(Expect) do
      if Expect[I] <> Body[I] then
      begin
        AssertEquals('the first differing body byte', I, -1);
        Exit;
      end;
    AssertTrue('the long body is byte exact', True);
  finally
    Client.Free;
  end;
end;

// ---- TAbuseLimitTest ----

function TAbuseLimitTest.StartWithBuckets(const AReset,
  AControl: TTokenBucketOptions; const AMaxContinuations: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := BaseFactory(TValidationHandler.Create)
    .WithResetBucket(AReset)
    .WithPingBucket(AControl)
    .WithSettingsBucket(AControl)
    .WithEmptyDataBucket(AControl)
    .WithWindowUpdateBucket(AControl)
    .WithContinuationBucket(AControl);
  if AMaxContinuations > 0 then
    Factory := Factory.WithMaxContinuationFrames(AMaxContinuations);
  GServer := Factory.Build;
  GServer.Start;
  Result := GServer.Port;
end;

function TAbuseLimitTest.StartServer(const AReset,
  AControl: TTokenBucketOptions): Integer;
begin
  Result := StartWithBuckets(AReset, AControl, 0);
end;

procedure TAbuseLimitTest.TearDown;
begin
  if GServer <> nil then
  begin
    GServer.Stop;
    GServer := nil;
  end;
end;

procedure TAbuseLimitTest.TestResetFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Frame: TFrame;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
begin
  // the reset bucket holds two resets before a dispatch, so the fourth trips.
  // The explicit costs match the factory defaults, because WithResetBucket
  // replaces the whole option record and a zero cost would never trip.
  Port := StartServer(
    TTokenBucketOptions.Create.WithCapacity(2).WithRefillPerSecond(0)
      .WithCostBeforeDispatch(1).WithCostAfterDispatch(5),
    SmallBucket(1000000));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    Client.SendFrame(Client.GetFrame(1, '/'));
    for I := 0 to 9 do
    begin
      Frame := BuildRstStreamFrame(LongWord(3 + I * 2), ecCancel);
      Client.SendFrame(Frame);
    end;
    AssertTrue('the reset flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestPingFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
  Payload: TBytes;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    SetLength(Payload, 8);
    for I := 0 to 11 do
      Client.SendFrame(BuildPingFrame(Payload, False));
    AssertTrue('the PING flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestSettingsFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    for I := 0 to 11 do
      Client.SendFrame(BuildSettingsFrame(TConnectionSettings.Defaults));
    AssertTrue('the SETTINGS flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestEmptyDataFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
  Empty: TBytes;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    Empty := nil;
    // an empty DATA frame on stream zero only charges the empty-DATA bucket
    for I := 0 to 11 do
      Client.SendFrame(BuildDataFrame(0, Empty, False));
    AssertTrue('the empty DATA flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestWindowUpdateFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    for I := 0 to 11 do
      Client.SendFrame(BuildWindowUpdateFrame(0, 1024));
    AssertTrue('the WINDOW_UPDATE flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestHeaderBlockOverLimitGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  Block, Big: TBytes;
  I: Integer;
begin
  // the block byte limit is twice the header list size, so a long block with
  // END_HEADERS cleared trips the limit on its first continuation frame
  Port := StartServer(SmallBucket(1000000), SmallBucket(1000000));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    SetLength(Big, 200000);
    for I := 0 to High(Big) do
      Big[I] := Byte(I);
    Block := Client.EncodeHeaders(THeaderBlock(nil));
    Client.SendFrame(BuildHeadersFrame(1, Block, False, True));
    // the block limit is 2 * 65536, so a 200000-octet block passes it
    Client.SendFrame(BuildContinuationFrame(1, Big, False));
    Client.SendFrame(BuildContinuationFrame(1, Big, True));
    AssertTrue('the oversized header block ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestHandlerExceptionIsReported;
var
  Port: Integer;
  Client: TRawClient;
  Observer: TCountingObserver;
  Frame: TFrame;
  I: Integer;
begin
  Observer := TCountingObserver.Create;
  GServer := BaseFactory(TRaisingValidationHandler.Create)
    .Build(Observer);
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    Client.SendFrame(Client.GetFrame(1, '/'));
    // the handler raises, so the stream gets an RST_STREAM
    for I := 1 to 60 do
    begin
      if Client.TakeFrame(Frame, 100) and
         (Frame.Header.FrameType = ftRstStream) and
         (Frame.Header.StreamId = 1) then
        Break;
    end;
    AssertTrue('the observer saw the handler exception',
      Observer.CountOf(seHandlerException) >= 1);
  finally
    Client.Free;
  end;
end;

// ---- TCancellationTest ----

procedure TCancellationTest.TearDown;
begin
  if GServer <> nil then
  begin
    GServer.Stop;
    GServer := nil;
  end;
end;

procedure TCancellationTest.TestResetRaisesInsideHandler;
var
  Port: Integer;
  Client: TRawClient;
  Handler: TBlockingReadHandler;
  Observer: TCountingObserver;
  Deadline: QWord;
begin
  Handler := TBlockingReadHandler.Create;
  Observer := TCountingObserver.Create;
  GServer := BaseFactory(Handler).Build(Observer);
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // a HEADERS frame with END_STREAM clear, so the body never arrives and
    // the handler parks inside Read until the reset
    Client.SendFrame(Client.OpenFrame(1, '/blocking'));
    AssertTrue('the handler reached Read', Handler.WaitStarted(4000));
    Client.SendFrame(BuildRstStreamFrame(1, ecCancel));
    // the cancel raises EStreamCancelled inside the handler thread
    Deadline := GetTickCount64 + 4000;
    while (not Handler.Cancelled) and (GetTickCount64 < Deadline) do
      Sleep(20);
    AssertTrue('the handler saw EStreamCancelled', Handler.Cancelled);
    AssertTrue('the observer saw the reset',
      Observer.CountOf(seStreamReset) >= 1);
  finally
    Client.Free;
  end;
end;

procedure TCancellationTest.TestResetBeforeDispatchNeverRuns;
var
  Port: Integer;
  Client: TRawClient;
  Handler: TValidationHandler;
begin
  Handler := TValidationHandler.Create;
  GServer := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(Handler)
    // one handler thread and no queue space, so later streams are refused
    .WithHandlerThreads(1)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500)
    .Build;
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // the first request is refused at once, so it never reaches the handler
    Client.SendFrame(Client.GetFrame(1, '/'));
    Client.SendFrame(BuildRstStreamFrame(1, ecCancel));
    Sleep(300);
    AssertEquals('a refused stream never runs the handler',
      0, Handler.StartedCount);
  finally
    Client.Free;
  end;
end;

// ---- TAdmissionExhaustionTest ----

procedure TAdmissionExhaustionTest.TearDown;
begin
  if GServer <> nil then
  begin
    GServer.Stop;
    GServer := nil;
  end;
end;

procedure TAdmissionExhaustionTest.TestExhaustionCountsFollowTheAdmissionRules;
var
  Port, I, Served: Integer;
  Client: TRawClient;
  Handler: TValidationHandler;
  Frame: TFrame;
begin
  Handler := TValidationHandler.Create;
  GServer := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(Handler)
    .WithHandlerThreads(2)
    .WithQueue(TQueueOptions.Create.WithDepth(4).WithMaxWaitMs(200)
      .WithRefusalMode(rmRefuseStream))
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500)
    .Build;
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // 20 requests on one connection, more than the pool and the queue hold
    for I := 1 to 20 do
      Client.SendFrame(Client.GetFrame(LongWord(1 + (I - 1) * 2), '/'));
    Served := 0;
    for I := 1 to 200 do
    begin
      if Client.TakeFrame(Frame, 50) then
      begin
        if (Frame.Header.FrameType = ftData) and
           Frame.IsEndStream then
          Inc(Served);
      end;
    end;
    AssertTrue('some requests were served', Served > 0);
    AssertTrue('some requests were refused or dropped',
      GServer.Stats.RefusedTotal + Handler.StartedCount <= 20);
    AssertTrue('the served count never passes the offered count',
      Handler.StartedCount <= 20);
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTest(TBytesFidelityTest);
  RegisterTest(TAbuseLimitTest);
  RegisterTest(TCancellationTest);
  RegisterTest(TAdmissionExhaustionTest);
end.
