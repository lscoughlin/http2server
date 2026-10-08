{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, factory, options, test, fpcunit
notes:
  - This unit tests the server factory, the option records and Validate.
  - A WithX test shows that the original record keeps its value.
  - A Validate test shows that several problems arrive in one call.
  - A source test shows that a numeric default lives only in a Create body.
---
}
/// Unit tests for the HTTP/2 server factory and its options
// - run with `make test`.
// - the immutability tests reuse one factory value, so a shared record can
//   be forked without a change to the stored value.
// - the source test reads src/Http2Server.Config.pas, because the rule that
//   every default lives in a Create body is a property of the source text.
unit Http2Server.Config.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors,
  Http2Server.Frames,
  Http2Server.Limits,
  Http2Server.Seam,
  Http2Server.Config;

type
  /// a handler that does nothing, only to satisfy the factory wiring
  TFakeHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// tests of THttp2ServerFactory, TTlsServerOptions and TQueueOptions
  TFactoryTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function ProblemText(const AProblems: TArray<string>): string;
    function HasProblem(const AProblems: TArray<string>;
      const AFragment: string): Boolean;
    /// count of numeric literals greater than one in the factory source that
    /// lie outside a Create body
    function DefaultsOutsideCreate(out AFaults: string): Integer;
  protected
    procedure SetUp; override;
  published
    procedure TestDefaultListener;
    procedure TestDefaultPoolSizes;
    procedure TestDefaultQueue;
    procedure TestDefaultStreams;
    procedure TestDefaultBuckets;
    procedure TestDefaultTimeouts;
    procedure TestDefaultWiring;
    procedure TestDefaultTls;
    procedure TestWithDoesNotChangeOriginal;
    procedure TestNestedRecordDoesNotChangeOriginal;
    procedure TestValidateGoodFactory;
    procedure TestValidateCleartextNeedsNoCertificate;
    procedure TestValidatePortRange;
    procedure TestValidatePortZeroAllowed;
    procedure TestValidatePoolSizes;
    procedure TestValidateQueueDepth;
    procedure TestValidateCertificateAndKey;
    procedure TestValidateFrameSize;
    procedure TestValidateWindows;
    procedure TestValidateHandlerRequired;
    procedure TestValidateSeveralProblemsInOneCall;
    procedure TestControlBucketsAreCarried;
    procedure TestResetBucketCosts;
    procedure TestDefaultsOnlyInCreate;
  end;

implementation

const
  /// the source file that holds the factory; the test reads this text
  cConfigSource = 'src/Http2Server.Config.pas';

{ TFakeHandler }

procedure TFakeHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  // the factory holds the handler; the test never calls it
end;

{ TFactoryTest }

procedure TFactoryTest.SetUp;
begin
  inherited SetUp;
  FHandler := TFakeHandler.Create;
end;

function TFactoryTest.ProblemText(const AProblems: TArray<string>): string;
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

function TFactoryTest.HasProblem(const AProblems: TArray<string>;
  const AFragment: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Length(AProblems) - 1 do
    if Pos(AFragment, AProblems[I]) > 0 then
      Exit(True);
end;

procedure TFactoryTest.TestDefaultListener;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default host', '0.0.0.0', F.Host);
  AssertEquals('the default port', 8443, F.Port);
  AssertEquals('the default backlog', 128, F.Backlog);
  AssertFalse('cleartext is off by default', F.ClearTextAllowed);
end;

procedure TFactoryTest.TestDefaultPoolSizes;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default IO thread count', 4, F.IOThreads);
  AssertEquals('the default handler thread count', 8, F.HandlerThreads);
  AssertEquals('the default cancel worker count', 2, F.CancelWorkerThreads);
end;

procedure TFactoryTest.TestDefaultQueue;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default queue depth', 64, F.Queue.Depth);
  AssertEquals('the default maximum queue wait', 5000, F.Queue.MaxWaitMs);
  AssertTrue('the default refusal mode resets the stream',
    F.Queue.RefusalMode = rmRefuseStream);
end;

procedure TFactoryTest.TestDefaultStreams;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default maximum concurrent streams', 100,
    Integer(F.MaxConcurrentStreams));
  AssertEquals('the default initial stream window', 65535,
    Integer(F.InitialStreamWindow));
  AssertEquals('the default initial connection window', 65535,
    Integer(F.InitialConnectionWindow));
  AssertEquals('the default maximum frame size', DefaultMaxFrameSize,
    Integer(F.MaxFrameSize));
  AssertEquals('the default maximum header list size', 65536,
    Integer(F.MaxHeaderListSize));
  AssertEquals('the default maximum CONTINUATION count', 16,
    Integer(F.MaxContinuationFrames));
  AssertEquals('the default header table size', 4096,
    Integer(F.HeaderTableSize));
end;

procedure TFactoryTest.TestDefaultBuckets;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default reset capacity', 1000,
    F.ResetBucket.Capacity);
  AssertEquals('the default reset refill', 100, Round(F.ResetBucket.RefillPerSecond));
  AssertEquals('the default reset cost before dispatch', 1,
    F.ResetBucket.CostBeforeDispatch);
  AssertEquals('the default reset cost after dispatch', 5,
    F.ResetBucket.CostAfterDispatch);
  AssertEquals('the default PING capacity', 100, F.PingBucket.Capacity);
  AssertEquals('the default PING refill', 10, Round(F.PingBucket.RefillPerSecond));
  AssertEquals('the default SETTINGS capacity', 100, F.SettingsBucket.Capacity);
  AssertEquals('the default empty DATA capacity', 100,
    F.EmptyDataBucket.Capacity);
  AssertEquals('the default WINDOW_UPDATE capacity', 10000,
    F.WindowUpdateBucket.Capacity);
  AssertEquals('the default WINDOW_UPDATE refill', 4000,
    Round(F.WindowUpdateBucket.RefillPerSecond));
  AssertEquals('the default CONTINUATION capacity', 100,
    F.ContinuationBucket.Capacity);
end;

procedure TFactoryTest.TestDefaultTimeouts;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default idle timeout', 60000, F.IdleTimeoutMs);
  AssertEquals('the default header timeout', 30000, F.HeaderTimeoutMs);
  AssertEquals('the default graceful stop timeout', 10000,
    F.GracefulStopTimeoutMs);
end;

procedure TFactoryTest.TestDefaultWiring;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertTrue('no handler is assigned by default', F.Handler = nil);
  AssertTrue('the default clock is assigned', F.Clock <> nil);
end;

procedure TFactoryTest.TestDefaultTls;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default certificate file is empty', '',
    F.Tls.CertificateFile);
  AssertEquals('the default key file is empty', '', F.Tls.KeyFile);
  AssertEquals('the default key password is empty', '', F.Tls.KeyPassword);
  AssertEquals('one default ALPN protocol', 1, Length(F.Tls.AlpnProtocols));
  AssertEquals('the default ALPN protocol', 'h2', F.Tls.AlpnProtocols[0]);
  AssertEquals('the default handshake timeout', 10000,
    F.Tls.HandshakeTimeoutMs);
end;

procedure TFactoryTest.TestWithDoesNotChangeOriginal;
var
  Base, Forked: THttp2ServerFactory;
  Tls: TTlsServerOptions;
  Queue: TQueueOptions;
  Bucket: TTokenBucketOptions;
begin
  Base := THttp2ServerFactory.Create;
  Forked := Base
    .WithHost('127.0.0.1')
    .WithPort(9443)
    .WithBacklog(16)
    .WithClearTextAllowed(True)
    .WithIOThreads(1)
    .WithHandlerThreads(2)
    .WithCancelWorkerThreads(3)
    .WithMaxConcurrentStreams(200)
    .WithInitialStreamWindow(1000)
    .WithInitialConnectionWindow(2000)
    .WithMaxFrameSize(32768)
    .WithMaxHeaderListSize(1024)
    .WithMaxContinuationFrames(4)
    .WithHeaderTableSize(2048)
    .WithIdleTimeout(1000)
    .WithHeaderTimeout(2000)
    .WithGracefulStopTimeout(3000);

  AssertEquals('the original host is unchanged', '0.0.0.0', Base.Host);
  AssertEquals('the original port is unchanged', 8443, Base.Port);
  AssertEquals('the original backlog is unchanged', 128, Base.Backlog);
  AssertFalse('the original cleartext setting is unchanged',
    Base.ClearTextAllowed);
  AssertEquals('the original IO thread count is unchanged', 4, Base.IOThreads);
  AssertEquals('the original handler thread count is unchanged', 8,
    Base.HandlerThreads);
  AssertEquals('the original cancel worker count is unchanged', 2,
    Base.CancelWorkerThreads);
  AssertEquals('the original stream cap is unchanged', 100,
    Integer(Base.MaxConcurrentStreams));
  AssertEquals('the original frame size is unchanged', DefaultMaxFrameSize,
    Integer(Base.MaxFrameSize));
  AssertEquals('the original idle timeout is unchanged', 60000,
    Base.IdleTimeoutMs);

  // the forked record holds every new value
  AssertEquals('the forked host', '127.0.0.1', Forked.Host);
  AssertEquals('the forked port', 9443, Forked.Port);
  AssertEquals('the forked backlog', 16, Forked.Backlog);
  AssertTrue('the forked cleartext setting', Forked.ClearTextAllowed);
  AssertEquals('the forked IO thread count', 1, Forked.IOThreads);
  AssertEquals('the forked handler thread count', 2, Forked.HandlerThreads);
  AssertEquals('the forked cancel worker count', 3,
    Forked.CancelWorkerThreads);
  AssertEquals('the forked stream cap', 200,
    Integer(Forked.MaxConcurrentStreams));
  AssertEquals('the forked frame size', 32768, Integer(Forked.MaxFrameSize));
  AssertEquals('the forked idle timeout', 1000, Forked.IdleTimeoutMs);

  // a nested record is a value: an edited copy leaves the original alone
  Tls := TTlsServerOptions.Create
    .WithCertificateFile('a.pem')
    .WithKeyFile('a.key');
  Base := THttp2ServerFactory.Create.WithTls(Tls);
  Forked := Base.WithTls(Tls.WithKeyPassword('secret'));
  AssertEquals('the original key password is unchanged', '',
    Base.Tls.KeyPassword);
  AssertEquals('the forked key password', 'secret',
    Forked.Tls.KeyPassword);

  // the same rule holds for the queue record
  Queue := TQueueOptions.Create.WithDepth(8);
  Base := THttp2ServerFactory.Create.WithQueue(Queue);
  Forked := Base.WithQueue(Queue.WithRefusalMode(rmHttp503));
  AssertTrue('the original refusal mode is unchanged',
    Base.Queue.RefusalMode = rmRefuseStream);
  AssertTrue('the forked refusal mode',
    Forked.Queue.RefusalMode = rmHttp503);

  // and for a bucket record
  Bucket := TTokenBucketOptions.Create.WithCapacity(5);
  Base := THttp2ServerFactory.Create.WithPingBucket(Bucket);
  Forked := Base.WithPingBucket(Bucket.WithCapacity(6));
  AssertEquals('the original bucket capacity is unchanged', 5,
    Base.PingBucket.Capacity);
  AssertEquals('the forked bucket capacity', 6, Forked.PingBucket.Capacity);
end;

procedure TFactoryTest.TestNestedRecordDoesNotChangeOriginal;
var
  Original, Edited: TTlsServerOptions;
  Q0, Q1: TQueueOptions;
begin
  Original := TTlsServerOptions.Create
    .WithCertificateFile('cert.pem')
    .WithKeyFile('key.pem')
    .WithKeyPassword('pw')
    .WithAlpnProtocols(nil)
    .WithHandshakeTimeoutMs(2000);
  Edited := Original.WithCertificateFile('other.pem');
  AssertEquals('the original certificate is unchanged', 'cert.pem',
    Original.CertificateFile);
  AssertEquals('the edited certificate', 'other.pem', Edited.CertificateFile);
  AssertEquals('the original key file survives the fork', 'key.pem',
    Edited.KeyFile);
  AssertEquals('the empty ALPN list is kept', 0, Length(Edited.AlpnProtocols));
  AssertEquals('the handshake timeout survives the fork', 2000,
    Edited.HandshakeTimeoutMs);

  Q0 := TQueueOptions.Create;
  Q1 := Q0.WithDepth(1).WithMaxWaitMs(2).WithRefusalMode(rmHttp503);
  AssertEquals('the original queue depth is unchanged', 64, Q0.Depth);
  AssertEquals('the original queue wait is unchanged', 5000, Q0.MaxWaitMs);
  AssertTrue('the original refusal mode is unchanged',
    Q0.RefusalMode = rmRefuseStream);
  AssertEquals('the edited queue depth', 1, Q1.Depth);
  AssertEquals('the edited queue wait', 2, Q1.MaxWaitMs);
  AssertTrue('the edited refusal mode', Q1.RefusalMode = rmHttp503);
end;

procedure TFactoryTest.TestValidateGoodFactory;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
  Ok: Boolean;
begin
  F := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile('cert.pem')
      .WithKeyFile('key.pem'));
  Problems := nil;
  Ok := F.Validate(Problems);
  AssertEquals('the good factory has no problem: ' + ProblemText(Problems),
    0, Length(Problems));
  AssertTrue('the good factory validates', Ok);
end;

procedure TFactoryTest.TestValidateCleartextNeedsNoCertificate;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
  Ok: Boolean;
begin
  F := THttp2ServerFactory.Create
    .WithClearTextAllowed(True)
    .WithHandler(FHandler);
  Problems := nil;
  Ok := F.Validate(Problems);
  AssertTrue('cleartext needs no certificate or key: ' + ProblemText(Problems),
    Ok);
end;

procedure TFactoryTest.TestValidatePortRange;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  F := THttp2ServerFactory.Create.WithHandler(FHandler).WithClearTextAllowed(True);
  Problems := nil;
  AssertFalse('a negative port fails validation', F.WithPort(-1).Validate(Problems));
  AssertTrue('the port problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'port'));

  Problems := nil;
  AssertFalse('a port above the TCP range fails validation',
    F.WithPort(65536).Validate(Problems));
  AssertTrue('the port problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'port'));

  Problems := nil;
  AssertTrue('the greatest TCP port is allowed: ' + ProblemText(Problems),
    F.WithPort(65535).Validate(Problems));
end;

procedure TFactoryTest.TestValidatePortZeroAllowed;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
  Ok: Boolean;
begin
  F := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithPort(0)
    .WithClearTextAllowed(True);
  Problems := nil;
  Ok := F.Validate(Problems);
  AssertTrue('port 0 asks for a free port and is allowed: ' +
    ProblemText(Problems), Ok);
end;

procedure TFactoryTest.TestValidatePoolSizes;
var
  Problems: TArray<string>;
begin
  THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithIOThreads(0)
    .Validate(Problems);
  AssertTrue('an IO thread count below one is reported: ' +
    ProblemText(Problems), HasProblem(Problems, 'IO thread'));

  THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithHandlerThreads(0)
    .Validate(Problems);
  AssertTrue('a handler thread count below one is reported: ' +
    ProblemText(Problems), HasProblem(Problems, 'handler thread'));

  THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithCancelWorkerThreads(0)
    .Validate(Problems);
  AssertTrue('a cancel worker count below one is reported: ' +
    ProblemText(Problems), HasProblem(Problems, 'cancel worker'));

  THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithBacklog(0)
    .Validate(Problems);
  AssertTrue('a backlog below one is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'backlog'));
end;

procedure TFactoryTest.TestValidateQueueDepth;
var
  Problems: TArray<string>;
begin
  THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithQueue(TQueueOptions.Create.WithDepth(-1))
    .Validate(Problems);
  AssertTrue('a negative queue depth is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'queue depth'));

  THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithQueue(TQueueOptions.Create.WithMaxWaitMs(-1))
    .Validate(Problems);
  AssertTrue('a negative queue wait is reported: ' + ProblemText(Problems),
    HasProblem(Problems, 'queue wait'));

  // depth 0 is legal: no request waits, every one beyond the free handlers
  // is refused at once
  Problems := nil;
  AssertTrue('queue depth 0 is allowed', THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .Validate(Problems));
end;

procedure TFactoryTest.TestValidateCertificateAndKey;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  F := THttp2ServerFactory.Create.WithHandler(FHandler);
  Problems := nil;
  AssertFalse('an empty certificate and key fail validation',
    F.Validate(Problems));
  AssertTrue('the certificate problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'certificate file is empty'));
  AssertTrue('the key problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'key file is empty'));

  // a certificate alone still leaves the key problem
  F := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithTls(TTlsServerOptions.Create.WithCertificateFile('cert.pem'));
  Problems := nil;
  AssertFalse('a missing key fails validation', F.Validate(Problems));
  AssertTrue('only the key problem remains: ' + ProblemText(Problems),
    HasProblem(Problems, 'key file is empty'));
end;

procedure TFactoryTest.TestValidateFrameSize;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  F := THttp2ServerFactory.Create
    .WithHandler(FHandler).WithClearTextAllowed(True);
  Problems := nil;
  AssertFalse('a frame size below the protocol minimum fails',
    F.WithMaxFrameSize(16383).Validate(Problems));
  AssertTrue('the frame size problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'frame size'));

  Problems := nil;
  AssertFalse('a frame size above the protocol maximum fails',
    F.WithMaxFrameSize(16777216).Validate(Problems));

  Problems := nil;
  AssertTrue('the protocol maximum frame size is allowed',
    F.WithMaxFrameSize(16777215).Validate(Problems));
end;

procedure TFactoryTest.TestValidateWindows;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  F := THttp2ServerFactory.Create
    .WithHandler(FHandler).WithClearTextAllowed(True);
  Problems := nil;
  AssertFalse('a stream window above the protocol limit fails',
    F.WithInitialStreamWindow($80000000).Validate(Problems));
  AssertTrue('the stream window problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'stream window'));

  Problems := nil;
  AssertFalse('a connection window above the protocol limit fails',
    F.WithInitialConnectionWindow($80000000).Validate(Problems));
  AssertTrue('the connection window problem is named: ' +
    ProblemText(Problems), HasProblem(Problems, 'connection window'));

  Problems := nil;
  AssertTrue('the protocol limit window is allowed',
    F.WithInitialStreamWindow($7FFFFFFF)
     .WithInitialConnectionWindow($7FFFFFFF)
     .Validate(Problems));
end;

procedure TFactoryTest.TestValidateHandlerRequired;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  F := THttp2ServerFactory.Create
    .WithClearTextAllowed(True)
    .WithClock(TManualMonotonicClock.Create);
  Problems := nil;
  AssertFalse('a missing handler fails validation', F.Validate(Problems));
  AssertTrue('the handler problem is named: ' + ProblemText(Problems),
    HasProblem(Problems, 'handler is not assigned'));
end;

procedure TFactoryTest.TestValidateSeveralProblemsInOneCall;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  // one call with a bad port, bad pool sizes and a missing handler
  F := THttp2ServerFactory.Create
    .WithPort(70000)
    .WithIOThreads(0)
    .WithHandlerThreads(0);
  Problems := nil;
  AssertFalse('the broken factory fails validation', F.Validate(Problems));
  AssertTrue('several problems arrive at once: ' + ProblemText(Problems),
    Length(Problems) >= 5);
  AssertTrue('the port problem is in the list: ' + ProblemText(Problems),
    HasProblem(Problems, 'port'));
  AssertTrue('the IO thread problem is in the list: ' + ProblemText(Problems),
    HasProblem(Problems, 'IO thread'));
  AssertTrue('the handler problem is in the list: ' + ProblemText(Problems),
    HasProblem(Problems, 'handler'));
end;

procedure TFactoryTest.TestControlBucketsAreCarried;
var
  F: THttp2ServerFactory;
  B: TTokenBucketOptions;
begin
  B := TTokenBucketOptions.Create
    .WithCapacity(9)
    .WithRefillPerSecond(3.5);
  F := THttp2ServerFactory.Create
    .WithPingBucket(B)
    .WithSettingsBucket(B.WithCapacity(8))
    .WithEmptyDataBucket(B.WithCapacity(7))
    .WithWindowUpdateBucket(B.WithCapacity(6))
    .WithContinuationBucket(B.WithCapacity(5));
  AssertEquals('the PING bucket capacity', 9, F.PingBucket.Capacity);
  AssertEquals('the PING bucket refill', 3.5, F.PingBucket.RefillPerSecond, 0.001);
  AssertEquals('the SETTINGS bucket capacity', 8, F.SettingsBucket.Capacity);
  AssertEquals('the empty DATA bucket capacity', 7,
    F.EmptyDataBucket.Capacity);
  AssertEquals('the WINDOW_UPDATE bucket capacity', 6,
    F.WindowUpdateBucket.Capacity);
  AssertEquals('the CONTINUATION bucket capacity', 5,
    F.ContinuationBucket.Capacity);
end;

procedure TFactoryTest.TestResetBucketCosts;
var
  F: THttp2ServerFactory;
  B: TTokenBucketOptions;
begin
  B := TTokenBucketOptions.Create
    .WithCapacity(50)
    .WithRefillPerSecond(1)
    .WithCostBeforeDispatch(2)
    .WithCostAfterDispatch(10);
  F := THttp2ServerFactory.Create.WithResetBucket(B);
  AssertEquals('the reset capacity', 50, F.ResetBucket.Capacity);
  AssertEquals('the reset cost before dispatch', 2,
    F.ResetBucket.CostBeforeDispatch);
  AssertEquals('the reset cost after dispatch', 10,
    F.ResetBucket.CostAfterDispatch);
end;

function TFactoryTest.DefaultsOutsideCreate(out AFaults: string): Integer;
var
  Lines: TStringList;
  I, Start, Stop: Integer;
  Line, Token, Roots, Path: string;
  PastHeader, InCreate: Boolean;
  Bodies, Value: Integer;

  function SourcePath: string;
  const
    Candidates: array[0..2] of string = ('', '..', '../..');
  var
    K: Integer;
  begin
    Result := '';
    for K := Low(Candidates) to High(Candidates) do
    begin
      Roots := IncludeTrailingPathDelimiter(
        ExpandFileName(GetCurrentDir + PathDelim + Candidates[K]));
      if FileExists(Roots + cConfigSource) then
        Exit(Roots + cConfigSource);
    end;
  end;

  function IsNameChar(const AChar: Char): Boolean;
  begin
    Result := (AChar = '_') or (AChar = '.') or
      ((AChar >= '0') and (AChar <= '9')) or
      ((AChar >= 'A') and (AChar <= 'Z')) or
      ((AChar >= 'a') and (AChar <= 'z'));
  end;

begin
  Result := 0;
  AFaults := '';
  Path := SourcePath;
  AssertTrue('the factory source is present at ' + cConfigSource +
    ' under the worktree root', Path <> '');
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    PastHeader := False;
    InCreate := False;
    Bodies := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if not PastHeader then
      begin
        // the pasdoc and YAML header holds a copyright year, not a limit
        if Pos('}', Line) > 0 then
          PastHeader := True;
        Continue;
      end;
      // drop a trailing comment
      Stop := Pos('//', Line);
      if Stop > 0 then
        Line := Copy(Line, 1, Stop - 1);

      if not InCreate then
      begin
        // a Create body carries the defaults; the interface declaration of
        // Create has no '.Create', so it does not start a body
        if (Pos('class function', Line) > 0) and
           (Pos('.Create', Line) > 0) then
        begin
          InCreate := True;
          Inc(Bodies);
        end;
      end
      else if Trim(Line) = 'end;' then
        InCreate := False;

      if InCreate then
        Continue;

      Start := 1;
      while Start <= Length(Line) do
      begin
        if (Line[Start] >= '0') and (Line[Start] <= '9') and
           ((Start = 1) or not IsNameChar(Line[Start - 1])) then
        begin
          Stop := Start;
          while (Stop <= Length(Line)) and
                (Line[Stop] >= '0') and (Line[Stop] <= '9') do
            Inc(Stop);
          Token := Copy(Line, Start, Stop - Start);
          Value := StrToIntDef(Token, 0);
          // the literals 0 and 1 are structural, not limits
          if Value > 1 then
          begin
            Inc(Result);
            AFaults := AFaults + 'line ' + IntToStr(I + 1) + ': ' +
              Trim(Line) + ' | ';
          end;
          Start := Stop;
        end
        else
          Inc(Start);
      end;
    end;
    AssertTrue('the source holds the Create bodies', Bodies >= 3);
  finally
    Lines.Free;
  end;
end;

procedure TFactoryTest.TestDefaultsOnlyInCreate;
var
  Faults: string;
begin
  AssertEquals('a numeric default lives only in a Create body', 0,
    DefaultsOutsideCreate(Faults));
  if Faults <> '' then
    Fail('defaults outside Create: ' + Faults);
end;

initialization
  RegisterTest(TFactoryTest);
end.
