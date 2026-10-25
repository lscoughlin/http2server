{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, live, validation, http2client, websocket
notes:
  - This program starts the server with TLS on loopback and drives it with the
    sibling client at ../http2client. It checks the three client certificate
    modes, the identity that a handler reads, the refusal of a bad client, the
    HTTP/1.1 path and the WebSocket handshake over HTTP/1.1 and HTTP/2.
  - The client does not speak WebSocket over HTTP/2, so a small raw HTTP/2 client
    in Http2Server.Mtls.Live.Raw opens the extended CONNECT stream.
  - The program is a validation run and puts no load on the server.
  - The first argument is the directory of the test PKI, made by
    tools/certs/make_mtls_pki.sh. The exit code is 0 when every check passed.
---
}
/// Live validation of mutual TLS against the sibling client
program Http2Server.MtlsLive;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Http2Server,
  Http2.Errors, Http2.ClientCert, Http2.Stream, Http2.Messages, Http2.Client,
  Http2.WebSocket,
  Http2Server.Mtls.Live.Server, Http2Server.Mtls.Live.Raw;

type
  /// the listener of the sibling client: it sends one text message when open
  TSendOnOpen = class(TWebSocketListener)
  public
    Opened, Done: TEvent;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket;
      const AError: Exception); override;
  end;

var
  Pki: string;
  Passed, Failed: Integer;
  Handler: TMtlsHandler;
  HandlerRef: IHttp2Handler;
  WsHandler: TMtlsWsHandler;
  WsRef: IWsHandler;

constructor TSendOnOpen.Create;
begin
  inherited Create;
  Opened := TEvent.Create(nil, True, False, '');
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TSendOnOpen.Destroy;
begin
  Done.Free;
  Opened.Free;
  inherited Destroy;
end;

procedure TSendOnOpen.OnOpen(const ASocket: IWebSocket);
begin
  ASocket.Request(4);
  Opened.SetEvent;
  ASocket.SendText('who am i');
end;

procedure TSendOnOpen.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  Done.SetEvent;
end;

procedure TSendOnOpen.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  Done.SetEvent;
end;

procedure Check(const AName: string; const ACondition: Boolean;
  const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(Passed);
    WriteLn('ok   ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

function Contains(const AText, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AText) > 0;
end;

function Identity(const AName: string): IClientIdentity;
begin
  Result := TClientIdentity.FromPemFiles(Pki + '/' + AName + '.crt',
    Pki + '/' + AName + '.key');
end;

/// one HTTP/2 GET with the sibling client; a failure answers 'refused:<class>'
function ClientGet(const APort: Integer; const AName: string;
  const ARequests: Integer = 1): string;
var
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Response: IHttpResponse;
  i: Integer;
begin
  Result := '';
  try
    Factory := THttpClientFactory.Create
      .WithInsecureTls
      .WithMaxConnectionsPerHost(1);
    if AName <> '' then
      Factory := Factory.WithClientCertificateFiles(Pki + '/' + AName + '.crt',
        Pki + '/' + AName + '.key');
    Client := Factory.Build;
    try
      for i := 1 to ARequests do
      begin
        Response := Client.Send(THttpRequest.Create(hmGet,
          'https://127.0.0.1:' + IntToStr(APort) + '/id'));
        if Response.StatusCode <> 200 then
          Exit('status ' + IntToStr(Response.StatusCode));
        if i > 1 then
          Result := Result + ' | ';
        Result := Result + ReadText(Response);
      end;
    finally
      Client.Close;
    end;
  except
    on E: Exception do
      Result := 'refused:' + E.ClassName;
  end;
end;

/// whether a saved TLS session resumes with a client certificate
function ResumptionWorks(const APort: Integer; const AVersion: string): Boolean;
var
  Common, Cmd: string;
begin
  Common := 'openssl s_client ' + AVersion + ' -connect 127.0.0.1:' + IntToStr(APort) +
    ' -alpn h2 -cert alice.crt -key alice.key';
  Cmd := 'cd ' + Pki + ' && rm -f resume.pem && (sleep 1; echo Q) | ' + Common +
    ' -sess_out resume.pem >/dev/null 2>&1; (sleep 1; echo Q) | ' + Common +
    ' -sess_in resume.pem 2>&1 | grep -q "^Reused"';
  Result := ExecuteProcess('/bin/sh', ['-c', Cmd]) = 0;
end;

function Refused(const AText: string): Boolean;
begin
  Result := Copy(AText, 1, 8) = 'refused:';
end;

/// a WebSocket over HTTP/1.1 with the sibling client
function ClientWsHttp1(const APort: Integer; const AName: string): Boolean;
var
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Listener: TSendOnOpen;
  ListenerRef: IWebSocketListener;
  Socket: IWebSocket;
begin
  Result := False;
  try
    Factory := THttpClientFactory.Create.WithInsecureTls;
    if AName <> '' then
      Factory := Factory.WithClientCertificateFiles(Pki + '/' + AName + '.crt',
        Pki + '/' + AName + '.key');
    Client := Factory.Build;
    try
      Listener := TSendOnOpen.Create;
      ListenerRef := Listener;
      Socket := Client.Send(TWebSocketRequest.Create('wss://127.0.0.1:' +
        IntToStr(APort) + '/ws', ListenerRef).WithAutoRequest);
      Result := WsHandler.MessageSeen.WaitFor(5000) = wrSignaled;
      Socket.Close;
      Listener.Done.WaitFor(2000);
    finally
      Client.Close;
    end;
  except
    on E: Exception do
      WriteLn('  ws http1: ', E.ClassName, ': ', E.Message);
  end;
end;

procedure RunNoneMode;
var
  R: TRawH2;
  W: TRawResult;
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
begin
  WriteLn('-- mode none');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, ccmNone, '', False, ccpNone);
  try
    Body := ClientGet(Server.Port, '');
    Check('none: a client without a certificate is served', Body = 'none;principal=', Body);
    Body := ClientGet(Server.Port, 'alice');
    Check('none: a certificate that nobody asked for gives no identity',
      Body = 'none;principal=', Body);
    R := TRawH2.Create(Server.Port, nil);
    try
      W := R.Get('/id');
      Check('none: the raw HTTP/2 client is served',
        (not W.Refused) and (W.Body = 'none;principal='), W.Status + ' ' + W.Body);
    finally
      R.Free;
    end;
  finally
    Server.Stop;
  end;
end;

procedure RunOptionalMode;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
  R: TRawH2;
  W: TRawResult;
  CallsBefore: Integer;
begin
  WriteLn('-- mode optional, principal = common name');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, ccmOptional, 'ca.crt', False,
    ccpCommonName);
  try
    Body := ClientGet(Server.Port, '');
    Check('optional: no certificate is served with a nil identity',
      Body = 'none;principal=', Body);
    Body := ClientGet(Server.Port, 'alice');
    Check('optional: a valid certificate gives the identity',
      Contains(Body, 'cn=alice;') and Contains(Body, 'principal=alice;'), Body);
    Check('optional: the subject keeps the organisation',
      Contains(Body, 'O=Example'), Body);
    Check('optional: the SAN names arrive',
      Contains(Body, 'dns=alice.example;') and
      Contains(Body, 'uri=spiffe://example.org/alice;') and
      Contains(Body, 'email=alice@example.org'), Body);
    Check('optional: the issuer is the test root', Contains(Body, 'CN=Test Root CA'), Body);
    CallsBefore := Handler.Calls;
    Body := ClientGet(Server.Port, 'mallory');
    Check('optional: a certificate of an unknown CA is refused', Refused(Body), Body);
    Check('optional: the refused client reached no handler', Handler.Calls = CallsBefore);
    // WebSocket over HTTP/2 without a certificate: the handshake succeeds and
    // the handler sees a nil identity, so it can answer 401 on its own
    WsHandler.Reset;
    R := TRawH2.Create(Server.Port, nil);
    try
      W := R.OpenWebSocket('/ws');
      Check('optional: WebSocket over HTTP/2 without a certificate opens',
        (not W.Refused) and (W.Status = '200'), W.Status);
      Check('optional: the WebSocket handler sees a nil identity',
        Copy(WsHandler.InitId, 1, 5) = 'none;', WsHandler.InitId);
    finally
      R.Free;
    end;
  finally
    Server.Stop;
  end;
end;

procedure RunRequiredMode;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body, First, Second: string;
  P: Integer;
  R: TRawH2;
  W: TRawResult;
  H1: TRawResult;
  CallsBefore, FailedBefore: Integer;
  Ident: IClientIdentity;
begin
  WriteLn('-- mode required, principal = subject DN');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, ccmRequired, 'ca.crt', False,
    ccpSubjectDn);
  try
    CallsBefore := Handler.Calls;
    FailedBefore := Obs.Failed;
    Body := ClientGet(Server.Port, '');
    Check('required: no certificate is refused', Refused(Body), Body);
    Body := ClientGet(Server.Port, 'mallory');
    Check('required: a certificate of an unknown CA is refused', Refused(Body), Body);
    Body := ClientGet(Server.Port, 'selfie');
    Check('required: a self-signed certificate outside the trust is refused',
      Refused(Body), Body);
    // the expired certificate loads in the client but the client factory
    // refuses it at Build, so the raw client presents it
    Ident := Identity('expired');
    try
      R := TRawH2.Create(Server.Port, Ident);
      try
        W := R.Get('/id');
        Check('required: an expired certificate is refused', W.Refused, W.Status);
      finally
        R.Free;
      end;
    except
      on E: Exception do
        Check('required: an expired certificate is refused (at dial)', True);
    end;
    Sleep(300);
    Check('required: the refused clients reached no handler', Handler.Calls = CallsBefore,
      IntToStr(Handler.Calls - CallsBefore) + ' calls');
    Check('required: the observer counted each of the four failed handshakes',
      Obs.Failed - FailedBefore = 4, IntToStr(Obs.Failed - FailedBefore));
    Check('required: the stats count the failed handshakes',
      Server.Stats.TlsHandshakeFailedTotal = 4,
      IntToStr(Server.Stats.TlsHandshakeFailedTotal));

    Body := ClientGet(Server.Port, 'alice', 2);
    P := Pos(' | ', Body);
    First := Copy(Body, 1, P - 1);
    Second := Copy(Body, P + 3, MaxInt);
    Check('required: a valid certificate is served', Contains(First, 'cn=alice;'), Body);
    Check('required: the principal is the subject DN, most specific name last',
      Contains(First, 'dn=OU=Eng,O=Example,CN=alice;') and
      Contains(First, ';principal=OU=Eng,O=Example,CN=alice;'), First);
    Check('required: two requests on one connection show one identity',
      (First <> '') and (First = Second), Body);

    Body := ClientGet(Server.Port, 'special');
    Check('required: a comma in a DN value is escaped as RFC 4514 says',
      Contains(Body, 'CN=Doe\, Jane') and Contains(Body, 'O=Acme\, Inc'), Body);
    Check('required: a saved TLS 1.2 session resumes with the certificate',
      ResumptionWorks(Server.Port, '-tls1_2'));
    Check('required: a saved TLS 1.3 session resumes with the certificate',
      ResumptionWorks(Server.Port, '-tls1_3'));

    // HTTP/1.1 over TLS on the same listener
    H1 := RawHttp1Get(Server.Port, Identity('alice'), '/id');
    Check('required: HTTP/1.1 over TLS is served with the identity',
      (not H1.Refused) and (H1.Status = '200') and Contains(H1.Body, 'cn=alice;'),
      H1.Status + ' ' + H1.Body);
    H1 := RawHttp1Get(Server.Port, nil, '/id');
    Check('required: HTTP/1.1 without a certificate is refused', H1.Refused);

    // WebSocket over HTTP/2 (RFC 8441 extended CONNECT)
    WsHandler.Reset;
    R := TRawH2.Create(Server.Port, Identity('alice'));
    try
      W := R.OpenWebSocket('/ws');
      Check('required: WebSocket over HTTP/2 opens with a certificate',
        (not W.Refused) and (W.Status = '200'), W.Status);
      Check('required: Init sees the identity over HTTP/2',
        Contains(WsHandler.InitId, 'cn=alice;'), WsHandler.InitId);
      R.SendWsText('who am i');
      Check('required: the session still has the identity at the first message',
        (WsHandler.MessageSeen.WaitFor(5000) = wrSignaled) and
        Contains(WsHandler.MessageId, 'cn=alice;'), WsHandler.MessageId);
    finally
      R.Free;
    end;
    CallsBefore := Handler.Calls;
    try
      R := TRawH2.Create(Server.Port, nil);
      try
        W := R.OpenWebSocket('/ws');
        Check('required: WebSocket over HTTP/2 without a certificate is refused',
          W.Refused);
      finally
        R.Free;
      end;
    except
      on E: Exception do
        Check('required: WebSocket over HTTP/2 without a certificate is refused (at dial)', True);
    end;
    Check('required: that refusal reached no handler', Handler.Calls = CallsBefore);

    // WebSocket over HTTP/1.1 with the sibling client
    WsHandler.Reset;
    Check('required: WebSocket over HTTP/1.1 delivers a message', ClientWsHttp1(Server.Port, 'alice'));
    Check('required: the HTTP/1.1 session sees the identity',
      Contains(WsHandler.InitId, 'cn=alice;') and Contains(WsHandler.MessageId, 'cn=alice;'),
      WsHandler.InitId + ' / ' + WsHandler.MessageId);
  finally
    Server.Stop;
  end;
end;

procedure RunSelfSignedTrust;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
begin
  WriteLn('-- required, trust file holds the root and a self-signed client');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, ccmRequired,
    'trust-selfie.pem', False, ccpNone);
  try
    Body := ClientGet(Server.Port, 'selfie');
    Check('self-signed: a self-signed client in the trust file is served',
      Contains(Body, 'cn=selfie;'), Body);
    Body := ClientGet(Server.Port, 'alice');
    Check('self-signed: a client of the root is served as well',
      Contains(Body, 'cn=alice;'), Body);
    Body := ClientGet(Server.Port, 'mallory');
    Check('self-signed: an unknown CA stays refused', Refused(Body), Body);
  finally
    Server.Stop;
  end;
end;

procedure RunSystemStore;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
begin
  WriteLn('-- required, operating system store only');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, ccmRequired, '', True, ccpNone);
  try
    // the test root is not in the system store of the host, and the live check
    // never changes that store. The client of the test root is refused, which
    // shows that the system store is the only anchor. A positive case needs a
    // certificate from a public CA and stays a documented gap
    Body := ClientGet(Server.Port, 'alice');
    Check('system store: a client of a private root is refused', Refused(Body), Body);
  finally
    Server.Stop;
  end;
end;

begin
  Pki := ParamStr(1);
  if (Pki = '') or not FileExists(Pki + '/ca.crt') then
  begin
    WriteLn(StdErr, 'usage: Http2Server.MtlsLive <pki-directory>');
    Halt(2);
  end;
  WsHandler := TMtlsWsHandler.Create;
  WsRef := WsHandler;
  Handler := TMtlsHandler.Create(WsRef);
  HandlerRef := Handler;
  RunNoneMode;
  RunOptionalMode;
  RunRequiredMode;
  RunSelfSignedTrust;
  RunSystemStore;
  WriteLn;
  WriteLn('passed ', Passed, ', failed ', Failed);
  if Failed > 0 then
    Halt(1);
end.
