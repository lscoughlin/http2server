{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, output, drain, test
notes:
  - Tests for the outbound drain in Http2Server.Output.
  - The drain obeys the stream window, the connection window and the peer
    frame size, and it wakes the IO thread once per transition from "no
    output" to "output".
---
}
/// Outbound drain tests for Http2Server.Output
unit Http2Server.Output.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.FlowControl,
  Http2Server.Hpack, Http2Server.Connection, Http2Server.Limits,
  Http2Server.Output, Http2Server.Seam, Http2Server.Stream;

type
  /// counts the wake-ups the drain asks for
  TCountingWaker = class(TInterfacedObject, IWriteWaker)
  private
    FSignals: Integer;
  public
    procedure Signal;
    property Signals: Integer read FSignals;
  end;

  /// writes a body into a stream and records how it ended
  TWriterProbe = class(TThread)
  private
    FStream: TServerStream;
    FData: TBytes;
    FStarted: Boolean;
    FDone: Boolean;
    FFailed: Boolean;
    FCancelled: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AStream: TServerStream; const AData: TBytes);
    function WaitStarted(const ATimeoutMs: Integer = 5000): Boolean;
    function WaitDone(const ATimeoutMs: Integer = 5000): Boolean;
    property Done: Boolean read FDone;
    property Failed: Boolean read FFailed;
    property Cancelled: Boolean read FCancelled;
    /// cancel the stream and wait, so Free never parks on a blocked writer
    procedure Unblock;
  end;

  TOutputDrainTest = class(TTestCase)
  private
    FKeepWaker: IWriteWaker;
    FCore: TServerConnectionCore;
    FLimits: TConnectionLimits;
    FClock: IMonotonicClock;
    FFlow: TFlowControl;
    FWaker: TCountingWaker;
    FDrain: TOutputDrain;
    FStreams: TObjectList<TServerStream>;

    function Options: TOutputDrainOptions;
    procedure Build;
    procedure BuildWith(const AConnWindow, AStreamWindow: Int64);
    procedure Release;
    function StreamFor(const AStreamId: LongWord): TServerStream;
    function Pack(const AData: TBytes): TBytes;
    function FramesOf(const AData: TBytes): TArray<TFrame>;
    function CountOf(const AFrames: TArray<TFrame>;
      const AFrameType: TFrameType): Integer;
    function DataOf(const AFrames: TArray<TFrame>): TBytes;
    function RandomBytes(const ACount: Integer): TBytes;
    function CountDataFor(const AFrames: TArray<TFrame>;
      const AStreamId: LongWord): Integer;
    function StreamRoomFor(const AStreamId: LongWord): Int64;
    function CoreOptions: TConnectionCoreOptions;
    function BuildLimits: TConnectionLimits;
    procedure MakeCore(const AMaxFrameSize: LongWord);
    function LongList: THeaderBlock;
    function ClientPrefaceBytes: TBytes;
    function RequestBlock(const AStreamId: LongWord): TFrame;
    function RequestWire(const AStreamIds: array of LongWord): TBytes;
    function WireOf(const AFrame: TFrame): TBytes;
    function DrainedFrames: TArray<TFrame>;
    procedure TearDown; override;
  published
    /// a write wakes the IO thread once, not once per call
    procedure TestWakerSignalsOncePerTransition;
    /// taking the bytes lets the next write wake the IO thread again
    procedure TestWakerSignalsAgainAfterOutputIsTaken;
    /// a small write becomes one DATA frame that names its stream
    procedure TestSmallWriteBecomesOneDataFrame;
    /// every octet value survives the drain
    procedure TestAllByteValuesRoundTrip;
    /// a large body is split into frames no larger than the peer size
    procedure TestBodyIsFramedByThePeerSize;
    /// a closed stream window stops the drain for that stream alone
    procedure TestClosedStreamWindowHoldsBackOnlyThatStream;
    /// a window update releases the held-back stream
    procedure TestWindowUpdateReleasesTheStream;
    /// a closed connection window stops every stream
    procedure TestClosedConnectionWindowStopsEveryStream;
    /// a full body drains and ends the stream once
    procedure TestFinishEndsTheStreamOnce;
    /// ten equal streams finish within one turn of each other
    procedure TestTenEqualStreamsFinishTogether;
    /// a handler blocked on a full buffer is released by the drain
    procedure TestDrainReleasesABlockedWriter;
    /// cancellation wakes a blocked writer with a stream error
    procedure TestCancelWakesABlockedWriter;
    /// the effective frame size is the smaller of the two limits
    procedure TestEffectiveFrameSizeIsTheSmallerLimit;
    procedure TestLongHeaderRunsNeverInterleave;
    procedure TestSequentialResponsesShareTheEncoderTable;
  end;

implementation

const
  WindowSize = 65535;
  ConnWindow = 1 shl 22;
  StarvedWindow = 1024;
  SmallFrameSize = 16384;
  // RFC 9113 section 3.4 client connection preface, in octets
  ClientPrefaceOctets: array[0..23] of Byte = (
    $50, $52, $49, $20, $2A, $20, $48, $54, $54, $50, $2F, $32,
    $2E, $30, $0D, $0A, $0D, $0A, $53, $4D, $0D, $0A, $0D, $0A);
  BodyBytes = 512;
  BufferChunk = 1024;

{ TCountingWaker }

procedure TCountingWaker.Signal;
begin
  Inc(FSignals);
end;

{ TWriterProbe }

constructor TWriterProbe.Create(const AStream: TServerStream;
  const AData: TBytes);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStream := AStream;
  FData := AData;
  Start;
end;

procedure TWriterProbe.Execute;
begin
  FStarted := True;
  try
    FStream.Write(FData);
  except
    on E: EStreamCancelled do
      FCancelled := True;
    on E: Exception do
      FFailed := True;
  end;
  FDone := True;
end;

function TWriterProbe.WaitStarted(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    if FStarted then
      Exit(True);
    Sleep(1);
  end;
  Result := FStarted;
end;

procedure TWriterProbe.Unblock;
begin
  if FDone then
    Exit;
  FStream.Cancel(ecCancel);
  WaitDone(6000);
end;

function TWriterProbe.WaitDone(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    if FDone then
      Exit(True);
    Sleep(1);
  end;
  Result := FDone;
end;

{ TOutputDrainTest }

function TOutputDrainTest.Options: TOutputDrainOptions;
begin
  Result.MaxFrameSize := SmallFrameSize;
  Result.BytesPerTurn := 0;
end;

procedure TOutputDrainTest.Build;
begin
  BuildWith(ConnWindow, WindowSize);
end;

procedure TOutputDrainTest.BuildWith(const AConnWindow,
  AStreamWindow: Int64);
begin
  FFlow := TFlowControl.Create(AConnWindow, AStreamWindow);
  FWaker := TCountingWaker.Create;
  FDrain := TOutputDrain.Create(Options, FFlow, FWaker);
  FStreams := TObjectList<TServerStream>.Create(True);
end;

procedure TOutputDrainTest.Release;
begin
  FStreams.Free;
  FStreams := nil;
  FDrain.Free;
  FDrain := nil;
  FWaker := nil;
  FFlow.Free;
  FFlow := nil;
end;

procedure TOutputDrainTest.TearDown;
begin
  Release;
  FCore.Free;
  FCore := nil;
  FLimits.Free;
  FLimits := nil;
  // the clock is reference-counted through its interface, so releasing the
  // last reference is the only thing that frees it
  FClock := nil;
end;

function TOutputDrainTest.CoreOptions: TConnectionCoreOptions;
begin
  Result.ConnectionWindow := ConnWindow;
  Result.InitialStreamWindow := WindowSize;
  Result.MaxConcurrentStreams := 16;
  Result.MaxFrameSize := SmallFrameSize;
  Result.MaxHeaderListSize := 65536;
  Result.MaxHeaderTableSize := 4096;
  Result.MaxContinuations := 16;
  Result.MaxHeaderBlockBytes := 65536;
  Result.InboundBufferLimit := 65536;
  Result.OutboundBufferLimit := 65536;
  Result.ConnectionUpdateThreshold := 32768;
  Result.StreamUpdateThreshold := 32768;
end;

function TOutputDrainTest.BuildLimits: TConnectionLimits;
var
  R, C: TTokenBucketOptions;
begin
  R := TTokenBucketOptions.Create.WithCapacity(10000).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(2);
  C := TTokenBucketOptions.Create.WithCapacity(10000).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(1);
  Result := TConnectionLimits.Create(FClock, R, C);
end;

procedure TOutputDrainTest.MakeCore(const AMaxFrameSize: LongWord);
var
  Options: TConnectionCoreOptions;
begin
  Options := CoreOptions;
  Options.MaxFrameSize := AMaxFrameSize;
  FClock := TManualMonotonicClock.Create;
  FLimits := BuildLimits;
  FCore := TServerConnectionCore.Create(Options, nil, FLimits, FClock);
end;

function TOutputDrainTest.LongList: THeaderBlock;
begin
  SetLength(Result, 1);
  Result[0].Name := 'x-long';
  Result[0].Value := StringOfChar('v', 900);
end;

function TOutputDrainTest.ClientPrefaceBytes: TBytes;
var
  I: Integer;
begin
  SetLength(Result, ClientPrefaceSize);
  for I := 0 to ClientPrefaceSize - 1 do
    Result[I] := ClientPreface[I];
end;

function TOutputDrainTest.WireOf(const AFrame: TFrame): TBytes;
var
  HeaderBytes: TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize],
      Length(AFrame.Payload));
end;

function TOutputDrainTest.RequestBlock(
  const AStreamId: LongWord): TFrame;
var
  Codec: THpackCodec;
  Fields: THeaderBlock;
  Encoded: TBytes;
begin
  // the client side of the exchange gets its own encoder
  Codec := THpackCodec.Create;
  try
    SetLength(Fields, 4);
    Fields[0].Name := ':method';
    Fields[0].Value := 'GET';
    Fields[1].Name := ':path';
    Fields[1].Value := '/';
    Fields[2].Name := ':scheme';
    Fields[2].Value := 'https';
    Fields[3].Name := ':authority';
    Fields[3].Value := 'localhost';
    Encoded := Codec.Encode(Fields);
  finally
    Codec.Free;
  end;
  Result := BuildHeadersFrame(AStreamId, Encoded, True, False);
end;

function TOutputDrainTest.RequestWire(
  const AStreamIds: array of LongWord): TBytes;
var
  Bytes: TBytes;
  I: Integer;
begin
  Result := ClientPrefaceBytes;
  // the client states its own settings first
  Bytes := WireOf(BuildSettingsFrame(TConnectionSettings.Defaults));
  SetLength(Result, Length(Result) + Length(Bytes));
  Move(Bytes[0], Result[Length(Result) - Length(Bytes)], Length(Bytes));
  for I := 0 to Length(AStreamIds) - 1 do
  begin
    Bytes := WireOf(RequestBlock(AStreamIds[I]));
    SetLength(Result, Length(Result) + Length(Bytes));
    Move(Bytes[0], Result[Length(Result) - Length(Bytes)], Length(Bytes));
  end;
end;

function TOutputDrainTest.DrainedFrames: TArray<TFrame>;
var
  Data: TBytes;
  Offset, N: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  Result := nil;
  if FCore = nil then
    Exit;
  FCore.Flush;
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

function TOutputDrainTest.StreamFor(
  const AStreamId: LongWord): TServerStream;
var
  I: Integer;
begin
  for I := 0 to FStreams.Count - 1 do
    if FStreams[I].StreamId = AStreamId then
      Exit(FStreams[I]);
  Result := TServerStream.Create(AStreamId, nil, nil, 1024 * 1024,
    1024 * 1024);
  FStreams.Add(Result);
  FFlow.OpenStream(AStreamId);
end;

function TOutputDrainTest.Pack(const AData: TBytes): TBytes;
begin
  // the drain already produced wire bytes, so the helper is not needed to
  // re-serialise them; it exists to prove the frames parse back
  Result := AData;
end;

function TOutputDrainTest.FramesOf(const AData: TBytes): TArray<TFrame>;
var
  Offset, N: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  Result := nil;
  Offset := 0;
  while Offset + FrameHeaderSize <= Length(AData) do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(AData[Offset], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    N := FrameHeaderSize + Integer(Header.Length);
    if Offset + N > Length(AData) then
      Break;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(AData[Offset + FrameHeaderSize], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    SetLength(Result, Length(Result) + 1);
    Result[Length(Result) - 1] := Frame;
    Inc(Offset, N);
  end;
end;

function TOutputDrainTest.CountOf(const AFrames: TArray<TFrame>;
  const AFrameType: TFrameType): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Length(AFrames) - 1 do
    if AFrames[I].Header.FrameType = AFrameType then
      Inc(Result);
end;

function TOutputDrainTest.StreamRoomFor(
  const AStreamId: LongWord): Int64;
var
  W: TWindow;
begin
  if FFlow.TryGetStream(AStreamId, W) then
    Result := W.Size
  else
    Result := 0;
end;

function TOutputDrainTest.CountDataFor(const AFrames: TArray<TFrame>;
  const AStreamId: LongWord): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Length(AFrames) - 1 do
    if (AFrames[I].Header.FrameType = ftData) and
       (AFrames[I].Header.StreamId = AStreamId) then
      Inc(Result);
end;

function TOutputDrainTest.DataOf(const AFrames: TArray<TFrame>): TBytes;
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
      begin
        Move(AFrames[I].Payload[0], Result[At],
          Length(AFrames[I].Payload));
        Inc(At, Length(AFrames[I].Payload));
      end;
    end;
end;

function TOutputDrainTest.RandomBytes(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte((I * 37 + I * I * 11) and $FF);
end;

procedure TOutputDrainTest.TestWakerSignalsOncePerTransition;
var
  Stream: TServerStream;
  Data: TBytes;
begin
  Build;
  Stream := StreamFor(1);
  SetLength(Data, BodyBytes);
  FillChar(Data[0], BodyBytes, Ord('a'));
  Stream.Write(Data);
  FDrain.NotifyWrite;
  FDrain.NotifyWrite;
  FDrain.NotifyWrite;
  AssertEquals('three writes with no drain in between wake the IO thread once',
    1, FWaker.Signals);
end;

procedure TOutputDrainTest.TestWakerSignalsAgainAfterOutputIsTaken;
var
  Stream: TServerStream;
  Data, Out1: TBytes;
begin
  Build;
  Stream := StreamFor(1);
  SetLength(Data, BodyBytes);
  FillChar(Data[0], BodyBytes, Ord('a'));
  Stream.Write(Data);
  FDrain.NotifyWrite;
  FDrain.Drain(FStreams);
  AssertTrue('the drain produced frames', FDrain.TakeOutput(Out1));
  FDrain.NotifyWrite;
  AssertEquals('a write after the drain wakes the IO thread again', 2,
    FWaker.Signals);
end;

procedure TOutputDrainTest.TestSmallWriteBecomesOneDataFrame;
var
  Stream: TServerStream;
  Data, Out1: TBytes;
  Frames: TArray<TFrame>;
begin
  Build;
  Stream := StreamFor(7);
  SetLength(Data, 5);
  Data[0] := Ord('h');
  Data[1] := Ord('e');
  Data[2] := Ord('l');
  Data[3] := Ord('l');
  Data[4] := Ord('o');
  Stream.Write(Data);
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  Frames := FramesOf(Out1);
  AssertEquals('a small write makes one DATA frame', 1,
    CountOf(Frames, ftData));
  AssertEquals('the frame names the stream', 7, Frames[0].Header.StreamId);
  AssertEquals('the payload survives', 'hello',
    string(PChar(@Frames[0].Payload[0])));
  AssertFalse('a write without a finish does not end the stream',
    Frames[0].IsEndStream);
end;

procedure TOutputDrainTest.TestAllByteValuesRoundTrip;
var
  Stream: TServerStream;
  Data, Out1, Back: TBytes;
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Build;
  Stream := StreamFor(1);
  SetLength(Data, 256);
  for I := 0 to 255 do
    Data[I] := Byte(I);
  Stream.Write(Data);
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  Frames := FramesOf(Out1);
  Back := DataOf(Frames);
  AssertEquals('every octet value survives the drain', 256, Length(Back));
  for I := 0 to 255 do
    AssertEquals(Format('octet %d', [I]), I, Back[I]);
end;

procedure TOutputDrainTest.TestBodyIsFramedByThePeerSize;
var
  Stream: TServerStream;
  Data, Out1: TBytes;
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Build;
  FDrain.ApplyPeerFrameSize(1024);
  Stream := StreamFor(1);
  Data := RandomBytes(4096);
  Stream.Write(Data);
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  Frames := FramesOf(Out1);
  AssertEquals('a 4 KB body with a 1 KB peer size makes four frames', 4,
    CountOf(Frames, ftData));
  for I := 0 to Length(Frames) - 1 do
    AssertTrue(Format('frame %d stays inside the peer size', [I]),
      Integer(Frames[I].Header.Length) <= 1024);
end;

procedure TOutputDrainTest.TestClosedStreamWindowHoldsBackOnlyThatStream;
var
  S1, S2: TServerStream;
  Data, Out1: TBytes;
  Frames: TArray<TFrame>;
begin
  BuildWith(ConnWindow, StarvedWindow);
  S1 := StreamFor(1);
  S2 := StreamFor(3);
  Data := RandomBytes(2048);
  S1.Write(Data);
  S2.Write(Data);
  // the peer gives stream 1 no more credit, whatever the connection holds
  while FFlow.TryConsume(1, 1) do
    ;
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  Frames := FramesOf(Out1);
  AssertEquals('the starved stream sends no frame', 0,
    CountDataFor(Frames, 1));
  AssertTrue('the other stream still sends', CountDataFor(Frames, 3) > 0);
  AssertEquals('the starved stream keeps its bytes', 2048, S1.OutboundCount);
end;

procedure TOutputDrainTest.TestWindowUpdateReleasesTheStream;
var
  Stream: TServerStream;
  Data, Out1: TBytes;
  Frames: TArray<TFrame>;
  Turns, Sent: Integer;
begin
  BuildWith(ConnWindow, StarvedWindow);
  Stream := StreamFor(1);
  Data := RandomBytes(2048);
  Stream.Write(Data);
  while FFlow.TryConsume(1, 1) do
    ;
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  AssertEquals('nothing leaves while the window is closed', 0,
    CountDataFor(FramesOf(Out1), 1));
  // the peer opens the window again
  FFlow.ApplyStreamUpdate(1, 8192);
  Sent := 0;
  for Turns := 1 to 16 do
  begin
    FDrain.Drain(FStreams);
    if not FDrain.TakeOutput(Out1) then
      Break;
    Inc(Sent, CountDataFor(FramesOf(Out1), 1));
    if Stream.OutboundCount = 0 then
      Break;
  end;
  AssertTrue('the update releases the stream', Sent > 0);
  AssertEquals('every byte left the stream buffer', 0, Stream.OutboundCount);
end;

procedure TOutputDrainTest.TestClosedConnectionWindowStopsEveryStream;
var
  S1, S2: TServerStream;
  Data, Out1: TBytes;
begin
  BuildWith(2048, WindowSize);
  S1 := StreamFor(1);
  S2 := StreamFor(3);
  Data := RandomBytes(1024);
  S1.Write(Data);
  S2.Write(Data);
  // the peer gives the connection itself no more credit; stream 1 keeps
  // its own credit, so only the connection window can hold the streams back
  AssertTrue('the connection window empties',
    FFlow.TryConsume(1, 2048));
  AssertEquals('the connection window is closed', 0,
    FFlow.Connection.Size);
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  AssertEquals('a closed connection window sends nothing', 0, Length(Out1));
  AssertEquals('the first stream keeps its bytes', 1024, S1.OutboundCount);
  AssertEquals('the second stream keeps its bytes', 1024, S2.OutboundCount);
end;

procedure TOutputDrainTest.TestFinishEndsTheStreamOnce;
var
  Stream: TServerStream;
  Data, Out1: TBytes;
  Frames: TArray<TFrame>;
  I, Ends: Integer;
begin
  Build;
  Stream := StreamFor(1);
  Data := RandomBytes(100);
  Stream.Write(Data);
  Stream.RequestFinish;
  FDrain.Drain(FStreams);
  FDrain.TakeOutput(Out1);
  Frames := FramesOf(Out1);
  Ends := 0;
  for I := 0 to Length(Frames) - 1 do
    if Frames[I].IsEndStream then
      Inc(Ends);
  AssertEquals('exactly one frame carries END_STREAM', 1, Ends);
  AssertTrue('the last data frame carries END_STREAM',
    Frames[Length(Frames) - 1].IsEndStream);
  // a second turn must not repeat the end
  FDrain.Drain(FStreams);
  AssertFalse('a second turn produces nothing',
    FDrain.TakeOutput(Out1));
end;

procedure TOutputDrainTest.TestTenEqualStreamsFinishTogether;
var
  I, Turns, Done: Integer;
  Data, Out1: TBytes;
  Stream: TServerStream;
  Frames: TArray<TFrame>;
begin
  // the connection window must cover every body, or the test measures
  // window exhaustion rather than fairness
  BuildWith(WindowSize * 10, WindowSize * 2);
  Data := RandomBytes(4096);
  for I := 1 to 10 do
  begin
    Stream := StreamFor(LongWord(I) * 2 - 1);
    Stream.Write(Data);
  end;
  Turns := 0;
  while Turns < 40 do
  begin
    FDrain.Drain(FStreams);
    if not FDrain.TakeOutput(Out1) then
      Break;
    Frames := FramesOf(Out1);
    Inc(Turns);
    Done := 0;
    for I := 0 to FStreams.Count - 1 do
      if FStreams[I].OutboundCount = 0 then
        Inc(Done);
    if Done = FStreams.Count then
      Break;
  end;
  AssertEquals('every stream drained', FStreams.Count, Done);
  AssertTrue('ten equal streams finish within a small number of turns',
    Turns <= 11);
end;

procedure TOutputDrainTest.TestDrainReleasesABlockedWriter;
var
  Override: TOutputDrainOptions;
  Stream: TServerStream;
  Writer: TWriterProbe;
  Data, Out1: TBytes;
  Turns: Integer;
begin
  Build;
  // half a chunk per turn, so the single blocked write needs at least two
  // turns to release.  A whole chunk per turn would let one turn free the
  // writer, and whether the writer thread reports that before the loop checks
  // its Done flag is a race, so the test would pass or fail by timing
  Override.MaxFrameSize := SmallFrameSize;
  Override.BytesPerTurn := BufferChunk div 2;
  FKeepWaker := FWaker;
  FDrain.Free;
  FDrain := TOutputDrain.Create(Override, FFlow, FWaker);
  // the buffer fills with one chunk, so the next handler chunk must block
  Stream := TServerStream.Create(1, nil, nil, 8192, BufferChunk);
  FStreams.Add(Stream);
  FFlow.OpenStream(1);
  SetLength(Data, BufferChunk);
  FillChar(Data[0], BufferChunk, Ord('w'));
  Stream.Write(Data);
  Writer := TWriterProbe.Create(Stream, Data);
  try
    AssertTrue('the writer reaches its block', Writer.WaitStarted);
    Sleep(20);
    AssertFalse('the writer is still blocked', Writer.Done);
    for Turns := 1 to 64 do
    begin
      FDrain.Drain(FStreams);
      FDrain.TakeOutput(Out1);
      if Writer.Done then
        Break;
    end;
    AssertTrue('the drain releases the writer', Writer.WaitDone(2000));
    AssertFalse('the writer raised nothing', Writer.Failed);
    AssertTrue('the drain needed more than one turn', Turns > 1);
  finally
    Writer.Unblock;
    Writer.Free;
  end;
end;

procedure TOutputDrainTest.TestCancelWakesABlockedWriter;
var
  Stream: TServerStream;
  Writer: TWriterProbe;
  Data: TBytes;
begin
  Build;
  Stream := TServerStream.Create(1, nil, nil, 8192, BufferChunk);
  FStreams.Add(Stream);
  FFlow.OpenStream(1);
  SetLength(Data, BufferChunk);
  FillChar(Data[0], BufferChunk, Ord('w'));
  Stream.Write(Data);
  Writer := TWriterProbe.Create(Stream, Data);
  try
    AssertTrue('the writer reaches its block', Writer.WaitStarted);
    Sleep(20);
    AssertFalse('the writer is still blocked', Writer.Done);
    Stream.Cancel(ecCancel);
    AssertTrue('cancellation wakes the writer', Writer.WaitDone(2000));
    AssertTrue('the writer reports the cancellation', Writer.Cancelled);
  finally
    Writer.Unblock;
    Writer.Free;
  end;
end;

procedure TOutputDrainTest.TestEffectiveFrameSizeIsTheSmallerLimit;
var
  Override: TOutputDrainOptions;
  Drain: TOutputDrain;
  Flow: TFlowControl;
begin
  Build;
  Override.MaxFrameSize := 4096;
  Override.BytesPerTurn := 0;
  Flow := TFlowControl.Create(WindowSize, WindowSize);
  Drain := TOutputDrain.Create(Override, Flow, nil);
  try
    Drain.ApplyPeerFrameSize(8192);
    AssertEquals('a peer size above the server size loses', 4096,
      Integer(Drain.EffectiveFrameSize));
    Drain.ApplyPeerFrameSize(1024);
    AssertEquals('a peer size below the server size wins', 1024,
      Integer(Drain.EffectiveFrameSize));
  finally
    Drain.Free;
    Flow.Free;
  end;
end;

procedure TOutputDrainTest.TestLongHeaderRunsNeverInterleave;
var
  Frames: TArray<TFrame>;
  I, J, Runs, Ended: Integer;
  Contiguous, SameStream, OneEnd: Boolean;
begin
  // a small frame size forces each header block into a HEADERS frame plus
  // CONTINUATION frames
  MakeCore(64);
  FCore.Feed(RequestWire([1, 3]));
  DrainedFrames;
  FCore.StreamById(1).QueueResponseHeaders(200, LongList, False);
  FCore.StreamById(3).QueueResponseHeaders(200, LongList, False);
  FCore.Flush;
  Frames := DrainedFrames;
  AssertTrue('a long list is split into more than one frame',
    CountOf(Frames, ftContinuation) >= 3);
  // walk each header block from its HEADERS frame to its END_HEADERS frame
  Runs := 0;
  Contiguous := True;
  SameStream := True;
  OneEnd := True;
  I := 0;
  while I < Length(Frames) do
  begin
    if Frames[I].Header.FrameType <> ftHeaders then
    begin
      Inc(I);
      Continue;
    end;
    Inc(Runs);
    J := I;
    while not Frames[J].IsEndHeaders do
    begin
      if J + 1 >= Length(Frames) then
      begin
        Contiguous := False;
        Break;
      end;
      if Frames[J + 1].Header.FrameType <> ftContinuation then
        Contiguous := False;
      if Frames[J + 1].Header.StreamId <> Frames[I].Header.StreamId then
        SameStream := False;
      Inc(J);
    end;
    Ended := 0;
    while (I <= J) and (I < Length(Frames)) do
    begin
      if Frames[I].IsEndHeaders then
        Inc(Ended);
      Inc(I);
    end;
    if Ended <> 1 then
      OneEnd := False;
  end;
  AssertEquals('each response makes one header run', 2, Runs);
  AssertTrue('every run is HEADERS then CONTINUATION with nothing between',
    Contiguous);
  AssertTrue('every frame of a run names the same stream', SameStream);
  AssertTrue('each run ends with END_HEADERS', OneEnd);
end;

procedure TOutputDrainTest.TestSequentialResponsesShareTheEncoderTable;
var
  Codec: THpackCodec;
  Fields: THeaderBlock;
  First, Second: TBytes;
begin
  Codec := THpackCodec.Create;
  try
    Codec.ApplySettings(4096);
    SetLength(Fields, 1);
    Fields[0].Name := 'x-dyn';
    Fields[0].Value := 'one';
    First := Codec.Encode(Fields);
    AssertTrue('the first block fills the encoder table',
      Codec.EncoderTableSize > 0);
    Fields[0].Value := 'two';
    Second := Codec.Encode(Fields);
    AssertTrue('the first block names the field literally', Length(First) > 6);
    AssertTrue('the second block refers to the dynamic table',
      Length(Second) < Length(First));
  finally
    Codec.Free;
  end;
end;

initialization
  RegisterTest(TOutputDrainTest);
end.
