{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, settings, credit, padding, flow control, window update, test
notes:
  - This unit holds the tests of story 25 of the hardening plan. Each test
    shows a defect of the review on the code before the fix.
  - The findings are H2-6 (a later SETTINGS frame resets the other entries),
    H2-4 (padded and dropped DATA are not credited in full), H2-10 (an octet is
    lost at a small connection window), the header block chunk size of the low
    items, the PADDED and PRIORITY pad octet, and H2-1 (an exception from the
    local credit reaches the read loop).
  - The tests drive the core in memory with the peer of Http2Server.H2Peer.
---
}
/// Tests of SETTINGS deltas and credit accounting
unit Http2Server.H2Credit.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.H2Peer;

type
  TH2CreditTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Start(const AOptions: TPeerOptions);
    function SmallThresholds: TPeerOptions;
    function PostWithLength(const AStreamId: LongWord;
      const ALength: Integer): THeaderBlock;
  protected
    procedure TearDown; override;
  published
    procedure TestLaterSettingsKeepsTheOtherEntries;
    procedure TestLaterSettingsDoesNotShrinkTheStreamWindows;
    procedure TestPaddedDataIsCreditedByTheFullFrame;
    procedure TestPaddingCreditReachesTheStreamWindow;
    procedure TestDataOverTheDeclaredLengthIsStillCredited;
    procedure TestDataOverTheInboundLimitIsStillCredited;
    procedure TestSmallConnectionWindowLosesNoOctet;
    procedure TestHeaderBlockChunksFollowThePeerFrameSize;
    procedure TestPaddedPriorityHeadersReadThePadOctet;
    procedure TestLocalCreditNeverRaisesThroughFeed;
    procedure TestPeerWindowOverflowIsAConnectionError;
  end;

implementation

procedure TH2CreditTest.TearDown;
begin
  FreeAndNil(FPeer);
end;

procedure TH2CreditTest.Start(const AOptions: TPeerOptions);
begin
  FPeer := TH2Peer.Create(AOptions);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

function TH2CreditTest.SmallThresholds: TPeerOptions;
begin
  Result := TPeerOptions.Default;
  Result.Core.ConnectionUpdateThreshold := 10;
  Result.Core.StreamUpdateThreshold := 20;
end;

function TH2CreditTest.PostWithLength(const AStreamId: LongWord;
  const ALength: Integer): THeaderBlock;
begin
  Result := RequestFields('POST', '/');
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)].Name := 'content-length';
  Result[High(Result)].Value := IntToStr(ALength);
end;

procedure TH2CreditTest.TestLaterSettingsKeepsTheOtherEntries;
begin
  Start(TPeerOptions.Default);
  FPeer.SendSettings([5, 4], [32768, 100000]);
  FPeer.Pump;
  FPeer.SendSettings([3], [10]);
  FPeer.Pump;
  AssertEquals('MAX_FRAME_SIZE survives a later SETTINGS frame', 32768,
    FPeer.Core.PeerSettings.MaxFrameSize);
  AssertEquals('INITIAL_WINDOW_SIZE survives a later SETTINGS frame', 100000,
    FPeer.Core.PeerSettings.InitialWindowSize);
  AssertEquals('MAX_CONCURRENT_STREAMS takes the new value', 10,
    FPeer.Core.PeerSettings.MaxConcurrentStreams);
end;

procedure TH2CreditTest.TestLaterSettingsDoesNotShrinkTheStreamWindows;
begin
  Start(TPeerOptions.Default);
  FPeer.SendSettings([4], [100000]);
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  AssertEquals('the window of the open stream follows the new initial size',
    100000, FPeer.Core.SendStreamWindowSize(1));
  FPeer.SendSettings([3], [10]);
  FPeer.Pump;
  AssertEquals('a SETTINGS frame without the entry leaves the window alone',
    100000, FPeer.Core.SendStreamWindowSize(1));
end;

procedure TH2CreditTest.TestPaddedDataIsCreditedByTheFullFrame;
begin
  Start(SmallThresholds);
  FPeer.SendPostHead(1);
  // payload: 1 pad length octet, 10 data octets, 20 padding octets = 31
  FPeer.SendPaddedData(1, 10, 20);
  FPeer.Pump;
  AssertEquals('the connection window gets back the whole payload (RFC 9113 6.9.1)',
    31, FPeer.WindowUpdateSum(0));
end;

procedure TH2CreditTest.TestPaddingCreditReachesTheStreamWindow;
begin
  Start(SmallThresholds);
  FPeer.SendPostHead(1);
  FPeer.SendPaddedData(1, 10, 20);
  FPeer.Pump;
  // the handler never reads the 10 data octets, but the padding and the pad
  // length octet are never read by anyone, so they are credited at once
  AssertEquals('the stream window gets back the padding', 21,
    FPeer.WindowUpdateSum(1));
end;

procedure TH2CreditTest.TestDataOverTheDeclaredLengthIsStillCredited;
begin
  Start(SmallThresholds);
  FPeer.SendHeaders(1, PostWithLength(1, 5), False);
  FPeer.SendData(1, 10);
  FPeer.Pump;
  AssertEquals('the stream was reset', 1, FPeer.CountOnStream(ftRstStream, 1));
  AssertEquals('the dropped octets are credited to the connection', 10,
    FPeer.WindowUpdateSum(0));
end;

procedure TH2CreditTest.TestDataOverTheInboundLimitIsStillCredited;
var
  Options: TPeerOptions;
begin
  Options := SmallThresholds;
  Options.Core.InboundBufferLimit := 100;
  Start(Options);
  FPeer.SendPostHead(1);
  FPeer.SendData(1, 200);
  FPeer.Pump;
  AssertEquals('the stream was reset', 1, FPeer.CountOnStream(ftRstStream, 1));
  AssertEquals('the dropped octets are credited to the connection', 200,
    FPeer.WindowUpdateSum(0));
end;

procedure TH2CreditTest.TestSmallConnectionWindowLosesNoOctet;
var
  Total: Int64;
begin
  Start(TPeerOptions.Default);
  FPeer.SendGet(1);
  FPeer.Pump;
  // leave a connection send window of 2 octets
  FPeer.Respond(1, 200, 65533);
  FPeer.Pump;
  FPeer.SendGet(3);
  FPeer.SendGet(5);
  FPeer.SendGet(7);
  FPeer.Pump;
  FPeer.QueueResponse(3, 200, 1, nil);
  FPeer.QueueResponse(5, 200, 1, nil);
  FPeer.QueueResponse(7, 200, 1, nil);
  FPeer.Core.Flush;
  FPeer.Pump;
  Total := FPeer.DataOctets(3) + FPeer.DataOctets(5) + FPeer.DataOctets(7);
  AssertEquals('the window of 2 octets lets 2 octets through', 2, Total);
  FPeer.SendWindowUpdate(0, 100);
  FPeer.Pump;
  Total := FPeer.DataOctets(3) + FPeer.DataOctets(5) + FPeer.DataOctets(7);
  AssertEquals('the third octet is still in the buffer and now leaves', 3, Total);
  AssertEquals('the peer saw no violation', 0, FPeer.Violations.Count);
end;

procedure TH2CreditTest.TestHeaderBlockChunksFollowThePeerFrameSize;
var
  Options: TPeerOptions;
  Fields: THeaderBlock;
  Value: string;
  I, Seed: Integer;
  P: TPeerFrame;
begin
  Options := TPeerOptions.Default;
  Options.Core.MaxFrameSize := 32768;
  Start(Options);
  // a value that Huffman coding cannot shrink below 16384 octets
  SetLength(Value, 50000);
  Seed := 12345;
  for I := 1 to Length(Value) do
  begin
    Seed := (Seed * 1103515245 + 12345) and $7FFFFFFF;
    Value[I] := Chr(33 + (Seed shr 8) mod 90);
  end;
  SetLength(Fields, 1);
  Fields[0].Name := 'x-big';
  Fields[0].Value := Value;
  FPeer.SendGet(1);
  FPeer.Pump;
  FPeer.QueueResponse(1, 200, 0, Fields);
  FPeer.Core.Flush;
  FPeer.Pump;
  for I := 0 to FPeer.Received.Count - 1 do
  begin
    P := FPeer.Received[I];
    if P.Frame.Header.FrameType in [ftHeaders, ftContinuation] then
      AssertTrue('a header frame stays within the 16384 of the peer',
        Length(P.Frame.Payload) <= 16384);
  end;
  AssertEquals('the peer decodes the block', 0, FPeer.Violations.Count);
  AssertEquals('200', FPeer.StatusOf(1));
end;

procedure TH2CreditTest.TestPaddedPriorityHeadersReadThePadOctet;
var
  Payload: TBytes;
  Frame: TFrame;
begin
  // pad length 3, dependency on stream 5, weight 10, a 2 octet block, 3 padding
  Payload := TBytes.Create(3, 0, 0, 0, 5, 10, $82, $84, 0, 0, 0);
  Frame := TFrame.Create(ftHeaders, [ffEndHeaders, ffPadded, ffPriority], 1,
    Payload);
  AssertEquals('the pad length octet comes first', 5,
    HeaderPriorityDependsOn(Frame));
end;

procedure TH2CreditTest.TestLocalCreditNeverRaisesThroughFeed;
begin
  Start(SmallThresholds);
  FPeer.SendPostHead(1);
  FPeer.SendData(1, 5);
  FPeer.Pump;
  // the peer opens its connection window to the maximum between two DATA
  // frames. The receive window is a separate object, so the credit that the
  // server sends next cannot pass 2^31-1
  FPeer.SendWindowUpdate(0, 2147483647 - 65535);
  FPeer.Pump;
  try
    FPeer.SendData(1, 5);
  except
    on E: Exception do
      Fail('the credit raised through Feed: ' + E.ClassName + ': ' + E.Message);
  end;
  FPeer.Pump;
  AssertEquals('the connection stays open', 0, FPeer.CountOf(ftGoAway));
end;

procedure TH2CreditTest.TestPeerWindowOverflowIsAConnectionError;
var
  Code: THttp2ErrorCode;
begin
  Start(TPeerOptions.Default);
  // one octet above 2^31-1 on the connection send window
  try
    FPeer.SendWindowUpdate(0, 2147483647 - 65535 + 1);
  except
    on E: Exception do
      Fail('the overflow raised through Feed: ' + E.ClassName);
  end;
  FPeer.Pump;
  AssertTrue('GOAWAY arrived', FPeer.GoAwayCode(Code));
  AssertTrue('the code is FLOW_CONTROL_ERROR', Code = ecFlowControlError);
end;

initialization
  RegisterTest(TH2CreditTest);
end.
