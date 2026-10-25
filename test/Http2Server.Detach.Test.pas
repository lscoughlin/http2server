{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, detach, channel, sink, credit, registry, test, fpcunit
notes:
  - This unit tests detached streams on a real connection core. Each test plays
    the handler. It takes the stream from the core, wraps it in the response
    adapter and calls Detach.
  - The tests read the frames that the core produces, so they check the wire
    order (HEADERS before DATA), the END_STREAM flag, the WINDOW_UPDATE credit
    and the RST_STREAM of an abort.
  - No test uses a thread or a sleep.
---
}
/// Unit tests for detached streams (Http2Server.Duplex and StreamChannel)
unit Http2Server.Detach.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Limits, Http2Server.Connection, Http2Server.Seam,
  Http2Server.Stream, Http2Server.Duplex, Http2Server.StreamAdapters;

type
  /// a sink that records what the channel delivers
  TRecordingSink = class(TInterfacedObject, IChannelSink)
  public
    Received: TBytes;
    Calls: Integer;
    Closed: Integer;
    LastClean: Boolean;
    Drained: Integer;
    Log: string;
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;
  end;

  /// an event receiver that does nothing
  TQuietEvents = class(TInterfacedObject, IConnectionEvents)
  public
    procedure RequestReady(const AStream: TServerStream);
    procedure StreamReset(const AStream: TServerStream);
    procedure ConnectionClosing;
    procedure LimitTripped(const AKind: TLimitKind);
  end;

  /// the response adapter and the stream that the test plays the handler for
  TServerResponseHolder = record
    Response: IServerResponse;
    Stream: TServerStream;
  end;

  TDetachTest = class(TTestCase)
  private
    FCore: TServerConnectionCore;
    FCoreRef: IInterface;
    FClock: TManualMonotonicClock;
    FClockRef: IMonotonicClock;
    FLimits: TConnectionLimits;
    FRegistry: IChannelRegistry;
    FSink: TRecordingSink;
    FSinkRef: IChannelSink;
    function Options(const AOutboundLimit: Integer): TConnectionCoreOptions;
    procedure MakeCore(const AOutboundLimit: Integer = 65536;
      const ARegistryLimit: Integer = 8);
    function Pack(const AFrames: array of TFrame; const APreface: Boolean = False): TBytes;
    function Block(const ANames, AValues: array of string): TBytes;
    function Request(const AStreamId: LongWord; const AEndStream: Boolean): TFrame;
    function Data(const AStreamId: LongWord; const ACount: Integer;
      const AEndStream: Boolean = False): TFrame;
    function Frames: TArray<TFrame>;
    function CountOf(const AFrames: TArray<TFrame>; const AType: TFrameType): Integer;
    function IndexOf(const AFrames: TArray<TFrame>; const AType: TFrameType): Integer;
    function Open(const AStreamId: LongWord; const AEndStream: Boolean): TServerResponseHolder;
    function Hdrs: THeaderBlock;
    function Bytes(const AText: string): TBytes;
    function DataText(const AFrames: TArray<TFrame>): string;
    function StatusOf(const AFrame: TFrame): string;
    procedure Start;
  protected
    procedure TearDown; override;
  published
    procedure TestDetachAfterHeadersKeepsTheStreamOpen;
    procedure TestSendThenGracefulCloseEndsTheStream;
    procedure TestPendingChannelHoldsSendsUntilActivate;
    procedure TestCompleteAnswersWithAnOrdinaryResponse;
    procedure TestCompleteWithoutABodyEndsTheHeaders;
    procedure TestSinkReceivesInboundDataInOrder;
    procedure TestCreditIsReturnedOnlyByReturnCredit;
    procedure TestEarlyBytesWaitForTheSink;
    procedure TestPeerEndStreamIsACleanClose;
    procedure TestPeerResetNotifiesTheSinkAndClosesTheChannel;
    procedure TestConnectionErrorNotifiesTheSink;
    procedure TestConnectionLossNotifiesTheSink;
    procedure TestSendReportsFullThenDrained;
    procedure TestAbortSendsRstStreamCancel;
    procedure TestRegistryLimitRefusesTheNextDetach;
    procedure TestSlotIsFreedWhenTheChannelEnds;
    procedure TestCloseAllClosesEveryChannel;
    procedure TestDetachedResponseRefusesOtherCalls;
    procedure TestSendAfterCloseIsRefused;
    procedure TestChannelOutlivesItsCore;
    procedure TestPeerResetWhilePendingEndsTheChannel;
    procedure TestConnectionServesOnAfterComplete;
  end;

implementation

const
  cMaxFrame = 16384;

{ TRecordingSink }

procedure TRecordingSink.BytesReceived(const AData; const ACount: Integer);
var
  N: Integer;
begin
  N := Length(Received);
  SetLength(Received, N + ACount);
  Move(AData, Received[N], ACount);
  Inc(Calls);
  Log := Log + 'B';
end;

procedure TRecordingSink.PeerClosed(const AClean: Boolean);
begin
  Inc(Closed);
  LastClean := AClean;
  if AClean then
    Log := Log + 'E'
  else
    Log := Log + 'R';
end;

procedure TRecordingSink.WriteDrained;
begin
  Inc(Drained);
  Log := Log + 'D';
end;

{ TQuietEvents }

procedure TQuietEvents.RequestReady(const AStream: TServerStream);
begin
end;

procedure TQuietEvents.StreamReset(const AStream: TServerStream);
begin
end;

procedure TQuietEvents.ConnectionClosing;
begin
end;

procedure TQuietEvents.LimitTripped(const AKind: TLimitKind);
begin
end;

{ TDetachTest }

function TDetachTest.Options(const AOutboundLimit: Integer): TConnectionCoreOptions;
begin
  Result.ConnectionWindow := 1048576;
  Result.InitialStreamWindow := 65535;
  Result.MaxConcurrentStreams := 16;
  Result.MaxFrameSize := cMaxFrame;
  Result.MaxHeaderListSize := 16384;
  Result.MaxHeaderTableSize := 4096;
  Result.MaxContinuations := 4;
  Result.MaxHeaderBlockBytes := 262144;
  Result.InboundBufferLimit := 65536;
  Result.OutboundBufferLimit := AOutboundLimit;
  Result.ConnectionUpdateThreshold := 32768;
  Result.StreamUpdateThreshold := 1000;
  Result.ConnectProtocol := False;
  Result.MaxOutputBytes := 0;
end;

procedure TDetachTest.MakeCore(const AOutboundLimit, ARegistryLimit: Integer);
var
  R, C: TTokenBucketOptions;
  Core: TServerConnectionCore;
begin
  FClock := TManualMonotonicClock.Create;
  FClockRef := FClock;
  R := TTokenBucketOptions.Create.WithCapacity(100000).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(2);
  C := TTokenBucketOptions.Create.WithCapacity(100000).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(1);
  FLimits := TConnectionLimits.Create(FClockRef, R, C);
  Core := TServerConnectionCore.Create(Options(AOutboundLimit),
    TQuietEvents.Create, FLimits, FClockRef);
  FCoreRef := Core;
  FCore := Core;
  FRegistry := TChannelRegistry.Create(ARegistryLimit);
  FSink := TRecordingSink.Create;
  FSinkRef := FSink;
end;

procedure TDetachTest.Start;
begin
  FCore.Feed(Pack([], True));
  Frames;   // drop the server SETTINGS and the acknowledgement
end;

procedure TDetachTest.TearDown;
begin
  FSinkRef := nil;
  FRegistry := nil;
  FCore := nil;
  FCoreRef := nil;
  if FLimits <> nil then
    FLimits.Free;
  FLimits := nil;
  FClockRef := nil;
end;

function TDetachTest.Pack(const AFrames: array of TFrame;
  const APreface: Boolean): TBytes;
var
  I, At, N: Integer;
  Body, Head: TBytes;
begin
  Body := nil;
  At := 0;
  for I := 0 to Length(AFrames) - 1 do
  begin
    SetLength(Head, FrameHeaderSize);
    AFrames[I].Header.WriteTo(Head);
    N := At + FrameHeaderSize + Length(AFrames[I].Payload);
    SetLength(Body, N);
    Move(Head[0], Body[At], FrameHeaderSize);
    Inc(At, FrameHeaderSize);
    if Length(AFrames[I].Payload) > 0 then
    begin
      Move(AFrames[I].Payload[0], Body[At], Length(AFrames[I].Payload));
      Inc(At, Length(AFrames[I].Payload));
    end;
  end;
  if not APreface then
    Exit(Body);
  SetLength(Result, ClientPrefaceSize + Length(Body));
  Move(ClientPreface[0], Result[0], ClientPrefaceSize);
  if Length(Body) > 0 then
    Move(Body[0], Result[ClientPrefaceSize], Length(Body));
end;

function TDetachTest.Block(const ANames, AValues: array of string): TBytes;
var
  Codec: THpackCodec;
  B: THeaderBlock;
  I: Integer;
begin
  Codec := THpackCodec.Create;
  try
    SetLength(B, Length(ANames));
    for I := 0 to Length(ANames) - 1 do
    begin
      B[I].Name := ANames[I];
      B[I].Value := AValues[I];
    end;
    Result := Codec.Encode(B);
  finally
    Codec.Free;
  end;
end;

function TDetachTest.Request(const AStreamId: LongWord;
  const AEndStream: Boolean): TFrame;
var
  Flags: TFrameFlags;
begin
  Flags := [ffEndHeaders];
  if AEndStream then
    Include(Flags, ffEndStream);
  Result := TFrame.Create(ftHeaders, Flags, AStreamId,
    Block([':method', ':scheme', ':path', ':authority'],
      ['GET', 'https', '/events', 'example.com']));
end;

function TDetachTest.Data(const AStreamId: LongWord; const ACount: Integer;
  const AEndStream: Boolean): TFrame;
var
  Payload: TBytes;
  Flags: TFrameFlags;
begin
  Flags := [];
  if AEndStream then
    Flags := [ffEndStream];
  SetLength(Payload, ACount);
  if ACount > 0 then
    FillChar(Payload[0], ACount, Ord('d'));
  Result := TFrame.Create(ftData, Flags, AStreamId, Payload);
end;

function TDetachTest.Frames: TArray<TFrame>;
var
  Buf: TBytes;
  Offset, N: Integer;
  HeadBytes: TBytes;
  H: TFrameHeader;
  F: TFrame;
begin
  Result := nil;
  FCore.Flush;
  FCore.TakeOutput(Buf);
  Offset := 0;
  while Offset + FrameHeaderSize <= Length(Buf) do
  begin
    SetLength(HeadBytes, FrameHeaderSize);
    Move(Buf[Offset], HeadBytes[0], FrameHeaderSize);
    H := TFrameHeader.ReadFrom(HeadBytes);
    N := FrameHeaderSize + Integer(H.Length);
    if Offset + N > Length(Buf) then
      Break;
    SetLength(F.Payload, H.Length);
    if H.Length > 0 then
      Move(Buf[Offset + FrameHeaderSize], F.Payload[0], H.Length);
    F.Header := H;
    SetLength(Result, Length(Result) + 1);
    Result[Length(Result) - 1] := F;
    Inc(Offset, N);
  end;
end;

function TDetachTest.CountOf(const AFrames: TArray<TFrame>;
  const AType: TFrameType): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AFrames) do
    if AFrames[I].Header.FrameType = AType then
      Inc(Result);
end;

function TDetachTest.IndexOf(const AFrames: TArray<TFrame>;
  const AType: TFrameType): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AFrames) do
    if AFrames[I].Header.FrameType = AType then
      Exit(I);
  Result := -1;
end;

function TDetachTest.Hdrs: THeaderBlock;
begin
  SetLength(Result, 1);
  Result[0].Name := 'content-type';
  Result[0].Value := 'text/event-stream';
end;

function TDetachTest.Bytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TDetachTest.DataText(const AFrames: TArray<TFrame>): string;
var
  I: Integer;
  S: string;
begin
  Result := '';
  for I := 0 to High(AFrames) do
    if (AFrames[I].Header.FrameType = ftData) and
       (Length(AFrames[I].Payload) > 0) then
    begin
      SetLength(S, Length(AFrames[I].Payload));
      Move(AFrames[I].Payload[0], S[1], Length(AFrames[I].Payload));
      Result := Result + S;
    end;
end;

function TDetachTest.StatusOf(const AFrame: TFrame): string;
var
  Codec: THpackCodec;
  H: THeaderBlock;
  I: Integer;
begin
  Result := '';
  Codec := THpackCodec.Create;
  try
    H := Codec.Decode(ExtractHeaderBlock(AFrame));
    for I := 0 to High(H) do
      if H[I].Name = ':status' then
        Exit(H[I].Value);
  finally
    Codec.Free;
  end;
end;

function TDetachTest.Open(const AStreamId: LongWord;
  const AEndStream: Boolean): TServerResponseHolder;
begin
  FCore.Feed(Pack([Request(AStreamId, AEndStream)]));
  Result.Stream := FCore.StreamById(AStreamId);
  AssertTrue('the stream exists', Result.Stream <> nil);
  Result.Response := TServerStreamResponse.Create(Result.Stream, FRegistry);
end;

procedure TDetachTest.TestDetachAfterHeadersKeepsTheStreamOpen;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  AssertTrue('the channel is active', Ch.State = csActive);
  AssertTrue(Ch.IsOpen);
  F := Frames;
  AssertEquals('the headers left', 1, CountOf(F, ftHeaders));
  AssertEquals('200', StatusOf(F[IndexOf(F, ftHeaders)]));
  AssertFalse('the headers carry no END_STREAM',
    F[IndexOf(F, ftHeaders)].IsEndStream);
  AssertEquals('the stream stays open after the handler returned', 1,
    FCore.OpenStreams);
end;

procedure TDetachTest.TestSendThenGracefulCloseEndsTheStream;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
  I: Integer;
  Ended: Boolean;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Frames;
  AssertTrue(Ch.Send(Bytes('data: one'#10#10)) = srQueued);
  AssertTrue(Ch.Send(Bytes('data: two'#10#10)) = srQueued);
  F := Frames;
  AssertEquals('the events reach the wire in order',
    'data: one'#10#10'data: two'#10#10, DataText(F));
  AssertEquals('still open', 1, FCore.OpenStreams);
  Ch.Close(ccGraceful);
  F := Frames;
  Ended := False;
  for I := 0 to High(F) do
    if (F[I].Header.FrameType = ftData) and F[I].IsEndStream then
      Ended := True;
  AssertTrue('END_STREAM follows the close', Ended);
  AssertEquals('the stream is gone', 0, FCore.OpenStreams);
  AssertFalse(Ch.IsOpen);
end;

procedure TDetachTest.TestPendingChannelHoldsSendsUntilActivate;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  Ch := H.Response.Detach;
  AssertTrue('no headers were sent, so the channel is pending',
    Ch.State = csPending);
  AssertTrue(Ch.Send(Bytes('hello')) = srQueued);
  AssertEquals('the held bytes count as queued', 5, Integer(Ch.QueuedBytes));
  F := Frames;
  AssertEquals('no HEADERS before Activate', 0, CountOf(F, ftHeaders));
  AssertEquals('no DATA before Activate', 0, CountOf(F, ftData));
  Ch.Activate(200, Hdrs);
  AssertTrue(Ch.State = csActive);
  F := Frames;
  AssertTrue('HEADERS leave before DATA',
    IndexOf(F, ftHeaders) < IndexOf(F, ftData));
  AssertEquals('hello', DataText(F));
end;

procedure TDetachTest.TestCompleteAnswersWithAnOrdinaryResponse;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
  Hd: THeaderBlock;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  Ch := H.Response.Detach;
  SetLength(Hd, 1);
  Hd[0].Name := 'www-authenticate';
  Hd[0].Value := 'Bearer';
  Ch.Complete(401, Hd, Bytes('denied'));
  F := Frames;
  AssertEquals('401', StatusOf(F[IndexOf(F, ftHeaders)]));
  AssertFalse('the headers do not end the stream, a body follows',
    F[IndexOf(F, ftHeaders)].IsEndStream);
  AssertEquals('denied', DataText(F));
  AssertTrue(F[High(F)].IsEndStream);
  AssertFalse(Ch.IsOpen);
  AssertEquals('the connection serves on, the stream is gone', 0,
    FCore.OpenStreams);
  AssertEquals('the slot is free again', 0, FRegistry.Count);
end;

procedure TDetachTest.TestCompleteWithoutABodyEndsTheHeaders;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  Ch := H.Response.Detach;
  Ch.Complete(403, nil, nil);
  F := Frames;
  AssertEquals('403', StatusOf(F[IndexOf(F, ftHeaders)]));
  // the core ends a response that has no body with an empty DATA frame
  AssertTrue('the last frame ends the stream',
    (F[High(F)].Header.FrameType = ftData) and F[High(F)].IsEndStream);
  AssertEquals('no body bytes', '', DataText(F));
  AssertEquals(0, FCore.OpenStreams);
end;

procedure TDetachTest.TestSinkReceivesInboundDataInOrder;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  FCore.Feed(Pack([Data(1, 100), Data(1, 50)]));
  AssertEquals('both frames reached the sink', 150, Length(FSink.Received));
  AssertEquals('BB', FSink.Log);
  AssertEquals('the stream keeps no inbound buffer', 0, H.Stream.InboundCount);
end;

procedure TDetachTest.TestCreditIsReturnedOnlyByReturnCredit;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
  I: Integer;
  Credit: Integer;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  FCore.Feed(Pack([Data(1, 4000)]));
  Frames;
  F := Frames;
  Credit := 0;
  for I := 0 to High(F) do
    if (F[I].Header.FrameType = ftWindowUpdate) and (F[I].Header.StreamId = 1) then
      Inc(Credit);
  AssertEquals('delivery alone returns no stream credit', 0, Credit);
  Ch.ReturnCredit(4000);
  F := Frames;
  for I := 0 to High(F) do
    if (F[I].Header.FrameType = ftWindowUpdate) and (F[I].Header.StreamId = 1) then
      Inc(Credit);
  AssertEquals('ReturnCredit sends one WINDOW_UPDATE for the stream', 1, Credit);
end;

procedure TDetachTest.TestEarlyBytesWaitForTheSink;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  FCore.Feed(Pack([Data(1, 30)]));
  AssertEquals('no sink yet, nothing delivered', 0, Length(FSink.Received));
  Ch.SetSink(FSinkRef);
  AssertEquals('the early bytes arrive at SetSink', 30, Length(FSink.Received));
  FCore.Feed(Pack([Data(1, 20)]));
  AssertEquals('later bytes follow directly', 50, Length(FSink.Received));
  AssertEquals('BB', FSink.Log);
end;

procedure TDetachTest.TestPeerEndStreamIsACleanClose;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  FCore.Feed(Pack([Data(1, 10, True)]));
  AssertEquals('B then E', 'BE', FSink.Log);
  AssertTrue(FSink.LastClean);
  AssertTrue('the local half is still open', Ch.IsOpen);
  Ch.Close(ccGraceful);
  Frames;
  AssertEquals('both halves ended, the stream is gone', 0, FCore.OpenStreams);
  AssertEquals('the slot is free again', 0, FRegistry.Count);
end;

procedure TDetachTest.TestPeerResetNotifiesTheSinkAndClosesTheChannel;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  Rst: TBytes;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  SetLength(Rst, 4);
  Rst[3] := Ord(ecCancel);
  FCore.Feed(Pack([TFrame.Create(ftRstStream, [], 1, Rst)]));
  AssertEquals('the sink hears the end once', 1, FSink.Closed);
  AssertFalse('a reset is not clean', FSink.LastClean);
  AssertFalse(Ch.IsOpen);
  AssertTrue(Ch.Send(Bytes('x')) = srClosed);
  AssertEquals('the slot is free again', 0, FRegistry.Count);
end;

procedure TDetachTest.TestConnectionErrorNotifiesTheSink;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  // DATA on an idle stream is a connection error and ends every open stream
  FCore.Feed(Pack([Data(99, 5)]));
  AssertEquals('the sink hears the end', 1, FSink.Closed);
  AssertFalse(FSink.LastClean);
  AssertFalse(Ch.IsOpen);
end;

procedure TDetachTest.TestConnectionLossNotifiesTheSink;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  FCore.ConnectionLost;
  AssertEquals('the sink hears the loss once', 1, FSink.Closed);
  AssertFalse(FSink.LastClean);
  AssertFalse(Ch.IsOpen);
  FCore.ConnectionLost;   // a second call changes nothing
  AssertEquals('still once', 1, FSink.Closed);
  AssertEquals('the slot is free again', 0, FRegistry.Count);
end;

procedure TDetachTest.TestSendReportsFullThenDrained;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  Big: TBytes;
  First, Second: TSendResult;
begin
  MakeCore(1000);
  Start;
  H := Open(1, True);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  Frames;
  SetLength(Big, 800);
  First := Ch.Send(Big);
  Second := Ch.Send(Big);
  AssertTrue('the first write fits', First = srQueued);
  AssertTrue('the second write passes the limit', Second = srFull);
  AssertEquals('nothing drained yet', 0, FSink.Drained);
  Frames;   // the IO side drains the buffer into DATA frames
  AssertEquals('the sink hears that the queue drained', 1, FSink.Drained);
  AssertTrue('the producer can write again', Ch.Send(Big) = srQueued);
end;

procedure TDetachTest.TestAbortSendsRstStreamCancel;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
  I: Integer;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  Frames;
  Ch.Close(ccAbort);
  F := Frames;
  AssertEquals('one RST_STREAM', 1, CountOf(F, ftRstStream));
  I := IndexOf(F, ftRstStream);
  AssertEquals('the code is CANCEL', Ord(ecCancel), Integer(F[I].Payload[3]));
  AssertEquals('the sink heard the end', 1, FSink.Closed);
  AssertFalse(Ch.IsOpen);
end;

procedure TDetachTest.TestRegistryLimitRefusesTheNextDetach;
var
  A, B: TServerResponseHolder;
  ChA: IDuplexChannel;
  Refused: Boolean;
begin
  MakeCore(65536, 1);
  Start;
  A := Open(1, True);
  A.Response.SendHeaders(200, Hdrs);
  ChA := A.Response.Detach;
  B := Open(3, True);
  B.Response.SendHeaders(200, Hdrs);
  Refused := False;
  try
    B.Response.Detach;
  except
    on EDetachRefused do
      Refused := True;
  end;
  AssertTrue('the second detach is refused at the limit', Refused);
  AssertEquals(1, FRegistry.Count);
  ChA.Close(ccAbort);
  AssertEquals('the slot is free', 0, FRegistry.Count);
  AssertTrue('the next detach succeeds', B.Response.Detach <> nil);
end;

procedure TDetachTest.TestSlotIsFreedWhenTheChannelEnds;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  AssertEquals(1, FRegistry.Count);
  Ch.Close(ccGraceful);
  AssertEquals('the slot is free after the end', 0, FRegistry.Count);
end;

procedure TDetachTest.TestCloseAllClosesEveryChannel;
var
  A, B: TServerResponseHolder;
  ChA, ChB: IDuplexChannel;
begin
  MakeCore;
  Start;
  A := Open(1, True);
  A.Response.SendHeaders(200, Hdrs);
  ChA := A.Response.Detach;
  B := Open(3, True);
  B.Response.SendHeaders(200, Hdrs);
  ChB := B.Response.Detach;
  FRegistry.CloseAll(ccGraceful);
  AssertFalse(ChA.IsOpen);
  AssertFalse(ChB.IsOpen);
  Frames;
  AssertEquals('both streams ended', 0, FCore.OpenStreams);
end;

procedure TDetachTest.TestDetachedResponseRefusesOtherCalls;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  Raised: Integer;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Raised := 0;
  try H.Response.Write(Bytes('x')); except on EHttpError do Inc(Raised); end;
  try H.Response.Finish; except on EHttpError do Inc(Raised); end;
  try H.Response.SendHeaders(200, Hdrs); except on EHttpError do Inc(Raised); end;
  try H.Response.Detach; except on EHttpError do Inc(Raised); end;
  AssertEquals('every call after Detach raises', 4, Raised);
  AssertTrue(Ch.IsOpen);
end;

procedure TDetachTest.TestSendAfterCloseIsRefused;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.Close(ccGraceful);
  AssertTrue(Ch.Send(Bytes('late')) = srClosed);
  AssertTrue(Ch.State = csClosed);
end;

procedure TDetachTest.TestChannelOutlivesItsCore;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  H.Response.SendHeaders(200, Hdrs);
  Ch := H.Response.Detach;
  Ch.SetSink(FSinkRef);
  // the connection ends and its core is freed while the owner holds the channel
  FCore := nil;
  FCoreRef := nil;
  AssertEquals('the sink heard the loss', 1, FSink.Closed);
  AssertFalse(FSink.LastClean);
  // every call below meets the lock, the host and the stream of a dead core
  Ch.ReturnCredit(1000);
  AssertTrue(Ch.Send(Bytes('late')) = srClosed);
  AssertEquals(0, Integer(Ch.QueuedBytes));
  AssertFalse(Ch.IsOpen);
  AssertTrue(Ch.State = csClosed);
  Ch.Close(ccGraceful);
  Ch.Close(ccAbort);
  Ch.ReturnCredit(1);
  Ch := nil;
end;

procedure TDetachTest.TestPeerResetWhilePendingEndsTheChannel;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  Rst: TBytes;
  Raised: Boolean;
begin
  MakeCore;
  Start;
  H := Open(1, False);
  Ch := H.Response.Detach;
  AssertTrue(Ch.State = csPending);
  Ch.SetSink(FSinkRef);
  SetLength(Rst, 4);
  Rst[3] := Ord(ecCancel);
  FCore.Feed(Pack([TFrame.Create(ftRstStream, [], 1, Rst)]));
  AssertEquals('the sink hears the reset', 1, FSink.Closed);
  AssertTrue(Ch.State = csClosed);
  AssertTrue(Ch.Send(Bytes('x')) = srClosed);
  // the pending phase is over, so Activate and Complete are refused
  Raised := False;
  try Ch.Activate(200, Hdrs); except on EHttpError do Raised := True; end;
  AssertTrue('Activate on an ended channel raises', Raised);
  Raised := False;
  try Ch.Complete(401, nil, nil); except on EHttpError do Raised := True; end;
  AssertTrue('Complete on an ended channel raises', Raised);
  AssertEquals('the slot is free again', 0, FRegistry.Count);
end;

procedure TDetachTest.TestConnectionServesOnAfterComplete;
var
  H: TServerResponseHolder;
  Ch: IDuplexChannel;
  F: TArray<TFrame>;
begin
  MakeCore;
  Start;
  H := Open(1, True);
  Ch := H.Response.Detach;
  Ch.Complete(403, nil, Bytes('no'));
  Frames;
  // the connection is intact: a new request on it is accepted and answered
  FCore.Feed(Pack([Request(3, True)]));
  AssertTrue('the next stream exists', FCore.StreamById(3) <> nil);
  F := Frames;
  AssertEquals('no GOAWAY and no RST_STREAM', 0,
    CountOf(F, ftGoAway) + CountOf(F, ftRstStream));
  FCore.StreamById(3).QueueResponseHeaders(200, nil, True);
  F := Frames;
  AssertEquals('200', StatusOf(F[IndexOf(F, ftHeaders)]));
end;

initialization
  RegisterTest(TDetachTest);

end.
