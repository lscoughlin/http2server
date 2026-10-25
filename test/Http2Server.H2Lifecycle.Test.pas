{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, stream lifecycle, refusal, trailers, goaway, reset, test
notes:
  - This unit holds the tests of story 27 of the hardening plan. The findings
    are H2-3 (an early exit skips the header block), H2-4 (frames that race a
    reset close the connection), H2-5 (a trailer block dispatches the handler a
    second time), H2-9 (a peer GOAWAY cancels the open streams) and four low
    items.
  - The tests drive the core in memory with the peer of Http2Server.H2Peer.
---
}
/// Tests of the stream lifecycle rules of the connection core
unit Http2Server.H2Lifecycle.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Stream, Http2Server.ResponseWriter, Http2Server.H2Peer;

type
  TH2LifecycleTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Start(const AOptions: TPeerOptions);
    function OneStreamOptions: TPeerOptions;
    function WithKeep(const AMethod: string): THeaderBlock;
    function ResetCodeOf(const AStreamId: LongWord): string;
  protected
    procedure TearDown; override;
  published
    procedure TestRefusedStreamStillDecodesItsHeaderBlock;
    procedure TestRefusedStreamAdvancesTheStreamIdOrder;
    procedure TestSelfDependencyDoesNotLeakStreamSlots;
    procedure TestDataOfARefusedStreamLeavesTheOthersOpen;
    procedure TestLateFramesOfAResetStreamAreIgnored;
    procedure TestTrailersDispatchTheHandlerOnce;
    procedure TestTrailersDoNotReplaceTheRequestHead;
    procedure TestTrailerEndRespectsTheDeclaredLength;
    procedure TestPeerGoAwayLetsOpenStreamsFinish;
    procedure TestNewStreamAfterServerGoAwayIsRefused;
    procedure TestEmptyDataOnStreamZeroIsAConnectionError;
    procedure TestResetSetIsBounded;
    procedure TestH2ResponseNamesAreLowercased;
    procedure TestH2ResponseRefusesConnectionSpecificFields;
  end;

implementation

procedure TH2LifecycleTest.TearDown;
begin
  FreeAndNil(FPeer);
end;

procedure TH2LifecycleTest.Start(const AOptions: TPeerOptions);
begin
  FPeer := TH2Peer.Create(AOptions);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

function TH2LifecycleTest.OneStreamOptions: TPeerOptions;
begin
  Result := TPeerOptions.Default;
  Result.Core.MaxConcurrentStreams := 1;
end;

/// a request that makes the peer encoder insert into its dynamic table
function TH2LifecycleTest.WithKeep(const AMethod: string): THeaderBlock;
begin
  Result := RequestFields(AMethod, '/');
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)].Name := 'x-keep';
  Result[High(Result)].Value := 'a value that goes into the dynamic table';
end;

function TH2LifecycleTest.ResetCodeOf(const AStreamId: LongWord): string;
var
  Code: THttp2ErrorCode;
begin
  if FPeer.ResetCode(AStreamId, Code) then
    Result := Http2ErrorCodeName(Code)
  else
    Result := '(none)';
end;

procedure TH2LifecycleTest.TestRefusedStreamStillDecodesItsHeaderBlock;
var
  Code: THttp2ErrorCode;
begin
  Start(OneStreamOptions);
  FPeer.SendPostHead(1);
  // stream 3 is above the limit, but its block inserts into the table
  FPeer.SendHeaders(3, WithKeep('GET'), True);
  FPeer.Pump;
  AssertEquals('stream 3 was refused', 'REFUSED_STREAM', ResetCodeOf(3));
  FPeer.SendRst(1, ecCancel);
  FPeer.SendHeaders(5, WithKeep('GET'), True);
  FPeer.Pump;
  if FPeer.GoAwayCode(Code) then
    Fail('the dynamic table fell out of step: ' + Http2ErrorCodeName(Code));
  AssertTrue('stream 5 reached the handler', FPeer.Events.ReadyIds.Contains(5));
end;

procedure TH2LifecycleTest.TestRefusedStreamAdvancesTheStreamIdOrder;
var
  Code: THttp2ErrorCode;
begin
  Start(OneStreamOptions);
  FPeer.SendPostHead(1);
  FPeer.SendGet(3);
  FPeer.Pump;
  AssertEquals('stream 3 was refused', 'REFUSED_STREAM', ResetCodeOf(3));
  FPeer.SendRst(1, ecCancel);
  // RFC 9113 section 5.1.1: an id that does not increase is a connection error
  FPeer.SendGet(3);
  FPeer.Pump;
  AssertTrue('stream 3 cannot be opened again', FPeer.GoAwayCode(Code));
  AssertTrue(Code = ecProtocolError);
end;

procedure TH2LifecycleTest.TestSelfDependencyDoesNotLeakStreamSlots;
var
  Options: TPeerOptions;
  I: Integer;
  Fields: THeaderBlock;
  Block, Payload: TBytes;
  Id: LongWord;
  Refused: Integer;
begin
  Options := TPeerOptions.Default;
  Options.Core.MaxConcurrentStreams := 10;
  Start(Options);
  Fields := RequestFields('GET', '/');
  Refused := 0;
  for I := 0 to 19 do
  begin
    Id := 1 + 2 * LongWord(I);
    Block := FPeer.Encoder.Encode(Fields);
    // HEADERS with the PRIORITY flag: the stream depends on itself
    SetLength(Payload, 5 + Length(Block));
    Payload[0] := (Id shr 24) and $7F;
    Payload[1] := (Id shr 16) and $FF;
    Payload[2] := (Id shr 8) and $FF;
    Payload[3] := Id and $FF;
    Payload[4] := 15;
    Move(Block[0], Payload[5], Length(Block));
    FPeer.Send(TFrame.Create(ftHeaders,
      [ffEndHeaders, ffEndStream, ffPriority], Id, Payload));
  end;
  FPeer.Pump;
  for I := 0 to 19 do
    if ResetCodeOf(1 + 2 * LongWord(I)) = 'REFUSED_STREAM' then
      Inc(Refused);
  AssertEquals('no stream was refused for a full table', 0, Refused);
  AssertEquals('no stream stays open', 0, FPeer.Core.OpenStreams);
end;

procedure TH2LifecycleTest.TestDataOfARefusedStreamLeavesTheOthersOpen;
var
  Options: TPeerOptions;
begin
  Options := OneStreamOptions;
  Options.Core.ConnectionUpdateThreshold := 10;
  Start(Options);
  FPeer.SendPostHead(1);
  FPeer.SendPostHead(3);
  FPeer.SendData(3, 100);
  FPeer.Pump;
  AssertEquals('stream 3 was refused', 'REFUSED_STREAM', ResetCodeOf(3));
  AssertEquals('no connection error', 0, FPeer.CountOf(ftGoAway));
  AssertEquals('stream 1 stays open', 1, FPeer.Core.OpenStreams);
  AssertEquals('the octets still count in the connection window', 100,
    FPeer.WindowUpdateSum(0));
end;

procedure TH2LifecycleTest.TestLateFramesOfAResetStreamAreIgnored;
var
  Fields: THeaderBlock;
begin
  Start(TPeerOptions.Default);
  // a body longer than the declared length makes the server reset stream 1
  Fields := RequestFields('POST', '/');
  SetLength(Fields, Length(Fields) + 1);
  Fields[High(Fields)].Name := 'content-length';
  Fields[High(Fields)].Value := '5';
  FPeer.SendHeaders(1, Fields, False);
  FPeer.SendData(1, 10);
  FPeer.Pump;
  AssertEquals('the server reset stream 1', 'PROTOCOL_ERROR', ResetCodeOf(1));
  // these frames were in flight before the peer saw the reset
  FPeer.SendData(1, 20);
  FPeer.SendWindowUpdate(1, 10);
  FPeer.SendRst(1, ecCancel);
  FPeer.SendGet(3);
  FPeer.Pump;
  AssertEquals('no connection error', 0, FPeer.CountOf(ftGoAway));
  AssertTrue('the next stream reaches the handler',
    FPeer.Events.ReadyIds.Contains(3));
end;

procedure TH2LifecycleTest.TestTrailersDispatchTheHandlerOnce;
var
  T: THeaderBlock;
begin
  Start(TPeerOptions.Default);
  FPeer.SendPostHead(1);
  FPeer.SendData(1, 10);
  SetLength(T, 1);
  T[0].Name := 'x-trailer';
  T[0].Value := 'v';
  FPeer.SendTrailers(1, T);
  FPeer.Pump;
  AssertEquals('the request head is dispatched once', 1, FPeer.Events.Requests);
end;

procedure TH2LifecycleTest.TestTrailersDoNotReplaceTheRequestHead;
var
  T, Head: THeaderBlock;
  Stream: TServerStream;
begin
  Start(TPeerOptions.Default);
  FPeer.SendPostHead(1);
  SetLength(T, 1);
  T[0].Name := 'x-trailer';
  T[0].Value := 'v';
  FPeer.SendTrailers(1, T);
  FPeer.Pump;
  Stream := FPeer.Core.StreamById(1);
  AssertTrue('the stream is still open to the handler', Stream <> nil);
  Head := Stream.RemoteHeaders;
  AssertEquals(':method', Head[0].Name);
  AssertEquals('the trailer is kept apart', 1, Length(Stream.Trailers));
  AssertEquals('x-trailer', Stream.Trailers[0].Name);
end;

procedure TH2LifecycleTest.TestTrailerEndRespectsTheDeclaredLength;
var
  Fields, T: THeaderBlock;
begin
  Start(TPeerOptions.Default);
  Fields := RequestFields('POST', '/');
  SetLength(Fields, Length(Fields) + 1);
  Fields[High(Fields)].Name := 'content-length';
  Fields[High(Fields)].Value := '10';
  FPeer.SendHeaders(1, Fields, False);
  FPeer.SendData(1, 4);
  SetLength(T, 1);
  T[0].Name := 'x-trailer';
  T[0].Value := 'v';
  FPeer.SendTrailers(1, T);
  FPeer.Pump;
  AssertEquals('a body shorter than the declared length resets the stream',
    'PROTOCOL_ERROR', ResetCodeOf(1));
end;

procedure TH2LifecycleTest.TestPeerGoAwayLetsOpenStreamsFinish;
begin
  Start(TPeerOptions.Default);
  FPeer.SendGet(1);
  FPeer.Pump;
  FPeer.SendGoAway(0);
  FPeer.Pump;
  AssertEquals('no stream was cancelled', 0, FPeer.Events.Resets);
  AssertTrue('stream 1 is still open', FPeer.Core.StreamById(1) <> nil);
  FPeer.Respond(1, 200, 100);
  FPeer.Pump;
  AssertEquals('the response reached the peer', 100, FPeer.DataOctets(1));
  AssertEquals('200', FPeer.StatusOf(1));
end;

procedure TH2LifecycleTest.TestNewStreamAfterServerGoAwayIsRefused;
begin
  Start(TPeerOptions.Default);
  FPeer.Core.GracefulGoAway(0, ecNoError);
  FPeer.SendGet(1);
  FPeer.Pump;
  AssertEquals('the new stream is refused', 'REFUSED_STREAM', ResetCodeOf(1));
  AssertEquals('the handler never saw it', 0, FPeer.Events.Requests);
end;

procedure TH2LifecycleTest.TestEmptyDataOnStreamZeroIsAConnectionError;
var
  Code: THttp2ErrorCode;
begin
  Start(TPeerOptions.Default);
  FPeer.Send(BuildDataFrame(0, nil, False));
  FPeer.Pump;
  AssertTrue('GOAWAY arrived', FPeer.GoAwayCode(Code));
  AssertTrue(Code = ecProtocolError);
end;

procedure TH2LifecycleTest.TestResetSetIsBounded;
var
  Options: TPeerOptions;
  I: Integer;
begin
  Options := TPeerOptions.Default;
  Options.Core.MaxConcurrentStreams := 1;
  Start(Options);
  FPeer.SendPostHead(1);
  // many refused streams: the set of reset ids keeps a bounded memory
  for I := 1 to 1000 do
    FPeer.SendGet(1 + 2 * LongWord(I));
  FPeer.Pump;
  AssertTrue('the reset set stays bounded', FPeer.Core.ResetSetCount <= 256);
  AssertEquals('no connection error', 0, FPeer.CountOf(ftGoAway));
end;

procedure TH2LifecycleTest.TestH2ResponseNamesAreLowercased;
var
  H, R: THeaderBlock;
begin
  SetLength(H, 1);
  H[0].Name := 'Content-Type';
  H[0].Value := 'text/plain';
  R := PrepareH2ResponseHeaders(H);
  AssertEquals('content-type', R[0].Name);
  AssertEquals('text/plain', R[0].Value);
end;

procedure TH2LifecycleTest.TestH2ResponseRefusesConnectionSpecificFields;
const
  Names: array[0..4] of string = ('Connection', 'keep-alive',
    'Transfer-Encoding', 'Upgrade', 'Proxy-Connection');
var
  H: THeaderBlock;
  I: Integer;
  Raised: Boolean;
begin
  SetLength(H, 1);
  H[0].Value := 'x';
  for I := 0 to High(Names) do
  begin
    H[0].Name := Names[I];
    Raised := False;
    try
      PrepareH2ResponseHeaders(H);
    except
      on E: EHttpError do
        Raised := True;
    end;
    AssertTrue(Names[I] + ' is refused on HTTP/2 (RFC 9113 section 8.2.2)', Raised);
  end;
end;

initialization
  RegisterTest(TH2LifecycleTest);
end.
