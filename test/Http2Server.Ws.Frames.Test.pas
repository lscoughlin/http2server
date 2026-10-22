{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, rfc 6455, frames, masking, close codes, utf-8, test, fpcunit
notes:
  - This unit tests the frame encoder, the mask, the close helpers and the
    incremental UTF-8 validator.
  - The frames are checked against the examples of RFC 6455 section 5.7. The
    validator is checked against the validator of mORMot2 on random input.
---
}
/// Unit tests for Http2Server.Ws.Frames and Http2Server.Ws.Utf8
unit Http2Server.Ws.Frames.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  mormot.core.base, mormot.core.unicode,
  Http2Server.Errors, Http2Server.Ws.Frames, Http2Server.Ws.Utf8;

type
  TWsFramesTest = class(TTestCase)
  private
    function Hex(const AData: TBytes): string;
    function Bytes(const AText: RawByteString): TBytes;
    function KeyOf(const A, B, C, D: Byte): TWsMaskKey;
  published
    procedure TestHeaderLengthForms;
    procedure TestHeaderRefusesATopBit;
    procedure TestMaskedHeaderCarriesTheKey;
    procedure TestRfcSection57Vectors;
    procedure TestMaskRoundTripInPieces;
    procedure TestZeroKeyIsLegal;
    procedure TestCloseCodeTable;
    procedure TestSendableCodesExclude1010;
    procedure TestBuildClosePayload;
    procedure TestParseClosePayload;
  end;

  TWsUtf8Test = class(TTestCase)
  published
    procedure TestBoundaryCases;
    procedure TestEverySplitGivesTheSameAnswer;
    procedure TestAgainstAnIndependentReference;
  end;

implementation

function TWsFramesTest.Hex(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AData) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + LowerCase(IntToHex(AData[I], 2));
  end;
end;

function TWsFramesTest.Bytes(const AText: RawByteString): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TWsFramesTest.KeyOf(const A, B, C, D: Byte): TWsMaskKey;
begin
  Result[0] := A;
  Result[1] := B;
  Result[2] := C;
  Result[3] := D;
end;

procedure TWsFramesTest.TestHeaderLengthForms;
var
  K: TWsMaskKey;
begin
  K := KeyOf(0, 0, 0, 0);
  AssertEquals('81 00', Hex(WsEncodeHeader(WsOpText, True, 0, False, K)));
  AssertEquals('81 7d', Hex(WsEncodeHeader(WsOpText, True, 125, False, K)));
  AssertEquals('81 7e 00 7e', Hex(WsEncodeHeader(WsOpText, True, 126, False, K)));
  AssertEquals('82 7e ff ff', Hex(WsEncodeHeader(WsOpBinary, True, 65535, False, K)));
  AssertEquals('82 7f 00 00 00 00 00 01 00 00',
    Hex(WsEncodeHeader(WsOpBinary, True, 65536, False, K)));
  AssertEquals('82 7f 00 00 00 01 00 00 00 00',
    Hex(WsEncodeHeader(WsOpBinary, True, UInt64(1) shl 32, False, K)));
  AssertEquals('01 03', Hex(WsEncodeHeader(WsOpText, False, 3, False, K)));
  AssertEquals('80 02', Hex(WsEncodeHeader(WsOpContinuation, True, 2, False, K)));
end;

procedure TWsFramesTest.TestHeaderRefusesATopBit;
var
  K: TWsMaskKey;
  Raised: Boolean;
begin
  K := KeyOf(0, 0, 0, 0);
  Raised := False;
  try
    WsEncodeHeader(WsOpBinary, True, UInt64(1) shl 63, False, K);
  except
    on EHttpError do
      Raised := True;
  end;
  AssertTrue('a length with the top bit set is refused', Raised);
  AssertEquals('the largest 63-bit length is encoded',
    '82 7f 7f ff ff ff ff ff ff ff',
    Hex(WsEncodeHeader(WsOpBinary, True, UInt64($7FFFFFFFFFFFFFFF), False, K)));
end;

procedure TWsFramesTest.TestMaskedHeaderCarriesTheKey;
begin
  AssertEquals('81 85 37 fa 21 3d',
    Hex(WsEncodeHeader(WsOpText, True, 5, True, KeyOf($37, $FA, $21, $3D))));
  AssertEquals('82 fe 01 00 01 02 03 04',
    Hex(WsEncodeHeader(WsOpBinary, True, 256, True, KeyOf(1, 2, 3, 4))));
end;

procedure TWsFramesTest.TestRfcSection57Vectors;
var
  K: TWsMaskKey;
  Big: TBytes;
  F: TBytes;
begin
  K := KeyOf($37, $FA, $21, $3D);
  AssertEquals('a single-frame unmasked text message',
    '81 05 48 65 6c 6c 6f',
    Hex(WsEncodeFrame(WsOpText, True, Bytes('Hello'), False, K)));
  AssertEquals('a single-frame masked text message',
    '81 85 37 fa 21 3d 7f 9f 4d 51 58',
    Hex(WsEncodeFrame(WsOpText, True, Bytes('Hello'), True, K)));
  AssertEquals('a fragmented unmasked text message, first frame',
    '01 03 48 65 6c', Hex(WsEncodeFrame(WsOpText, False, Bytes('Hel'), False, K)));
  AssertEquals('a fragmented unmasked text message, last frame',
    '80 02 6c 6f',
    Hex(WsEncodeFrame(WsOpContinuation, True, Bytes('lo'), False, K)));
  AssertEquals('an unmasked ping', '89 05 48 65 6c 6c 6f',
    Hex(WsEncodeFrame(WsOpPing, True, Bytes('Hello'), False, K)));
  AssertEquals('a masked pong', '8a 85 37 fa 21 3d 7f 9f 4d 51 58',
    Hex(WsEncodeFrame(WsOpPong, True, Bytes('Hello'), True, K)));
  SetLength(Big, 256);
  F := WsEncodeFrame(WsOpBinary, True, Big, False, K);
  AssertEquals('256 octets: the 16-bit length form', '82 7e 01 00',
    Hex(Copy(F, 0, 4)));
  AssertEquals(260, Length(F));
  SetLength(Big, 65536);
  F := WsEncodeFrame(WsOpBinary, True, Big, False, K);
  AssertEquals('64 KiB: the 64-bit length form',
    '82 7f 00 00 00 00 00 01 00 00', Hex(Copy(F, 0, 10)));
  AssertEquals(65546, Length(F));
end;

procedure TWsFramesTest.TestMaskRoundTripInPieces;
var
  Data, Whole, Pieces: TBytes;
  Key: TWsMaskKey;
  I, At, N, Seed: Integer;
  Reference: TBytes;
begin
  RandSeed := 20260101;
  for Seed := 1 to 200 do
  begin
    N := Random(300);
    SetLength(Data, N);
    for I := 0 to N - 1 do
      Data[I] := Random(256);
    Key := WsMaskKeyFromLongWord(Random($7FFFFFFF) * 2 + Random(2));
    // the reference masks one octet at a time
    Reference := Copy(Data);
    for I := 0 to N - 1 do
      Reference[I] := Reference[I] xor Key[I and 3];
    Whole := Copy(Data);
    if N > 0 then
      WsApplyMask(Key, Whole[0], N, 0);
    AssertEquals('one call agrees with the octet loop', Hex(Reference), Hex(Whole));
    // the same bytes in pieces of random size keep the phase
    Pieces := Copy(Data);
    At := 0;
    while At < N do
    begin
      I := 1 + Random(9);
      if At + I > N then
        I := N - At;
      WsApplyMask(Key, Pieces[At], I, At);
      Inc(At, I);
    end;
    AssertEquals('pieces agree with the whole', Hex(Reference), Hex(Pieces));
    // masking twice restores the data
    if N > 0 then
      WsApplyMask(Key, Whole[0], N, 0);
    AssertEquals('masking twice restores', Hex(Data), Hex(Whole));
  end;
end;

procedure TWsFramesTest.TestZeroKeyIsLegal;
var
  Data: TBytes;
begin
  Data := Bytes('abc');
  WsApplyMask(KeyOf(0, 0, 0, 0), Data[0], 3, 0);
  AssertEquals('a zero key changes nothing', '61 62 63', Hex(Data));
  AssertEquals('a masked frame with the zero key', '81 83 00 00 00 00 61 62 63',
    Hex(WsEncodeFrame(WsOpText, True, Bytes('abc'), True, KeyOf(0, 0, 0, 0))));
end;

procedure TWsFramesTest.TestCloseCodeTable;
var
  C: Integer;
  Expected: Boolean;
begin
  for C := -1 to 5100 do
  begin
    // RFC 6455 section 7.4 and the IANA registry of 2026-10-22
    Expected := ((C >= 1000) and (C <= 1003)) or ((C >= 1007) and (C <= 1014)) or
      ((C >= 3000) and (C <= 4999));
    AssertEquals('code ' + IntToStr(C), Expected, WsCloseCodeValid(C));
  end;
end;

procedure TWsFramesTest.TestSendableCodesExclude1010;
begin
  AssertTrue(WsCloseCodeSendable(1000));
  AssertTrue(WsCloseCodeSendable(1013));
  AssertTrue(WsCloseCodeSendable(4000));
  AssertFalse('1010 is a client code', WsCloseCodeSendable(1010));
  AssertFalse(WsCloseCodeSendable(1005));
  AssertFalse(WsCloseCodeSendable(1006));
  AssertFalse(WsCloseCodeSendable(1015));
  AssertFalse(WsCloseCodeSendable(1004));
  AssertFalse(WsCloseCodeSendable(2000));
  AssertFalse(WsCloseCodeSendable(5000));
end;

procedure TWsFramesTest.TestBuildClosePayload;
var
  Raised: Integer;
  Code: Integer;

  procedure Expect(const ACode: Integer; const AReason: RawByteString);
  begin
    try
      WsBuildClosePayload(ACode, AReason);
    except
      on EHttpError do
        Inc(Raised);
    end;
  end;

begin
  AssertEquals('03 e8', Hex(WsBuildClosePayload(1000, '')));
  AssertEquals('03 e9 62 79 65', Hex(WsBuildClosePayload(1001, 'bye')));
  AssertEquals(125, Length(WsBuildClosePayload(1000, StringOfChar('x', 123))));
  Raised := 0;
  for Code in [1005, 1006, 1015, 1004, 1010, 2000, 5000, 0, 999] do
    Expect(Code, '');
  Expect(1000, StringOfChar('x', 124));
  AssertEquals('every bad code and the long reason are refused', 10, Raised);
end;

procedure TWsFramesTest.TestParseClosePayload;
var
  Code: Integer;
  Reason: RawByteString;
  F: TWsFailure;
begin
  F := WsParseClosePayload(nil, Code, Reason);
  AssertEquals('an empty payload is valid', 0, F.Code);
  AssertEquals('and has code 1005', 1005, Code);
  F := WsParseClosePayload(Bytes(#3), Code, Reason);
  AssertEquals('one octet is a protocol error', 1002, F.Code);
  F := WsParseClosePayload(Bytes(#$03#$ED), Code, Reason);   // 1005
  AssertEquals('1005 is not on the wire', 1002, F.Code);
  F := WsParseClosePayload(Bytes(#$03#$F4), Code, Reason);   // 1012
  AssertEquals('1012 is assigned and valid', 0, F.Code);
  AssertEquals(1012, Code);
  F := WsParseClosePayload(Bytes(#$03#$E8'bye'), Code, Reason);
  AssertEquals(0, F.Code);
  AssertEquals('bye', string(Reason));
  F := WsParseClosePayload(Bytes(#$03#$E8#$FF), Code, Reason);
  AssertEquals('a reason that is not UTF-8', 1007, F.Code);
end;

{ TWsUtf8Test }

procedure TWsUtf8Test.TestBoundaryCases;

  procedure Check(const AText: RawByteString; const AValid: Boolean;
    const AName: string);
  begin
    if AText = '' then
      AssertEquals(AName, AValid, WsUtf8IsValid(PAnsiChar('')^, 0))
    else
      AssertEquals(AName, AValid, WsUtf8IsValid(AText[1], Length(AText)));
  end;

begin
  Check('', True, 'empty');
  Check('abc', True, 'ascii');
  Check(#$7F, True, 'U+007F');
  Check(#$C2#$80, True, 'U+0080');
  Check(#$DF#$BF, True, 'U+07FF');
  Check(#$E0#$A0#$80, True, 'U+0800');
  Check(#$EF#$BF#$BF, True, 'U+FFFF');
  Check(#$F0#$90#$80#$80, True, 'U+10000');
  Check(#$F4#$8F#$BF#$BF, True, 'U+10FFFF');
  Check(#$ED#$9F#$BF, True, 'U+D7FF');
  Check(#$EE#$80#$80, True, 'U+E000');
  Check(#$C0#$80, False, 'overlong NUL');
  Check(#$C1#$BF, False, 'overlong 7F');
  Check(#$E0#$9F#$BF, False, 'overlong U+07FF');
  Check(#$F0#$8F#$BF#$BF, False, 'overlong U+FFFF');
  Check(#$ED#$A0#$80, False, 'surrogate U+D800');
  Check(#$ED#$BF#$BF, False, 'surrogate U+DFFF');
  Check(#$F4#$90#$80#$80, False, 'above U+10FFFF');
  Check(#$F5#$80#$80#$80, False, 'lead byte F5');
  Check(#$80, False, 'a lone continuation byte');
  Check(#$BF, False, 'a lone continuation byte BF');
  Check(#$C2, False, 'a truncated 2-byte sequence');
  Check(#$E2#$82, False, 'a truncated 3-byte sequence');
  Check(#$F0#$9F#$98, False, 'a truncated 4-byte sequence');
  Check(#$C2#$41, False, 'a bad continuation');
  Check(#$FF, False, 'FF');
  Check('é€😀', True, 'a mixed text');
end;

procedure TWsUtf8Test.TestEverySplitGivesTheSameAnswer;
const
  Samples: array[0..4] of RawByteString = (
    'a€b', #$F0#$9F#$98#$80'x', #$E2#$82, #$F0#$9F#$98, 'ok');
var
  I, Cut: Integer;
  S: RawByteString;
  V: TWsUtf8Validator;
  Whole, Split: Boolean;
begin
  for I := Low(Samples) to High(Samples) do
  begin
    S := Samples[I];
    Whole := WsUtf8IsValid(S[1], Length(S));
    for Cut := 0 to Length(S) do
    begin
      V.Reset;
      Split := True;
      if Cut > 0 then
        Split := V.Feed(S[1], Cut);
      if Split and (Cut < Length(S)) then
        Split := V.Feed(S[Cut + 1], Length(S) - Cut);
      Split := Split and V.IsComplete;
      AssertEquals('sample ' + IntToStr(I) + ' cut ' + IntToStr(Cut), Whole, Split);
    end;
  end;
end;

/// an independent reference: the byte ranges of Unicode table 3-7, one case per
/// lead byte, written as a table walk and not as a state machine
function ReferenceIsValidUtf8(const S: RawByteString): Boolean;
var
  I, K, Need: Integer;
  B, Lo, Hi: Byte;
begin
  Result := False;
  I := 1;
  while I <= Length(S) do
  begin
    B := Byte(S[I]);
    Lo := $80;
    Hi := $BF;
    case B of
      $00..$7F: Need := 0;
      $C2..$DF: Need := 1;
      $E0: begin Need := 2; Lo := $A0; end;
      $E1..$EC, $EE..$EF: Need := 2;
      $ED: begin Need := 2; Hi := $9F; end;
      $F0: begin Need := 3; Lo := $90; end;
      $F1..$F3: Need := 3;
      $F4: begin Need := 3; Hi := $8F; end;
    else
      Exit;
    end;
    if I + Need > Length(S) then
      Exit;
    for K := 1 to Need do
    begin
      if (Byte(S[I + K]) < Lo) or (Byte(S[I + K]) > Hi) then
        Exit;
      Lo := $80;
      Hi := $BF;
    end;
    Inc(I, Need + 1);
  end;
  Result := True;
end;

procedure TWsUtf8Test.TestAgainstAnIndependentReference;
var
  Iter, N, I: Integer;
  S: RawByteString;
  Ours, Theirs, Lenient: Boolean;
  Hexed: string;
  Pool: array[0..15] of Byte;
  Differences: Integer;
begin
  // bytes drawn from the interesting ranges: ASCII, continuation, lead bytes
  Pool[0] := $41; Pool[1] := $7F; Pool[2] := $80; Pool[3] := $8F;
  Pool[4] := $90; Pool[5] := $9F; Pool[6] := $A0; Pool[7] := $BF;
  Pool[8] := $C2; Pool[9] := $DF; Pool[10] := $E0; Pool[11] := $ED;
  Pool[12] := $EF; Pool[13] := $F0; Pool[14] := $F4; Pool[15] := $F5;
  RandSeed := 7;
  Differences := 0;
  for Iter := 1 to 100000 do
  begin
    N := Random(8);
    SetLength(S, N);
    for I := 1 to N do
      S[I] := AnsiChar(Pool[Random(16)]);
    if N = 0 then
      Ours := True
    else
      Ours := WsUtf8IsValid(S[1], N);
    Theirs := ReferenceIsValidUtf8(S);
    if Theirs <> Ours then
    begin
      Hexed := '';
      for I := 1 to N do
        Hexed := Hexed + IntToHex(Ord(S[I]), 2) + ' ';
      Fail('the validator differs from the reference on ' + Hexed);
    end;
    // mORMot2 IsValidUtf8 is more lenient than RFC 3629: it accepts an overlong
    // E0 90 9F and an unfinished sequence at the end. It must never be stricter.
    Lenient := IsValidUtf8(S);
    if Ours and not Lenient then
      Inc(Differences);
  end;
  AssertEquals('the strict validator never rejects what mORMot2 rejects', 0,
    Differences);
end;

initialization
  RegisterTest(TWsFramesTest);
  RegisterTest(TWsUtf8Test);

end.
