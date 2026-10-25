{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, live, server side, handler, websocket, observer
notes:
  - This unit is the server side of the live mutual TLS validation. The handler
    answers the identity it sees, so a client can check what a handler reads.
  - The WebSocket handler records the identity at Init and again at Message, from
    the session snapshot, so the check covers a session that outlives the
    handler call of the upgrade.
---
}
/// The server side of the live mutual TLS validation
unit Http2Server.Mtls.Live.Server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  mormot.core.base, mormot.core.os,
  Http2Server;

type
  /// the observer that counts failed handshakes
  TMtlsObserver = class(TInterfacedObject, IHttp2ServerObserver)
  public
    Failed: Integer;
    procedure OnEvent(const AEvent: TServerEvent);
  end;

  /// the WebSocket handler that records the identity it sees
  TMtlsWsHandler = class(TInterfacedObject, IWsHandler)
  private
    FLock: TCriticalSection;
    FInitId, FMessageId: string;
  public
    MessageSeen: TEvent;
    constructor Create;
    destructor Destroy; override;
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
    function InitId: string;
    function MessageId: string;
    procedure Reset;
  end;

  /// the handler: GET /id answers the identity, /ws opens a WebSocket
  TMtlsHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FWs: IWsHandler;
  public
    Calls: Integer;
    constructor Create(const AWs: IWsHandler);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

/// the text of an identity, as the handler answers it
function Describe(const ACert: IClientCertificate;
  const APrincipal: string): string;

/// a TLS server on a free loopback port with the given mode and trust
function BuildMtlsServer(const APki: string; const AHandler: IHttp2Handler;
  const AObserver: IHttp2ServerObserver; const AMode: TClientCertMode;
  const ACaFile: string; const ASystemStore: Boolean;
  const APrincipal: TClientCertPrincipal): IHttp2Server;

implementation

function Join(const AList: TArray<string>): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(AList) do
  begin
    if i > 0 then
      Result := Result + ',';
    Result := Result + AList[i];
  end;
end;

function Describe(const ACert: IClientCertificate;
  const APrincipal: string): string;
begin
  if ACert = nil then
    Exit('none;principal=' + APrincipal);
  Result := 'cn=' + ACert.CommonName + ';dn=' + ACert.SubjectDn +
    ';issuer=' + ACert.IssuerDn + ';principal=' + APrincipal +
    ';sha=' + ACert.Sha256 + ';dns=' + Join(ACert.SanDns) +
    ';uri=' + Join(ACert.SanUri) + ';email=' + Join(ACert.SanEmail);
end;

{ TMtlsObserver }

procedure TMtlsObserver.OnEvent(const AEvent: TServerEvent);
begin
  if AEvent.Kind = seTlsHandshakeFailed then
    InterlockedIncrement(Failed);
end;

{ TMtlsWsHandler }

constructor TMtlsWsHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  MessageSeen := TEvent.Create(nil, True, False, '');
end;

destructor TMtlsWsHandler.Destroy;
begin
  MessageSeen.Free;
  FLock.Free;
  inherited Destroy;
end;

function TMtlsWsHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  FLock.Acquire;
  try
    FInitId := Describe(ARequest.ClientCertificate, ARequest.Principal);
  finally
    FLock.Release;
  end;
  Result := TWsInitResult.Accepted;
end;

procedure TMtlsWsHandler.Message(const ASession: IWsSession;
  const AData: TBytes; const AText: Boolean);
begin
  FLock.Acquire;
  try
    // the session holds a snapshot of the request, so this read happens after
    // the handler call of the upgrade has returned
    FMessageId := Describe(ASession.Request.ClientCertificate,
      ASession.Request.Principal);
  finally
    FLock.Release;
  end;
  MessageSeen.SetEvent;
end;

procedure TMtlsWsHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TMtlsWsHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
end;

procedure TMtlsWsHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

function TMtlsWsHandler.InitId: string;
begin
  FLock.Acquire;
  try
    Result := FInitId;
  finally
    FLock.Release;
  end;
end;

function TMtlsWsHandler.MessageId: string;
begin
  FLock.Acquire;
  try
    Result := FMessageId;
  finally
    FLock.Release;
  end;
end;

procedure TMtlsWsHandler.Reset;
begin
  FLock.Acquire;
  try
    FInitId := '';
    FMessageId := '';
  finally
    FLock.Release;
  end;
  MessageSeen.ResetEvent;
end;

{ TMtlsHandler }

constructor TMtlsHandler.Create(const AWs: IWsHandler);
begin
  inherited Create;
  FWs := AWs;
end;

procedure TMtlsHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Text: string;
  Body: TBytes;
begin
  InterlockedIncrement(Calls);
  if ARequest.Path = '/ws' then
  begin
    AcceptWebSocket(ARequest, AResponse, FWs);
    Exit;
  end;
  Text := Describe(ARequest.ClientCertificate, ARequest.Principal);
  SetLength(Body, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Body[0], Length(Text));
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

function BuildMtlsServer(const APki: string; const AHandler: IHttp2Handler;
  const AObserver: IHttp2ServerObserver; const AMode: TClientCertMode;
  const ACaFile: string; const ASystemStore: Boolean;
  const APrincipal: TClientCertPrincipal): IHttp2Server;
var
  Tls: TTlsServerOptions;
begin
  Tls := TTlsServerOptions.Create
    .WithCertificateFile(APki + '/server.crt')
    .WithKeyFile(APki + '/server.key')
    .WithClientCertMode(AMode)
    .WithClientTrustSystemStore(ASystemStore)
    .WithClientCertPrincipal(APrincipal);
  if ACaFile <> '' then
    Tls := Tls.WithClientCaFile(APki + '/' + ACaFile);
  Result := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(False)
    .WithTls(Tls)
    .WithHandler(AHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500)
    .WithWebSockets(TWsOptions.Create)
    .Build(AObserver);
  Result.Start;
end;

end.
