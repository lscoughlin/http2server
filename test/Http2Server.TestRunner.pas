{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, fpcunit
notes:
  - This unit registers the test cases of the HTTP/2 server suite.
  - Each test unit registers its own cases in its initialization section.
---
}
/// fpcunit registration unit for the HTTP/2 server test suite
// - the console runner calls RegisterTests once, before the suite runs
// - a test unit joins the suite by its presence in the uses clause below
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
  SysUtils, fpcunit, testregistry,
  // each unit registers its test cases in its initialization section
  Http2Server.Alpn.Test,
  Http2Server.Config.Test,
  Http2Server.Connection.Test,
  Http2Server.Errors.Test,
  Http2Server.Frames.Test,
  Http2Server.Hpack.Test,
  Http2Server.HpackProps.Test,
  Http2Server.FlowControl.Test,
  Http2Server.Headers.Test,
  Http2Server.Protocol.Server.Test,
  Http2Server.Seam.Test,
  Http2Server.Stream.Test,
  Http2Server.Limits.Test,
  Http2Server.Output.Test,
  Http2Server.Admission.Test;

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
