{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, abuse, credit, test
notes:
  - Tests for TServerConnectionCore, the server connection state machine.
  - This unit holds the abuse bucket tests, the flow control credit tests, the
    response header encoding tests and the closed stream release test.
  - The shared fixture is the class TConnectionFixture in the unit
    Http2Server.Connection.Test.
---
}
/// Connection core abuse, credit and output tests for Http2Server.Connection
unit Http2Server.Connection.Flow.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Limits, Http2Server.Connection, Http2Server.Seam,
  Http2Server.Stream, Http2Server.Connection.Test;

type
  TConnectionFlowTest = class(TConnectionFixture)
  published
    procedure TestResetAbuseTripsTheBucket;
    procedure TestBucketTripSendsEnhanceYourCalm;
    procedure TestControlFrameAbuseTripsTheBucket;
    procedure TestConnectionCreditReturnsOnBuffer;
    procedure TestStreamCreditFollowsAHandlerRead;
    procedure TestResponseHeadersAreEncodedOnce;
    procedure TestLongHeaderListKeepsRunsContiguous;
    procedure TestClosedStreamsAreFreed;
  end;

implementation

const
  TestStreamWindow = 65535;
  TestConnectionWindow = 65535;

{ TConnectionFlowTest }

procedure TConnectionFlowTest.TestResetAbuseTripsTheBucket;
var
  Frames: TArray<TFrame>;
  List: array of TFrame;
  I: Integer;
begin
  NewCore(3);
  // a reset on an idle stream is a fault, so each reset needs an open
  // stream: the list opens a stream and then resets it
  SetLength(List, 20);
  for I := 0 to 9 do
  begin
    List[I * 2] := RequestFrame(LongWord(I) * 2 + 1, False);
    List[I * 2 + 1] := TFrame.Create(ftRstStream, [], LongWord(I) * 2 + 1,
      RstPayload(ecCancel));
  end;
  FCore.Feed(Pack(True, List));
  Frames := OutputFrames;
  AssertTrue('the reset flood trips the bucket', FEvents.Tripped);
  AssertEquals('the reset bucket tripped', Ord(lkReset),
    Ord(FEvents.TripKind));
  AssertTrue('the output stays bounded', Length(Frames) <= 40);
  AssertTrue('the GOAWAY left the core', FCore.GoAwaySent);
end;

procedure TConnectionFlowTest.TestBucketTripSendsEnhanceYourCalm;
var
  Frames: TArray<TFrame>;
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
  List: array of TFrame;
  I: Integer;
begin
  NewCore(2);
  // each reset follows its own open stream, because a reset on an idle
  // stream is a connection fault that ends the feed at the first frame
  SetLength(List, 10);
  for I := 0 to 4 do
  begin
    List[I * 2] := RequestFrame(LongWord(I) * 2 + 1, False);
    List[I * 2 + 1] := TFrame.Create(ftRstStream, [], LongWord(I) * 2 + 1,
      RstPayload(ecCancel));
  end;
  FCore.Feed(Pack(True, List));
  Frames := OutputFrames;
  ParseGoAway(AnyOf(Frames, ftGoAway), Id, Code, Debug);
  AssertEquals('a tripped bucket says ENHANCE_YOUR_CALM',
    Ord(ecEnhanceYourCalm), Ord(Code));
  AssertEquals('the GOAWAY names the last processed stream', 3, Id);
end;

procedure TConnectionFlowTest.TestControlFrameAbuseTripsTheBucket;
var
  I: Integer;
  List: array of TFrame;
  Ping: TBytes;
begin
  // a control bucket of one token trips on the second PING
  Release;
  FOptions := PlainOptions;
  FClock := TManualMonotonicClock.Create;
  FEvents := TRecordingEvents.Create;
  FLimits := TConnectionLimits.Create(FClock,
    TTokenBucketOptions.Create.WithCapacity(10000).WithRefillPerSecond(0)
      .WithCostBeforeDispatch(1).WithCostAfterDispatch(2),
    TTokenBucketOptions.Create.WithCapacity(1).WithRefillPerSecond(0)
      .WithCostBeforeDispatch(1).WithCostAfterDispatch(1));
  FCore := TServerConnectionCore.Create(FOptions, FEvents, FLimits, FClock);
  Ping := BlockOf(['a'], ['b']);
  SetLength(Ping, 8);
  SetLength(List, 4);
  for I := 0 to Length(List) - 1 do
    List[I] := TFrame.Create(ftPing, [], 0, Ping);
  FCore.Feed(Pack(True, List));
  AssertTrue('a PING flood trips the bucket', FEvents.Tripped);
  AssertEquals('the PING bucket tripped', Ord(lkPing),
    Ord(FEvents.TripKind));
end;

procedure TConnectionFlowTest.TestConnectionCreditReturnsOnBuffer;
var
  Override: TConnectionCoreOptions;
  Frames: TArray<TFrame>;
  Wu: TFrame;
  I: Integer;
begin
  Override := PlainOptions;
  Override.ConnectionUpdateThreshold := 100;
  NewCore;
  Release;
  MakeCoreWith(Override, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, False),
    DataFrame(1, 1000)]));
  Frames := OutputFrames;
  Wu := AnyOf(Frames, ftWindowUpdate);
  AssertEquals('the connection WINDOW_UPDATE is credited', 0,
    Wu.Header.StreamId);
  AssertEquals('the buffer returns the connection credit',
    Int64(TestConnectionWindow), FCore.ConnectionWindowSize);
  // a second body frame keeps the connection window open without a handler
  for I := 1 to 3 do
    FCore.Feed(Pack(False, [DataFrame(1, 1000)]));
  AssertTrue('the connection never stalls while the handler is idle',
    FCore.ConnectionWindowSize > 0);
end;

procedure TConnectionFlowTest.TestStreamCreditFollowsAHandlerRead;
var
  Override: TConnectionCoreOptions;
  Stream: TServerStream;
  Frames: TArray<TFrame>;
  Buf: array[0..127] of Byte;
  I: Integer;
begin
  Override := PlainOptions;
  Override.StreamUpdateThreshold := 100;
  NewCore;
  Release;
  MakeCoreWith(Override, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, False),
    DataFrame(1, 1000)]));
  OutputFrames;
  Stream := FCore.StreamById(1);
  Frames := OutputFrames;
  AssertEquals('no stream credit before a handler read', 0,
    CountOf(Frames, ftWindowUpdate));
  for I := 1 to 8 do
    Stream.Read(Buf, SizeOf(Buf));
  FCore.Flush;
  Frames := OutputFrames;
  AssertTrue('a handler read releases stream credit',
    CountOf(Frames, ftWindowUpdate) > 0);
  AssertEquals('the read octets are credited', Int64(TestStreamWindow),
    FCore.StreamWindowSize(1));
end;

procedure TConnectionFlowTest.TestResponseHeadersAreEncodedOnce;
var
  Stream: TServerStream;
  Frames: TArray<TFrame>;
  Headers: THeaderBlock;
  Head: TFrame;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1, False)]));
  OutputFrames;
  Stream := FCore.StreamById(1);
  SetLength(Headers, 1);
  Headers[0].Name := 'content-type';
  Headers[0].Value := 'text/plain';
  Stream.QueueResponseHeaders(200, Headers, False);
  FCore.Flush;
  Frames := OutputFrames;
  AssertEquals('one response header block makes one HEADERS frame', 1,
    CountOf(Frames, ftHeaders));
  Head := AnyOf(Frames, ftHeaders);
  AssertEquals('the response carries its status', '200', StatusOf(Head));
  AssertEquals('the response uses the request stream', 1, Head.Header.StreamId);
  // the second flush must not repeat the block
  FCore.Flush;
  AssertEquals('a repeated flush queues nothing', 0,
    CountOf(OutputFrames, ftHeaders));
end;

procedure TConnectionFlowTest.TestLongHeaderListKeepsRunsContiguous;
var
  Override: TConnectionCoreOptions;
  Stream: TServerStream;
  Frames: TArray<TFrame>;
  Headers: THeaderBlock;
  I, HeadAt, ContAt: Integer;
  Encoded: TBytes;
begin
  Override := PlainOptions;
  Override.MaxFrameSize := 64;
  NewCore;
  Release;
  MakeCoreWith(Override, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, False)]));
  OutputFrames;
  SetLength(Headers, 1);
  Headers[0].Name := 'x-long';
  Headers[0].Value := StringOfChar('v', 400);
  Stream := FCore.StreamById(1);
  Stream.QueueResponseHeaders(200, Headers, False);
  FCore.Flush;
  Frames := OutputFrames;
  HeadAt := IndexOf(Frames, ftHeaders);
  AssertTrue('a long header list makes a HEADERS frame', HeadAt >= 0);
  AssertTrue('a long header list makes CONTINUATION frames',
    CountOf(Frames, ftContinuation) > 0);
  // the first CONTINUATION follows the HEADERS frame at once
  AssertEquals('the header run is contiguous', Ord(ftHeaders),
    Ord(Frames[HeadAt].Header.FrameType));
  AssertEquals('the frame after HEADERS is a CONTINUATION',
    Ord(ftContinuation), Ord(Frames[HeadAt + 1].Header.FrameType));
  ContAt := HeadAt + CountOf(Frames, ftContinuation);
  AssertTrue('the run ends with END_HEADERS',
    Frames[ContAt].IsEndHeaders);
  // every frame of the run names the same stream
  for I := HeadAt to ContAt do
    AssertEquals('every frame of the run names the stream', 1,
      Frames[I].Header.StreamId);
end;

procedure TConnectionFlowTest.TestClosedStreamsAreFreed;
var
  Before, After: PtrUInt;
  I: Integer;
begin
  NewCore;
  FCore.Feed(Pack(True, []));
  OutputFrames;
  Before := GetFPCHeapStatus.CurrHeapUsed;
  // each cycle opens a stream and then resets it, so the core closes it
  for I := 0 to 1999 do
  begin
    FCore.Feed(Pack(False, [
      RequestFrame(LongWord(I) * 2 + 1, False),
      TFrame.Create(ftRstStream, [], LongWord(I) * 2 + 1,
        RstPayload(ecCancel))]));
    OutputFrames;
  end;
  After := GetFPCHeapStatus.CurrHeapUsed;
  AssertEquals('every closed stream left the core', 0, FCore.OpenStreams);
  // the heap grows by the fixed cost of the last stream only, not by one
  // stream per cycle: a retained stream costs about 700 bytes
  AssertTrue('a closed stream is freed, not retained',
    (After - Before) < 100000);
end;

initialization
  RegisterTest(TConnectionFlowTest);
end.
