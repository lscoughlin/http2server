{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, extended connect, rfc 8441, live, test, fpcunit
notes:
  - This unit tests the WebSocket handshake of RFC 8441 on a running server with a raw
    h2c frame client. It covers the SETTINGS rule, the validation rules for the
    pseudo-header :protocol, the refusals, Init, the echo, the close mapping and the
    flow control of a large message.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Live tests of WebSocket over HTTP/2
unit Http2Server.Ws.Http2.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Generics.Collections, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2Server, Http2Server.Errors, Http2Server.Hpack, Http2Server.Headers,
  Http2Server.Frames, Http2Server.Seam, Http2Server.Ws.Frames, Http2Server.Ws.Types,
  Http2Server.Http1.RawClient, Http2Server.Ws.TestKit, Http2Server.Ws.Http1.Test;

type
  /// a raw h2c client that keeps every frame it receives
  TH2WsClient = class
  private
    FSock: TCrtSocket;
    FEnc, FDec: THpackCodec;
    FBuf: RawByteString;
    FFrames: TList<TFrame>;
    FFields: TList<THeaderBlock>;
    FConnWindow: Int64;
    FStreamWindow: TDictionary<LongWord, Int64>;
    FPeerAdvertisesConnect: Boolean;
    procedure Pump(const AWaitMs: Integer);
    procedure Write(const AFrame: TFrame);
    function Credit(const AStreamId: LongWord): Int64;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    procedure OpenStream(const AId: LongWord; const AFields: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure OpenWebSocket(const AId: LongWord; const AExtra: THeaderBlock = nil);
    procedure OpenGet(const AId: LongWord; const APath: string);
    /// send AData as DATA frames, waiting for the windows of the server
    procedure SendData(const AId: LongWord; const AData: TBytes; const AEnd: Boolean = False);
    procedure SendRst(const AId: LongWord; const ACode: THttp2ErrorCode);
    /// the fields of the first HEADERS frame of the stream; False after the timeout
    function WaitHeaders(const AId: LongWord; const ATimeoutMs: Integer;
      out AFields: THeaderBlock): Boolean;
    /// the DATA octets that arrived on the stream so far
    function DataOf(const AId: LongWord): TBytes;
    /// wait until the WebSocket frames on the stream, decoded, contain AText
    function WaitFrames(const AId: LongWord; const AText: string;
      const ATimeoutMs: Integer = 5000): Boolean;
    function WaitEnded(const AId: LongWord; const ATimeoutMs: Integer = 5000): Boolean;
    function WaitReset(const AId: LongWord; const ATimeoutMs: Integer;
      out ACode: THttp2ErrorCode): Boolean;
    /// the received frames as text, for a failure message
    function Dump: string;
    property PeerAdvertisesConnect: Boolean read FPeerAdvertisesConnect;
  end;

  TWsHttp2Test = class(TTestCase)
  private
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function Factory: THttp2ServerFactory;
    function Status(const AFields: THeaderBlock): string;
    function Field(const AFields: THeaderBlock; const AName: string): string;
    function Open(out AClient: TH2WsClient; const AId: LongWord = 1;
      const AExtra: THeaderBlock = nil): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSettingsAdvertiseConnectOnlyWithWebSockets;
    procedure TestExtendedConnectWithoutTheSettingIsAStreamError;
    procedure TestProtocolOnAnotherMethodIsAStreamError;
    procedure TestHandshakeAnswers200WithoutEndStream;
    procedure TestEchoOnTheStream;
    procedure TestAnOrdinaryGetAndAWebSocketShareAConnection;
    procedure TestManyStreamsOnOneConnection;
    procedure TestClientCloseIsAnsweredAndEndsTheStream;
    procedure TestEndStreamWithoutCloseIs1006;
    procedure TestRstStreamIs1006AndTheConnectionStays;
    procedure TestStopSendsGoingAway;
    procedure TestRefusalsKeepTheConnection;
    procedure TestInitRejectIs401AndTheConnectionStays;
    procedure TestInitGreetingAndSubprotocol;
    procedure TestTrailerOnAWebSocketStreamIsAStreamError;
    procedure TestLargeMessageUsesFlowControl;
    procedure TestTheDetachLimitAnswers503;
  end;

implementation

function FrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

{ TH2WsClient }

constructor TH2WsClient.Create(const APort: Integer);
var
  Wire: TBytes;
begin
  inherited Create;
  FEnc := THpackCodec.Create;
  FDec := THpackCodec.Create;
  FFrames := TList<TFrame>.Create;
  FFields := TList<THeaderBlock>.Create;
  FStreamWindow := TDictionary<LongWord, Int64>.Create;
  FConnWindow := 65535;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, ResponseMs);
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Wire := Cat(Wire, FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

destructor TH2WsClient.Destroy;
begin
  FSock.Free;
  FStreamWindow.Free;
  FFields.Free;
  FFrames.Free;
  FDec.Free;
  FEnc.Free;
  inherited Destroy;
end;

procedure TH2WsClient.Write(const AFrame: TFrame);
var
  Wire: TBytes;
begin
  Wire := FrameBytes(AFrame);
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

function TH2WsClient.Credit(const AStreamId: LongWord): Int64;
begin
  if not FStreamWindow.TryGetValue(AStreamId, Result) then
    Result := 65535;
end;

procedure TH2WsClient.Pump(const AWaitMs: Integer);
var
  Pending: TCrtSocketPending;
  Chunk: RawByteString;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
  Frame: TFrame;
  Settings: TConnectionSettings;
begin
  Pending := FSock.SockReceivePending(AWaitMs);
  if not (Pending in [cspSocketError, cspSocketClosed]) then
  begin
    Chunk := FSock.SockReceiveString;
    if Chunk <> '' then
      FBuf := FBuf + Chunk;
  end;
  while Length(FBuf) >= FrameHeaderSize do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    N := FrameHeaderSize + Integer(Header.Length);
    if Length(FBuf) < N then
      Break;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(FBuf[FrameHeaderSize + 1], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    FBuf := Copy(FBuf, N + 1, MaxInt);
    case Header.FrameType of
      ftSettings:
        if not Frame.IsAck then
        begin
          Settings := TConnectionSettings.Decode(Frame.Payload);
          FPeerAdvertisesConnect := Settings.EnableConnectProtocol;
          Write(BuildSettingsAck);
        end;
      ftWindowUpdate:
        if Header.StreamId = 0 then
          Inc(FConnWindow, ParseWindowUpdate(Frame))
        else
          FStreamWindow.AddOrSetValue(Header.StreamId,
            Credit(Header.StreamId) + ParseWindowUpdate(Frame));
      ftData:
        if Header.Length > 0 then
        begin
          // keep the windows of the server open
          Write(BuildWindowUpdateFrame(0, Header.Length));
          Write(BuildWindowUpdateFrame(Header.StreamId, Header.Length));
        end;
    end;
    FFrames.Add(Frame);
    if Header.FrameType = ftHeaders then
      FFields.Add(FDec.Decode(ExtractHeaderBlock(Frame)))
    else
      FFields.Add(nil);
  end;
end;

procedure TH2WsClient.OpenStream(const AId: LongWord; const AFields: THeaderBlock;
  const AEndStream: Boolean);
begin
  Write(BuildHeadersFrame(AId, FEnc.Encode(AFields), True, AEndStream));
end;

procedure TH2WsClient.OpenWebSocket(const AId: LongWord; const AExtra: THeaderBlock);
var
  F: THeaderBlock;
  I, N: Integer;

  procedure Add(const AName, AValue: string);
  begin
    SetLength(F, N + 1);
    F[N].Name := AName;
    F[N].Value := AValue;
    Inc(N);
  end;

begin
  F := nil;
  N := 0;
  Add(':method', 'CONNECT');
  Add(':scheme', 'http');
  Add(':path', '/ws');
  Add(':authority', 'localhost');
  Add(':protocol', 'websocket');
  Add('sec-websocket-version', '13');
  for I := 0 to High(AExtra) do
    Add(AExtra[I].Name, AExtra[I].Value);
  OpenStream(AId, F);
end;

procedure TH2WsClient.OpenGet(const AId: LongWord; const APath: string);
var
  F: THeaderBlock;
begin
  SetLength(F, 4);
  F[0].Name := ':method';
  F[0].Value := 'GET';
  F[1].Name := ':scheme';
  F[1].Value := 'http';
  F[2].Name := ':path';
  F[2].Value := APath;
  F[3].Name := ':authority';
  F[3].Value := 'localhost';
  OpenStream(AId, F, True);
end;

procedure TH2WsClient.SendData(const AId: LongWord; const AData: TBytes; const AEnd: Boolean);
var
  Pos, N: Integer;
  Chunk: TBytes;
  Deadline: QWord;
begin
  Pos := 0;
  Deadline := GetTickCount64 + 10000;
  if Length(AData) = 0 then
  begin
    Write(BuildDataFrame(AId, nil, AEnd));
    Exit;
  end;
  while Pos < Length(AData) do
  begin
    N := Length(AData) - Pos;
    if N > 16384 then
      N := 16384;
    while (FConnWindow < N) or (Credit(AId) < N) do
    begin
      Pump(20);
      if GetTickCount64 > Deadline then
        raise Exception.Create('the windows of the server stayed closed');
    end;
    SetLength(Chunk, N);
    Move(AData[Pos], Chunk[0], N);
    Dec(FConnWindow, N);
    FStreamWindow.AddOrSetValue(AId, Credit(AId) - N);
    Inc(Pos, N);
    Write(BuildDataFrame(AId, Chunk, AEnd and (Pos >= Length(AData))));
  end;
end;

procedure TH2WsClient.SendRst(const AId: LongWord; const ACode: THttp2ErrorCode);
begin
  Write(BuildRstStreamFrame(AId, ACode));
end;

function TH2WsClient.WaitHeaders(const AId: LongWord; const ATimeoutMs: Integer;
  out AFields: THeaderBlock): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  AFields := nil;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    for I := 0 to FFrames.Count - 1 do
      if (FFrames[I].Header.FrameType = ftHeaders) and (FFrames[I].Header.StreamId = AId) then
      begin
        AFields := FFields[I];
        Exit(True);
      end;
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := False;
end;

function TH2WsClient.DataOf(const AId: LongWord): TBytes;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FFrames.Count - 1 do
    if (FFrames[I].Header.FrameType = ftData) and (FFrames[I].Header.StreamId = AId) then
      Result := Cat(Result, ExtractDataPayload(FFrames[I]));
end;

function TH2WsClient.WaitFrames(const AId: LongWord; const AText: string;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  L: TStringList;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pump(20);
    L := DecodeOutput(DataOf(AId));
    try
      if Pos(AText, L.Text) > 0 then
        Exit(True);
    finally
      L.Free;
    end;
  until GetTickCount64 > Deadline;
  Result := False;
end;

function TH2WsClient.WaitEnded(const AId: LongWord; const ATimeoutMs: Integer): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    for I := 0 to FFrames.Count - 1 do
      if (FFrames[I].Header.StreamId = AId) and
         (FFrames[I].Header.FrameType in [ftData, ftHeaders]) and FFrames[I].IsEndStream then
        Exit(True);
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := False;
end;

function TH2WsClient.Dump: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FFrames.Count - 1 do
    Result := Result + Format('[%s s%d len%d fl%d] ', [FrameTypeName(FFrames[I].Header.FrameType),
      FFrames[I].Header.StreamId, FFrames[I].Header.Length, FrameFlagsToByte(FFrames[I].Header.Flags)]);
end;

function TH2WsClient.WaitReset(const AId: LongWord; const ATimeoutMs: Integer;
  out ACode: THttp2ErrorCode): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  ACode := ecNoError;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    for I := 0 to FFrames.Count - 1 do
      if (FFrames[I].Header.StreamId = AId) and (FFrames[I].Header.FrameType = ftRstStream) then
      begin
        ParseRstStream(FFrames[I], ACode);
        Exit(True);
      end;
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := False;
end;

{ TWsHttp2Test }

procedure TWsHttp2Test.SetUp;
begin
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
end;

procedure TWsHttp2Test.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
end;

function TWsHttp2Test.Factory: THttp2ServerFactory;
begin
  Result := LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create.WithQueuedMessages(256));
end;

procedure TWsHttp2Test.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function TWsHttp2Test.Status(const AFields: THeaderBlock): string;
begin
  Result := Field(AFields, ':status');
end;

function TWsHttp2Test.Field(const AFields: THeaderBlock; const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(AFields) do
    if AFields[I].Name = AName then
      Exit(AFields[I].Value);
  Result := '';
end;

function TWsHttp2Test.Open(out AClient: TH2WsClient; const AId: LongWord;
  const AExtra: THeaderBlock): Boolean;
var
  F: THeaderBlock;
begin
  AClient := TH2WsClient.Create(FServer.Port);
  AClient.OpenWebSocket(AId, AExtra);
  Result := AClient.WaitHeaders(AId, ResponseMs, F) and (Status(F) = '200');
end;

procedure TWsHttp2Test.TestSettingsAdvertiseConnectOnlyWithWebSockets;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenGet(1, '/hello');
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertTrue('SETTINGS_ENABLE_CONNECT_PROTOCOL is set', C.PeerAdvertisesConnect);
  finally
    C.Free;
  end;
  FServer.Stop;
  StartServer(LiveFactory(FRouterRef));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenGet(1, '/hello');
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertFalse('the setting is absent without WithWebSockets', C.PeerAdvertisesConnect);
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestExtendedConnectWithoutTheSettingIsAStreamError;
var
  C: TH2WsClient;
  Code: THttp2ErrorCode;
  F: THeaderBlock;
begin
  StartServer(LiveFactory(FRouterRef));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue(C.WaitReset(1, ResponseMs, Code));
    AssertTrue(Code = ecProtocolError);
    // the connection stays open for the next request
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestProtocolOnAnotherMethodIsAStreamError;
var
  C: TH2WsClient;
  F: THeaderBlock;
  Code: THttp2ErrorCode;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    SetLength(F, 5);
    F[0].Name := ':method';
    F[0].Value := 'GET';
    F[1].Name := ':scheme';
    F[1].Value := 'http';
    F[2].Name := ':path';
    F[2].Value := '/ws';
    F[3].Name := ':authority';
    F[3].Value := 'localhost';
    F[4].Name := ':protocol';
    F[4].Value := 'websocket';
    C.OpenStream(1, F, True);
    AssertTrue(C.WaitReset(1, ResponseMs, Code));
    AssertTrue(Code = ecProtocolError);
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHttp2Test.TestHandshakeAnswers200WithoutEndStream;
var
  C: TH2WsClient;
  F: THeaderBlock;
  I: Integer;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('200', Status(F));
    for I := 0 to High(F) do
      AssertTrue('no HTTP/1.1 upgrade field: ' + F[I].Name,
        not (F[I].Name = 'upgrade') and not (F[I].Name = 'sec-websocket-accept'));
    AssertFalse('the stream stays open', C.WaitEnded(1, 200));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestEchoOnTheStream;
var
  C: TH2WsClient;
begin
  FRecording.Echo := True;
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendData(1, ClientText('hello over h2'));
    AssertTrue(C.WaitFrames(1, 'T:hello over h2'));
    C.SendData(1, ClientFrame(WsOpPing, True, BytesOf('abc')));
    AssertTrue(C.WaitFrames(1, 'O:616263'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestAnOrdinaryGetAndAWebSocketShareAConnection;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  FRecording.Echo := True;
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
    AssertTrue(C.WaitEnded(3));
    C.SendData(1, ClientText('still open'));
    AssertTrue(C.WaitFrames(1, 'T:still open'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestManyStreamsOnOneConnection;
var
  C: TH2WsClient;
  I, J: Integer;
  F: THeaderBlock;
begin
  FRecording.Echo := True;
  StartServer(Factory.WithMaxConcurrentStreams(128));
  C := TH2WsClient.Create(FServer.Port);
  try
    // a burst of CONNECT requests can pass the admission queue, so the client opens
    // the streams in groups of ten and waits for each group, as a careful client does
    for I := 0 to 99 do
    begin
      C.OpenWebSocket(LongWord(1 + 2 * I));
      if I mod 10 = 9 then
        for J := I - 9 to I do
          AssertTrue('stream ' + IntToStr(J), C.WaitHeaders(LongWord(1 + 2 * J), 10000, F));
    end;
    for I := 0 to 99 do
      C.SendData(LongWord(1 + 2 * I), ClientText('m' + IntToStr(I)));
    for I := 0 to 99 do
      AssertTrue('echo ' + IntToStr(I), C.WaitFrames(LongWord(1 + 2 * I), 'T:m' + IntToStr(I), 10000));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestClientCloseIsAnsweredAndEndsTheStream;
var
  C: TH2WsClient;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendData(1, ClientClose(1000, 'bye'));
    AssertTrue(C.WaitFrames(1, 'C:1000:'));
    AssertTrue('the server ends its half', C.WaitEnded(1));
    AssertTrue(WaitUntilText(FRecording, 'closed 1000 bye clean=True'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestEndStreamWithoutCloseIs1006;
var
  C: TH2WsClient;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendData(1, nil, True);
    AssertTrue('the session closed with 1006: ' + FRecording.AllText,
      WaitUntilText(FRecording, 'closed 1006'));
    AssertTrue('the server ends its half', C.WaitEnded(1));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestRstStreamIs1006AndTheConnectionStays;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendRst(1, ecCancel);
    AssertTrue(WaitUntilText(FRecording, 'closed 1006'));
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestStopSendsGoingAway;
var
  C: TH2WsClient;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    FServer.Stop;
    AssertTrue('Close 1001 reached the client', C.WaitFrames(1, 'C:1001:'));
    AssertTrue(WaitUntilText(FRecording, 'closed 1001'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestRefusalsKeepTheConnection;
var
  C: TH2WsClient;
  F, Extra: THeaderBlock;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    // a version the server does not speak
    SetLength(Extra, 1);
    Extra[0].Name := 'sec-websocket-version';
    Extra[0].Value := '12';
    C.OpenWebSocket(1, Extra);
    AssertTrue('version answer', C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('400', Status(F));
    AssertEquals('13', Field(F, 'sec-websocket-version'));
    // a foreign origin
    SetLength(Extra, 1);
    Extra[0].Name := 'origin';
    Extra[0].Value := 'https://evil.test';
    C.OpenWebSocket(3, Extra);
    AssertTrue('origin answer', C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('403', Status(F));
    AssertTrue('origin end', C.WaitEnded(3));
    // the connection still serves
    C.OpenGet(5, '/hello');
    AssertTrue('get after refusals ' + C.Dump, C.WaitHeaders(5, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHttp2Test.TestInitRejectIs401AndTheConnectionStays;
var
  C: TH2WsClient;
  F, H: THeaderBlock;
  Res: TWsInitResult;
begin
  Res := TWsInitResult.Rejected(401);
  SetLength(H, 1);
  H[0].Name := 'www-authenticate';
  H[0].Value := 'Basic realm="x"';
  Res.RejectHeaders := H;
  FRecording.InitResult := Res;
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('401', Status(F));
    AssertEquals('Basic realm="x"', Field(F, 'www-authenticate'));
    AssertTrue(C.WaitEnded(1));
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestInitGreetingAndSubprotocol;
var
  C: TH2WsClient;
  F, Extra: THeaderBlock;
begin
  FRecording.InitResult := TWsInitResult.AcceptedWith('json');
  FRecording.InitSend := BytesOf('welcome');
  FRecording.InitSendText := True;
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    SetLength(Extra, 1);
    Extra[0].Name := 'sec-websocket-protocol';
    Extra[0].Value := 'chat, json';
    C.OpenWebSocket(1, Extra);
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('200', Status(F));
    AssertEquals('json', Field(F, 'sec-websocket-protocol'));
    AssertTrue(C.WaitFrames(1, 'T:welcome'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestTrailerOnAWebSocketStreamIsAStreamError;
var
  C: TH2WsClient;
  T: THeaderBlock;
  Code: THttp2ErrorCode;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    SetLength(T, 1);
    T[0].Name := 'x-trailer';
    T[0].Value := '1';
    C.OpenStream(1, T, True);
    AssertTrue(C.WaitReset(1, ResponseMs, Code));
    AssertTrue(Code = ecProtocolError);
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestLargeMessageUsesFlowControl;
var
  C: TH2WsClient;
  Big, Wire: TBytes;
  I, Pos, N: Integer;
  Op: Byte;
  L: TStringList;
  Deadline: QWord;
begin
  FRecording.Echo := True;
  StartServer(Factory.WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)
    .WithMaxMessageSize(2 * 1024 * 1024)));
  AssertTrue(Open(C));
  try
    SetLength(Big, 400 * 1024);
    for I := 0 to High(Big) do
      Big[I] := Ord('a') + (I mod 20);
    Wire := nil;
    Pos := 0;
    while Pos < Length(Big) do
    begin
      N := Length(Big) - Pos;
      if N > 32768 then
        N := 32768;
      if Pos = 0 then
        Op := WsOpText
      else
        Op := WsOpContinuation;
      Wire := Cat(Wire, ClientFrame(Op, Pos + N >= Length(Big), Copy(Big, Pos, N)));
      Inc(Pos, N);
    end;
    C.SendData(1, Wire);
    Deadline := GetTickCount64 + 15000;
    repeat
      N := Length(C.DataOf(1));
      if N >= Length(Big) then
        Break;
      C.WaitFrames(1, 'never matches', 50);
    until GetTickCount64 > Deadline;
    L := DecodeOutput(C.DataOf(1));
    try
      AssertEquals(1, L.Count);
      AssertEquals(Length(Big) + 2, Length(L[0]));
    finally
      L.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestTheDetachLimitAnswers503;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(Factory.WithMaxDetachedStreams(1));
  AssertTrue(Open(C));
  try
    C.OpenWebSocket(3);
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('503', Status(F));
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TWsHttp2Test);

end.
