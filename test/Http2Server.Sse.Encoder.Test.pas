{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: sse, server-sent events, encoder, test, fpcunit
notes:
  - This unit tests the event encoder.
  - The tests assert the exact bytes of the rules E1 to E18 of the WHATWG
    HTML Living Standard section 9.2.
---
}
/// Unit tests for Http2Server.Sse.Encoder
unit Http2Server.Sse.Encoder.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2Server.Sse.Encoder;

type
  TSseEncoderTest = class(TTestCase)
  private
    function Enc(const AEvent: TSseEvent): string;
    function Ev(const AData: string; const AId: string = '';
      const AEvent: string = ''; const ARetry: Integer = 0): TSseEvent;
    procedure ExpectError(const AEvent: TSseEvent; const AName: string);
  published
    procedure TestOneDataLine;
    procedure TestMultiLineDataSplitsAtLfCrAndCrlf;
    procedure TestDataEndingWithABreakWritesAFinalEmptyField;
    procedure TestEmptyDataWritesOneEmptyField;
    procedure TestFieldsAndTheirOrder;
    procedure TestALeadingSpaceKeepsItsFirstSpace;
    procedure TestEmptyIdIsLegal;
    procedure TestInjectionIsRejected;
    procedure TestNulIsRejected;
    procedure TestInvalidUtf8IsRejected;
    procedure TestRetryRules;
    procedure TestMultiByteTextPassesThrough;
    procedure TestCommentEncoding;
    procedure TestLastEventIdCleaning;
    procedure TestNoBomAndAlwaysABlankLine;
  end;

implementation

function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

{ TSseEncoderTest }

function TSseEncoderTest.Enc(const AEvent: TSseEvent): string;
begin
  Result := TextOf(SseEncodeEvent(AEvent));
end;

function TSseEncoderTest.Ev(const AData, AId, AEvent: string;
  const ARetry: Integer): TSseEvent;
begin
  Result := TSseEvent.Text(UTF8String(AData));
  Result.Id := UTF8String(AId);
  Result.Event := UTF8String(AEvent);
  Result.Retry := ARetry;
end;

procedure TSseEncoderTest.ExpectError(const AEvent: TSseEvent;
  const AName: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    SseEncodeEvent(AEvent);
  except
    on ESseError do
      Raised := True;
  end;
  AssertTrue(AName + ' is rejected', Raised);
end;

procedure TSseEncoderTest.TestOneDataLine;
begin
  AssertEquals('data: hello'#10#10, Enc(Ev('hello')));
end;

procedure TSseEncoderTest.TestMultiLineDataSplitsAtLfCrAndCrlf;
begin
  AssertEquals('LF', 'data: a'#10'data: b'#10#10, Enc(Ev('a'#10'b')));
  AssertEquals('CR', 'data: a'#10'data: b'#10#10, Enc(Ev('a'#13'b')));
  AssertEquals('CRLF is one break', 'data: a'#10'data: b'#10#10,
    Enc(Ev('a'#13#10'b')));
  AssertEquals('CR LF CR is two breaks', 'data: a'#10'data:'#10'data: b'#10#10,
    Enc(Ev('a'#13#10#13'b')));
  AssertEquals('an empty line inside the data', 'data: a'#10'data:'#10'data: b'#10#10,
    Enc(Ev('a'#10#10'b')));
end;

procedure TSseEncoderTest.TestDataEndingWithABreakWritesAFinalEmptyField;
begin
  AssertEquals('data: a'#10'data:'#10#10, Enc(Ev('a'#10)));
  AssertEquals('data: a'#10'data:'#10#10, Enc(Ev('a'#13#10)));
end;

procedure TSseEncoderTest.TestEmptyDataWritesOneEmptyField;
var
  E: TSseEvent;
begin
  AssertEquals('data:'#10#10, Enc(Ev('')));
  Finalize(E);
  FillChar(E, SizeOf(E), 0);
  AssertEquals('a default event writes one empty data field', 'data:'#10#10, Enc(E));
end;

procedure TSseEncoderTest.TestFieldsAndTheirOrder;
begin
  AssertEquals('retry: 3000'#10'id: 7'#10'event: tick'#10'data: x'#10#10,
    Enc(Ev('x', '7', 'tick', 3000)));
end;

procedure TSseEncoderTest.TestALeadingSpaceKeepsItsFirstSpace;
begin
  // the client removes one space after the colon, so two spaces keep one
  AssertEquals('data:  x'#10#10, Enc(Ev(' x')));
  AssertEquals('id:  7'#10'data: x'#10#10, Enc(Ev('x', ' 7')));
end;

procedure TSseEncoderTest.TestEmptyIdIsLegal;
begin
  // the data is empty here, and an empty id field is not written: Id is empty
  AssertEquals('data: x'#10#10, Enc(Ev('x', '')));
end;

procedure TSseEncoderTest.TestInjectionIsRejected;
begin
  ExpectError(Ev('x', 'a'#10'data: injected'), 'LF in id');
  ExpectError(Ev('x', 'a'#13'b'), 'CR in id');
  ExpectError(Ev('x', '', 'a'#10#10'data: injected'), 'LF in event');
  ExpectError(Ev('x', '', 'a'#13'b'), 'CR in event');
end;

procedure TSseEncoderTest.TestNulIsRejected;
begin
  ExpectError(Ev('x', 'a'#0'b'), 'NUL in id');
  ExpectError(Ev('a'#0'b'), 'NUL in data');
end;

procedure TSseEncoderTest.TestInvalidUtf8IsRejected;
begin
  ExpectError(Ev('a'#$FF), 'data');
  ExpectError(Ev('x', 'a'#$C0#$80), 'id');
  ExpectError(Ev('x', '', #$ED#$A0#$80), 'event');
end;

procedure TSseEncoderTest.TestRetryRules;
begin
  AssertEquals('retry: 1'#10'data: x'#10#10, Enc(Ev('x', '', '', 1)));
  AssertEquals('retry: 86400000'#10'data: x'#10#10,
    Enc(Ev('x', '', '', cSseMaxRetryMs)));
  ExpectError(Ev('x', '', '', -1), 'a negative retry');
  ExpectError(Ev('x', '', '', cSseMaxRetryMs + 1), 'a retry over the cap');
end;

procedure TSseEncoderTest.TestMultiByteTextPassesThrough;
begin
  AssertEquals('data: é€😀'#10#10, Enc(Ev('é€😀')));
  AssertEquals('U+2028 is not a break', 'data: a'#$E2#$80#$A8'b'#10#10,
    Enc(Ev('a'#$E2#$80#$A8'b')));
end;

procedure TSseEncoderTest.TestCommentEncoding;
var
  Raised: Boolean;
begin
  AssertEquals(': keep-alive'#10#10, TextOf(SseEncodeComment('keep-alive')));
  AssertEquals(': '#10#10, TextOf(SseEncodeComment('')));
  Raised := False;
  try
    SseEncodeComment('a'#10'data: x');
  except
    on ESseError do
      Raised := True;
  end;
  AssertTrue('a break in a comment is rejected', Raised);
end;

procedure TSseEncoderTest.TestLastEventIdCleaning;
begin
  AssertEquals('42', string(SseCleanLastEventId('42')));
  AssertEquals('', string(SseCleanLastEventId('')));
  AssertEquals('a break makes it absent', '', string(SseCleanLastEventId('a'#10'b')));
  AssertEquals('a NUL makes it absent', '', string(SseCleanLastEventId('a'#0'b')));
  AssertEquals('bad UTF-8 makes it absent', '', string(SseCleanLastEventId(#$FF)));
  AssertEquals('é', string(SseCleanLastEventId('é')));
end;

procedure TSseEncoderTest.TestNoBomAndAlwaysABlankLine;
var
  S: string;
begin
  S := Enc(Ev('x'));
  AssertTrue('no BOM', Copy(S, 1, 3) <> #$EF#$BB#$BF);
  AssertEquals('every event ends with a blank line', #10#10,
    Copy(S, Length(S) - 1, 2));
  S := Enc(Ev('a'#10#10#10));
  AssertEquals(#10#10, Copy(S, Length(S) - 1, 2));
end;

initialization
  RegisterTest(TSseEncoderTest);
end.
