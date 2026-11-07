{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, tls, https
notes:
  - This example builds a TLS server on port 8443 and serves one page.
  - The arguments are the server certificate and the server key. The pair
    test/certs/localhost.crt and test/certs/localhost.key serves for a
    first run.
  - A client reads it with the command curl --cacert test/certs/localhost.crt
    https://127.0.0.1:8443/ or with the command curl --http2 --cacert
    test/certs/localhost.crt https://127.0.0.1:8443/ for HTTP/2 over TLS.
  - The server runs until the caller presses Enter, then stops.
---
}
/// A small TLS HTTP/2 server
// - the program builds a factory with a certificate, builds the server,
//   starts it and stops it
program tls_server;

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
  TTlsHelloHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure TTlsHelloHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
  Text: string;
begin
  // the handler is synchronous: it reads what it needs, writes the response
  // and returns
  Text := 'hello from the TLS server; you asked for ' + ARequest.Path +
    sLineBreak;
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
  if ParamCount < 2 then
  begin
    Writeln(StdErr, 'usage: tls_server <server.crt> <server.key>');
    Halt(2);
  end;
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(8443)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile(ParamStr(1))
      .WithKeyFile(ParamStr(2)))
    .WithHandler(TTlsHelloHandler.Create)
    .Build;
  Server.Start;
  Writeln('the server listens on port ', Server.Port, ' (https)');
  Writeln('press Enter to stop');
  Readln(Line);
  Server.Stop;
  Writeln('the server stopped');
end.
