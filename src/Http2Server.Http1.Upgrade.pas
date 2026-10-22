{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, upgrade, websocket, handshake, 101, sec-websocket-accept, rfc 6455
notes:
  - This unit accepts a WebSocket upgrade on HTTP/1.1 (RFC 6455 section 4.2). It
    runs the cheap checks first, in a fixed order. A failed check answers an ordinary
    HTTP error response and leaves the connection for the next request. After the
    checks it detaches the response into a raw channel at once and starts the
    session, whose first task is IWsHandler.Init.
  - No 101 goes out before Init accepts. The 101 response carries Upgrade, Connection
    and Sec-WebSocket-Accept, and Sec-WebSocket-Protocol when a subprotocol is chosen.
    The server sends no Sec-WebSocket-Extensions field, because it supports no
    extension.
  - A request with a body, or with octets after the head, is refused, so the server
    never reads WebSocket octets as HTTP.
---
}
/// The WebSocket upgrade over HTTP/1.1
unit Http2Server.Http1.Upgrade;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam,
  Http2Server.Duplex, Http2Server.Http1.SocketChannel, Http2Server.Ws.Types;

type
  /// the 101 response of an accepted upgrade
  THttp1WsHandshake = class(TInterfacedObject, IWsHandshake)
  private
    FKey: string;
  public
    constructor Create(const AKey: string);
    function Activation(const ASubprotocol: string;
      const AExtra: THeaderBlock): TWsActivation;
  end;

/// check the upgrade request and start the session
// - answers True when the session started; Init decides the rest
// - answers False after an error response; the handler then returns
function Http1AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AUpgrade: IH1Upgradable;
  const AHandler: IWsHandler): Boolean;

implementation

uses
  Http2Server.Ws.Handshake, Http2Server.Ws.Origin, Http2Server.Ws.Session;

constructor THttp1WsHandshake.Create(const AKey: string);
begin
  inherited Create;
  FKey := AKey;
end;

function THttp1WsHandshake.Activation(const ASubprotocol: string;
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
  Result.Status := 101;
  N := 0;
  Add('upgrade', 'websocket');
  Add('connection', 'Upgrade');
  Add('sec-websocket-accept', WsAcceptKey(FKey));
  if ASubprotocol <> '' then
    Add('sec-websocket-protocol', ASubprotocol);
  for I := 0 to High(AExtra) do
  begin
    // the protocol fields belong to the server
    if SameText(AExtra[I].Name, 'upgrade') or SameText(AExtra[I].Name, 'connection') or
       SameText(AExtra[I].Name, 'sec-websocket-accept') or
       SameText(AExtra[I].Name, 'sec-websocket-protocol') or
       SameText(AExtra[I].Name, 'sec-websocket-extensions') then
      raise EHttpError.Create('Init set the handshake field ' + AExtra[I].Name);
    Add(AExtra[I].Name, AExtra[I].Value);
  end;
end;

/// answer an error with no body and leave the connection for the next request
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

function Http1AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AUpgrade: IH1Upgradable;
  const AHandler: IWsHandler): Boolean;
var
  Env: IWsEnvironment;
  Headers: THeaderBlock;
  Key: string;
  Verdict: TWsOriginVerdict;
  Channel: IDuplexChannel;
  Offered: TArray<string>;
begin
  Result := False;
  if not Supports(AUpgrade.WsEnvironment, IWsEnvironment, Env) then
    raise EHttpError.Create('the server has no WebSocket environment');
  Headers := ARequest.Headers;

  // the checks of RFC 6455 section 4.2.1, cheap ones first
  if AUpgrade.UpgradeMethod <> 'GET' then
  begin
    Refuse(AResponse, 405, 'allow', 'GET');
    Exit;
  end;
  if (AUpgrade.UpgradeMinor < 1) or not AUpgrade.UpgradeTokensPresent then
  begin
    Refuse(AResponse, 400);
    Exit;
  end;
  Key := WsFirstField(Headers, 'sec-websocket-key');
  if (WsFieldCount(Headers, 'sec-websocket-key') <> 1) or not WsKeyIsValid(Key) then
  begin
    Refuse(AResponse, 400);
    Exit;
  end;
  if (WsFieldCount(Headers, 'sec-websocket-version') <> 1) or
     (Trim(WsFirstField(Headers, 'sec-websocket-version')) <> '13') then
  begin
    // RFC 6455 section 4.4: the answer names the version that the server speaks
    Refuse(AResponse, 400, 'sec-websocket-version', '13');
    Exit;
  end;
  Verdict := WsCheckUpgradeOrigin(Env.Options, ARequest.Scheme, ARequest.Authority, Headers);
  if not Verdict.Accept then
  begin
    Refuse(AResponse, Verdict.Status);
    Exit;
  end;
  if AUpgrade.HasRequestBody or (AUpgrade.BufferedAfterHead > 0) then
  begin
    Refuse(AResponse, 400);
    Exit;
  end;

  Offered := WsOfferedSubprotocols(Headers, Env.Options.Subprotocols);
  try
    Channel := AUpgrade.DetachForUpgrade;
  except
    on EDetachRefused do
    begin
      Refuse(AResponse, 503, 'retry-after', '1');
      Exit;
    end;
  end;
  // the session takes the channel; Init runs next, on the streaming pool
  WsStartSession(Channel, ARequest, AHandler, THttp1WsHandshake.Create(Key), Offered);
  Result := True;
end;

end.
