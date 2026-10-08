{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, test
notes:
  - Tests for TServerConnectionCore, the server connection state machine.
  - The core names no mORMot unit, so these tests drive it with byte arrays
    and no socket.
  - The frame inputs follow RFC 9113 sections 4.2, 5.1.1, 5.1.2, 6.5 and 6.9.
---
}
/// Connection core tests for Http2Server.Connection
unit Http2Server.Connection.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Limits, Http2Server.Connection, Http2Server.Seam,
  Http2Server.Stream;

type
  /// records every event the core raises
  TRecordingEvents = class(TInterfacedObject, IConnectionEvents)
  private
    FRequests: Integer;
    FResets: Integer;
    FClosing: Integer;
    FTripKind: TLimitKind;
    FTripped: Boolean;
  public
    procedure RequestReady(const AStream: TServerStream);
    procedure StreamReset(const AStream: TServerStream);
    procedure ConnectionClosing;
    procedure LimitTripped(const AKind: TLimitKind);
    property Requests: Integer read FRequests;
    property Resets: Integer read FResets;
    property Closing: Integer read FClosing;
    property Tripped: Boolean read FTripped;
    property TripKind: TLimitKind read FTripKind;
  end;

  TConnectionCoreTest = class(TTestCase)
  private
    FCore: TServerConnectionCore;
    FEvents: TRecordingEvents;
    FClock: TManualMonotonicClock;
    FLimits: TConnectionLimits;
    FOptions: TConnectionCoreOptions;

    function PlainOptions: TConnectionCoreOptions;
    function BuildLimits(const ACapacity: Integer): TConnectionLimits;
    procedure MakeCoreWith(const AOptions: TConnectionCoreOptions;
      const ACapacity: Integer);
    procedure MakeCore(const ACapacity: Integer = 10000);
    function NewCore(const ACapacity: Integer = 10000): TServerConnectionCore;
    procedure Release;
    function PrefaceBytes: TBytes;
    function Slice(const AData: TBytes; const AStart,
      ACount: Integer): TBytes;
    function RstPayload(const ACode: THttp2ErrorCode): TBytes;
    function AckSettingsOf(const AFrames: TArray<TFrame>): Boolean;
    function GoAwayCodeOf(const AFrames: TArray<TFrame>): THttp2ErrorCode;
    function GoAwayPayload(const ALastStreamId: LongWord;
      const ACode: THttp2ErrorCode): TBytes;
    function Pack(const APreface: Boolean;
      const AFrames: array of TFrame): TBytes;
    function Greedy(AStreamId: LongWord): TFrame;
    function RequestFrame(AStreamId: LongWord;
      const AEndStream: Boolean = True): TFrame;
    function BlockOf(const ANames: array of string;
      const AValues: array of string): TBytes;
    function DataFrame(AStreamId: LongWord; const ACount: Integer;
      const AEndStream: Boolean = False): TFrame;
    function OutputFrames: TArray<TFrame>;
    function FirstTypeOf(const AFrames: TArray<TFrame>): TFrameType;
    function AnyOf(const AFrames: TArray<TFrame>;
      const AFrameType: TFrameType): TFrame;
    function IndexOf(const AFrames: TArray<TFrame>;
      const AFrameType: TFrameType): Integer;
    function CountOf(const AFrames: TArray<TFrame>;
      const AFrameType: TFrameType): Integer;
    function StatusOf(const AFrame: TFrame): string;
    procedure TearDown; override;
  published
    procedure TestServerSettingsIsTheFirstFrame;
    procedure TestWrongPrefaceIsRefused;
    procedure TestPrefaceSplitAcrossFeeds;
    procedure TestSettingsIsAcknowledged;
    procedure TestInitialWindowChangeAdjustsOpenStreams;
    procedure TestHeadersSplitAtEveryByteStillArrives;
    procedure TestPartialFrameIsBuffered;
    procedure TestEvenStreamIdClosesTheConnection;
    procedure TestRepeatedStreamIdClosesTheConnection;
    procedure TestOverConcurrentLimitIsRefused;
    procedure TestRequestRaisesRequestReady;
    procedure TestEndStreamOnHeadersClosesRemoteSide;
    procedure TestContinuationAssemblesTheHeaderBlock;
    procedure TestContinuationCapClosesTheConnection;
    procedure TestHeaderListTooLargeClosesTheConnection;
    procedure TestContinuationWithoutHeadersIsRefused;
    procedure TestDataReachesTheStreamAndBothWindows;
    procedure TestDataOverrunIsAConnectionError;
    procedure TestSlowHandlerResetsOnlyItsStream;
    procedure TestPingIsAcknowledged;
    procedure TestPriorityIsIgnored;
    procedure TestClientGoAwayCancelsOpenStreams;
    procedure TestRstStreamKeepsTheConnection;
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
  TestMaxFrameSize = 16384;
  TestMaxConcurrent = 4;
  TestHeaderTableSize = 4096;
  TestMaxHeaderListSize = 16384;
  TestInboundLimit = 65536;
  TestOutboundLimit = 65536;
  TestStreamWindow = 65535;
  TestConnectionWindow = 65535;
  TestConnThreshold = 32768;
  TestStreamThreshold = 32768;
  TestContinuationCap = 4;
  TestBodySize = 1024;

{ TRecordingEvents }

procedure TRecordingEvents.RequestReady(const AStream: TServerStream);
begin
  Inc(FRequests);
end;

procedure TRecordingEvents.StreamReset(const AStream: TServerStream);
begin
  Inc(FResets);
end;

procedure TRecordingEvents.ConnectionClosing;
begin
  Inc(FClosing);
end;

procedure TRecordingEvents.LimitTripped(const AKind: TLimitKind);
begin
  FTripped := True;
  FTripKind := AKind;
end;

{ TConnectionCoreTest }

function TConnectionCoreTest.PlainOptions: TConnectionCoreOptions;
begin
  Result.ConnectionWindow := TestConnectionWindow;
  Result.InitialStreamWindow := TestStreamWindow;
  Result.MaxConcurrentStreams := TestMaxConcurrent;
  Result.MaxFrameSize := TestMaxFrameSize;
  Result.MaxHeaderListSize := TestMaxHeaderListSize;
  Result.MaxHeaderTableSize := TestHeaderTableSize;
  Result.MaxContinuations := TestContinuationCap;
  Result.MaxHeaderBlockBytes := 262144;
  Result.InboundBufferLimit := TestInboundLimit;
  Result.OutboundBufferLimit := TestOutboundLimit;
  Result.ConnectionUpdateThreshold := TestConnThreshold;
  Result.StreamUpdateThreshold := TestStreamThreshold;
end;

function TConnectionCoreTest.BuildLimits(
  const ACapacity: Integer): TConnectionLimits;
var
  R, C: TTokenBucketOptions;
begin
  R := TTokenBucketOptions.Create.WithCapacity(ACapacity).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(2);
  C := TTokenBucketOptions.Create.WithCapacity(ACapacity).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(1);
  Result := TConnectionLimits.Create(FClock, R, C);
end;

procedure TConnectionCoreTest.MakeCoreWith(
  const AOptions: TConnectionCoreOptions; const ACapacity: Integer);
begin
  FOptions := AOptions;
  FClock := TManualMonotonicClock.Create;
  FEvents := TRecordingEvents.Create;
  FLimits := BuildLimits(ACapacity);
  FCore := TServerConnectionCore.Create(FOptions, FEvents, FLimits, FClock);
end;

procedure TConnectionCoreTest.MakeCore(const ACapacity: Integer);
begin
  MakeCoreWith(PlainOptions, ACapacity);
end;

function TConnectionCoreTest.NewCore(
  const ACapacity: Integer): TServerConnectionCore;
begin
  Release;
  MakeCore(ACapacity);
  Result := FCore;
end;

procedure TConnectionCoreTest.Release;
begin
  // the interface reference owns the core, so only the class field clears
  FCore := nil;
  if FLimits <> nil then
  begin
    FLimits.Free;
    FLimits := nil;
  end;
  FEvents := nil;
  FClock := nil;
end;

procedure TConnectionCoreTest.TearDown;
begin
  Release;
end;

function TConnectionCoreTest.PrefaceBytes: TBytes;
begin
  SetLength(Result, ClientPrefaceSize);
  Move(ClientPreface[0], Result[0], ClientPrefaceSize);
end;

function TConnectionCoreTest.Pack(const APreface: Boolean;
  const AFrames: array of TFrame): TBytes;
var
  I, Offset, N, At: Integer;
  Body: TBytes;
  Header: TBytes;
begin
  Body := nil;
  At := 0;
  for I := 0 to Length(AFrames) - 1 do
  begin
    SetLength(Header, FrameHeaderSize);
    AFrames[I].Header.WriteTo(Header);
    N := At + FrameHeaderSize + Length(AFrames[I].Payload);
    SetLength(Body, N);
    Move(Header[0], Body[At], FrameHeaderSize);
    At := At + FrameHeaderSize;
    if Length(AFrames[I].Payload) > 0 then
    begin
      Move(AFrames[I].Payload[0], Body[At], Length(AFrames[I].Payload));
      At := At + Length(AFrames[I].Payload);
    end;
  end;
  if not APreface then
    Exit(Body);
  SetLength(Result, ClientPrefaceSize + Length(Body));
  Move(ClientPreface[0], Result[0], ClientPrefaceSize);
  if Length(Body) > 0 then
    Move(Body[0], Result[ClientPrefaceSize], Length(Body));
end;

function TConnectionCoreTest.BlockOf(const ANames: array of string;
  const AValues: array of string): TBytes;
var
  Codec: THpackCodec;
  Block: THeaderBlock;
  I: Integer;
begin
  Codec := THpackCodec.Create;
  try
    SetLength(Block, Length(ANames));
    for I := 0 to Length(ANames) - 1 do
    begin
      Block[I].Name := ANames[I];
      Block[I].Value := AValues[I];
    end;
    Result := Codec.Encode(Block);
  finally
    Codec.Free;
  end;
end;

function TConnectionCoreTest.RequestFrame(AStreamId: LongWord;
  const AEndStream: Boolean): TFrame;
var
  Flags: TFrameFlags;
  Block: TBytes;
begin
  Block := BlockOf([':method', ':scheme', ':path', ':authority'],
    ['GET', 'https', '/index.html', 'example.com']);
  Flags := [ffEndHeaders];
  if AEndStream then
    Include(Flags, ffEndStream);
  Result := TFrame.Create(ftHeaders, Flags, AStreamId, Block);
end;

function TConnectionCoreTest.Greedy(AStreamId: LongWord): TFrame;
var
  Block: TBytes;
begin
  Block := BlockOf([':method', ':scheme', ':path'],
    ['GET', 'https', StringOfChar('p', 200)]);
  Result := TFrame.Create(ftHeaders, [ffEndHeaders], AStreamId, Block);
end;

function TConnectionCoreTest.DataFrame(AStreamId: LongWord;
  const ACount: Integer; const AEndStream: Boolean): TFrame;
var
  Payload: TBytes;
  Flags: TFrameFlags;
begin
  Flags := [];
  if AEndStream then
    Flags := [ffEndStream];
  if ACount > 0 then
  begin
    SetLength(Payload, ACount);
    FillChar(Payload[0], ACount, Ord('d'));
  end;
  Result := TFrame.Create(ftData, Flags, AStreamId, Payload);
end;

function TConnectionCoreTest.OutputFrames: TArray<TFrame>;
var
  Data: TBytes;
  Offset, N: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  Result := nil;
  FCore.TakeOutput(Data);
  Offset := 0;
  while Offset + FrameHeaderSize <= Length(Data) do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(Data[Offset], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    N := FrameHeaderSize + Integer(Header.Length);
    if Offset + N > Length(Data) then
      Break;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(Data[Offset + FrameHeaderSize], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    SetLength(Result, Length(Result) + 1);
    Result[Length(Result) - 1] := Frame;
    Inc(Offset, N);
  end;
end;

function TConnectionCoreTest.Slice(const AData: TBytes; const AStart,
  ACount: Integer): TBytes;
begin
  Result := nil;
  if ACount <= 0 then
    Exit;
  SetLength(Result, ACount);
  Move(AData[AStart], Result[0], ACount);
end;

function TConnectionCoreTest.RstPayload(
  const ACode: THttp2ErrorCode): TBytes;
begin
  SetLength(Result, 4);
  Result[0] := 0;
  Result[1] := 0;
  Result[2] := 0;
  Result[3] := Ord(ACode);
end;

function TConnectionCoreTest.GoAwayPayload(const ALastStreamId: LongWord;
  const ACode: THttp2ErrorCode): TBytes;
begin
  SetLength(Result, 8);
  Result[0] := (ALastStreamId shr 24) and $FF;
  Result[1] := (ALastStreamId shr 16) and $FF;
  Result[2] := (ALastStreamId shr 8) and $FF;
  Result[3] := ALastStreamId and $FF;
  Result[4] := 0;
  Result[5] := 0;
  Result[6] := 0;
  Result[7] := Ord(ACode);
end;

function TConnectionCoreTest.AckSettingsOf(
  const AFrames: TArray<TFrame>): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Length(AFrames) - 1 do
    if (AFrames[I].Header.FrameType = ftSettings) and AFrames[I].IsAck then
      Exit(True);
end;

function TConnectionCoreTest.GoAwayCodeOf(
  const AFrames: TArray<TFrame>): THttp2ErrorCode;
var
  Id: LongWord;
  Debug: TBytes;
begin
  ParseGoAway(AnyOf(AFrames, ftGoAway), Id, Result, Debug);
end;

function TConnectionCoreTest.FirstTypeOf(
  const AFrames: TArray<TFrame>): TFrameType;
begin
  AssertTrue('the output holds a frame', Length(AFrames) > 0);
  Result := AFrames[0].Header.FrameType;
end;

function TConnectionCoreTest.IndexOf(const AFrames: TArray<TFrame>;
  const AFrameType: TFrameType): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to Length(AFrames) - 1 do
    if AFrames[I].Header.FrameType = AFrameType then
      Exit(I);
end;

function TConnectionCoreTest.AnyOf(const AFrames: TArray<TFrame>;
  const AFrameType: TFrameType): TFrame;
var
  I: Integer;
begin
  for I := 0 to Length(AFrames) - 1 do
    if AFrames[I].Header.FrameType = AFrameType then
      Exit(AFrames[I]);
  Fail(Format('no frame of type %d in the output', [Ord(AFrameType)]));
end;

function TConnectionCoreTest.CountOf(const AFrames: TArray<TFrame>;
  const AFrameType: TFrameType): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Length(AFrames) - 1 do
    if AFrames[I].Header.FrameType = AFrameType then
      Inc(Result);
end;

function TConnectionCoreTest.StatusOf(const AFrame: TFrame): string;
var
  Codec: THpackCodec;
  Headers: THeaderBlock;
  I: Integer;
begin
  Result := '';
  Codec := THpackCodec.Create;
  try
    Headers := Codec.Decode(ExtractHeaderBlock(AFrame));
    for I := 0 to Length(Headers) - 1 do
      if Headers[I].Name = ':status' then
        Exit(Headers[I].Value);
  finally
    Codec.Free;
  end;
end;

procedure TConnectionCoreTest.TestServerSettingsIsTheFirstFrame;
var
  Frames: TArray<TFrame>;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1)]));
  Frames := OutputFrames;
  AssertEquals('the server SETTINGS frame leads the output',
    Ord(ftSettings), Ord(FirstTypeOf(Frames)));
  AssertFalse('the leading frame is not an ACK', Frames[0].IsAck);
  AssertEquals('the leading frame uses stream zero', 0,
    Frames[0].Header.StreamId);
  AssertEquals('the stream opened', 1, FCore.OpenStreams);
end;

procedure TConnectionCoreTest.TestWrongPrefaceIsRefused;
var
  Data: TBytes;
  Frames: TArray<TFrame>;
begin
  NewCore;
  Data := Pack(True, [RequestFrame(1)]);
  Data[3] := Ord('X');
  FCore.Feed(Data);
  Frames := OutputFrames;
  AssertEquals('a wrong preface is a protocol error', Ord(ecProtocolError),
    Ord(GoAwayCodeOf(Frames)));
  AssertEquals('no stream was created', 0, FCore.OpenStreams);
  AssertTrue('the connection reports its close', FEvents.Closing > 0);
end;

procedure TConnectionCoreTest.TestPrefaceSplitAcrossFeeds;
var
  Data: TBytes;
begin
  NewCore;
  Data := Pack(True, [RequestFrame(1)]);
  FCore.Feed(Slice(Data, 0, 7));
  FCore.Feed(Slice(Data, 7, Length(Data) - 7));
  AssertEquals('the preface split across feeds is accepted', 1,
    FCore.OpenStreams);
  AssertEquals('the request arrived once', 1, FEvents.Requests);
end;

procedure TConnectionCoreTest.TestSettingsIsAcknowledged;
var
  Frames: TArray<TFrame>;
  Peer: TFrame;
begin
  NewCore;
  Peer := TFrame.Create(ftSettings, [], 0,
    TConnectionSettings.Defaults.Encode);
  FCore.Feed(Pack(True, [Peer]));
  Frames := OutputFrames;
  AssertTrue('the peer SETTINGS frame is acknowledged',
    AckSettingsOf(Frames));
end;

procedure TConnectionCoreTest.TestInitialWindowChangeAdjustsOpenStreams;
var
  S: TConnectionSettings;
  Peer: TFrame;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1, False)]));
  OutputFrames;
  S := TConnectionSettings.Defaults;
  S.InitialWindowSize := TestStreamWindow + 1000;
  Peer := TFrame.Create(ftSettings, [], 0, S.Encode);
  FCore.Feed(Pack(False, [Peer]));
  OutputFrames;
  AssertEquals('the open stream window follows the delta',
    Int64(TestStreamWindow + 1000), FCore.StreamWindowSize(1));
end;

procedure TConnectionCoreTest.TestHeadersSplitAtEveryByteStillArrives;
var
  Data: TBytes;
  Cut: Integer;
begin
  Data := Pack(True, [RequestFrame(1)]);
  for Cut := 1 to Length(Data) - 1 do
  begin
    NewCore;
    FCore.Feed(Slice(Data, 0, Cut));
    FCore.Feed(Slice(Data, Cut, Length(Data) - Cut));
    AssertEquals(Format('cut %d opens the stream', [Cut]), 1,
      FCore.OpenStreams);
    AssertEquals(Format('cut %d delivers the request', [Cut]), 1,
      FEvents.Requests);
  end;
end;

procedure TConnectionCoreTest.TestPartialFrameIsBuffered;
var
  Data: TBytes;
begin
  NewCore;
  Data := Pack(True, [RequestFrame(1)]);
  FCore.Feed(Slice(Data, 0, Length(Data) - 3));
  AssertEquals('no stream opens before the frame is complete', 0,
    FCore.OpenStreams);
  FCore.Feed(Slice(Data, Length(Data) - 3, 3));
  AssertEquals('the stream opens when the frame completes', 1,
    FCore.OpenStreams);
end;

procedure TConnectionCoreTest.TestEvenStreamIdClosesTheConnection;
var
  Frames: TArray<TFrame>;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(2)]));
  Frames := OutputFrames;
  AssertEquals('an even stream id is a protocol error', Ord(ecProtocolError),
    Ord(GoAwayCodeOf(Frames)));
  AssertFalse('the connection reports no open stream', FCore.OpenStreams > 0);
end;

procedure TConnectionCoreTest.TestRepeatedStreamIdClosesTheConnection;
var
  Frames: TArray<TFrame>;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(3, False), RequestFrame(1, False)]));
  Frames := OutputFrames;
  AssertEquals('a stream id that does not increase is a protocol error',
    Ord(ecProtocolError), Ord(GoAwayCodeOf(Frames)));
end;

procedure TConnectionCoreTest.TestOverConcurrentLimitIsRefused;
var
  Frames: TArray<TFrame>;
  I: Integer;
  Refused: TFrame;
begin
  NewCore;
  for I := 1 to TestMaxConcurrent do
    FCore.Feed(Pack(I = 1, [RequestFrame(I * 2 - 1, False)]));
  FCore.Feed(Pack(False, [RequestFrame(TestMaxConcurrent * 2 + 1, False)]));
  Frames := OutputFrames;
  Refused := AnyOf(Frames, ftRstStream);
  AssertEquals('the refused stream is the one above the limit',
    LongWord(TestMaxConcurrent * 2 + 1), Refused.Header.StreamId);
  AssertEquals('only the streams under the limit stay open',
    TestMaxConcurrent, FCore.OpenStreams);
  AssertFalse('the connection stays open', FCore.GoAwaySent);
end;

procedure TConnectionCoreTest.TestRequestRaisesRequestReady;
var
  Stream: TServerStream;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1)]));
  AssertEquals('the request arrived once', 1, FEvents.Requests);
  Stream := FCore.StreamById(1);
  AssertTrue('the stream is reachable', Stream <> nil);
  AssertEquals('the method reached the stream', 'GET',
    Stream.RemoteHeaders[0].Value);
  AssertEquals('the path reached the stream', '/index.html',
    Stream.RemoteHeaders[2].Value);
end;

procedure TConnectionCoreTest.TestEndStreamOnHeadersClosesRemoteSide;
var
  Stream: TServerStream;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1, True)]));
  Stream := FCore.StreamById(1);
  AssertTrue('END_STREAM closes the remote side', Stream.BodyIsComplete);
end;

procedure TConnectionCoreTest.TestContinuationAssemblesTheHeaderBlock;
var
  Encoded, First, Second: TBytes;
  Head, Cont: TFrame;
  Half: Integer;
  Stream: TServerStream;
begin
  NewCore;
  Encoded := BlockOf([':method', ':scheme', ':path', 'x-long'],
    ['GET', 'https', '/x', StringOfChar('v', 400)]);
  Half := Length(Encoded) div 2;
  First := Slice(Encoded, 0, Half);
  Second := Slice(Encoded, Half, Length(Encoded) - Half);
  Head := TFrame.Create(ftHeaders, [], 1, First);
  Cont := TFrame.Create(ftContinuation, [ffEndHeaders], 1, Second);
  FCore.Feed(Pack(True, [Head, Cont]));
  AssertEquals('the assembled block delivers one request', 1,
    FEvents.Requests);
  Stream := FCore.StreamById(1);
  AssertEquals('the split value is reassembled',
    StringOfChar('v', 400), Stream.RemoteHeaders[3].Value);
end;

procedure TConnectionCoreTest.TestContinuationCapClosesTheConnection;
var
  Frames: TArray<TFrame>;
  I: Integer;
  List: array of TFrame;
  Head, Cont: TFrame;
begin
  NewCore;
  Head := TFrame.Create(ftHeaders, [], 1,
    Slice(BlockOf([':method'], ['GET']), 0, 3));
  // one more CONTINUATION than the cap allows
  SetLength(List, TestContinuationCap + 2);
  List[0] := Head;
  for I := 0 to TestContinuationCap do
  begin
    Cont := TFrame.Create(ftContinuation, [], 1, BlockOf(['a'], ['b']));
    if I = TestContinuationCap then
      Cont.Header.Flags := [ffEndHeaders];
    List[I + 1] := Cont;
  end;
  FCore.Feed(Pack(True, List));
  Frames := OutputFrames;
  AssertEquals('a CONTINUATION flood says ENHANCE_YOUR_CALM',
    Ord(ecEnhanceYourCalm), Ord(GoAwayCodeOf(Frames)));
  AssertEquals('the request never completed', 0, FEvents.Requests);
end;

procedure TConnectionCoreTest.TestHeaderListTooLargeClosesTheConnection;
var
  Override: TConnectionCoreOptions;
  Frames: TArray<TFrame>;
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
begin
  Override := PlainOptions;
  Override.MaxHeaderListSize := 40;
  NewCore;
  Release;
  MakeCoreWith(Override, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, True)]));
  Frames := OutputFrames;
  ParseGoAway(AnyOf(Frames, ftGoAway), Id, Code, Debug);
  AssertEquals('a header list above the limit says ENHANCE_YOUR_CALM',
    Ord(ecEnhanceYourCalm), Ord(Code));
  AssertEquals('the request never completed', 0, FEvents.Requests);
end;

procedure TConnectionCoreTest.TestContinuationWithoutHeadersIsRefused;
var
  Frames: TArray<TFrame>;
  Cont: TFrame;
begin
  NewCore;
  Cont := TFrame.Create(ftContinuation, [ffEndHeaders], 1,
    BlockOf(['a'], ['b']));
  FCore.Feed(Pack(True, [Cont]));
  Frames := OutputFrames;
  AnyOf(Frames, ftGoAway);
end;

procedure TConnectionCoreTest.TestDataReachesTheStreamAndBothWindows;
var
  Stream: TServerStream;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1, False), DataFrame(1, TestBodySize)]));
  OutputFrames;
  Stream := FCore.StreamById(1);
  AssertEquals('the body bytes reached the stream buffer', TestBodySize,
    Stream.InboundCount);
  AssertEquals('the stream window lost the body octets',
    Int64(TestStreamWindow - TestBodySize), FCore.StreamWindowSize(1));
  AssertEquals('the connection window lost the body octets',
    Int64(TestConnectionWindow - TestBodySize), FCore.ConnectionWindowSize);
end;

procedure TConnectionCoreTest.TestDataOverrunIsAConnectionError;
var
  Override: TConnectionCoreOptions;
  Frames: TArray<TFrame>;
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
  GoAway: TFrame;
begin
  Override := PlainOptions;
  Override.InitialStreamWindow := TestBodySize;
  NewCore;
  Release;
  MakeCoreWith(Override, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, False),
    DataFrame(1, TestBodySize * 2)]));
  Frames := OutputFrames;
  GoAway := AnyOf(Frames, ftGoAway);
  ParseGoAway(GoAway, Id, Code, Debug);
  AssertEquals('an overrun is a flow-control connection error',
    Ord(ecFlowControlError), Ord(Code));
end;

procedure TConnectionCoreTest.TestSlowHandlerResetsOnlyItsStream;
var
  Override: TConnectionCoreOptions;
  Frames: TArray<TFrame>;
  Rst: TFrame;
begin
  Override := PlainOptions;
  Override.InboundBufferLimit := TestBodySize;
  NewCore;
  Release;
  MakeCoreWith(Override, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, False), DataFrame(1, TestBodySize)]));
  FCore.Feed(Pack(False, [DataFrame(1, TestBodySize)]));
  Frames := OutputFrames;
  Rst := AnyOf(Frames, ftRstStream);
  AssertEquals('the slow stream is reset', 1, Rst.Header.StreamId);
  AssertFalse('the connection stays open', FCore.GoAwaySent);
  AssertEquals('the reset stream is closed', 0, FCore.OpenStreams);
end;

procedure TConnectionCoreTest.TestPingIsAcknowledged;
var
  Frames: TArray<TFrame>;
  Payload: TBytes;
  Ack: TFrame;
  I: Integer;
begin
  NewCore;
  SetLength(Payload, 8);
  FillChar(Payload[0], 8, Ord('p'));
  FCore.Feed(Pack(True, [TFrame.Create(ftPing, [], 0, Payload)]));
  Frames := OutputFrames;
  Ack := AnyOf(Frames, ftPing);
  AssertTrue('the PING is acknowledged', Ack.IsAck);
  AssertEquals('the echoed payload length', 8, Length(Ack.Payload));
  for I := 0 to 7 do
    AssertEquals(Format('echoed octet %d', [I]), Ord('p'),
      Ack.Payload[I]);
end;

procedure TConnectionCoreTest.TestPriorityIsIgnored;
var
  Frames: TArray<TFrame>;
  Payload: TBytes;
begin
  NewCore;
  SetLength(Payload, 5);
  Payload[0] := 0;
  Payload[1] := 0;
  Payload[2] := 0;
  Payload[3] := 0;
  Payload[4] := 16;
  FCore.Feed(Pack(True, [TFrame.Create(ftPriority, [], 1, Payload)]));
  Frames := OutputFrames;
  AssertEquals('a PRIORITY frame produces no RST_STREAM', 0,
    CountOf(Frames, ftRstStream));
  AssertFalse('a PRIORITY frame names no stream', FCore.OpenStreams > 0);
  AssertFalse('the connection stays open', FCore.GoAwaySent);
end;

procedure TConnectionCoreTest.TestClientGoAwayCancelsOpenStreams;
var
  Stream: TServerStream;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1, False), RequestFrame(3, False)]));
  Stream := FCore.StreamById(1);
  // a running handler holds one reference, so the stream stays alive after
  // the core closes it
  Stream.AddRef;
  FCore.Feed(Pack(False, [TFrame.Create(ftGoAway, [], 0,
    GoAwayPayload(1, ecNoError))]));
  AssertEquals('a client GOAWAY closes every stream', 0, FCore.OpenStreams);
  AssertEquals('a client GOAWAY resets each open stream', 2, FEvents.Resets);
  AssertTrue('the blocked stream is cancelled', Stream.IsCancelled);
  Stream.ReleaseRef;
  AssertTrue('the connection reports its close', FEvents.Closing > 0);
end;

procedure TConnectionCoreTest.TestRstStreamKeepsTheConnection;
var
  Stream: TServerStream;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1, False)]));
  Stream := FCore.StreamById(1);
  // a running handler holds one reference, so the stream stays alive after
  // the core closes it
  Stream.AddRef;
  FCore.Feed(Pack(False, [TFrame.Create(ftRstStream, [], 1,
    RstPayload(ecCancel))]));
  AssertEquals('the reset stream is closed', 0, FCore.OpenStreams);
  AssertEquals('the reset raised one event', 1, FEvents.Resets);
  AssertTrue('the stream is cancelled', Stream.IsCancelled);
  Stream.ReleaseRef;
  AssertFalse('the connection stays open', FCore.GoAwaySent);
end;

procedure TConnectionCoreTest.TestResetAbuseTripsTheBucket;
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

procedure TConnectionCoreTest.TestBucketTripSendsEnhanceYourCalm;
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

procedure TConnectionCoreTest.TestControlFrameAbuseTripsTheBucket;
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

procedure TConnectionCoreTest.TestConnectionCreditReturnsOnBuffer;
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

procedure TConnectionCoreTest.TestStreamCreditFollowsAHandlerRead;
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

procedure TConnectionCoreTest.TestResponseHeadersAreEncodedOnce;
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

procedure TConnectionCoreTest.TestLongHeaderListKeepsRunsContiguous;
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

procedure TConnectionCoreTest.TestClosedStreamsAreFreed;
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
  RegisterTest(TConnectionCoreTest);
end.
