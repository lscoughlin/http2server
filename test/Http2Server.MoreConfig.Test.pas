{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, limits, socket, tls, test, fpcunit
notes:
  - This unit tests the server limits, the socket options and the TLS
    version range.
  - A WithX test shows that the original record keeps its value.
  - A Validate test shows that several problems arrive in one call.
---
}
/// Unit tests for the server limits, the socket options and the TLS range
// - run with `make test`.
// - the tests use the factory Validate, so a bad record is refused at build.
unit Http2Server.MoreConfig.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Seam,
  Http2Server.Config,
  Http2Server.Config.Limits,
  Http2Server.Config.Socket,
  Http2Server.Config.Tls;

type
  /// a handler that does nothing, only to satisfy the factory wiring
  TStubHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// tests of TServerLimits, TSocketOptions and the TLS version range
  TMoreConfigTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function BaseFactory: THttp2ServerFactory;
    function ProblemText(const AProblems: TArray<string>): string;
    function HasProblem(const AProblems: TArray<string>;
      const AFragment: string): Boolean;
  protected
    procedure SetUp; override;
  published
    procedure TestDefaultServerLimits;
    procedure TestDefaultSocketOptions;
    procedure TestDefaultTlsVersions;
    procedure TestFactoryCarriesNewRecords;
    procedure TestServerLimitsImmutability;
    procedure TestSocketOptionsImmutability;
    procedure TestTlsVersionImmutability;
    procedure TestFactoryWithNewRecords;
    procedure TestValidateServerLimits;
    procedure TestValidateDataFrameSize;
    procedure TestValidateSocketOptions;
    procedure TestValidateTlsVersionOrder;
    procedure TestValidateSeveralProblemsInOneCall;
  end;

implementation

{ TStubHandler }

procedure TStubHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  // the factory holds the handler; the test never calls it
end;

{ TMoreConfigTest }

procedure TMoreConfigTest.SetUp;
begin
  inherited SetUp;
  FHandler := TStubHandler.Create;
end;

function TMoreConfigTest.BaseFactory: THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True);
end;

function TMoreConfigTest.ProblemText(const AProblems: TArray<string>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(AProblems) - 1 do
  begin
    if I > 0 then
      Result := Result + '; ';
    Result := Result + AProblems[I];
  end;
end;

function TMoreConfigTest.HasProblem(const AProblems: TArray<string>;
  const AFragment: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Length(AProblems) - 1 do
    if Pos(AFragment, AProblems[I]) > 0 then
      Exit(True);
end;

procedure TMoreConfigTest.TestDefaultServerLimits;
var
  L: TServerLimits;
begin
  L := TServerLimits.Create;
  AssertEquals('the default maximum connection count', 10000,
    L.MaxConnections);
  AssertEquals('the default stream read timeout', 30000,
    L.StreamReadTimeoutMs);
  AssertEquals('the default stream write timeout', 30000,
    L.StreamWriteTimeoutMs);
  AssertEquals('the default write timeout', 60000, L.WriteTimeoutMs);
  AssertEquals('the default outbound frame cap', 10000, L.MaxOutboundFrames);
  AssertEquals('the default outbound control frame cap', 1000,
    L.MaxOutboundControlFrames);
  AssertEquals('the default outbound data frame size', 0,
    L.MaxDataFrameSizeOut);
end;

procedure TMoreConfigTest.TestDefaultSocketOptions;
var
  O: TSocketOptions;
begin
  O := TSocketOptions.Create;
  AssertTrue('TCP no-delay is on by default', O.TcpNoDelay);
  AssertEquals('the default keep-alive idle time', 0, O.KeepAliveIdleSec);
  AssertEquals('the default keep-alive interval', 0, O.KeepAliveIntervalSec);
  AssertEquals('the default keep-alive count', 0, O.KeepAliveCount);
  AssertEquals('the default send buffer size', 0, O.SendBufferBytes);
  AssertEquals('the default receive buffer size', 0, O.RecvBufferBytes);
  AssertFalse('reuse-port is off by default', O.ReusePort);
end;

procedure TMoreConfigTest.TestDefaultTlsVersions;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create;
  AssertTrue('the default minimum TLS version is 1.2',
    T.MinTlsVersion = tvTls12);
  AssertTrue('the default maximum TLS version is 1.3',
    T.MaxTlsVersion = tvTls13);
end;

procedure TMoreConfigTest.TestFactoryCarriesNewRecords;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the factory connection count', 10000,
    F.ServerLimits.MaxConnections);
  AssertEquals('the factory stream read timeout', 30000,
    F.ServerLimits.StreamReadTimeoutMs);
  AssertEquals('the factory stream write timeout', 30000,
    F.ServerLimits.StreamWriteTimeoutMs);
  AssertEquals('the factory write timeout', 60000,
    F.ServerLimits.WriteTimeoutMs);
  AssertEquals('the factory outbound frame cap', 10000,
    F.ServerLimits.MaxOutboundFrames);
  AssertEquals('the factory outbound control frame cap', 1000,
    F.ServerLimits.MaxOutboundControlFrames);
  AssertEquals('the factory outbound data frame size', 0,
    F.ServerLimits.MaxDataFrameSizeOut);
  AssertTrue('the factory TCP no-delay', F.Socket.TcpNoDelay);
  AssertEquals('the factory keep-alive idle time', 0,
    F.Socket.KeepAliveIdleSec);
  AssertEquals('the factory keep-alive interval', 0,
    F.Socket.KeepAliveIntervalSec);
  AssertEquals('the factory keep-alive count', 0, F.Socket.KeepAliveCount);
  AssertEquals('the factory send buffer size', 0, F.Socket.SendBufferBytes);
  AssertEquals('the factory receive buffer size', 0, F.Socket.RecvBufferBytes);
  AssertFalse('the factory reuse-port', F.Socket.ReusePort);
  AssertTrue('the factory minimum TLS version is 1.2',
    F.Tls.MinTlsVersion = tvTls12);
  AssertTrue('the factory maximum TLS version is 1.3',
    F.Tls.MaxTlsVersion = tvTls13);
end;

procedure TMoreConfigTest.TestServerLimitsImmutability;
var
  Base, Forked: TServerLimits;
begin
  Base := TServerLimits.Create;
  Forked := Base
    .WithMaxConnections(10)
    .WithStreamReadTimeoutMs(11)
    .WithStreamWriteTimeoutMs(12)
    .WithWriteTimeoutMs(13)
    .WithMaxOutboundFrames(14)
    .WithMaxOutboundControlFrames(15)
    .WithMaxDataFrameSizeOut(16384);
  AssertEquals('the original connection count is unchanged', 10000,
    Base.MaxConnections);
  AssertEquals('the original stream read timeout is unchanged', 30000,
    Base.StreamReadTimeoutMs);
  AssertEquals('the original stream write timeout is unchanged', 30000,
    Base.StreamWriteTimeoutMs);
  AssertEquals('the original write timeout is unchanged', 60000,
    Base.WriteTimeoutMs);
  AssertEquals('the original outbound frame cap is unchanged', 10000,
    Base.MaxOutboundFrames);
  AssertEquals('the original outbound control frame cap is unchanged', 1000,
    Base.MaxOutboundControlFrames);
  AssertEquals('the original outbound data frame size is unchanged', 0,
    Base.MaxDataFrameSizeOut);
  AssertEquals('the forked connection count', 10, Forked.MaxConnections);
  AssertEquals('the forked stream read timeout', 11,
    Forked.StreamReadTimeoutMs);
  AssertEquals('the forked stream write timeout', 12,
    Forked.StreamWriteTimeoutMs);
  AssertEquals('the forked write timeout', 13, Forked.WriteTimeoutMs);
  AssertEquals('the forked outbound frame cap', 14, Forked.MaxOutboundFrames);
  AssertEquals('the forked outbound control frame cap', 15,
    Forked.MaxOutboundControlFrames);
  AssertEquals('the forked outbound data frame size', 16384,
    Forked.MaxDataFrameSizeOut);
end;

procedure TMoreConfigTest.TestSocketOptionsImmutability;
var
  Base, Forked: TSocketOptions;
begin
  Base := TSocketOptions.Create;
  Forked := Base
    .WithTcpNoDelay(False)
    .WithKeepAliveIdleSec(60)
    .WithKeepAliveIntervalSec(30)
    .WithKeepAliveCount(3)
    .WithSendBufferBytes(65536)
    .WithRecvBufferBytes(32768)
    .WithReusePort(True);
  AssertTrue('the original TCP no-delay is unchanged', Base.TcpNoDelay);
  AssertEquals('the original keep-alive idle time is unchanged', 0,
    Base.KeepAliveIdleSec);
  AssertEquals('the original keep-alive interval is unchanged', 0,
    Base.KeepAliveIntervalSec);
  AssertEquals('the original keep-alive count is unchanged', 0,
    Base.KeepAliveCount);
  AssertEquals('the original send buffer size is unchanged', 0,
    Base.SendBufferBytes);
  AssertEquals('the original receive buffer size is unchanged', 0,
    Base.RecvBufferBytes);
  AssertFalse('the original reuse-port is unchanged', Base.ReusePort);
  AssertFalse('the forked TCP no-delay', Forked.TcpNoDelay);
  AssertEquals('the forked keep-alive idle time', 60, Forked.KeepAliveIdleSec);
  AssertEquals('the forked keep-alive interval', 30,
    Forked.KeepAliveIntervalSec);
  AssertEquals('the forked keep-alive count', 3, Forked.KeepAliveCount);
  AssertEquals('the forked send buffer size', 65536, Forked.SendBufferBytes);
  AssertEquals('the forked receive buffer size', 32768, Forked.RecvBufferBytes);
  AssertTrue('the forked reuse-port', Forked.ReusePort);
end;

procedure TMoreConfigTest.TestTlsVersionImmutability;
var
  Base, Forked: TTlsServerOptions;
begin
  Base := TTlsServerOptions.Create;
  Forked := Base.WithMinTlsVersion(tvTls13).WithMaxTlsVersion(tvTls13);
  AssertTrue('the original minimum version is unchanged',
    Base.MinTlsVersion = tvTls12);
  AssertTrue('the original maximum version is unchanged',
    Base.MaxTlsVersion = tvTls13);
  AssertTrue('the forked minimum version',
    Forked.MinTlsVersion = tvTls13);
  AssertTrue('the forked maximum version',
    Forked.MaxTlsVersion = tvTls13);
  AssertEquals('the handshake timeout survives the fork', 10000,
    Forked.HandshakeTimeoutMs);
end;

procedure TMoreConfigTest.TestFactoryWithNewRecords;
var
  Base, Forked: THttp2ServerFactory;
begin
  Base := THttp2ServerFactory.Create;
  Forked := Base
    .WithServerLimits(TServerLimits.Create.WithMaxConnections(7))
    .WithSocketOptions(TSocketOptions.Create.WithReusePort(True));
  AssertEquals('the original connection count is unchanged', 10000,
    Base.ServerLimits.MaxConnections);
  AssertFalse('the original reuse-port is unchanged', Base.Socket.ReusePort);
  AssertEquals('the forked connection count', 7,
    Forked.ServerLimits.MaxConnections);
  AssertTrue('the forked reuse-port', Forked.Socket.ReusePort);
end;

procedure TMoreConfigTest.TestValidateServerLimits;
var
  Problems: TArray<string>;
  Base: THttp2ServerFactory;
begin
  Base := BaseFactory;
  AssertTrue('the defaults are valid: ' + ProblemText(Problems),
    Base.Validate(Problems));

  Base.WithServerLimits(
    TServerLimits.Create.WithMaxConnections(-1)).Validate(Problems);
  AssertTrue('a negative connection count is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the maximum connection count is below 0'));
  Problems := nil;
  AssertTrue('a connection count of 0 is allowed: ' + ProblemText(Problems),
    Base.WithServerLimits(
      TServerLimits.Create.WithMaxConnections(0)).Validate(Problems));

  Base.WithServerLimits(
    TServerLimits.Create.WithStreamReadTimeoutMs(0)).Validate(Problems);
  AssertTrue('a stream read timeout below 1 is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the stream read timeout is below 1'));

  Base.WithServerLimits(
    TServerLimits.Create.WithStreamWriteTimeoutMs(0)).Validate(Problems);
  AssertTrue('a stream write timeout below 1 is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the stream write timeout is below 1'));

  Base.WithServerLimits(
    TServerLimits.Create.WithWriteTimeoutMs(-1)).Validate(Problems);
  AssertTrue('a negative write timeout is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the write timeout is below 0'));
  Problems := nil;
  AssertTrue('a write timeout of 0 turns the check off: ' +
    ProblemText(Problems),
    Base.WithServerLimits(
      TServerLimits.Create.WithWriteTimeoutMs(0)).Validate(Problems));

  Base.WithServerLimits(
    TServerLimits.Create.WithMaxOutboundFrames(-1)).Validate(Problems);
  AssertTrue('a negative outbound frame cap is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the outbound frame cap is below 0'));
  Problems := nil;
  AssertTrue('an outbound frame cap of 0 turns the cap off: ' +
    ProblemText(Problems),
    Base.WithServerLimits(
      TServerLimits.Create.WithMaxOutboundFrames(0)).Validate(Problems));

  Base.WithServerLimits(
    TServerLimits.Create.WithMaxOutboundControlFrames(-1)).Validate(Problems);
  AssertTrue('a negative outbound control frame cap is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the outbound control frame cap is below 0'));

  Base.WithServerLimits(TServerLimits.Create
    .WithMaxOutboundFrames(5)
    .WithMaxOutboundControlFrames(6)).Validate(Problems);
  AssertTrue('a control cap above the frame cap is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the control frame cap is above the frame cap'));
  Problems := nil;
  AssertTrue('a control cap equal to the frame cap is allowed: ' +
    ProblemText(Problems),
    Base.WithServerLimits(TServerLimits.Create
      .WithMaxOutboundFrames(5)
      .WithMaxOutboundControlFrames(5)).Validate(Problems));
  Problems := nil;
  AssertTrue('a control cap is allowed while the frame cap is off: ' +
    ProblemText(Problems),
    Base.WithServerLimits(TServerLimits.Create
      .WithMaxOutboundFrames(0)
      .WithMaxOutboundControlFrames(6)).Validate(Problems));
end;

procedure TMoreConfigTest.TestValidateDataFrameSize;
var
  Problems: TArray<string>;
  Base: THttp2ServerFactory;

  procedure Check(const ASize: Integer);
  begin
    Problems := nil;
    Base.WithServerLimits(
      TServerLimits.Create.WithMaxDataFrameSizeOut(ASize)).Validate(Problems);
  end;

begin
  Base := BaseFactory;
  Check(0);
  AssertTrue('a size of 0 is allowed: ' + ProblemText(Problems),
    not HasProblem(Problems, 'data frame size'));
  Check(1024);
  AssertTrue('a size of 1024 is allowed: ' + ProblemText(Problems),
    not HasProblem(Problems, 'data frame size'));
  Check(16384);
  AssertTrue('a size of 16384 is allowed: ' + ProblemText(Problems),
    not HasProblem(Problems, 'data frame size'));
  Check(16777215);
  AssertTrue('a size of 16777215 is allowed: ' + ProblemText(Problems),
    not HasProblem(Problems, 'data frame size'));
  Check(-1);
  AssertTrue('a size of -1 is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'the outbound data frame size is outside the range'));
  Check(1);
  AssertTrue('a size of 1 is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'the outbound data frame size is outside the range'));
  Check(1023);
  AssertTrue('a size of 1023 is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'the outbound data frame size is outside the range'));
  Check(16777216);
  AssertTrue('a size of 16777216 is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'the outbound data frame size is outside the range'));
end;

procedure TMoreConfigTest.TestValidateSocketOptions;
var
  Problems: TArray<string>;
  Base: THttp2ServerFactory;
begin
  Base := BaseFactory;
  AssertTrue('the defaults are valid: ' + ProblemText(Problems),
    Base.Validate(Problems));

  Base.WithSocketOptions(
    TSocketOptions.Create.WithKeepAliveIdleSec(-1)).Validate(Problems);
  AssertTrue('a negative keep-alive idle time is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the keep-alive values are not valid'));

  Base.WithSocketOptions(
    TSocketOptions.Create.WithKeepAliveIntervalSec(-1)).Validate(Problems);
  AssertTrue('a negative keep-alive interval is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the keep-alive values are not valid'));

  Base.WithSocketOptions(
    TSocketOptions.Create.WithKeepAliveCount(-1)).Validate(Problems);
  AssertTrue('a negative keep-alive count is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the keep-alive values are not valid'));

  Base.WithSocketOptions(TSocketOptions.Create
    .WithKeepAliveIdleSec(60)).Validate(Problems);
  AssertTrue('an idle keep-alive with no interval is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the keep-alive values are not valid'));

  Base.WithSocketOptions(TSocketOptions.Create
    .WithKeepAliveIdleSec(60)
    .WithKeepAliveIntervalSec(30)).Validate(Problems);
  AssertTrue('an idle keep-alive with no count is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the keep-alive values are not valid'));

  Problems := nil;
  AssertTrue('a full keep-alive triple is allowed: ' + ProblemText(Problems),
    Base.WithSocketOptions(TSocketOptions.Create
      .WithKeepAliveIdleSec(60)
      .WithKeepAliveIntervalSec(30)
      .WithKeepAliveCount(3)).Validate(Problems));
  Problems := nil;
  AssertTrue('a silent triple turns keep-alive off: ' + ProblemText(Problems),
    Base.WithSocketOptions(TSocketOptions.Create
      .WithKeepAliveIdleSec(0)
      .WithKeepAliveIntervalSec(30)
      .WithKeepAliveCount(3)).Validate(Problems));

  Base.WithSocketOptions(
    TSocketOptions.Create.WithSendBufferBytes(-1)).Validate(Problems);
  AssertTrue('a negative send buffer size is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the socket buffer size is below 0'));

  Base.WithSocketOptions(
    TSocketOptions.Create.WithRecvBufferBytes(-1)).Validate(Problems);
  AssertTrue('a negative receive buffer size is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the socket buffer size is below 0'));
end;

procedure TMoreConfigTest.TestValidateTlsVersionOrder;
var
  Problems: TArray<string>;
  Base: THttp2ServerFactory;
begin
  Base := BaseFactory;
  AssertTrue('the defaults are valid: ' + ProblemText(Problems),
    Base.Validate(Problems));

  Base.WithTls(TTlsServerOptions.Create
    .WithMinTlsVersion(tvTls13)
    .WithMaxTlsVersion(tvTls12)).Validate(Problems);
  AssertTrue('an inverted version range is reported: ' +
    ProblemText(Problems),
    HasProblem(Problems,
      'the minimum TLS version is above the maximum'));

  Problems := nil;
  AssertTrue('a range of 1.2 alone is allowed: ' + ProblemText(Problems),
    Base.WithTls(TTlsServerOptions.Create
      .WithMinTlsVersion(tvTls12)
      .WithMaxTlsVersion(tvTls12)).Validate(Problems));
  Problems := nil;
  AssertTrue('a range of 1.3 alone is allowed: ' + ProblemText(Problems),
    Base.WithTls(TTlsServerOptions.Create
      .WithMinTlsVersion(tvTls13)
      .WithMaxTlsVersion(tvTls13)).Validate(Problems));
end;

procedure TMoreConfigTest.TestValidateSeveralProblemsInOneCall;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  // one call with bad limits, bad socket values and an inverted TLS range
  F := BaseFactory
    .WithServerLimits(TServerLimits.Create
      .WithMaxConnections(-1)
      .WithStreamReadTimeoutMs(0)
      .WithStreamWriteTimeoutMs(0))
    .WithSocketOptions(TSocketOptions.Create
      .WithKeepAliveIdleSec(60)
      .WithSendBufferBytes(-1))
    .WithTls(TTlsServerOptions.Create
      .WithMinTlsVersion(tvTls13)
      .WithMaxTlsVersion(tvTls12));
  Problems := nil;
  AssertFalse('the broken factory fails validation', F.Validate(Problems));
  AssertTrue('several problems arrive at once: ' + ProblemText(Problems),
    Length(Problems) >= 6);
  AssertTrue('the connection count problem is in the list: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the maximum connection count is below 0'));
  AssertTrue('the stream read problem is in the list: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the stream read timeout is below 1'));
  AssertTrue('the stream write problem is in the list: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the stream write timeout is below 1'));
  AssertTrue('the keep-alive problem is in the list: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the keep-alive values are not valid'));
  AssertTrue('the buffer problem is in the list: ' + ProblemText(Problems),
    HasProblem(Problems, 'the socket buffer size is below 0'));
  AssertTrue('the TLS version problem is in the list: ' +
    ProblemText(Problems),
    HasProblem(Problems, 'the minimum TLS version is above the maximum'));
end;

initialization
  RegisterTest(TMoreConfigTest);
end.
