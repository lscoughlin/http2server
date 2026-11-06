{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, test, connections, socket options
notes:
  - Tests for the connection cap and the socket options of the async server.
  - The cap test serves real requests, so an off-by-one fails it.
  - The socket test reads each applied value back with getsockopt.
  - The reuse-port tests bind two servers to one port, and they pass
    without a check where the platform lacks the option.
---
}
/// Connection cap and socket option tests for Http2Server.Async
unit Http2Server.AsyncCaps.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Sockets,
  mormot.core.base,
  mormot.net.sock,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Headers, Http2Server.Config, Http2Server.Config.Limits,
  Http2Server.Config.Socket, Http2Server.Seam, Http2Server.Stream,
  Http2Server.Async, Http2Server.Async.Socket;

type
  /// an echo handler that answers every request with a fixed body
  TCapEchoHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// one raw h2c client over a blocking socket
  TCapClient = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
    FBuf: RawByteString;
    procedure Pump(const AWaitMs: Integer);
    function TakeFrame(out AFrame: TFrame): Boolean;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    property Sock: TCrtSocket read FSock;
    /// send the preface, one SETTINGS frame and one GET request
    procedure SendGet(const AStreamId: LongWord; const APath: string);
    /// read frames until a DATA frame of AStreamId arrives, or the deadline
    function WaitForResponse(const AStreamId: LongWord;
      const ATimeoutMs: Integer; out ABody: TBytes): Boolean;
  end;

  /// the cap and socket option tests of the async server
  TAsyncCapsTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    function StartServer(const AMaxConnections: Integer): Integer;
    procedure StopServer;
    /// the mORMot2 cap of a factory with the given connection limit
    function MappingOf(const AMaxConnections: Integer): Integer;
    /// TRUE once the peer closed the socket within ATimeoutMs
    function PeerClosed(const AClient: TCrtSocket;
      const ATimeoutMs: Integer): Boolean;
    /// TRUE once a fresh socket serves a request, within ATimeoutMs
    function SlotFreed(const APort, ATimeoutMs: Integer): Boolean;
    /// one socket option of a file descriptor, read back with getsockopt
    function GetSockInt(const AFd: TSocket;
      const ALevel, AName: Integer): Integer;
    /// TRUE when two loopback sockets share one port with SO_REUSEPORT
    function ReusePortWorks: Boolean;
    /// TRUE when two mORMot2 binds without the option share one port
    function ListenerSharesPort: Boolean;
  public
    procedure TearDown; override;
  published
    /// a factory value of N maps to the mORMot2 value of N minus one
    procedure TestMaxConnectionsMapping;
    /// a cap of two serves exactly two connections, then frees a slot
    procedure TestConnectionCapServesExactlyTwo;
    /// each applied socket option reads back with getsockopt
    procedure TestSocketOptionsApply;
    /// a second server without reuse-port fails to bind the same port
    procedure TestReusePortOffRefusesSecondBind;
    /// two servers with reuse-port share one port
    procedure TestReusePortOnSharesPort;
  end;

implementation

const
  CapRequestPath = '/echo';
  CapResponseBody = 'hello from the cap echo handler';
  CapIoTimeoutMs = 4000;
  CapResponseTimeoutMs = 5000;

{$IFDEF DARWIN}
const
  cCapTcpKeepIdle = $10;
  cCapTcpKeepIntvl = $101;
  cCapTcpKeepCnt = $102;
{$ELSE} {$IFDEF FREEBSD}
const
  cCapTcpKeepIdle = 256;
  cCapTcpKeepIntvl = 512;
  cCapTcpKeepCnt = 1024;
{$ELSE}
const
  cCapTcpKeepIdle = 4;
  cCapTcpKeepIntvl = 5;
  cCapTcpKeepCnt = 6;
{$ENDIF} {$ENDIF}

/// the raw bytes of a text literal, in the default code page
function CapBytesOf(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

/// the text of a byte array, in the default code page
// - a direct string(TBytes) cast is not valid for a dynamic array
function CapTextOf(const AData: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

/// append B to A and answer the joined array
function CapConcat(const A, B: TBytes): TBytes;
begin
  Result := nil;
  Result := A;
  if Length(B) = 0 then
    exit;
  SetLength(Result, Length(A) + Length(B));
  Move(B[0], Result[Length(A)], Length(B));
end;

/// serialize one frame to the wire bytes of the frame
function CapFrameBytes(const AFrame: TFrame): TBytes;
begin
  Result := nil;
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize],
      Length(AFrame.Payload));
end;

{ TCapEchoHandler }

procedure TCapEchoHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
  Headers: THeaderBlock;
begin
  SetLength(Headers, 1);
  Headers[0].Name := 'content-type';
  Headers[0].Value := 'text/plain';
  AResponse.SendHeaders(200, Headers, False);
  Body := CapBytesOf(CapResponseBody);
  AResponse.Write(Body);
  AResponse.Finish;
end;

{ TCapClient }

constructor TCapClient.Create(const APort: Integer);
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp,
    CapIoTimeoutMs);
end;

destructor TCapClient.Destroy;
begin
  FSock.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure TCapClient.Pump(const AWaitMs: Integer);
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

function TCapClient.TakeFrame(out AFrame: TFrame): Boolean;
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
begin
  Result := False;
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
  Result := True;
end;

procedure TCapClient.SendGet(const AStreamId: LongWord;
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
  Bytes := CapFrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults));
  Wire := CapConcat(Wire, Bytes);
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
  Bytes := CapFrameBytes(BuildHeadersFrame(AStreamId, Encoded, True, True));
  Wire := CapConcat(Wire, Bytes);
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

function TCapClient.WaitForResponse(const AStreamId: LongWord;
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
          ABody := CapConcat(ABody, Got);
          if Frame.IsEndStream then
            Exit(True);
        end
        else if Frame.IsEndStream then
          Exit(Length(ABody) > 0);
      end;
  end;
end;

{ TAsyncCapsTest }

function TAsyncCapsTest.StartServer(const AMaxConnections: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TCapEchoHandler.Create)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithServerLimits(TServerLimits.Create.WithMaxConnections(
      AMaxConnections));
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  Result := FServer.BoundPort;
end;

procedure TAsyncCapsTest.StopServer;
begin
  FreeAndNil(FServer);
end;

procedure TAsyncCapsTest.TearDown;
begin
  StopServer;
end;

function TAsyncCapsTest.MappingOf(const AMaxConnections: Integer): Integer;
var
  Factory: THttp2ServerFactory;
  Server: THttp2AsyncServer;
begin
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TCapEchoHandler.Create)
    .WithServerLimits(TServerLimits.Create.WithMaxConnections(
      AMaxConnections));
  Server := THttp2AsyncServer.Create(Factory);
  try
    Result := Server.MaxConnections;
  finally
    Server.Free;
  end;
end;

function TAsyncCapsTest.PeerClosed(const AClient: TCrtSocket;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Pending: TCrtSocketPending;
begin
  Result := False;
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

function TAsyncCapsTest.SlotFreed(const APort,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Client: TCapClient;
  Body: TBytes;
begin
  // the server drops the closed socket on its own turn, so a fresh socket
  // retries until one serves a request or the deadline passes
  Result := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Client := nil;
    try
      try
        Client := TCapClient.Create(APort);
        Client.SendGet(1, CapRequestPath);
        if Client.WaitForResponse(1, 500, Body) and
           (CapTextOf(Body) = CapResponseBody) then
          Exit(True);
      except
        on E: Exception do
          ; // a refused socket raises here; the next retry follows
      end;
    finally
      Client.Free;
    end;
    Sleep(100);
  end;
end;

function TAsyncCapsTest.GetSockInt(const AFd: TSocket;
  const ALevel, AName: Integer): Integer;
var
  Len: TSockLen;
begin
  Result := 0;
  Len := SizeOf(Result);
  if fpgetsockopt(AFd, ALevel, AName, @Result, @Len) <> 0 then
    Fail('getsockopt failed for the option');
end;

function TAsyncCapsTest.ReusePortWorks: Boolean;
var
  S1, S2: TSocket;
  Addr: TInetSockAddr;
  Len: TSockLen;
  Value: Integer;
begin
  Result := False;
  S1 := fpsocket(AF_INET, SOCK_STREAM, 0);
  S2 := fpsocket(AF_INET, SOCK_STREAM, 0);
  try
    if (S1 < 0) or (S2 < 0) then
      exit;
    Value := 1;
    if fpsetsockopt(S1, SOL_SOCKET, SO_REUSEPORT, @Value,
      SizeOf(Value)) <> 0 then
      exit;
    if fpsetsockopt(S2, SOL_SOCKET, SO_REUSEPORT, @Value,
      SizeOf(Value)) <> 0 then
      exit;
    FillByte(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := 0;
    Addr.sin_addr.s_addr := htonl(LongWord($7F000001));
    if fpbind(S1, @Addr, SizeOf(Addr)) <> 0 then
      exit;
    Len := SizeOf(Addr);
    if fpgetsockname(S1, @Addr, @Len) <> 0 then
      exit;
    // the second bind of the same port succeeds only with the option
    Result := fpbind(S2, @Addr, SizeOf(Addr)) = 0;
  finally
    if S1 >= 0 then
      CloseSocket(S1);
    if S2 >= 0 then
      CloseSocket(S2);
  end;
end;

procedure TAsyncCapsTest.TestMaxConnectionsMapping;
begin
  AssertEquals('a value of 2 maps to 1', 1, MappingOf(2));
  AssertEquals('a value of 1 maps to 0', 0, MappingOf(1));
  AssertEquals('a value of 0 means no cap', MaxInt, MappingOf(0));
  AssertEquals('the default maps to 9999', 9999, MappingOf(10000));
end;

procedure TAsyncCapsTest.TestConnectionCapServesExactlyTwo;
var
  Port: Integer;
  C1, C2: TCapClient;
  C3: TCrtSocket;
  B1, B2: TBytes;
begin
  Port := StartServer(2);
  C1 := TCapClient.Create(Port);
  C2 := TCapClient.Create(Port);
  try
    C1.SendGet(1, CapRequestPath);
    C2.SendGet(1, CapRequestPath);
    AssertTrue('the first connection got no response',
      C1.WaitForResponse(1, CapResponseTimeoutMs, B1));
    AssertTrue('the second connection got no response',
      C2.WaitForResponse(1, CapResponseTimeoutMs, B2));
    AssertEquals(CapResponseBody, CapTextOf(B1));
    AssertEquals(CapResponseBody, CapTextOf(B2));
    // the third socket is refused: the server closes it without a reply
    C3 := TCrtSocket.Open('127.0.0.1', IntToStr(Port), nlTcp,
      CapIoTimeoutMs);
    try
      AssertTrue('the third socket stayed open',
        PeerClosed(C3, CapResponseTimeoutMs));
    finally
      C3.Free;
    end;
  finally
    C1.Free;
    C2.Free;
  end;
  // the closed connection frees its slot, so a new socket serves again
  AssertTrue('no slot freed after the close',
    SlotFreed(Port, 15000));
end;

procedure TAsyncCapsTest.TestSocketOptionsApply;
var
  Port: Integer;
  Client: TCapClient;
  Fd: TSocket;
  Options: TSocketOptions;
begin
  Port := StartServer(100);
  Client := TCapClient.Create(Port);
  try
    Fd := TSocket(Client.Sock.Sock.Socket);
    Options := TSocketOptions.Create
      .WithTcpNoDelay(True)
      .WithKeepAliveIdleSec(60)
      .WithKeepAliveIntervalSec(10)
      .WithKeepAliveCount(5)
      .WithSendBufferBytes(32768)
      .WithRecvBufferBytes(32768);
    ApplySocketOptions(Client.Sock.Sock, Options);
    // Darwin answers the flag bits (4) and not 1, so any nonzero value
    // means on
    AssertTrue('no-delay is on',
      GetSockInt(Fd, IPPROTO_TCP, TCP_NODELAY) <> 0);
    // Darwin answers the flag bits here too, so any nonzero value means on
    AssertTrue('keep-alive is on',
      GetSockInt(Fd, SOL_SOCKET, SO_KEEPALIVE) <> 0);
    AssertEquals('the idle time is 60', 60,
      GetSockInt(Fd, IPPROTO_TCP, cCapTcpKeepIdle));
    AssertEquals('the interval is 10', 10,
      GetSockInt(Fd, IPPROTO_TCP, cCapTcpKeepIntvl));
    AssertEquals('the count is 5', 5,
      GetSockInt(Fd, IPPROTO_TCP, cCapTcpKeepCnt));
    AssertTrue('the send buffer is at least 32768',
      GetSockInt(Fd, SOL_SOCKET, SO_SNDBUF) >= 32768);
    AssertTrue('the receive buffer is at least 32768',
      GetSockInt(Fd, SOL_SOCKET, SO_RCVBUF) >= 32768);
    // the chosen value is set even when it turns the option off
    ApplySocketOptions(Client.Sock.Sock,
      TSocketOptions.Create.WithTcpNoDelay(False));
    AssertEquals('no-delay is off', 0,
      GetSockInt(Fd, IPPROTO_TCP, TCP_NODELAY));
  finally
    Client.Free;
  end;
end;

function TAsyncCapsTest.ListenerSharesPort: Boolean;
var
  S1, S2: TNetSocket;
  Addr: TNetAddr;
begin
  Result := False;
  S1 := nil;
  S2 := nil;
  try
    // the same bind path as the server without the reuse-port option
    if NewSocket('127.0.0.1', '0', nlTcp, True, 0, 0, 0, 0, S1,
      @Addr, False) <> nrOk then
      exit;
    Result := NewSocket('127.0.0.1', RawUtf8(IntToStr(Addr.Port)), nlTcp,
      True, 0, 0, 0, 0, S2, nil, False) = nrOk;
  finally
    if S1 <> nil then
      S1.ShutdownAndClose(False);
    if S2 <> nil then
      S2.ShutdownAndClose(False);
  end;
end;

procedure TAsyncCapsTest.TestReusePortOffRefusesSecondBind;
var
  First, Second: THttp2AsyncServer;
  Factory: THttp2ServerFactory;
  Port: Integer;
  Refused: Boolean;
begin
  // mORMot2 sets SO_REUSEPORT on every listener on Darwin, so the second
  // bind holds there even with the option off
  if ListenerSharesPort then
  begin
    WriteLn('the default bind shares a port here; the bind-refusal test ',
      'ends without a check');
    exit;
  end;
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TCapEchoHandler.Create);
  First := THttp2AsyncServer.Create(Factory);
  try
    First.Start;
    Port := First.BoundPort;
    Factory := THttp2ServerFactory.Create
      .WithHost('127.0.0.1')
      .WithPort(Port)
      .WithClearTextAllowed(True)
      .WithHandler(TCapEchoHandler.Create);
    Second := THttp2AsyncServer.Create(Factory);
    try
      Refused := False;
      try
        Second.Start;
      except
        on Exception do
          Refused := True;
      end;
      AssertTrue('the second bind held the same port', Refused);
    finally
      Second.Free;
    end;
  finally
    First.Free;
  end;
end;

procedure TAsyncCapsTest.TestReusePortOnSharesPort;
var
  First, Second: THttp2AsyncServer;
  Factory: THttp2ServerFactory;
  Port: Integer;
  Client: TCapClient;
  Body: TBytes;
begin
  if not ReusePortWorks then
  begin
    WriteLn('SO_REUSEPORT is not available; the port-sharing test ends ',
      'without a check');
    exit;
  end;
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TCapEchoHandler.Create)
    .WithSocketOptions(TSocketOptions.Create.WithReusePort(True));
  First := THttp2AsyncServer.Create(Factory);
  try
    First.Start;
    Port := First.BoundPort;
    Factory := THttp2ServerFactory.Create
      .WithHost('127.0.0.1')
      .WithPort(Port)
      .WithClearTextAllowed(True)
      .WithHandler(TCapEchoHandler.Create)
      .WithSocketOptions(TSocketOptions.Create.WithReusePort(True));
    Second := THttp2AsyncServer.Create(Factory);
    try
      Second.Start;
      // the shared port still serves a request
      Client := TCapClient.Create(Port);
      try
        Client.SendGet(1, CapRequestPath);
        AssertTrue('the shared port gave no response',
          Client.WaitForResponse(1, CapResponseTimeoutMs, Body));
        AssertEquals(CapResponseBody, CapTextOf(Body));
      finally
        Client.Free;
      end;
    finally
      Second.Free;
    end;
  finally
    First.Free;
  end;
end;

initialization
  RegisterTest(TAsyncCapsTest);
end.
