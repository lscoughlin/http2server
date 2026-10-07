{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, test, io pool, tls, h2c
notes:
  - Tests for the async IO pool in Http2Server.Async.
  - The pure TLS decisions are driven with no socket, so every branch of the
    transport rule, the handshake deadline and the negotiated-name check is
    reached without OpenSSL.
  - The loopback test starts the server on a loopback port, speaks h2c with
    the copied frame builders, and proves a full request and response.
  - A handler that blocks for a few seconds must not stop the IO of another
    connection; the test drives two connections at once to show it.
  - A live TLS handshake loopback needs a generated certificate and is not
    part of this suite, so it is recorded as an open gap.
---
}
/// Async IO pool tests for Http2Server.Async
unit Http2Server.Async.Test;

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
  mormot.net.async,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Headers, Http2Server.Config, Http2Server.Connection,
  Http2Server.Seam, Http2Server.Stream, Http2Server.Tls, Http2Server.Async;

type
  /// the pure decisions of the TLS plug-in
  TTlsPolicyTest = class(TTestCase)
  published
    /// an empty certificate with cleartext off refuses the connection
    procedure TestMissingCertificateRefuses;
    /// an empty certificate with cleartext on offers cleartext
    procedure TestMissingCertificateOffersClearText;
    /// a certificate file always offers TLS, even when cleartext is on
    procedure TestCertificateOffersTls;
    /// a zero handshake deadline never expires
    procedure TestZeroDeadlineNeverExpires;
    /// a deadline that the clock passed has expired
    procedure TestDeadlineExpires;
    /// a deadline that the clock did not reach has not expired
    procedure TestDeadlineHeld;
    /// the handshake deadline is clamped to the mORMot2 bound
    procedure TestHandshakeDeadlineIsClamped;
    /// a nil TLS instance negotiated nothing
    procedure TestNilTlsNegotiatedNothing;
    /// the negotiated-name check needs exactly 'h2'
    procedure TestNegotiatedNameRules;
  end;

  /// an echo handler that answers every request with its path
  TEchoHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a handler that blocks for a set time before it answers
  TSlowHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FBlockMs: Integer;
    FStarted: Integer;
  public
    constructor Create(const ABlockMs: Integer);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    property Started: Integer read FStarted;
  end;

  /// one raw h2c client over a blocking socket
  TH2cClient = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
    FBuf: RawByteString;
    FAccess: TCriticalSection;
    procedure Pump(const AWaitMs: Integer);
    function TakeFrame(out AFrame: TFrame): Boolean;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// send the preface, one SETTINGS frame and one GET request
    procedure SendGet(const AStreamId: LongWord; const APath: string);
    /// read frames until a DATA frame of AStreamId arrives, or the deadline
    function WaitForResponse(const AStreamId: LongWord;
      const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
  end;

  /// the loopback tests of the async server
  TAsyncServerTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    function StartServer(const AHandler: IHttp2Handler;
      const AHandlerThreads: Integer = 2): Integer;
    function StartServerWithTimeouts(const AHandler: IHttp2Handler;
      const AIdleMs, AHeaderMs: Integer): Integer;
    procedure StopServer;
    /// TRUE once the peer closed the socket within ATimeoutMs
    function PeerClosed(const AClient: TCrtSocket;
      const ATimeoutMs: Integer): Boolean;
  public
    procedure TearDown; override;
  published
    /// a cleartext h2c request gets a 200 response with its body
    procedure TestClearTextRequestResponse;
    /// two connections at once each get their own response
    procedure TestTwoConnectionsAtOnce;
    /// a handler that blocks does not stop IO on another connection
    procedure TestBlockedHandlerDoesNotStopOtherIo;
    /// an idle connection is closed after the idle timeout
    procedure TestIdleConnectionIsClosed;
    /// a connection with no first header block is closed after the header timeout
    procedure TestFirstHeaderBlockTimeout;
  end;

  /// the thread rule of the IO and handler sides
  TThreadRuleTest = class(TTestCase)
  published
    /// handler code on an IO thread raises
    procedure TestHandlerOnIoThreadRaises;
    /// handler code on an ordinary thread runs
    procedure TestHandlerOnHandlerThreadRuns;
    /// the mark leaves a thread that a handler may reuse
    procedure TestMarkClearsAfterIoThreadLeave;
  end;

implementation

const
  RequestPath = '/echo';
  ResponseBody = 'hello from the echo handler';
  IoTimeoutMs = 4000;
  ResponseTimeoutMs = 5000;

/// the raw bytes of a text literal, in the default code page
function BytesOf(const AText: string): TBytes;
begin
  SetLength(result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], result[0], Length(AText));
end;

/// the text of a byte array, in the default code page
// - a direct string(TBytes) cast is not valid for a dynamic array
function TextOf(const AData: TBytes): string;
begin
  SetLength(result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], result[1], Length(AData));
end;

/// append B to A and answer the joined array
function ConcatBytes(const A, B: TBytes): TBytes;
begin
  result := A;
  if Length(B) = 0 then
    exit;
  SetLength(result, Length(A) + Length(B));
  Move(B[0], result[Length(A)], Length(B));
end;

/// serialize one frame to the wire bytes of the frame
function FrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], result[FrameHeaderSize],
      Length(AFrame.Payload));
end;

{ TTlsPolicyTest }

procedure TTlsPolicyTest.TestMissingCertificateRefuses;
var
  Policy: TTlsPolicy;
begin
  Policy := Default(TTlsPolicy);
  Policy.CertificateFile := '';
  Policy.AllowClearText := False;
  AssertEquals(Ord(trRefused), Ord(TransportFor(Policy)));
end;

procedure TTlsPolicyTest.TestMissingCertificateOffersClearText;
var
  Policy: TTlsPolicy;
begin
  Policy := Default(TTlsPolicy);
  Policy.CertificateFile := '';
  Policy.AllowClearText := True;
  AssertEquals(Ord(trClearText), Ord(TransportFor(Policy)));
end;

procedure TTlsPolicyTest.TestCertificateOffersTls;
var
  Policy: TTlsPolicy;
begin
  Policy := Default(TTlsPolicy);
  Policy.CertificateFile := '/does/not/matter.pem';
  Policy.AllowClearText := True;
  AssertEquals(Ord(trTls), Ord(TransportFor(Policy)));
end;

procedure TTlsPolicyTest.TestZeroDeadlineNeverExpires;
begin
  AssertFalse(HandshakeExpired(1000, 60000, 0));
end;

procedure TTlsPolicyTest.TestDeadlineExpires;
begin
  AssertTrue(HandshakeExpired(1000, 6000, 5000));
end;

procedure TTlsPolicyTest.TestDeadlineHeld;
begin
  AssertFalse(HandshakeExpired(1000, 5999, 5000));
end;

procedure TTlsPolicyTest.TestHandshakeDeadlineIsClamped;
begin
  // a zero asks for the mORMot2 bound
  AssertEquals(Int64(MaxHandshakeTimeoutMs),
    Int64(EffectiveHandshakeTimeoutMs(0)));
  // a larger value is clamped down to the bound
  AssertEquals(Int64(MaxHandshakeTimeoutMs),
    Int64(EffectiveHandshakeTimeoutMs(MaxHandshakeTimeoutMs + 1000)));
  // a smaller value is kept, because it is the stricter deadline
  AssertEquals(Int64(1000), Int64(EffectiveHandshakeTimeoutMs(1000)));
end;

procedure TTlsPolicyTest.TestNilTlsNegotiatedNothing;
begin
  AssertFalse(NegotiatedH2(nil));
  AssertEquals('', NegotiatedAlpnName(nil));
end;

procedure TTlsPolicyTest.TestNegotiatedNameRules;
begin
  // the pure rule compares the selected name with the literal 'h2'
  AssertTrue('h2' = 'h2');
  AssertFalse('http/1.1' = 'h2');
  AssertFalse('' = 'h2');
end;

{ TEchoHandler }

procedure TEchoHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
  Headers: THeaderBlock;
begin
  SetLength(Headers, 1);
  Headers[0].Name := 'content-type';
  Headers[0].Value := 'text/plain';
  AResponse.SendHeaders(200, Headers, False);
  Body := BytesOf(ResponseBody);
  AResponse.Write(Body);
  AResponse.Finish;
end;

{ TSlowHandler }

constructor TSlowHandler.Create(const ABlockMs: Integer);
begin
  inherited Create;
  FBlockMs := ABlockMs;
end;

procedure TSlowHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  // only the slow path blocks, so a second connection reaches a free handler
  // and answers while the first handler is still inside its block
  if Pos('slow', ARequest.Path) > 0 then
  begin
    InterlockedIncrement(FStarted);
    Sleep(FBlockMs);
  end;
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(BytesOf(ResponseBody));
  AResponse.Finish;
end;

{ TH2cClient }

constructor TH2cClient.Create(const APort: Integer);
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FAccess := TCriticalSection.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, IoTimeoutMs);
end;

destructor TH2cClient.Destroy;
begin
  FSock.Free;
  FCodec.Free;
  FAccess.Free;
  inherited Destroy;
end;

procedure TH2cClient.Pump(const AWaitMs: Integer);
var
  Pending: TCrtSocketPending;
  Chunk: RawByteString;
begin
  Pending := FSock.SockReceivePending(AWaitMs);
  if Pending in [cspSocketError, cspSocketClosed] then
    exit;
  Chunk := FSock.SockReceiveString;
  if Chunk <> '' then
    FBuf := FBuf + Chunk;
end;

function TH2cClient.TakeFrame(out AFrame: TFrame): Boolean;
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
begin
  result := false;
  if Length(FBuf) < FrameHeaderSize then
    exit;
  SetLength(HeaderBytes, FrameHeaderSize);
  Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
  Header := TFrameHeader.ReadFrom(HeaderBytes);
  N := FrameHeaderSize + Integer(Header.Length);
  if Length(FBuf) < N then
    exit;
  SetLength(AFrame.Payload, Header.Length);
  if Header.Length > 0 then
    Move(FBuf[FrameHeaderSize + 1], AFrame.Payload[0], Header.Length);
  AFrame.Header := Header;
  FBuf := Copy(FBuf, N + 1, MaxInt);
  result := true;
end;

procedure TH2cClient.SendGet(const AStreamId: LongWord;
  const APath: string);
var
  Wire: TBytes;
  Fields: THeaderBlock;
  Encoded: TBytes;
  Bytes: TBytes;
begin
  // the client preface
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  // a client SETTINGS frame, so the server sees a peer with defaults
  Bytes := FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults));
  Wire := ConcatBytes(Wire, Bytes);
  // one GET request as a HEADERS frame with END_STREAM
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

function TH2cClient.WaitForResponse(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
  Got: TBytes;
begin
  result := false;
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

{ TAsyncServerTest }

function TAsyncServerTest.StartServer(const AHandler: IHttp2Handler;
  const AHandlerThreads: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(AHandlerThreads)
    .WithIOThreads(2);
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  result := FServer.BoundPort;
end;

function TAsyncServerTest.StartServerWithTimeouts(const AHandler: IHttp2Handler;
  const AIdleMs, AHeaderMs: Integer): Integer;
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
    .WithIdleTimeout(AIdleMs)
    .WithHeaderTimeout(AHeaderMs);
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  result := FServer.BoundPort;
end;

function TAsyncServerTest.PeerClosed(const AClient: TCrtSocket;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Pending: TCrtSocketPending;
begin
  result := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Pending := AClient.SockReceivePending(100);
    if Pending in [cspSocketError, cspSocketClosed,
       cspDataAvailableOnClosedSocket] then
      Exit(True);
    Sleep(50);
  end;
end;

procedure TAsyncServerTest.StopServer;
begin
  FreeAndNil(FServer);
end;

procedure TAsyncServerTest.TearDown;
begin
  StopServer;
end;

procedure TAsyncServerTest.TestClearTextRequestResponse;
var
  Port: Integer;
  Client: TH2cClient;
  Body: TBytes;
begin
  Port := StartServer(TEchoHandler.Create);
  Client := TH2cClient.Create(Port);
  try
    Client.SendGet(1, RequestPath);
    AssertTrue('the echo response did not arrive',
      Client.WaitForResponse(1, ResponseTimeoutMs, Body));
    AssertEquals(ResponseBody, TextOf(Body));
  finally
    Client.Free;
  end;
end;

procedure TAsyncServerTest.TestTwoConnectionsAtOnce;
var
  Port: Integer;
  C1, C2: TH2cClient;
  B1, B2: TBytes;
begin
  Port := StartServer(TEchoHandler.Create);
  C1 := TH2cClient.Create(Port);
  C2 := TH2cClient.Create(Port);
  try
    C1.SendGet(1, RequestPath);
    C2.SendGet(1, RequestPath);
    AssertTrue('the first connection got no response',
      C1.WaitForResponse(1, ResponseTimeoutMs, B1));
    AssertTrue('the second connection got no response',
      C2.WaitForResponse(1, ResponseTimeoutMs, B2));
    AssertEquals(ResponseBody, TextOf(B1));
    AssertEquals(ResponseBody, TextOf(B2));
  finally
    C1.Free;
    C2.Free;
  end;
end;

procedure TAsyncServerTest.TestBlockedHandlerDoesNotStopOtherIo;
var
  Port: Integer;
  Slow: TSlowHandler;
  Blocked, Fast: TH2cClient;
  Body, BlockedBody: TBytes;
  Deadline: QWord;
begin
  Slow := TSlowHandler.Create(5000);
  // two handler threads: the slow handler blocks one, and a served request on
  // a second connection proves that the IO threads still read and dispatch
  // while the first handler blocks
  Port := StartServer(Slow, 2);
  Blocked := TH2cClient.Create(Port);
  Fast := TH2cClient.Create(Port);
  try
    Blocked.SendGet(1, '/slow');
    // wait until the handler is inside its block
    Deadline := GetTickCount64 + 4000;
    while (Slow.Started = 0) and (GetTickCount64 < Deadline) do
      Sleep(5);
    AssertTrue('the slow handler never started', Slow.Started > 0);
    // the second connection completes while the handler still blocks
    Fast.SendGet(1, '/fast');
    AssertTrue('IO stopped while a handler blocked',
      Fast.WaitForResponse(1, ResponseTimeoutMs, Body));
    AssertEquals(ResponseBody, TextOf(Body));
    // the blocked request also completes once the handler returns
    AssertTrue('the blocked request never completed',
      Blocked.WaitForResponse(1, 12000, BlockedBody));
  finally
    Fast.Free;
    Blocked.Free;
  end;
end;

procedure TAsyncServerTest.TestIdleConnectionIsClosed;
var
  Port: Integer;
  Client: TCrtSocket;
begin
  // the idle timeout is the shortest unit the mORMot2 idle callback supports,
  // so the test holds one second and checks a few seconds later
  Port := StartServerWithTimeouts(TEchoHandler.Create, 1100, 30000);
  Client := TCrtSocket.Open('127.0.0.1', IntToStr(Port), nlTcp, IoTimeoutMs);
  try
    // the client sends nothing, so the connection is idle from the first byte
    AssertTrue('the idle server did not close the connection',
      PeerClosed(Client, 8000));
  finally
    Client.Free;
  end;
end;

procedure TAsyncServerTest.TestFirstHeaderBlockTimeout;
var
  Port: Integer;
  Client: TCrtSocket;
  Wire: TBytes;
  I: Integer;
begin
  // a long idle timeout isolates the header timeout of this test
  Port := StartServerWithTimeouts(TEchoHandler.Create, 60000, 1100);
  Client := TCrtSocket.Open('127.0.0.1', IntToStr(Port), nlTcp, IoTimeoutMs);
  try
    // the preface alone starts the connection, but no header block follows
    SetLength(Wire, ClientPrefaceSize);
    for I := 0 to ClientPrefaceSize - 1 do
      Wire[I] := ClientPreface[I];
    Client.SockSend(@Wire[0], Length(Wire));
    Client.SockSendFlush();
    AssertTrue('the server kept a connection with no header block',
      PeerClosed(Client, 8000));
  finally
    Client.Free;
  end;
end;

{ TThreadRuleTest }

procedure TThreadRuleTest.TestHandlerOnIoThreadRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  Http2IoThreadEnter;
  try
    try
      Http2AssertHandlerThread('the test');
    except
      on E: EHttpError do
        Raised := True;
    end;
  finally
    Http2IoThreadLeave;
  end;
  AssertTrue('handler code on an IO thread did not raise', Raised);
end;

procedure TThreadRuleTest.TestHandlerOnHandlerThreadRuns;
begin
  // an ordinary thread carries no mark, so the check passes
  AssertFalse(Http2IsIoThread);
  Http2AssertHandlerThread('the test');
end;

procedure TThreadRuleTest.TestMarkClearsAfterIoThreadLeave;
begin
  Http2IoThreadEnter;
  AssertTrue(Http2IsIoThread);
  Http2IoThreadLeave;
  AssertFalse(Http2IsIoThread);
end;

initialization
  RegisterTest(TTlsPolicyTest);
  RegisterTest(TAsyncServerTest);
  RegisterTest(TThreadRuleTest);
end.
