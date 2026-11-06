{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, output, caps, data frame, test, fpcunit
notes:
  - This unit tests the outbound frame caps and the DATA frame size cap.
  - The core holds no socket, so the tests drive it with byte arrays.
  - The long download simulates the IO reports at the core level, so the
    suite stays fast.
---
}
/// Unit tests for the outbound caps of the connection core
// - run with `make test`.
unit Http2Server.OutputCaps.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Connection, Http2Server.Seam,
  Http2Server.Stream, Http2Server.Config, Http2Server.Config.Limits,
  Http2Server.Async.Options, Http2Server.Connection.Test;

type
  /// a handler that does nothing, only to satisfy the factory wiring
  TCapsStubHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// tests of the outbound frame caps and the DATA frame size cap
  TOutputCapsTest = class(TConnectionFixture)
  private
    FStub: IHttp2Handler;
    function CappedOptions(const AMaxFrames, AMaxControl,
      AMaxData: LongWord): TConnectionCoreOptions;
    function Ping: TFrame;
    function ClientSettings: TFrame;
    function ClientSettingsBig(const AMaxFrameSize,
      AInitialWindow: LongWord): TFrame;
    function PatternBytes(const ACount: Integer): TBytes;
    function SameBytes(const AFirst, ASecond: TBytes): Boolean;
    procedure CountData(const AData: TBytes; out AFrames: Integer;
      out AOctets: Int64);
    function DataConcat(const AFrames: TArray<TFrame>): TBytes;
    function DataMax(const AFrames: TArray<TFrame>): Integer;
    function GoAwayCode(const AFrames: TArray<TFrame>): THttp2ErrorCode;
  protected
    procedure SetUp; override;
  published
    /// PINGs without a drain abort the connection at the frame cap
    procedure TestPingFloodWithoutDrainAbortsAtTheCap;
    /// PINGs with a drain that reports never abort
    procedure TestPingFloodWithReportsDoesNotAbort;
    /// a frame cap of 0 never trips
    procedure TestZeroFrameCapNeverTrips;
    /// the control cap trips before the total cap
    procedure TestControlCapTripsBeforeTotalCap;
    /// a 10 KiB response leaves in DATA frames of at most 1024 octets
    procedure TestDataFramesObeyMaxDataFrameSizeOut;
    /// a zero DATA cap with MaxFrameSize 65536 sends frames of 65536
    procedure TestZeroDataCapSendsUpToMaxFrameSize;
    /// the factory ServerLimits reach the core options
    procedure TestFactoryMapsTheThreeCaps;
    /// a steady reader of 170 MiB never trips the frame cap
    procedure TestLongDownloadWithSteadyReaderDoesNotTrip;
    /// a reader that stops trips a cap
    procedure TestLongDownloadStoppedReaderTripsACap;
  end;

implementation

const
  /// the octets one round of the long download moves: the whole window
  cRoundOctets = 65535;
  /// the octets that stay pending after each report of the long download
  cRoundPending = 100;
  /// the rounds of the long download: 2600 rounds move about 170 MiB in
  /// 10400 DATA frames of 16384 octets, above the cap of 10000 frames
  cLongRounds = 2600;

{ TCapsStubHandler }

procedure TCapsStubHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  // the factory holds the handler; the test never calls it
end;

{ TOutputCapsTest }

procedure TOutputCapsTest.SetUp;
begin
  inherited SetUp;
  FStub := TCapsStubHandler.Create;
end;

function TOutputCapsTest.CappedOptions(const AMaxFrames, AMaxControl,
  AMaxData: LongWord): TConnectionCoreOptions;
begin
  // every new field is set here, so no test depends on a default
  Result := PlainOptions;
  Result.MaxOutboundFrames := AMaxFrames;
  Result.MaxOutboundControlFrames := AMaxControl;
  Result.MaxDataFrameSizeOut := AMaxData;
end;

function TOutputCapsTest.Ping: TFrame;
var
  Payload: TBytes;
begin
  SetLength(Payload, 8);
  Payload[0] := 1;
  Payload[7] := 8;
  Result := BuildPingFrame(Payload, False);
end;

function TOutputCapsTest.ClientSettings: TFrame;
begin
  Result := BuildSettingsFrame(TConnectionSettings.Defaults);
end;

function TOutputCapsTest.ClientSettingsBig(const AMaxFrameSize,
  AInitialWindow: LongWord): TFrame;
var
  Peer: TConnectionSettings;
begin
  Peer := TConnectionSettings.Defaults;
  Peer.MaxFrameSize := AMaxFrameSize;
  Peer.InitialWindowSize := AInitialWindow;
  Result := BuildSettingsFrame(Peer);
end;

function TOutputCapsTest.PatternBytes(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte(I mod 251);
end;

function TOutputCapsTest.SameBytes(const AFirst,
  ASecond: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(AFirst) <> Length(ASecond) then
    Exit(False);
  for I := 0 to Length(AFirst) - 1 do
    if AFirst[I] <> ASecond[I] then
      Exit(False);
  Result := True;
end;

procedure TOutputCapsTest.CountData(const AData: TBytes; out AFrames: Integer;
  out AOctets: Int64);
var
  Offset: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
begin
  // the headers of the batch are walked without copying the payloads
  AFrames := 0;
  AOctets := 0;
  Offset := 0;
  while Offset + FrameHeaderSize <= Length(AData) do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(AData[Offset], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    if Offset + FrameHeaderSize + Integer(Header.Length) > Length(AData) then
      Break;
    if Header.FrameType = ftData then
    begin
      Inc(AFrames);
      Inc(AOctets, Header.Length);
    end;
    Inc(Offset, FrameHeaderSize + Integer(Header.Length));
  end;
end;

function TOutputCapsTest.DataConcat(
  const AFrames: TArray<TFrame>): TBytes;
var
  I, At: Integer;
begin
  Result := nil;
  At := 0;
  for I := 0 to Length(AFrames) - 1 do
    if AFrames[I].Header.FrameType = ftData then
    begin
      SetLength(Result, At + Length(AFrames[I].Payload));
      if Length(AFrames[I].Payload) > 0 then
        Move(AFrames[I].Payload[0], Result[At],
          Length(AFrames[I].Payload));
      Inc(At, Length(AFrames[I].Payload));
    end;
end;

function TOutputCapsTest.DataMax(const AFrames: TArray<TFrame>): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Length(AFrames) - 1 do
    if AFrames[I].Header.FrameType = ftData then
      if Length(AFrames[I].Payload) > Result then
        Result := Length(AFrames[I].Payload);
end;

function TOutputCapsTest.GoAwayCode(
  const AFrames: TArray<TFrame>): THttp2ErrorCode;
var
  Id: LongWord;
  Debug: TBytes;
begin
  ParseGoAway(AnyOf(AFrames, ftGoAway), Id, Result, Debug);
end;

procedure TOutputCapsTest.TestPingFloodWithoutDrainAbortsAtTheCap;
var
  Options: TConnectionCoreOptions;
  I: Integer;
begin
  Options := CappedOptions(10, 0, 0);
  Options.MaxOutputBytes := 0;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings]));
  // the preface queues the server SETTINGS and its acknowledgment, so two
  // frames wait before the first PING
  I := 0;
  while (I < 20) and not FCore.Aborted do
  begin
    Inc(I);
    FCore.Feed(Pack(False, [Ping]));
  end;
  AssertTrue('the flood aborts the connection', FCore.Aborted);
  AssertEquals('eleven frames pass the cap of ten', 9, I);
  AssertEquals('the abort says ENHANCE_YOUR_CALM',
    Ord(ecEnhanceYourCalm), Ord(GoAwayCode(OutputFrames)));
end;

procedure TOutputCapsTest.TestPingFloodWithReportsDoesNotAbort;
var
  Options: TConnectionCoreOptions;
  Data: TBytes;
  I: Integer;
begin
  Options := CappedOptions(10, 0, 0);
  Options.MaxOutputBytes := 0;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings]));
  for I := 1 to 50 do
  begin
    FCore.Feed(Pack(False, [Ping]));
    FCore.TakeOutput(Data);
    FCore.ReportWritten(FCore.HandedOutTotal);
    AssertFalse('no PING aborts while the reader drains', FCore.Aborted);
  end;
  AssertFalse('the connection stays open', FCore.GoAwaySent);
end;

procedure TOutputCapsTest.TestZeroFrameCapNeverTrips;
var
  Options: TConnectionCoreOptions;
  I: Integer;
begin
  Options := CappedOptions(0, 0, 0);
  Options.MaxOutputBytes := 0;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings]));
  for I := 1 to 200 do
    FCore.Feed(Pack(False, [Ping]));
  AssertFalse('a cap of 0 never aborts', FCore.Aborted);
  AssertFalse('no GOAWAY leaves', FCore.GoAwaySent);
  AssertEquals('every PING is answered', 200,
    CountOf(OutputFrames, ftPing));
end;

procedure TOutputCapsTest.TestControlCapTripsBeforeTotalCap;
var
  Options: TConnectionCoreOptions;
  I: Integer;
begin
  Options := CappedOptions(100, 5, 0);
  Options.MaxOutputBytes := 0;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings]));
  // two control frames wait already; the fourth PING is the sixth
  I := 0;
  while (I < 20) and not FCore.Aborted do
  begin
    Inc(I);
    FCore.Feed(Pack(False, [Ping]));
  end;
  AssertTrue('the flood aborts the connection', FCore.Aborted);
  AssertEquals('six control frames pass the cap of five', 4, I);
  AssertEquals('the abort says ENHANCE_YOUR_CALM',
    Ord(ecEnhanceYourCalm), Ord(GoAwayCode(OutputFrames)));
end;

procedure TOutputCapsTest.TestDataFramesObeyMaxDataFrameSizeOut;
var
  Options: TConnectionCoreOptions;
  Stream: TServerStream;
  Body, Back: TBytes;
  Frames: TArray<TFrame>;
  Headers: THeaderBlock;
begin
  Options := CappedOptions(0, 0, 1024);
  Options.MaxOutputBytes := 0;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings, RequestFrame(1, True)]));
  Stream := FCore.StreamById(1);
  AssertTrue('the stream is open', Stream <> nil);
  Headers := nil;
  Stream.QueueResponseHeaders(200, Headers, False);
  Body := PatternBytes(10240);
  Stream.Write(Body);
  FCore.Flush;
  Frames := OutputFrames;
  AssertEquals('ten DATA frames leave', 10, CountOf(Frames, ftData));
  AssertEquals('no DATA frame passes 1024 octets', 1024,
    DataMax(Frames));
  Back := DataConcat(Frames);
  AssertTrue('the bytes are unchanged', SameBytes(Body, Back));
end;

procedure TOutputCapsTest.TestZeroDataCapSendsUpToMaxFrameSize;
var
  Options: TConnectionCoreOptions;
  Stream: TServerStream;
  Body, Back: TBytes;
  Frames: TArray<TFrame>;
  Headers: THeaderBlock;
begin
  Options := CappedOptions(0, 0, 0);
  Options.MaxFrameSize := 65536;
  Options.OutboundBufferLimit := 262144;
  Options.MaxOutputBytes := 0;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings, RequestFrame(1, True)]));
  // the peer allows 65536-octet frames and opens its windows wide
  FCore.Feed(Pack(False, [ClientSettingsBig(65536, 1000000),
    BuildWindowUpdateFrame(0, 1000000)]));
  Stream := FCore.StreamById(1);
  AssertTrue('the stream is open', Stream <> nil);
  Headers := nil;
  Stream.QueueResponseHeaders(200, Headers, False);
  Body := PatternBytes(150000);
  Stream.Write(Body);
  FCore.Flush;
  Frames := OutputFrames;
  AssertEquals('three DATA frames leave', 3, CountOf(Frames, ftData));
  AssertEquals('a DATA frame reaches 65536 octets', 65536,
    DataMax(Frames));
  Back := DataConcat(Frames);
  AssertTrue('the bytes are unchanged', SameBytes(Body, Back));
end;

procedure TOutputCapsTest.TestFactoryMapsTheThreeCaps;
var
  Factory: THttp2ServerFactory;
  Options: TConnectionCoreOptions;
begin
  Factory := THttp2ServerFactory.Create
    .WithHandler(FStub)
    .WithClearTextAllowed(True)
    .WithServerLimits(TServerLimits.Create
      .WithMaxOutboundFrames(11)
      .WithMaxOutboundControlFrames(7)
      .WithMaxDataFrameSizeOut(2048));
  Options := BuildConnectionCoreOptions(Factory);
  AssertEquals('the frame cap reaches the core', 11,
    Integer(Options.MaxOutboundFrames));
  AssertEquals('the control cap reaches the core', 7,
    Integer(Options.MaxOutboundControlFrames));
  AssertEquals('the DATA size reaches the core', 2048,
    Integer(Options.MaxDataFrameSizeOut));
  Factory := THttp2ServerFactory.Create
    .WithHandler(FStub)
    .WithClearTextAllowed(True);
  Options := BuildConnectionCoreOptions(Factory);
  AssertEquals('the default frame cap is 10000', 10000,
    Integer(Options.MaxOutboundFrames));
  AssertEquals('the default control cap is 1000', 1000,
    Integer(Options.MaxOutboundControlFrames));
  AssertEquals('the default DATA size is 0', 0,
    Integer(Options.MaxDataFrameSizeOut));
end;

procedure TOutputCapsTest.TestLongDownloadWithSteadyReaderDoesNotTrip;
var
  Options: TConnectionCoreOptions;
  Stream: TServerStream;
  Chunk, Batch: TBytes;
  Headers: THeaderBlock;
  Round, Got: Integer;
  DataFrames: Integer;
  DataOctets, RoundOctets: Int64;
begin
  Options := CappedOptions(10000, 1000, 0);
  Options.MaxOutputBytes := 16777216;
  Options.OutboundBufferLimit := 131072;
  MakeCoreWith(Options, 1000000);
  FCore.Feed(Pack(True, [ClientSettings, RequestFrame(1, True)]));
  Stream := FCore.StreamById(1);
  AssertTrue('the stream is open', Stream <> nil);
  Headers := nil;
  Stream.QueueResponseHeaders(200, Headers, False);
  Chunk := PatternBytes(cRoundOctets);
  DataFrames := 0;
  DataOctets := 0;
  for Round := 1 to cLongRounds do
  begin
    Stream.Write(Chunk);
    FCore.Flush;
    AssertFalse('no round aborts while the reader drains', FCore.Aborted);
    FCore.TakeOutput(Batch);
    CountData(Batch, Got, RoundOctets);
    Inc(DataFrames, Got);
    Inc(DataOctets, RoundOctets);
    // the reader is at full speed but always leaves some octets pending
    FCore.ReportWritten(FCore.HandedOutTotal - cRoundPending);
    FCore.Feed(Pack(False, [BuildWindowUpdateFrame(0, cRoundOctets),
      BuildWindowUpdateFrame(1, cRoundOctets)]));
  end;
  AssertFalse('the connection stays open', FCore.Aborted);
  AssertTrue('more than 10000 DATA frames left', DataFrames > 10000);
  AssertTrue('more than 10000 x 16 KiB left',
    DataOctets > Int64(10000) * 16384);
end;

procedure TOutputCapsTest.TestLongDownloadStoppedReaderTripsACap;
var
  Options: TConnectionCoreOptions;
  Stream: TServerStream;
  Chunk: TBytes;
  Headers: THeaderBlock;
  Round: Integer;
begin
  Options := CappedOptions(64, 0, 0);
  Options.MaxOutputBytes := 0;
  Options.OutboundBufferLimit := 131072;
  MakeCoreWith(Options, 100000);
  FCore.Feed(Pack(True, [ClientSettings, RequestFrame(1, True)]));
  Stream := FCore.StreamById(1);
  AssertTrue('the stream is open', Stream <> nil);
  Headers := nil;
  Stream.QueueResponseHeaders(200, Headers, False);
  Chunk := PatternBytes(cRoundOctets);
  Round := 0;
  while (Round < 200) and not FCore.Aborted do
  begin
    Inc(Round);
    Stream.Write(Chunk);
    FCore.Flush;
    // the windows stay open; only the reads stop
    FCore.Feed(Pack(False, [BuildWindowUpdateFrame(0, cRoundOctets),
      BuildWindowUpdateFrame(1, cRoundOctets)]));
  end;
  AssertTrue('the stopped reader trips the cap', FCore.Aborted);
  AssertEquals('the abort says ENHANCE_YOUR_CALM',
    Ord(ecEnhanceYourCalm), Ord(GoAwayCode(OutputFrames)));
end;

initialization
  RegisterTest(TOutputCapsTest);
end.
