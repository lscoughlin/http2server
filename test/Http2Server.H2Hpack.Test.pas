{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, hpack, dynamic table, settings header table size, test
notes:
  - This unit holds the tests of story 26 of the hardening plan. They test the
    finding H2-2, that the SETTINGS_HEADER_TABLE_SIZE of the peer changed the
    local decoder and that the encoder never told the peer about its table size.
  - The peer decodes with a table that the test caps, so a table that is too
    large for the peer shows as an undecodable block.
---
}
/// Tests of the two HPACK table directions
unit Http2Server.H2Hpack.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.H2Peer;

type
  TH2HpackTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Start(const AOptions: TPeerOptions);
    procedure Exchange(const AStreamId: LongWord; const ADate: string);
    function FirstBlock(const AStreamId: LongWord): TBytes;
    function LeadingUpdates(const ABlock: TBytes): TArray<LongWord>;
  protected
    procedure TearDown; override;
  published
    procedure TestHugePeerTableSizeDoesNotGrowTheDecoder;
    procedure TestSmallPeerTableSizeDoesNotShrinkTheDecoder;
    procedure TestChangingDateHeaderDecodesAgainstAPeerOf4096;
    procedure TestNoUpdateWhenNothingChanged;
    procedure TestLoweredPeerSizeStartsTheNextBlockWithAnUpdate;
    procedure TestTwoChangesSignalTheSmallestAndTheFinalSize;
    procedure TestEncoderNeverPassesTheLocalCap;
  end;

implementation

procedure TH2HpackTest.TearDown;
begin
  FreeAndNil(FPeer);
end;

procedure TH2HpackTest.Start(const AOptions: TPeerOptions);
begin
  FPeer := TH2Peer.Create(AOptions);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

/// one request and one response with a changing date and a stable type
procedure TH2HpackTest.Exchange(const AStreamId: LongWord; const ADate: string);
var
  Fields: THeaderBlock;
begin
  SetLength(Fields, 2);
  Fields[0].Name := 'date';
  Fields[0].Value := ADate;
  Fields[1].Name := 'content-type';
  Fields[1].Value := 'text/plain; charset=utf-8';
  FPeer.SendGet(AStreamId);
  FPeer.Pump;
  FPeer.QueueResponse(AStreamId, 200, 0, Fields);
  FPeer.Core.Flush;
  FPeer.Pump;
end;

function TH2HpackTest.FirstBlock(const AStreamId: LongWord): TBytes;
var
  I: Integer;
begin
  for I := 0 to FPeer.Received.Count - 1 do
    if (FPeer.Received[I].Frame.Header.FrameType = ftHeaders) and
       (FPeer.Received[I].Frame.Header.StreamId = AStreamId) then
      Exit(ExtractHeaderBlock(FPeer.Received[I].Frame));
  Result := nil;
end;

/// the dynamic table size updates at the start of a block (RFC 7541 section 6.3)
function TH2HpackTest.LeadingUpdates(const ABlock: TBytes): TArray<LongWord>;
var
  Pos: Integer;
  Value: LongWord;
  Shift: Integer;
  B: Byte;
begin
  Result := nil;
  Pos := 0;
  while (Pos < Length(ABlock)) and ((ABlock[Pos] and $E0) = $20) do
  begin
    Value := ABlock[Pos] and $1F;
    Inc(Pos);
    if Value = $1F then
    begin
      Shift := 0;
      repeat
        B := ABlock[Pos];
        Inc(Pos);
        Value := Value + LongWord(B and $7F) shl Shift;
        Inc(Shift, 7);
      until (B and $80) = 0;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Value;
  end;
end;

procedure TH2HpackTest.TestHugePeerTableSizeDoesNotGrowTheDecoder;
begin
  Start(TPeerOptions.Default);
  FPeer.SendSettings([1], [4294967295]);
  FPeer.Pump;
  AssertEquals('the decoder follows the local setting only', 4096,
    FPeer.Core.HpackDecoderMaxSize);
end;

procedure TH2HpackTest.TestSmallPeerTableSizeDoesNotShrinkTheDecoder;
begin
  Start(TPeerOptions.Default);
  FPeer.SendSettings([1], [100]);
  FPeer.Pump;
  AssertEquals('the decoder follows the local setting only', 4096,
    FPeer.Core.HpackDecoderMaxSize);
end;

procedure TH2HpackTest.TestChangingDateHeaderDecodesAgainstAPeerOf4096;
var
  Options: TPeerOptions;
  I: Integer;
begin
  Options := TPeerOptions.Default;
  // the local table is larger than the table of the peer decoder
  Options.Core.MaxHeaderTableSize := 65536;
  Start(Options);
  for I := 0 to 199 do
    Exchange(1 + 2 * I, Format('Mon, 26 Oct 2026 00:%.2d:%.2d GMT',
      [I div 60, I mod 60]));
  AssertEquals('the peer decodes all 200 blocks', 0, FPeer.Violations.Count);
  AssertEquals(200, FPeer.CountOf(ftHeaders));
end;

procedure TH2HpackTest.TestNoUpdateWhenNothingChanged;
begin
  Start(TPeerOptions.Default);
  Exchange(1, 'Mon, 26 Oct 2026 00:00:00 GMT');
  AssertEquals('no size update without a change', 0,
    Length(LeadingUpdates(FirstBlock(1))));
end;

procedure TH2HpackTest.TestLoweredPeerSizeStartsTheNextBlockWithAnUpdate;
var
  Updates: TArray<LongWord>;
begin
  Start(TPeerOptions.Default);
  Exchange(1, 'Mon, 26 Oct 2026 00:00:00 GMT');
  FPeer.SendSettings([1], [256]);
  FPeer.Pump;
  Exchange(3, 'Mon, 26 Oct 2026 00:00:01 GMT');
  Updates := LeadingUpdates(FirstBlock(3));
  AssertEquals('one size update opens the block', 1, Length(Updates));
  AssertTrue('the update is not larger than the new size', Updates[0] <= 256);
  AssertEquals('the peer decodes the block', 0, FPeer.Violations.Count);
  AssertEquals('the encoder uses the new size', 256, FPeer.Core.HpackEncoderMaxSize);
end;

procedure TH2HpackTest.TestTwoChangesSignalTheSmallestAndTheFinalSize;
var
  Updates: TArray<LongWord>;
begin
  Start(TPeerOptions.Default);
  Exchange(1, 'Mon, 26 Oct 2026 00:00:00 GMT');
  FPeer.SendSettings([1], [100]);
  FPeer.SendSettings([1], [3000]);
  FPeer.Pump;
  Exchange(3, 'Mon, 26 Oct 2026 00:00:01 GMT');
  Updates := LeadingUpdates(FirstBlock(3));
  AssertEquals('two updates open the block', 2, Length(Updates));
  AssertEquals('the smallest size comes first (RFC 7541 section 4.2)', 100,
    Updates[0]);
  AssertEquals('the final size comes second', 3000, Updates[1]);
  AssertEquals('the peer decodes the block', 0, FPeer.Violations.Count);
end;

procedure TH2HpackTest.TestEncoderNeverPassesTheLocalCap;
var
  Options: TPeerOptions;
begin
  Options := TPeerOptions.Default;
  Options.Core.MaxHeaderTableSize := 1000;
  Start(Options);
  FPeer.SendSettings([1], [65536]);
  FPeer.Pump;
  AssertEquals('the encoder stays at the local cap', 1000,
    FPeer.Core.HpackEncoderMaxSize);
end;

initialization
  RegisterTest(TH2HpackTest);
end.
