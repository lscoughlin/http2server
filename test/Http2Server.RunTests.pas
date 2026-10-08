{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, consoletestrunner
notes:
  - This program runs the HTTP/2 server test suite from the console.
  - The program returns exit code 0 when every test passes.
---
}
/// Program entry point for the HTTP/2 server test suite (`make test`)
program Http2Server.RunTests;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, consoletestrunner, Http2Server.TestRunner;

var
  App: TTestRunner;
begin
  RegisterTests;
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'http2server test suite';
    App.Run;
  finally
    App.Free;
  end;
end.
