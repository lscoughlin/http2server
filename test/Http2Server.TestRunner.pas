{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
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
  Http2Server.Async.Test,
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
  Http2Server.StreamPool.Test,
  Http2Server.Detach.Test,
  Http2Server.DetachLive.Test,
  Http2Server.Ws.Frames.Test,
  Http2Server.Ws.Parser.Test,
  Http2Server.Sse.Test,
  Http2Server.SseLive.Test,
  Http2Server.ResponseWriter.Test,
  Http2Server.Http1.TestKit,
  Http2Server.Http1.Head.Test,
  Http2Server.Http1.Chunked.Test,
  Http2Server.Http1.RawClient,
  Http2Server.Http1.Live.Test,
  Http2Server.Http1.Config.Test,
  Http2Server.Http1.Detach.Test,
  Http2Server.Http1.Fuzz.Test,
  Http2Server.Ws.Origin.Test,
  Http2Server.Ws.TestKit,
  Http2Server.Ws.Session.Test,
  Http2Server.Ws.Pool.Test,
  Http2Server.Ws.Http1.Test,
  Http2Server.Ws.Http2.Test,
  Http2Server.ConnectProtocol.Test,
  Http2Server.Output.Test,
  Http2Server.Licence.Test,
  Http2Server.Encoding.Test,
  Http2Server.Validation.Test,
  Http2Server.Admission.Test,
  Http2Server.AccessLog.Test,
  Http2Server.Mtls.Test,
  Http2Server.H2Peer.Test,
  Http2Server.H2Credit.Test,
  Http2Server.H2Flow.Test,
  Http2Server.H2Hpack.Test,
  Http2Server.H2Lifecycle.Test,
  Http2Server.H2Locks.Test,
  Http2Server.WsHardening.Test,
  Http2Server.Lifecycle.Test,
  Http2Server.ConfigRanges.Test,
  Http2Server.Facade.Test,
  Http2Server.Server.Test;

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
