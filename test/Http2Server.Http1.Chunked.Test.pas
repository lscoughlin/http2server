{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, hostile input, chunked, trailer, chunk extension, parser gaps, test, fpcunit
notes:
  - This unit holds the hostile-input cases 53 to 66 of the HTTP/1.1 parser, the
    chunked body and its trailer.
  - The probe tests feed the parser of mORMot2 alone and record what it accepts.
    They show the gaps that the guard closes. If a new version of mORMot2 closes
    a gap, the probe fails, and the rule in the guard stays as a second line.
---
}
/// Hostile-input tests of the chunked body, and the probe of the parser alone
unit Http2Server.Http1.Chunked.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  mormot.core.base, mormot.net.http,
  Http2Server.Http1.Limits, Http2Server.Http1.Guard, Http2Server.Http1.TestKit;

type
  THttp1ChunkedTest = class(TTestCase)
  private
    FLimits: THttp11Limits;
    procedure Reject(const AName, AInput: string; const AStatuses: array of Integer);
    function Probe(const AInput: string; out ALeft: Integer): THttpRequestState;
  protected
    procedure SetUp; override;
  published
    procedure TestChunkSizeGrammar;
    procedure TestChunkSizeOverflow;
    procedure TestChunkDataFraming;
    procedure TestChunkExtensions;
    procedure TestTrailerSection;
    procedure TestIncompleteChunkedBodies;
    procedure TestPipelinedRequestAfterAChunkedBody;
    procedure TestChunkedBodyIsDeliveredWithoutFraming;
    procedure TestProbeContentLengthListIsAcceptedByTheParserAlone;
    procedure TestProbeTransferEncodingWithoutSpaceIsNotChunkedForTheParserAlone;
    procedure TestProbeGarbageChunkSizeEndsTheBodyForTheParserAlone;
    procedure TestProbeTrailerFieldIsTakenAsTheLastLineByTheParserAlone;
  end;

implementation

const
  CRLF = #13#10;
  Second = 'GET /second HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF;
  Head = 'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF;

procedure THttp1ChunkedTest.SetUp;
begin
  FLimits := THttp11Limits.Create;
end;

procedure THttp1ChunkedTest.Reject(const AName, AInput: string;
  const AStatuses: array of Integer);
var
  T: string;
  I: Integer;
  Hit: Boolean;
begin
  T := H1RunAll(AInput + Second, FLimits);
  Hit := False;
  for I := 0 to High(AStatuses) do
    if H1Rejected(T, AStatuses[I]) then
      Hit := True;
  AssertTrue(AName + ': rejected; got: ' + T, Hit);
  AssertEquals(AName + ': the second request is not processed', 0, Pos('/second', T));
  AssertEquals(AName + ': the request does not complete', 0, Pos('E' + #10, T));
end;

procedure THttp1ChunkedTest.TestChunkSizeGrammar;
var
  V: string;
begin
  // case 53
  for V in ['0x5', '+5', '-5', ' 5', '', 'g', '5g', '5 5'] do
    Reject('case 53 size "' + V + '"', Head + V + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, [400]);
end;

procedure THttp1ChunkedTest.TestChunkSizeOverflow;
begin
  // case 54: no wrap to a small value
  Reject('case 54', Head + 'FFFFFFFFFFFFFFFFF' + CRLF + 'x' + CRLF, [400, 413]);
  Reject('a size over the chunk limit', Head + '2000000' + CRLF, [413]);
  Reject('a size of 2^63', Head + '8000000000000000' + CRLF, [400, 413]);
end;

procedure THttp1ChunkedTest.TestChunkDataFraming;
begin
  // case 55: size 5, six octets of data
  Reject('case 55', Head + '5' + CRLF + 'hellox' + CRLF + '0' + CRLF + CRLF, [400]);
  // case 56
  Reject('case 56', Head + '5' + CRLF + 'helloXX' + CRLF + '0' + CRLF + CRLF, [400]);
  // case 57: a bare LF after the data
  Reject('case 57', Head + '5' + CRLF + 'hello'#10'0' + CRLF + CRLF, [400]);
end;

procedure THttp1ChunkedTest.TestChunkExtensions;
var
  T, V: string;
begin
  // case 59
  Reject('case 59', Head + '5;' + StringOfChar('a', 100000) + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, [400]);
  // case 60
  T := H1RunAll(Head + '5;foo=bar' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, FLimits);
  AssertTrue('case 60: ' + T, Pos('B hello', T) > 0);
  // case 61
  for V in ['5;', '5;;', '5;a=', '5;a="b', '5;a=b;'] do
    Reject('case 61 "' + V + '"', Head + V + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, [400]);
  T := H1RunAll(Head + '5 ;a=b' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, FLimits);
  AssertTrue('case 61: BWS before the semicolon is valid: ' + T, Pos('B hello', T) > 0);
  T := H1RunAll(Head + '5;a="b c";d=e' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, FLimits);
  AssertTrue('a quoted extension value: ' + T, Pos('B hello', T) > 0);
end;

procedure THttp1ChunkedTest.TestTrailerSection;
var
  T: string;
  I: Integer;
  Many: string;
begin
  // case 62
  Reject('case 62 one large field', Head + '0' + CRLF + 'X-A: ' + StringOfChar('a', 100000) + CRLF + CRLF, [431]);
  Many := '';
  for I := 1 to 2000 do
    Many := Many + 'X-' + IntToStr(I) + ': v' + CRLF;
  Reject('case 62 many fields', Head + '0' + CRLF + Many + CRLF, [431]);
  // case 63: the trailer is discarded and never merged
  T := H1RunAll(Head + '5' + CRLF + 'hello' + CRLF + '0' + CRLF + 'Content-Length: 99' + CRLF +
    'Transfer-Encoding: gzip' + CRLF + 'Host: other' + CRLF + CRLF + Second, FLimits);
  AssertTrue('case 63 the body ends: ' + T, Pos('B hello', T) > 0);
  AssertTrue('case 63 the next request follows', Pos('H GET /second auth=a', T) > 0);
  AssertEquals('case 63 the head has no trailer field', 0, Pos('other', T));
  // case 64
  Reject('case 64 space before the colon', Head + '0' + CRLF + 'X-A : b' + CRLF + CRLF, [400]);
  Reject('case 64 obs-fold', Head + '0' + CRLF + 'X-A: b' + CRLF + ' c' + CRLF + CRLF, [400]);
  // an empty trailer section
  T := H1RunAll(Head + '0' + CRLF + CRLF, FLimits);
  AssertTrue(T, Pos('E' + #10, T) > 0);
end;

procedure THttp1ChunkedTest.TestIncompleteChunkedBodies;
var
  T: string;
begin
  // case 58: the connection ends in the middle of a chunk
  T := H1RunAll(Head + '5' + CRLF + 'hel', FLimits);
  AssertTrue(T, Pos('partial hel', T) > 0);
  AssertEquals(0, Pos('E' + #10, T));
  // before the last chunk
  T := H1RunAll(Head + '5' + CRLF + 'hello' + CRLF, FLimits);
  AssertEquals(0, Pos('E' + #10, T));
  // case 65: the last chunk with no final CRLF
  T := H1RunAll(Head + '0' + CRLF, FLimits);
  AssertEquals('case 65', 0, Pos('E' + #10, T));
  T := H1RunAll(Head + '0' + CRLF + 'X-A: b' + CRLF, FLimits);
  AssertEquals('a trailer with no blank line', 0, Pos('E' + #10, T));
end;

procedure THttp1ChunkedTest.TestPipelinedRequestAfterAChunkedBody;
var
  T: string;
begin
  // case 66
  T := H1RunAll(Head + '3' + CRLF + 'abc' + CRLF + '2' + CRLF + 'de' + CRLF + '0' + CRLF + CRLF + Second,
    FLimits);
  AssertTrue(T, Pos('B abcde', T) > 0);
  AssertTrue('the next request is processed in order', Pos('H GET /second', T) > Pos('B abcde', T));
end;

procedure THttp1ChunkedTest.TestChunkedBodyIsDeliveredWithoutFraming;
var
  T: string;
begin
  T := H1RunAll(Head + 'A' + CRLF + '0123456789' + CRLF + '0' + CRLF + CRLF, FLimits);
  AssertTrue(T, Pos('B 0123456789', T) > 0);
  AssertTrue('the chunked body over the limit is refused', H1Rejected(
    H1RunAll(Head + '5' + CRLF + 'hello' + CRLF + '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF,
      FLimits.WithMaxBodySize(8)), 413));
end;

/// feed AInput to the parser of mORMot2 alone and answer its state
function THttp1ChunkedTest.Probe(const AInput: string; out ALeft: Integer): THttpRequestState;
var
  Ctx: THttpRequestContext;
  St: TProcessParseLine;
  Buf: RawByteString;
begin
  FillChar(Ctx, SizeOf(Ctx), 0);
  Buf := AInput;
  UniqueString(Buf);
  Ctx.Reset;
  Ctx.State := hrsGetCommand;
  Ctx.Options := [hroHeadersUnfiltered];
  Ctx.ContentMaxSize := 1000000;
  St.P := PUtf8Char(Buf);
  St.Len := Length(Buf);
  St.Line := nil;
  St.LineLen := 0;
  // the call returns at the start of a body, so it runs again until it rests
  while (St.Len > 0) and (Ctx.State < hrsWaitProcessing) do
    if not Ctx.ProcessRead(St, {returnOnStateChange=}False) then
      Break;
  ALeft := St.Len;
  Result := Ctx.State;
  AssertTrue(Ctx.HeaderFlags = Ctx.HeaderFlags);
end;

procedure THttp1ChunkedTest.TestProbeContentLengthListIsAcceptedByTheParserAlone;
var
  Left: Integer;
begin
  // the parser alone reads 5 from the list "5, 6" and takes the body as 5 octets
  AssertTrue(Probe('POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5, 6' + CRLF + CRLF +
    'hello', Left) = hrsWaitProcessing);
  AssertEquals('it consumed the 5 octets', 0, Left);
end;

procedure THttp1ChunkedTest.TestProbeTransferEncodingWithoutSpaceIsNotChunkedForTheParserAlone;
var
  Left: Integer;
  State: THttpRequestState;
begin
  // "Transfer-Encoding:chunked" is chunked for a front end that skips the space
  // and is no body for the parser alone: the chunk data would be a new request
  State := Probe('POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding:chunked' + CRLF + CRLF +
    '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF, Left);
  AssertTrue('the parser alone sees no body', State = hrsWaitProcessing);
  AssertTrue('and leaves the chunk octets unread', Left > 0);
end;

procedure THttp1ChunkedTest.TestProbeGarbageChunkSizeEndsTheBodyForTheParserAlone;
var
  Left: Integer;
  State: THttpRequestState;
begin
  State := Probe('POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
    'zz' + CRLF + 'GET /smuggled HTTP/1.1' + CRLF + CRLF, Left);
  // the parser alone reads "zz" as a positive size and takes the next request,
  // 'GET /smuggled ...', as chunk data
  AssertTrue('the parser alone is inside chunk data', State = hrsGetBodyChunkedData);
  AssertEquals('and it consumed the smuggled request as data', 0, Left);
end;

procedure THttp1ChunkedTest.TestProbeTrailerFieldIsTakenAsTheLastLineByTheParserAlone;
var
  Left: Integer;
  State: THttpRequestState;
begin
  State := Probe('POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
    '0' + CRLF + 'X-Trailer: v' + CRLF + CRLF, Left);
  AssertTrue('the first trailer line ends the body', State = hrsWaitProcessing);
  AssertEquals('and the real blank line is left over as the start of the next request', 2, Left);
end;

initialization
  RegisterTest(THttp1ChunkedTest);

end.
