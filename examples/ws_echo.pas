{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, http1, websocket, example, echo, browser
notes:
  - This example serves a WebSocket echo on port 8084 at the path /ws, and a page with
    a small browser client at /. One handler serves HTTP/1.1 and HTTP/2 clients.
  - Open http://127.0.0.1:8084/ in a browser, type a message and send it. The page
    shows the echo. A client such as websocat can connect to ws://127.0.0.1:8084/ws.
  - The echo handler sends every message back as it received it, with the same type.
    Init accepts every upgrade and picks the subprotocol echo when the client offers it.
  - The queue of messages is larger than the default, because an HTTP/1.1 client sends
    a burst without flow control (see doc/design/websocket.md).
  - The server runs until the caller presses Enter, then stops.
  - There are three optional arguments. They are the host (default 127.0.0.1), the port (default 8084) and the
    word big, which raises the message limits to 32 MiB for a conformance run. The word
    load raises the limit of detached streams to 30000 for a load run.
---
}
/// A WebSocket echo server with a browser page
program ws_echo;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Math,
  mormot.core.base,
  Http2Server;

const
  Page =
    '<!doctype html><meta charset="utf-8"><title>WebSocket echo</title>' +
    '<h1>WebSocket echo</h1><input id="m" size="40" value="hello"> ' +
    '<button id="s">send</button><pre id="log"></pre><script>' +
    'var log=document.getElementById("log");' +
    'function add(t){log.textContent+=t+"\n";}' +
    'var ws=new WebSocket((location.protocol=="https:"?"wss://":"ws://")+location.host+"/ws","echo");' +
    'ws.onopen=function(){add("open, subprotocol "+ws.protocol);};' +
    'ws.onmessage=function(e){add("echo: "+e.data);};' +
    'ws.onclose=function(e){add("closed "+e.code);};' +
    'document.getElementById("s").onclick=function(){ws.send(document.getElementById("m").value);};' +
    '</script>';

type
  /// the application side of a session: it echoes every message
  TEchoHandler = class(TInterfacedObject, IWsHandler)
  public
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// the handler of the routes: /ws upgrades, / serves the page
  TRouter = class(TInterfacedObject, IHttp2Handler)
  private
    FEcho: IWsHandler;
  public
    constructor Create;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

function WantsUpgrade(const ARequest: IServerRequest): Boolean;
var
  I: Integer;
  H: THeaderBlock;
begin
  H := ARequest.Headers;
  for I := 0 to High(H) do
    if SameText(H[I].Name, 'sec-websocket-key') then
      Exit(True);
  Result := False;
end;

function TEchoHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
var
  I: Integer;
begin
  // the session may start sending in Init; the frames leave after the handshake
  for I := 0 to High(AOffered) do
    if AOffered[I] = 'echo' then
      Exit(TWsInitResult.AcceptedWith('echo'));
  Result := TWsInitResult.Accepted;
end;

procedure TEchoHandler.Message(const ASession: IWsSession; const AData: TBytes;
  const AText: Boolean);
begin
  // a refused send means the outbound queue is full; the example drops the echo
  ASession.Send(AData, AText);
end;

procedure TEchoHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TEchoHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  WriteLn('session ', ASession.Id, ' closed with ', ACode, ' ', AReason);
end;

procedure TEchoHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
  WriteLn('session ', ASession.Id, ' failed: ', E.Message);
end;

constructor TRouter.Create;
begin
  inherited Create;
  FEcho := TEchoHandler.Create;
end;

procedure TRouter.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  H: THeaderBlock;
  Body: TBytes;
begin
  // the path /ws upgrades, and so does any request that carries a WebSocket key, which
  // is how a conformance client asks
  if (ARequest.Path = '/ws') or WantsUpgrade(ARequest) then
  begin
    // a False answer means that an error response went out; the handler returns
    AcceptWebSocket(ARequest, AResponse, FEcho);
    Exit;
  end;
  SetLength(Body, Length(Page));
  Move(Page[1], Body[0], Length(Page));
  SetLength(H, 2);
  H[0].Name := 'content-type';
  H[0].Value := 'text/html; charset=utf-8';
  H[1].Name := 'content-length';
  H[1].Value := IntToStr(Length(Body));
  AResponse.SendHeaders(200, H, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

var
  Server: IHttp2Server;
  Line, Host: string;
  Port: Integer;
  Options: TWsOptions;
begin
  Host := '127.0.0.1';
  if ParamCount >= 1 then
    Host := ParamStr(1);
  Port := 8084;
  if ParamCount >= 2 then
    Port := StrToIntDef(ParamStr(2), 8084);
  Options := TWsOptions.Create.WithQueuedMessages(256);
  if (ParamCount >= 3) and (ParamStr(3) = 'big') then
    Options := Options.WithMaxMessageSize(33554432).WithMaxFrameSize(33554432)
      .WithMaxFragments(100000).WithPingIntervalMs(0)
      .WithMessageBucket(TTokenBucketOptions.Create.WithCapacity(1000000)
        .WithRefillPerSecond(1000000));
  Server := THttp2ServerFactory.Create
    .WithMaxConcurrentStreams(256)
    .WithMaxDetachedStreams(IfThen((ParamCount >= 3) and (ParamStr(3) = 'load'), 30000, 10000))
    .WithHost(Host)
    .WithPort(Port)
    .WithClearTextAllowed(True)
    .WithHandler(TRouter.Create)
    .WithWebSockets(Options)
    .Build;
  Server.Start;
  WriteLn('WebSocket echo on http://', Host, ':', Server.Port, '/ ; press Enter to stop');
  Flush(Output);
  ReadLn(Line);
  Server.Stop;
end.
