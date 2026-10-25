{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, mtls, client certificate, tls
notes:
  - This example builds a TLS server that requires a client certificate and
    answers each request with the identity of the client.
  - The arguments are the server certificate, the server key and the file with
    the trust anchors for client certificates. The server listens on port 8443.
  - A client reads it with the command curl --cacert server.crt --cert client.crt
    --key client.key https://localhost:8443/ . A client without a certificate
    fails in the TLS handshake and no request reaches the handler.
---
}
/// A mutual TLS server
// - the program builds a factory with the client certificate mode set to
//   required, and a handler that reads the verified identity from the request
program mtls_server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  mormot.core.base,
  Http2Server;

type
  /// the handler of the example
  TWhoAmIHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure TWhoAmIHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Cert: IClientCertificate;
  Body: TBytes;
  Text: string;
begin
  // the identity belongs to the connection. It is nil only in the optional
  // mode, when the client sent no certificate
  Cert := ARequest.ClientCertificate;
  if Cert = nil then
    Text := 'anonymous' + sLineBreak
  else
    Text := 'subject ' + Cert.SubjectDn + sLineBreak +
      'issuer ' + Cert.IssuerDn + sLineBreak +
      'sha256 ' + Cert.Sha256 + sLineBreak +
      'principal ' + ARequest.Principal + sLineBreak;
  SetLength(Body, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Body[0], Length(Text));
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

var
  Server: IHttp2Server;
  Line: string;
begin
  if ParamCount < 3 then
  begin
    Writeln(StdErr, 'usage: mtls_server <server.crt> <server.key> <client-trust.pem>');
    Halt(2);
  end;
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(8443)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile(ParamStr(1))
      .WithKeyFile(ParamStr(2))
      // ccmRequired refuses a client without a certificate in the handshake.
      // ccmOptional serves it, and the handler sees a nil identity
      .WithClientCertMode(ccmRequired)
      .WithClientCaFile(ParamStr(3))
      // the principal is empty unless the caller asks for the subject
      .WithClientCertPrincipal(ccpSubjectDn))
    .WithHandler(TWhoAmIHandler.Create)
    .Build;
  Server.Start;
  Writeln('the server listens on port ', Server.Port, ' (https, client certificate required)');
  Writeln('press Enter to stop');
  Readln(Line);
  Server.Stop;
  Writeln('the server stopped');
end.
