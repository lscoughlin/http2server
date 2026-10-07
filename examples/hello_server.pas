{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, hello, cleartext
notes:
  - This example builds a cleartext server on port 8080 and serves one page.
  - The server runs until the caller presses Enter, then stops.
---
}
/// A small cleartext HTTP/2 server
// - the program builds a factory, builds the server, starts it and stops it
program hello_server;

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
  THelloHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure THelloHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
  Text: string;
begin
  // the handler is synchronous: it reads what it needs, writes the response
  // and returns
  Text := 'hello from the HTTP/2 server; you asked for ' + ARequest.Path +
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
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(8080)
    .WithClearTextAllowed(True)
    .WithHandler(THelloHandler.Create)
    .Build;
  Server.Start;
  Writeln('the server listens on port ', Server.Port, ' (h2c)');
  Writeln('press Enter to stop');
  Readln(Line);
  Server.Stop;
  Writeln('the server stopped');
end.
