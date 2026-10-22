{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http1, upgrade, handshake, origin, subprotocol, live, test, fpcunit
notes:
  - This unit tests the WebSocket upgrade on HTTP/1.1 on a running server with a
    raw-socket client. It covers the accept key, the checks of RFC 6455 section 4.2.1
    in their order, Init, the origin policy, the subprotocol rule, and a session over
    the upgraded connection.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Live tests of the WebSocket upgrade over HTTP/1.1
unit Http2Server.Ws.Http1.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server, Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam,
  Http2Server.Ws.Handshake, Http2Server.Ws.Frames, Http2Server.Ws.Types,
  Http2Server.Http1.RawClient, Http2Server.Ws.TestKit;

type
  /// routes: /ws upgrades, anything else answers a plain body
  TWsRouter = class(TInterfacedObject, IHttp2Handler)
  private
    FCalls: Integer;
  public
    Handler: IWsHandler;
    procedure Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
    function Calls: Integer;
  end;

  TWsHandshakeUnitTest = class(TTestCase)
  published
    procedure TestTheAcceptKeyOfRfc6455;
    procedure TestKeyValidity;
    procedure TestFieldTokens;
    procedure TestSubprotocolSelectionIsCaseSensitive;
  end;

  TWsHttp1Test = class(TTestCase)
  private
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function Upgrade(const AExtra: string = ''; const AKey: string = 'dGhlIHNhbXBsZSBub25jZQ==';
      const AVersion: string = '13'; const AMethod: string = 'GET';
      const AVersionLine: string = 'HTTP/1.1'): string;
    function Open(out AClient: TRawHttp; out AHead: TRawResponse; const AExtra: string = ''): Boolean;
    function Frames(const ASome: string): TStringList;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestHandshakeAnswers101WithTheAcceptKey;
    procedure TestInitSeesTheHeadersAndTheCookie;
    procedure TestRejectWith401AndHeaderThenKeepAlive;
    procedure TestNo101BeforeInitDecides;
    procedure TestGreetingFromInitFollowsTheResponse;
    procedure TestEachCheckFailsWithItsStatusAndInitNeverRuns;
    procedure TestOriginPolicy;
    procedure TestSubprotocolIsNegotiated;
    procedure TestBodyAndPipelinedOctetsAreRefused;
    procedure TestEchoOverOneHundredMessages;
    procedure TestPingIsAnswered;
    procedure TestCleanCloseEndsTheConnection;
    procedure TestAbnormalCloseIs1006;
    procedure TestStopSendsGoingAway;
    procedure TestTheDetachLimitAnswers503;
  end;

/// wait until the recording of the handler holds AText; false after five seconds
function WaitUntilText(const AHandler: TRecordingHandler; const AText: string): Boolean;

implementation

function WaitUntilText(const AHandler: TRecordingHandler; const AText: string): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 5000;
  repeat
    if Pos(AText, AHandler.AllText) > 0 then
      Exit(True);
    Sleep(5);
  until GetTickCount64 > Deadline;
  Result := Pos(AText, AHandler.AllText) > 0;
end;

{ TWsRouter }

procedure TWsRouter.Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
var
  H: THeaderBlock;
begin
  Inc(FCalls);
  if ARequest.Path = '/ws' then
  begin
    AcceptWebSocket(ARequest, AResponse, Handler);
    Exit;
  end;
  SetLength(H, 1);
  H[0].Name := 'content-length';
  H[0].Value := '2';
  AResponse.SendHeaders(200, H, False);
  AResponse.Write(BytesOf('ok'));
  AResponse.Finish;
end;

function TWsRouter.Calls: Integer;
begin
  Result := FCalls;
end;

{ TWsHandshakeUnitTest }

procedure TWsHandshakeUnitTest.TestTheAcceptKeyOfRfc6455;
begin
  // RFC 6455 section 1.3
  AssertEquals('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', WsAcceptKey('dGhlIHNhbXBsZSBub25jZQ=='));
end;

procedure TWsHandshakeUnitTest.TestKeyValidity;
begin
  AssertTrue(WsKeyIsValid('dGhlIHNhbXBsZSBub25jZQ=='));
  AssertTrue('surrounding white space is trimmed', WsKeyIsValid(' dGhlIHNhbXBsZSBub25jZQ== '));
  AssertFalse('too short', WsKeyIsValid('dGhlIHNhbXBsZQ=='));
  AssertFalse('empty', WsKeyIsValid(''));
  AssertFalse('not base64', WsKeyIsValid('!!!!!!!!!!!!!!!!!!!!!!=='));
  AssertFalse('17 octets', WsKeyIsValid('dGhlIHNhbXBsZSBub25jZXE='));
  AssertFalse('no padding', WsKeyIsValid('dGhlIHNhbXBsZSBub25jZQAA'));
end;

procedure TWsHandshakeUnitTest.TestFieldTokens;
var
  H: THeaderBlock;
  T: TArray<string>;
begin
  SetLength(H, 3);
  H[0].Name := 'Sec-WebSocket-Protocol';
  H[0].Value := ' chat , superchat';
  H[1].Name := 'x';
  H[1].Value := 'no';
  H[2].Name := 'sec-websocket-protocol';
  H[2].Value := 'v2,,';
  T := WsFieldTokens(H, 'sec-websocket-protocol');
  AssertEquals(3, Length(T));
  AssertEquals('chat', T[0]);
  AssertEquals('superchat', T[1]);
  AssertEquals('v2', T[2]);
  AssertTrue(WsHasToken(T, 'CHAT'));
  AssertFalse(WsHasToken(T, 'CHAT', True));
  AssertEquals(2, WsFieldCount(H, 'SEC-WEBSOCKET-PROTOCOL'));
end;

procedure TWsHandshakeUnitTest.TestSubprotocolSelectionIsCaseSensitive;
var
  H: THeaderBlock;
  T: TArray<string>;
begin
  SetLength(H, 1);
  H[0].Name := 'sec-websocket-protocol';
  H[0].Value := 'Chat, json, v2';
  T := WsOfferedSubprotocols(H, nil);
  AssertEquals('an empty server list passes every offer on', 3, Length(T));
  T := WsOfferedSubprotocols(H, TArray<string>.Create('chat', 'json'));
  AssertEquals('only the tokens the server holds, with the exact case', 1, Length(T));
  AssertEquals('json', T[0]);
end;

{ TWsHttp1Test }

procedure TWsHttp1Test.SetUp;
begin
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
end;

procedure TWsHttp1Test.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
end;

procedure TWsHttp1Test.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function TWsHttp1Test.Upgrade(const AExtra, AKey, AVersion, AMethod, AVersionLine: string): string;
begin
  Result := AMethod + ' /ws ' + AVersionLine + CRLF + 'Host: localhost' + CRLF +
    'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF;
  if AKey <> '' then
    Result := Result + 'Sec-WebSocket-Key: ' + AKey + CRLF;
  if AVersion <> '' then
    Result := Result + 'Sec-WebSocket-Version: ' + AVersion + CRLF;
  Result := Result + AExtra + CRLF;
end;

function TWsHttp1Test.Open(out AClient: TRawHttp; out AHead: TRawResponse;
  const AExtra: string): Boolean;
begin
  AClient := TRawHttp.Create(FServer.Port);
  AClient.Send(Upgrade(AExtra));
  Result := AClient.ReadHead(ResponseMs, AHead) and (AHead.Status = 101);
end;

function TWsHttp1Test.Frames(const ASome: string): TStringList;
begin
  Result := DecodeOutput(BytesOf(ASome));
end;

procedure TWsHttp1Test.TestHandshakeAnswers101WithTheAcceptKey;
var
  C: TRawHttp;
  H: TRawResponse;
begin
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H));
  try
    AssertEquals('websocket', LowerCase(H.Header('upgrade')));
    AssertEquals('upgrade', LowerCase(H.Header('connection')));
    AssertEquals('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', H.Header('sec-websocket-accept'));
    AssertEquals('no extension is offered', '', H.Header('sec-websocket-extensions'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestInitSeesTheHeadersAndTheCookie;
var
  C: TRawHttp;
  H: TRawResponse;
begin
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H, 'Cookie: sid=42' + CRLF));
  try
    AssertTrue(Pos('cookie=sid=42', FRecording.Line(0)) > 0);
    AssertEquals('Init runs on the streaming pool', 'pool', FRecording.ThreadOf(0));
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestRejectWith401AndHeaderThenKeepAlive;
var
  C: TRawHttp;
  R: TRawResponse;
  Res: TWsInitResult;
  H: THeaderBlock;
begin
  Res := TWsInitResult.Rejected(401);
  SetLength(H, 1);
  H[0].Name := 'www-authenticate';
  H[0].Value := 'Basic realm="x"';
  Res.RejectHeaders := H;
  Res.RejectBody := BytesOf('denied');
  FRecording.InitResult := Res;
  StartServer(LiveFactory(FRouterRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(Upgrade);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(401, R.Status);
    AssertEquals('Basic realm="x"', R.Header('www-authenticate'));
    AssertEquals('denied', R.Body);
    // the connection serves HTTP/1.1 again
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('ok', R.Body);
    AssertFalse(C.Closed);
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestNo101BeforeInitDecides;
var
  C: TRawHttp;
  H: TRawResponse;
  Early: string;
begin
  FRecording.InitSleepMs := 400;
  StartServer(LiveFactory(FRouterRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(Upgrade);
    Early := C.ReadSome(150);
    AssertEquals('nothing goes out while Init runs', '', Early);
    AssertTrue(C.ReadHead(ResponseMs, H));
    AssertEquals(101, H.Status);
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestGreetingFromInitFollowsTheResponse;
var
  C: TRawHttp;
  H: TRawResponse;
  L: TStringList;
begin
  FRecording.InitSend := BytesOf('hello client');
  FRecording.InitSendText := True;
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H));
  try
    L := Frames(C.ReadSome(300));
    try
      AssertEquals('T:hello client', L.Text.Trim);
    finally
      L.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestEachCheckFailsWithItsStatusAndInitNeverRuns;
var
  C: TRawHttp;
  R: TRawResponse;

  procedure Expect(const AName, ARequest: string; const AStatus: Integer);
  begin
    C := TRawHttp.Create(FServer.Port);
    try
      C.Send(ARequest);
      AssertTrue(AName + ': a response', C.ReadResponse(False, ResponseMs, R));
      AssertEquals(AName, AStatus, R.Status);
    finally
      C.Free;
    end;
  end;

begin
  StartServer(LiveFactory(FRouterRef));
  Expect('a POST', Upgrade('', 'dGhlIHNhbXBsZSBub25jZQ==', '13', 'POST'), 405);
  Expect('HTTP/1.0', Upgrade('', 'dGhlIHNhbXBsZSBub25jZQ==', '13', 'GET', 'HTTP/1.0'), 400);
  Expect('no key', Upgrade('', '', '13'), 400);
  Expect('a bad key', Upgrade('', 'short', '13'), 400);
  Expect('no version', Upgrade('', 'dGhlIHNhbXBsZSBub25jZQ==', ''), 400);
  Expect('no Upgrade token', 'GET /ws HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF +
    'Sec-WebSocket-Version: 13' + CRLF + CRLF, 400);
  Expect('no Connection token', 'GET /ws HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    'Upgrade: websocket' + CRLF + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF +
    'Sec-WebSocket-Version: 13' + CRLF + CRLF, 400);
  // the version answer names the version the server speaks
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(Upgrade('', 'dGhlIHNhbXBsZSBub25jZQ==', '12'));
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(400, R.Status);
    AssertEquals('13', R.Header('sec-websocket-version'));
    // the connection stays open for the next request
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('ok', R.Body);
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHttp1Test.TestOriginPolicy;
var
  C: TRawHttp;
  R: TRawResponse;

  function Try_(const AOrigin: string): Integer;
  begin
    C := TRawHttp.Create(FServer.Port);
    try
      C.Send(Upgrade(AOrigin));
      if C.ReadHead(ResponseMs, R) then
        Result := R.Status
      else
        Result := 0;
    finally
      C.Free;
    end;
  end;

begin
  StartServer(LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create
    .WithOriginPolicy(opAllowList)
    .WithAllowedOrigins(TArray<string>.Create('https://partner.example'))));
  AssertEquals('no Origin', 101, Try_(''));
  AssertEquals('the same origin', 101, Try_('Origin: http://localhost' + CRLF));
  AssertEquals('an allowed origin', 101, Try_('Origin: https://partner.example' + CRLF));
  AssertEquals('a foreign origin', 403, Try_('Origin: https://evil.test' + CRLF));
  AssertEquals('null', 403, Try_('Origin: null' + CRLF));
  AssertEquals('a malformed origin', 400, Try_('Origin: https://partner.example/x' + CRLF));
  AssertEquals('two Origin fields', 400, Try_('Origin: http://localhost' + CRLF +
    'Origin: http://localhost' + CRLF));
end;

procedure TWsHttp1Test.TestSubprotocolIsNegotiated;
var
  C: TRawHttp;
  H: TRawResponse;
begin
  FRecording.InitResult := TWsInitResult.AcceptedWith('json');
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H, 'Sec-WebSocket-Protocol: chat, json' + CRLF));
  try
    AssertEquals('json', H.Header('sec-websocket-protocol'));
    AssertTrue('Init saw the offer', Pos('offered=chat,json,', FRecording.Line(0)) > 0);
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestBodyAndPipelinedOctetsAreRefused;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FRouterRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /ws HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Upgrade: websocket' + CRLF +
      'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF +
      'Sec-WebSocket-Version: 13' + CRLF + 'Content-Length: 5' + CRLF + CRLF + 'hello');
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('a request with a body', 400, R.Status);
  finally
    C.Free;
  end;
  C := TRawHttp.Create(FServer.Port);
  try
    // octets right after the head, in the same write
    C.Send(Upgrade + 'GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('pipelined octets after the head', 400, R.Status);
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHttp1Test.TestEchoOverOneHundredMessages;
var
  C: TRawHttp;
  H: TRawResponse;
  I: Integer;
  S: string;
  L: TStringList;
  Deadline: QWord;
begin
  FRecording.Echo := True;
  // HTTP/1.1 has no flow control, so a burst of 100 messages needs a queue to match;
  // with the default cap of 16 the session closes with 1008
  StartServer(LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)));
  AssertTrue(Open(C, H));
  try
    for I := 1 to 100 do
      C.Send(TextOf(ClientText('message ' + IntToStr(I), True, WsOpText)));
    S := '';
    Deadline := GetTickCount64 + ResponseMs;
    repeat
      S := S + C.ReadSome(100);
      L := Frames(S);
      try
        if L.Count >= 100 then
          Break;
      finally
        L.Free;
      end;
    until GetTickCount64 > Deadline;
    L := Frames(S);
    try
      AssertEquals(100, L.Count);
      AssertEquals('T:message 1', L[0]);
      AssertEquals('T:message 100', L[99]);
    finally
      L.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestPingIsAnswered;
var
  C: TRawHttp;
  H: TRawResponse;
  L: TStringList;
begin
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H));
  try
    C.Send(TextOf(ClientFrame(WsOpPing, True, BytesOf('abc'))));
    L := Frames(C.ReadSome(300));
    try
      AssertEquals('O:616263', L.Text.Trim);
    finally
      L.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestCleanCloseEndsTheConnection;
var
  C: TRawHttp;
  H: TRawResponse;
  L: TStringList;
begin
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H));
  try
    C.Send(TextOf(ClientClose(1000, 'bye')));
    L := Frames(C.ReadSome(300));
    try
      AssertEquals('the server echoes the code', 'C:1000:', L.Text.Trim);
    finally
      L.Free;
    end;
    AssertTrue('the server closes the TCP connection', C.WaitClosed(ResponseMs));
    AssertTrue(WaitUntilText(FRecording, 'closed 1000 bye clean=True'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestAbnormalCloseIs1006;
var
  C: TRawHttp;
  H: TRawResponse;
begin
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H));
  C.Free;
  AssertTrue(WaitUntilText(FRecording, 'closed 1006'));
end;

procedure TWsHttp1Test.TestStopSendsGoingAway;
var
  C: TRawHttp;
  H: TRawResponse;
  L: TStringList;
begin
  StartServer(LiveFactory(FRouterRef));
  AssertTrue(Open(C, H));
  try
    FServer.Stop;
    L := Frames(C.ReadSome(500));
    try
      AssertTrue('Close 1001 reached the client: ' + L.Text, Pos('C:1001:', L.Text) > 0);
    finally
      L.Free;
    end;
    AssertTrue(WaitUntilText(FRecording, 'closed 1001'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp1Test.TestTheDetachLimitAnswers503;
var
  A, B: TRawHttp;
  H, R: TRawResponse;
begin
  StartServer(LiveFactory(FRouterRef).WithMaxDetachedStreams(1));
  AssertTrue(Open(A, H));
  B := TRawHttp.Create(FServer.Port);
  try
    B.Send(Upgrade);
    AssertTrue(B.ReadResponse(False, ResponseMs, R));
    AssertEquals(503, R.Status);
  finally
    A.Free;
    B.Free;
  end;
end;

initialization
  RegisterTest(TWsHandshakeUnitTest);
  RegisterTest(TWsHttp1Test);

end.
