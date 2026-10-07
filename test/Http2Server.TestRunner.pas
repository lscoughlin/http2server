{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, fpcunit
notes:
  - This unit registers the test cases of the HTTP/2 server suite.
  - The suite holds no case until the server units exist.
---
}
/// fpcunit registration unit for the HTTP/2 server test suite
// - the console runner calls RegisterTests once, before the suite runs
// - the suite is empty until the server units exist; an empty suite passes
unit Http2Server.TestRunner;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

/// registers every test case of the suite on the global test registry
procedure RegisterTests;

implementation

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry;

const
  /// name of the top-level suite in the runner report
  cHttp2ServerSuiteName = 'Http2Server';

procedure RegisterTests;
var
  Suite: TTestSuite;
begin
  Suite := TTestSuite.Create(cHttp2ServerSuiteName);
  GetTestRegistry.AddTest(Suite);
end;

end.
