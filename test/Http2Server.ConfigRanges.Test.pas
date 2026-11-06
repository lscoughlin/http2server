{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: configuration, validate, ranges, host, backlog
notes:
  - These tests hold the range checks of Validate and the effect of Host and
    Backlog.
  - Validate lists every problem in one call. A queue depth of 0 stays valid.
---
}
unit Http2Server.ConfigRanges.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2Server, Http2Server.Config, Http2Server.Async.Options, Http2Server.Async,
  Http2Server.Server.Test, Http2Server.Http1.RawClient;

type
  TConfigRangesTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function Base: THttp2ServerFactory;
    function Rejects(const AFactory: THttp2ServerFactory;
      const AWord: string): Boolean;
  protected
    procedure SetUp; override;
  published
    procedure TestNegativeTimeoutsAreRejected;
    procedure TestNegativeLifetimeIsRejected;
    procedure TestZeroAndPositiveLifetimeIsAccepted;
    procedure TestBothLifetimeProblemsComeInOneCall;
    procedure TestBucketWithoutCapacityIsRejected;
    procedure TestZeroWindowsAreRejected;
    procedure TestZeroStreamLimitIsRejected;
    procedure TestHeaderTableAbove2To31IsRejected;
    procedure TestKeyFileMayBeEmptyWhenTheCertificateHoldsIt;
    procedure TestQueueDepthZeroStaysValid;
    procedure TestAllProblemsComeInOneMessage;
    procedure TestBindAddressTextUsesTheHost;
    procedure TestListenerBindsTheHost;
  end;

implementation

procedure TConfigRangesTest.SetUp;
begin
  FHandler := TTestHandler.Create;
end;

function TConfigRangesTest.Base: THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True);
end;

function TConfigRangesTest.Rejects(const AFactory: THttp2ServerFactory;
  const AWord: string): Boolean;
var
  Problems: TArray<string>;
  I: Integer;
begin
  Result := False;
  if AFactory.Validate(Problems) then
    Exit;
  for I := 0 to High(Problems) do
    if Pos(AWord, Problems[I]) > 0 then
      Exit(True);
end;

procedure TConfigRangesTest.TestNegativeTimeoutsAreRejected;
begin
  AssertTrue('idle', Rejects(Base.WithIdleTimeout(-1), 'idle timeout'));
  AssertTrue('header', Rejects(Base.WithHeaderTimeout(-1), 'header timeout'));
  AssertTrue('graceful', Rejects(Base.WithGracefulStopTimeout(-1), 'graceful'));
end;

procedure TConfigRangesTest.TestNegativeLifetimeIsRejected;
begin
  AssertTrue('age', Rejects(Base.WithMaxConnectionAge(-1),
    'the maximum connection age is below 0'));
  AssertTrue('streams', Rejects(Base.WithMaxStreamsPerConnection(-1),
    'the maximum streams per connection is below 0'));
end;

procedure TConfigRangesTest.TestZeroAndPositiveLifetimeIsAccepted;
var
  Problems: TArray<string>;
begin
  AssertTrue('age 0', Base.WithMaxConnectionAge(0).Validate(Problems));
  AssertTrue('age positive',
    Base.WithMaxConnectionAge(60000).Validate(Problems));
  AssertTrue('streams 0',
    Base.WithMaxStreamsPerConnection(0).Validate(Problems));
  AssertTrue('streams positive',
    Base.WithMaxStreamsPerConnection(100).Validate(Problems));
end;

procedure TConfigRangesTest.TestBothLifetimeProblemsComeInOneCall;
var
  Problems: TArray<string>;
  Bad: THttp2ServerFactory;
begin
  Bad := Base.WithMaxConnectionAge(-1).WithMaxStreamsPerConnection(-1);
  AssertFalse('the bad factory fails validation', Bad.Validate(Problems));
  AssertTrue('both problems arrive at once: ' + IntToStr(Length(Problems)),
    Length(Problems) >= 2);
  AssertTrue('the age problem is in the list',
    Rejects(Bad, 'the maximum connection age is below 0'));
  AssertTrue('the stream problem is in the list',
    Rejects(Bad, 'the maximum streams per connection is below 0'));
end;

procedure TConfigRangesTest.TestBucketWithoutCapacityIsRejected;
begin
  AssertTrue(Rejects(Base.WithResetBucket(
    TTokenBucketOptions.Create.WithCapacity(0).WithRefillPerSecond(1)),
    'reset bucket'));
  AssertTrue(Rejects(Base.WithPingBucket(
    TTokenBucketOptions.Create.WithCapacity(0).WithRefillPerSecond(1)),
    'ping bucket'));
end;

procedure TConfigRangesTest.TestZeroWindowsAreRejected;
begin
  AssertTrue(Rejects(Base.WithInitialStreamWindow(0), 'initial stream window'));
  AssertTrue(Rejects(Base.WithInitialConnectionWindow(0),
    'initial connection window'));
end;

procedure TConfigRangesTest.TestZeroStreamLimitIsRejected;
begin
  AssertTrue(Rejects(Base.WithMaxConcurrentStreams(0), 'concurrent stream'));
end;

procedure TConfigRangesTest.TestHeaderTableAbove2To31IsRejected;
begin
  AssertTrue(Rejects(Base.WithHeaderTableSize(LongWord(2147483648)),
    'header table'));
  AssertFalse(Rejects(Base.WithHeaderTableSize(LongWord(2147483647)),
    'header table'));
end;

procedure TConfigRangesTest.TestKeyFileMayBeEmptyWhenTheCertificateHoldsIt;
var
  Problems: TArray<string>;
  F: THttp2ServerFactory;
begin
  // ApplyTls takes an empty key file, because a PEM file can hold both
  F := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithTls(TTlsServerOptions.Create.WithCertificateFile('a.pem'));
  AssertTrue('SRV-12: Validate and ApplyTls agree: ' +
    ' no problem about the key', F.Validate(Problems));
end;

procedure TConfigRangesTest.TestQueueDepthZeroStaysValid;
var
  Problems: TArray<string>;
begin
  AssertTrue(Base.WithQueue(TQueueOptions.Create.WithDepth(0)).Validate(Problems));
end;

procedure TConfigRangesTest.TestAllProblemsComeInOneMessage;
var
  Problems: TArray<string>;
begin
  AssertFalse(Base.WithIdleTimeout(-1).WithMaxConcurrentStreams(0)
    .WithInitialStreamWindow(0).Validate(Problems));
  AssertTrue('three problems at least: ' + IntToStr(Length(Problems)),
    Length(Problems) >= 3);
end;

procedure TConfigRangesTest.TestBindAddressTextUsesTheHost;
begin
  AssertEquals('127.0.0.1:8080', string(BindAddressText('127.0.0.1', 8080)));
  AssertEquals('0.0.0.0:9', string(BindAddressText('', 9)));
  AssertEquals('::1:7', string(BindAddressText('::1', 7)));
end;

procedure TConfigRangesTest.TestListenerBindsTheHost;
var
  Server: THttp2AsyncServer;
  Addr: TNetAddr;
begin
  Server := THttp2AsyncServer.Create(Base.WithHost('127.0.0.1').WithPort(0));
  try
    Server.Start;
    AssertTrue('the socket has a name', Server.Server.Sock.GetName(Addr) = nrOk);
    AssertEquals('SRV-13: the listener holds the host of the factory',
      '127.0.0.1', string(Addr.IPShort));
  finally
    Server.Stop;
    Server.Free;
  end;
end;

initialization
  RegisterTest(TConfigRangesTest);

end.
