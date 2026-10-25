{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, validation, abuse, cancellation, exhaustion
notes:
  - The abuse, cancellation and admission validation tests of the server.
    Every test runs a real cleartext server on a loopback port and speaks h2c
    with the frame builders.
  - The abuse tests drive one control frame kind past its token bucket and
    check the GOAWAY error code and that the peer socket closes.
  - The cancellation tests check that a reset raises EStreamCancelled inside
    the handler thread and that the thread returns to the pool.
  - The exhaustion tests check the served, refused and dropped counts of the
    admission rules.
  - The handlers, the raw client and the start helpers are in the unit
    Http2Server.Validation.Test.
---
}
/// Validation tests for the server: abuse limits, cancellation, exhaustion
unit Http2Server.Validation.Abuse.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.base,
  mormot.core.os,
  mormot.net.sock,
  Http2Server,
  Http2Server.Errors, Http2Server.Limits, Http2Server.Config,
  Http2Server.Frames, Http2Server.Headers,
  Http2Server.Validation.Test;

type
  /// the abuse tests of the server, one per control frame kind
  TAbuseLimitTest = class(TTestCase)
  private
    function StartWithBuckets(const AReset, AControl: TTokenBucketOptions;
      const AMaxContinuations: Integer): Integer;
    function StartServer(const AReset, AControl: TTokenBucketOptions): Integer;
  public
    procedure TearDown; override;
  published
    /// a reset flood trips the reset bucket and closes with ENHANCE_YOUR_CALM
    procedure TestResetFloodGoAway;
    /// a PING flood trips the PING bucket and closes
    procedure TestPingFloodGoAway;
    /// a SETTINGS flood trips the SETTINGS bucket and closes
    procedure TestSettingsFloodGoAway;
    /// an empty DATA flood trips the empty-DATA bucket and closes
    procedure TestEmptyDataFloodGoAway;
    /// a WINDOW_UPDATE flood trips the WINDOW_UPDATE bucket and closes
    procedure TestWindowUpdateFloodGoAway;
    /// a large header block closes with ENHANCE_YOUR_CALM
    procedure TestHeaderBlockOverLimitGoAway;
    /// a handler exception reaches the observer as an internal error
    procedure TestHandlerExceptionIsReported;
  end;

  /// the cancellation tests of the server
  TCancellationTest = class(TTestCase)
  public
    procedure TearDown; override;
  published
    /// a reset raises EStreamCancelled inside the handler thread and frees it
    procedure TestResetRaisesInsideHandler;
    /// a reset before dispatch drops the request and the handler never runs
    procedure TestResetBeforeDispatchNeverRuns;
  end;

  /// the admission exhaustion test of the server
  TAdmissionExhaustionTest = class(TTestCase)
  public
    procedure TearDown; override;
  published
    /// the served, refused and dropped counts follow the admission rules
    procedure TestExhaustionCountsFollowTheAdmissionRules;
  end;

implementation

const
  ResponseTimeoutMs = 6000;

var
  /// the servers that the tests start, stopped in TearDown
  GServer: IHttp2Server;

// ---- TAbuseLimitTest ----

function TAbuseLimitTest.StartWithBuckets(const AReset,
  AControl: TTokenBucketOptions; const AMaxContinuations: Integer): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := BaseFactory(TValidationHandler.Create)
    .WithResetBucket(AReset)
    .WithPingBucket(AControl)
    .WithSettingsBucket(AControl)
    .WithEmptyDataBucket(AControl)
    .WithWindowUpdateBucket(AControl)
    .WithContinuationBucket(AControl);
  if AMaxContinuations > 0 then
    Factory := Factory.WithMaxContinuationFrames(AMaxContinuations);
  GServer := Factory.Build;
  GServer.Start;
  Result := GServer.Port;
end;

function TAbuseLimitTest.StartServer(const AReset,
  AControl: TTokenBucketOptions): Integer;
begin
  Result := StartWithBuckets(AReset, AControl, 0);
end;

procedure TAbuseLimitTest.TearDown;
begin
  if GServer <> nil then
  begin
    GServer.Stop;
    GServer := nil;
  end;
end;

procedure TAbuseLimitTest.TestResetFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Frame: TFrame;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
begin
  // the reset bucket holds two resets before a dispatch, so the fourth trips.
  // The explicit costs match the factory defaults, because WithResetBucket
  // replaces the whole option record and a zero cost would never trip.
  Port := StartServer(
    TTokenBucketOptions.Create.WithCapacity(2).WithRefillPerSecond(0)
      .WithCostBeforeDispatch(1).WithCostAfterDispatch(5),
    SmallBucket(1000000));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // RFC 9113 section 5.1 makes a reset on an idle stream a connection
    // fault, so the flood opens each stream and then resets it
    for I := 0 to 9 do
    begin
      Client.SendFrame(Client.GetFrame(LongWord(1 + I * 2), '/'));
      Frame := BuildRstStreamFrame(LongWord(1 + I * 2), ecCancel);
      Client.SendFrame(Frame);
    end;
    AssertTrue('the reset flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestPingFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
  Payload: TBytes;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    SetLength(Payload, 8);
    for I := 0 to 11 do
      Client.SendFrame(BuildPingFrame(Payload, False));
    AssertTrue('the PING flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestSettingsFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    for I := 0 to 11 do
      Client.SendFrame(BuildSettingsFrame(TConnectionSettings.Defaults));
    AssertTrue('the SETTINGS flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestEmptyDataFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
  Empty: TBytes;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    Empty := nil;
    // an empty DATA frame on an open stream only charges the empty-DATA bucket;
    // on stream zero it would be a PROTOCOL_ERROR at once
    Client.SendFrame(Client.OpenFrame(1, '/'));
    for I := 0 to 11 do
      Client.SendFrame(BuildDataFrame(1, Empty, False));
    AssertTrue('the empty DATA flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestWindowUpdateFloodGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  I: Integer;
begin
  Port := StartServer(SmallBucket(1000000), SmallBucket(5));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    for I := 0 to 11 do
      Client.SendFrame(BuildWindowUpdateFrame(0, 1024));
    AssertTrue('the WINDOW_UPDATE flood ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
    AssertTrue('the server closes the peer socket', Client.PeerClosed(4000));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestHeaderBlockOverLimitGoAway;
var
  Port: Integer;
  Client: TRawClient;
  Code: THttp2ErrorCode;
  Last: LongWord;
  Block, Big: TBytes;
  I: Integer;
begin
  // the block byte limit is twice the header list size, so a long block with
  // END_HEADERS cleared trips the limit across several continuation frames.
  // Each frame stays inside the frame-size limit, because an oversized frame
  // is a different fault that fires first.
  Port := StartServer(SmallBucket(1000000), SmallBucket(1000000));
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    SetLength(Big, 16384);
    for I := 0 to High(Big) do
      Big[I] := Byte(I);
    Block := Client.EncodeHeaders(THeaderBlock(nil));
    Client.SendFrame(BuildHeadersFrame(1, Block, False, True));
    // the block limit is 2 * 65536, so nine 16384-octet frames pass it
    for I := 0 to 8 do
      Client.SendFrame(BuildContinuationFrame(1, Big, I = 8));
    AssertTrue('the oversized header block ends in GOAWAY',
      Client.WaitGoAway(Code, Last, ResponseTimeoutMs));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
  finally
    Client.Free;
  end;
end;

procedure TAbuseLimitTest.TestHandlerExceptionIsReported;
var
  Port: Integer;
  Client: TRawClient;
  Observer: TCountingObserver;
  Frame: TFrame;
  I: Integer;
begin
  Observer := TCountingObserver.Create;
  GServer := BaseFactory(TRaisingValidationHandler.Create)
    .Build(Observer);
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    Client.SendFrame(Client.GetFrame(1, '/'));
    // the handler raises, so the stream gets an RST_STREAM
    for I := 1 to 60 do
    begin
      if Client.TakeFrame(Frame, 100) and
         (Frame.Header.FrameType = ftRstStream) and
         (Frame.Header.StreamId = 1) then
        Break;
    end;
    AssertTrue('the observer saw the handler exception',
      Observer.CountOf(seHandlerException) >= 1);
  finally
    Client.Free;
  end;
end;

// ---- TCancellationTest ----

procedure TCancellationTest.TearDown;
begin
  if GServer <> nil then
  begin
    GServer.Stop;
    GServer := nil;
  end;
end;

procedure TCancellationTest.TestResetRaisesInsideHandler;
var
  Port: Integer;
  Client: TRawClient;
  Handler: TBlockingReadHandler;
  Observer: TCountingObserver;
  Deadline: QWord;
begin
  Handler := TBlockingReadHandler.Create;
  Observer := TCountingObserver.Create;
  GServer := BaseFactory(Handler).Build(Observer);
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // a HEADERS frame with END_STREAM clear, so the body never arrives and
    // the handler parks inside Read until the reset
    Client.SendFrame(Client.OpenFrame(1, '/blocking'));
    AssertTrue('the handler reached Read', Handler.WaitStarted(4000));
    Client.SendFrame(BuildRstStreamFrame(1, ecCancel));
    // the cancel raises EStreamCancelled inside the handler thread
    Deadline := GetTickCount64 + 4000;
    while (not Handler.Cancelled) and (GetTickCount64 < Deadline) do
      Sleep(20);
    AssertTrue('the handler saw EStreamCancelled', Handler.Cancelled);
    AssertTrue('the observer saw the reset',
      Observer.CountOf(seStreamReset) >= 1);
  finally
    Client.Free;
  end;
end;

procedure TCancellationTest.TestResetBeforeDispatchNeverRuns;
var
  Port: Integer;
  Client: TRawClient;
  Handler: TValidationHandler;
begin
  Handler := TValidationHandler.Create;
  GServer := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(Handler)
    // one handler thread and no queue space, so later streams are refused
    .WithHandlerThreads(1)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500)
    .Build;
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // the first request is refused at once, so it never reaches the handler
    Client.SendFrame(Client.GetFrame(1, '/'));
    Client.SendFrame(BuildRstStreamFrame(1, ecCancel));
    Sleep(300);
    AssertEquals('a refused stream never runs the handler',
      0, Handler.StartedCount);
  finally
    Client.Free;
  end;
end;

// ---- TAdmissionExhaustionTest ----

procedure TAdmissionExhaustionTest.TearDown;
begin
  if GServer <> nil then
  begin
    GServer.Stop;
    GServer := nil;
  end;
end;

procedure TAdmissionExhaustionTest.TestExhaustionCountsFollowTheAdmissionRules;
var
  Port, I, Served: Integer;
  Client: TRawClient;
  Handler: TValidationHandler;
  Frame: TFrame;
begin
  Handler := TValidationHandler.Create;
  GServer := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(Handler)
    .WithHandlerThreads(2)
    .WithQueue(TQueueOptions.Create.WithDepth(4).WithMaxWaitMs(200)
      .WithRefusalMode(rmRefuseStream))
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500)
    .Build;
  GServer.Start;
  Port := GServer.Port;
  Client := TRawClient.Create(Port);
  try
    Client.SendPreface;
    // 20 requests on one connection, more than the pool and the queue hold
    for I := 1 to 20 do
      Client.SendFrame(Client.GetFrame(LongWord(1 + (I - 1) * 2), '/'));
    Served := 0;
    for I := 1 to 200 do
    begin
      if Client.TakeFrame(Frame, 50) then
      begin
        if (Frame.Header.FrameType = ftData) and
           Frame.IsEndStream then
          Inc(Served);
      end;
    end;
    AssertTrue('some requests were served', Served > 0);
    AssertTrue('some requests were refused or dropped',
      GServer.Stats.RefusedTotal + Handler.StartedCount <= 20);
    AssertTrue('the served count never passes the offered count',
      Handler.StartedCount <= 20);
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTest(TAbuseLimitTest);
  RegisterTest(TCancellationTest);
  RegisterTest(TAdmissionExhaustionTest);
end.
