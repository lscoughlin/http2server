{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, websocket, extended connect, rfc 8441, handshake
notes:
  - This unit accepts a WebSocket on an HTTP/2 stream with the extended CONNECT method
    of RFC 8441. The request has the method CONNECT and the pseudo-header :protocol
    with the value websocket. It has no key and no Upgrade field.
  - The checks run in a fixed order. A failed check answers an ordinary HTTP response
    with END_STREAM, and the HTTP/2 connection stays open. After the checks the unit
    detaches the stream at once and starts the session, whose first task is
    IWsHandler.Init.
  - The success response is 200, without END_STREAM, with sec-websocket-protocol when a
    subprotocol is chosen (RFC 8441 section 5). RFC 8441 and RFC 6455 were checked on
    2026-10-22 at https://www.rfc-editor.org/info/rfc8441 and
    https://www.rfc-editor.org/info/rfc6455.
---
}
/// The WebSocket handshake over HTTP/2
unit Http2Server.Ws.Http2;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam,
  Http2Server.Duplex, Http2Server.StreamAdapters, Http2Server.Ws.Types;

type
  /// the 200 response of an accepted extended CONNECT
  THttp2WsHandshake = class(TInterfacedObject, IWsHandshake)
  public
    function Activation(const ASubprotocol: string;
      const AExtra: THeaderBlock): TWsActivation;
  end;

/// check the extended CONNECT and start the session
// - answers True when the session started; Init decides the rest
// - answers False after an error response; the handler then returns
function Http2AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AUpgrade: IH2Upgradable;
  const AHandler: IWsHandler): Boolean;

implementation

uses
  Http2Server.Ws.Handshake, Http2Server.Ws.Origin, Http2Server.Ws.Session;

function THttp2WsHandshake.Activation(const ASubprotocol: string;
  const AExtra: THeaderBlock): TWsActivation;
var
  N, I: Integer;

  procedure Add(const AName, AValue: string);
  begin
    SetLength(Result.Headers, N + 1);
    Result.Headers[N].Name := AName;
    Result.Headers[N].Value := AValue;
    Result.Headers[N].Sensitive := False;
    Inc(N);
  end;

begin
  Result := Default(TWsActivation);
  Result.Status := 200;
  N := 0;
  if ASubprotocol <> '' then
    Add('sec-websocket-protocol', ASubprotocol);
  for I := 0 to High(AExtra) do
  begin
    if SameText(AExtra[I].Name, 'sec-websocket-protocol') or
       SameText(AExtra[I].Name, 'sec-websocket-extensions') or
       SameText(AExtra[I].Name, 'sec-websocket-accept') then
      raise EHttpError.Create('Init set the handshake field ' + AExtra[I].Name);
    Add(AExtra[I].Name, AExtra[I].Value);
  end;
end;

/// answer an error with no body; the HTTP/2 connection stays open
procedure Refuse(const AResponse: IServerResponse; const AStatus: Integer;
  const AExtraName: string = ''; const AExtraValue: string = '');
var
  H: THeaderBlock;
begin
  H := nil;
  SetLength(H, 1);
  H[0].Name := 'content-length';
  H[0].Value := '0';
  if AExtraName <> '' then
  begin
    SetLength(H, 2);
    H[1].Name := AExtraName;
    H[1].Value := AExtraValue;
  end;
  AResponse.SendHeaders(AStatus, H, True);
end;

function Http2AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AUpgrade: IH2Upgradable;
  const AHandler: IWsHandler): Boolean;
var
  Env: IWsEnvironment;
  Headers: THeaderBlock;
  Conn: IH2ConnectRequest;
  Verdict: TWsOriginVerdict;
  Channel: IDuplexChannel;
  Offered: TArray<string>;
begin
  Result := False;
  if not Supports(AUpgrade.WsEnvironment, IWsEnvironment, Env) then
    raise EHttpError.Create('the server has no WebSocket environment');
  Headers := ARequest.Headers;

  // RFC 8441 section 4: the method is CONNECT and :protocol is websocket
  if not Supports(ARequest, IH2ConnectRequest, Conn) or (ARequest.Method <> 'CONNECT') then
  begin
    Refuse(AResponse, 405, 'allow', 'CONNECT');
    Exit;
  end;
  if Conn.Protocol <> 'websocket' then
  begin
    Refuse(AResponse, 501);
    Exit;
  end;
  if (WsFieldCount(Headers, 'sec-websocket-version') <> 1) or
     (Trim(WsFirstField(Headers, 'sec-websocket-version')) <> '13') then
  begin
    Refuse(AResponse, 400, 'sec-websocket-version', '13');
    Exit;
  end;
  Verdict := WsCheckUpgradeOrigin(Env.Options, ARequest.Scheme, ARequest.Authority, Headers);
  if not Verdict.Accept then
  begin
    Refuse(AResponse, Verdict.Status);
    Exit;
  end;

  Offered := WsOfferedSubprotocols(Headers, Env.Options.Subprotocols);
  try
    Channel := AResponse.Detach;
  except
    on EDetachRefused do
    begin
      Refuse(AResponse, 503, 'retry-after', '1');
      Exit;
    end;
  end;
  WsStartSession(Channel, ARequest, AHandler, THttp2WsHandshake.Create, Offered);
  Result := True;
end;

end.
