{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, hostile input, request smuggling, request line, content-length, transfer-encoding, host, test, fpcunit
notes:
  - This unit holds the hostile-input cases 1 to 52 and 70 to 89 of the HTTP/1.1
    parser. Each case sends a second request after the defect and checks that
    the server does not process it after a framing error.
  - Every case runs through the parser of mORMot2 and the guard, fed whole, one
    octet at a time and in random pieces. The transcripts must agree.
  - The case numbers are those of the research notes of the project.
---
}
/// Hostile-input tests of the HTTP/1.1 request head
unit Http2Server.Http1.Head.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Http1.Limits, Http2Server.Http1.Guard, Http2Server.Http1.TestKit;

type
  THttp1HeadTest = class(TTestCase)
  private
    FLimits: THttp11Limits;
    procedure Reject(const AName, AInput: string; const AStatuses: array of Integer);
    procedure Accept(const AName, AInput, APrefix: string);
  protected
    procedure SetUp; override;
  published
    procedure TestFramingConflicts;
    procedure TestContentLengthForms;
    procedure TestContentLengthOverflow;
    procedure TestTransferEncodingForms;
    procedure TestSpaceBeforeTheColon;
    procedure TestLineFoldingAndLeadingWhiteSpace;
    procedure TestBareLineEnds;
    procedure TestControlOctetsInFields;
    procedure TestFieldNameAndLineGrammar;
    procedure TestRequestLineGrammar;
    procedure TestHostRules;
    procedure TestRequestTargetForms;
    procedure TestSizeLimits;
    procedure TestLeadingEmptyLines;
    procedure TestPipelinedDefectStopsTheConnection;
    procedure TestBodyOfAGetRequest;
    procedure TestConnectionTokens;
    procedure TestNonAsciiOctets;
    procedure TestExpectRules;
    procedure TestUpgradeIsIgnoredWhereItMust;
    procedure TestMethodsAndVersions;
    procedure TestSplitDeliveryIsAlwaysTheSame;
  end;

implementation

const
  CRLF = #13#10;
  Second = 'GET /second HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF;
  Base = 'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF;

procedure THttp1HeadTest.SetUp;
begin
  FLimits := THttp11Limits.Create;
end;

procedure THttp1HeadTest.Reject(const AName, AInput: string;
  const AStatuses: array of Integer);
var
  T: string;
  I: Integer;
  Hit: Boolean;
begin
  // the defect is followed by a second request on the same connection
  T := H1RunAll(AInput + Second, FLimits);
  Hit := False;
  for I := 0 to High(AStatuses) do
    if H1Rejected(T, AStatuses[I]) then
      Hit := True;
  AssertTrue(AName + ': rejected with one of the allowed statuses; got: ' + T, Hit);
  AssertEquals(AName + ': the second request is not processed', 0, Pos('/second', T));
end;

procedure THttp1HeadTest.Accept(const AName, AInput, APrefix: string);
var
  T: string;
begin
  T := H1RunAll(AInput, FLimits);
  AssertEquals(AName + ': ' + T, 1, Pos(APrefix, T));
end;

procedure THttp1HeadTest.TestFramingConflicts;
begin
  // cases 1 and 2
  Reject('case 1', Base + 'Content-Length: 5' + CRLF + 'Transfer-Encoding: chunked' + CRLF +
    CRLF + '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF + 'GET /x HTTP/1.1' + CRLF, [400]);
  Reject('case 2', Base + 'Content-Length: 100' + CRLF + 'Transfer-Encoding: chunked' + CRLF +
    CRLF + '0' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestContentLengthForms;
var
  V: string;
begin
  Reject('case 3 two lines 5 and 6', Base + 'Content-Length: 5' + CRLF + 'Content-Length: 6' +
    CRLF + CRLF + 'hello', [400]);
  Reject('case 4 list 5, 6', Base + 'Content-Length: 5, 6' + CRLF + CRLF + 'hello', [400]);
  Reject('case 5 list 5, 5', Base + 'Content-Length: 5, 5' + CRLF + CRLF + 'hello', [400]);
  Reject('case 6 two equal lines', Base + 'Content-Length: 5' + CRLF + 'Content-Length: 5' +
    CRLF + CRLF + 'hello', [400]);
  for V in ['+5', '-1', '0x10', '5 5', '5a', '1e3', '5.0', ''] do
    Reject('cases 7 to 11 value "' + V + '"', Base + 'Content-Length: ' + V + CRLF + CRLF +
      'hello', [400]);
  Accept('a plain length', Base + 'Content-Length: 5' + CRLF + CRLF + 'hello',
    'H POST / auth=a fr=length len=5');
  Accept('a zero length is no body', Base + 'Content-Length: 0' + CRLF + CRLF,
    'H POST / auth=a fr=none len=0');
  Accept('leading zeros are digits', Base + 'Content-Length: 005' + CRLF + CRLF + 'hello',
    'H POST / auth=a fr=length len=5');
end;

procedure THttp1HeadTest.TestContentLengthOverflow;
begin
  Reject('case 12', Base + 'Content-Length: 99999999999999999999999999' + CRLF + CRLF,
    [400, 413]);
  Reject('case 13 two to the 64', Base + 'Content-Length: 18446744073709551616' + CRLF + CRLF,
    [400, 413]);
  Reject('case 13 two to the 32', Base + 'Content-Length: 4294967296' + CRLF + CRLF,
    [400, 413]);
  Reject('case 69 over the body limit', Base + 'Content-Length: 99999999' + CRLF + CRLF, [413]);
end;

procedure THttp1HeadTest.TestTransferEncodingForms;
begin
  Reject('case 14', Base + 'Transfer-Encoding: chunked, gzip' + CRLF + CRLF + '0' + CRLF + CRLF, [400]);
  Reject('case 15', Base + 'Transfer-Encoding: gzip' + CRLF + CRLF, [400, 501]);
  Reject('case 16', Base + 'Transfer-Encoding: foo, chunked' + CRLF + CRLF + '0' + CRLF + CRLF,
    [400, 501]);
  Reject('case 17 two chunked codings', Base + 'Transfer-Encoding: chunked, chunked' + CRLF +
    CRLF + '0' + CRLF + CRLF, [400]);
  Reject('case 17 two lines', Base + 'Transfer-Encoding: chunked' + CRLF +
    'Transfer-Encoding: chunked' + CRLF + CRLF + '0' + CRLF + CRLF, [400]);
  Reject('case 18 parameter', Base + 'Transfer-Encoding: chunked;x=1' + CRLF + CRLF + '0' +
    CRLF + CRLF, [400]);
  Reject('case 19 empty', Base + 'Transfer-Encoding:' + CRLF + CRLF, [400]);
  Reject('case 21 xchunked', Base + 'Transfer-Encoding: xchunked' + CRLF + CRLF, [400, 501]);
  Reject('case 21 vertical tab', Base + 'Transfer-Encoding: chunked'#11 + CRLF + CRLF, [400, 501]);
  Reject('case 21 quoted', Base + 'Transfer-Encoding: "chunked"' + CRLF + CRLF, [400, 501]);
  Reject('case 23 HTTP/1.0', 'POST / HTTP/1.0' + CRLF + 'Transfer-Encoding: chunked' + CRLF +
    CRLF + '0' + CRLF + CRLF, [400]);
  // case 22: names and codings are case-insensitive
  Accept('case 22 mixed case', Base + 'Transfer-Encoding: Chunked' + CRLF + CRLF + '0' + CRLF + CRLF,
    'H POST / auth=a fr=chunked');
  Accept('case 22 upper case', Base + 'TRANSFER-ENCODING: CHUNKED' + CRLF + CRLF + '0' + CRLF + CRLF,
    'H POST / auth=a fr=chunked');
end;

procedure THttp1HeadTest.TestSpaceBeforeTheColon;
begin
  Reject('case 20', Base + 'Transfer-Encoding : chunked' + CRLF + CRLF + '0' + CRLF + CRLF, [400]);
  Reject('case 24', Base + 'Content-Length : 5' + CRLF + CRLF + 'hello', [400]);
  Reject('case 25', Base + 'Content-Length'#9': 5' + CRLF + CRLF + 'hello', [400]);
end;

procedure THttp1HeadTest.TestLineFoldingAndLeadingWhiteSpace;
begin
  Reject('case 26', 'POST / HTTP/1.1' + CRLF + ' Content-Length: 5' + CRLF + 'Host: a' + CRLF +
    CRLF + 'hello', [400]);
  Reject('case 27', Base + 'X-A: b' + CRLF + ' Content-Length: 5' + CRLF + CRLF + 'hello', [400]);
  Reject('case 28', Base + 'X-A: b' + CRLF + #9'Transfer-Encoding: chunked' + CRLF + CRLF +
    '0' + CRLF + CRLF, [400]);
  Reject('case 52', 'GET / HTTP/1.1' + CRLF + ' Host: a' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestBareLineEnds;
var
  T: string;
begin
  // case 29: a lone LF is not a line end for the parser of mORMot2. The head
  // never completes, so the header deadline of the connection ends it
  T := H1RunAll('GET / HTTP/1.1'#10'Host: a'#10#10, FLimits);
  AssertEquals('case 29: no event and no handler', '', T);
  // when CRLF follows later, the earlier LF sits inside the request line
  Reject('case 29 mixed', 'GET / HTTP/1.1'#10'Host: a'#10#10, [400]);
  Reject('case 30 bare CR in a value', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b'#13'c' +
    CRLF + CRLF, [400]);
  Reject('case 31 bare CR in the request line', 'GET /a'#13'b HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    CRLF, [400]);
  Reject('case 31 bare CR in a name', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X'#13'A: b' +
    CRLF + CRLF, [400]);
  Reject('a lone LF inside a value', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b'#10 +
    'Content-Length: 5' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestControlOctetsInFields;
begin
  Reject('case 32 NUL in a value', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b'#0'c' +
    CRLF + CRLF, [400]);
  Reject('case 33 NUL in a name', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X'#0'A: b' + CRLF +
    CRLF, [400]);
  Reject('case 33 DEL in a name', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X'#127'A: b' +
    CRLF + CRLF, [400]);
  Reject('case 33 control in the target', 'GET /a'#1'b HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    CRLF, [400]);
  Reject('DEL in a value', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b'#127 + CRLF +
    CRLF, [400]);
end;

procedure THttp1HeadTest.TestFieldNameAndLineGrammar;
begin
  Reject('case 34 space', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Bad Name: x' + CRLF + CRLF, [400]);
  Reject('case 34 parenthesis', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Bad(Name): x' + CRLF +
    CRLF, [400]);
  Reject('case 35 no colon', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'BadHeader' + CRLF + CRLF, [400]);
  Reject('case 36 empty name', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + ': value' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestRequestLineGrammar;
begin
  Reject('case 37 two spaces', 'GET  / HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 37 tab', 'GET'#9'/ HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 38 extra token', 'GET / x HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 38 no version', 'GET /' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 39 space in the target', 'GET /a b HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 86 HTTP/0.9 style', 'GET /' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestHostRules;
var
  V: string;
begin
  Reject('case 40', 'GET / HTTP/1.1' + CRLF + CRLF, [400]);
  Reject('case 41 same value', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 41 other value', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Host: b' + CRLF + CRLF, [400]);
  for V in ['a b', 'a/b', '@x', 'a:99999x', 'a:70000', 'a@b', '[::1', ''] do
    Reject('cases 42 and 43 "' + V + '"', 'GET / HTTP/1.1' + CRLF + 'Host: ' + V + CRLF + CRLF, [400]);
  Accept('a host with a port', 'GET / HTTP/1.1' + CRLF + 'Host: example.com:8080' + CRLF + CRLF,
    'H GET / auth=example.com:8080');
  Accept('an IPv6 host', 'GET / HTTP/1.1' + CRLF + 'Host: [::1]:8080' + CRLF + CRLF,
    'H GET / auth=[::1]:8080');
  Accept('HTTP/1.0 needs no Host', 'GET / HTTP/1.0' + CRLF + CRLF, 'H GET / auth= fr=none len=0 v1.0');
end;

procedure THttp1HeadTest.TestRequestTargetForms;
begin
  Accept('case 44 absolute-form', 'GET http://a/p?q=1 HTTP/1.1' + CRLF + 'Host: b' + CRLF + CRLF,
    'H GET /p?q=1 auth=a');
  Accept('absolute-form without a path', 'GET http://a HTTP/1.1' + CRLF + 'Host: b' + CRLF + CRLF,
    'H GET / auth=a');
  Reject('absolute-form needs a Host too', 'GET http://a/ HTTP/1.1' + CRLF + CRLF, [400]);
  Reject('absolute-form with userinfo', 'GET http://u@a/ HTTP/1.1' + CRLF + 'Host: b' + CRLF + CRLF, [400]);
  Accept('case 81', 'OPTIONS * HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, 'H OPTIONS * auth=a');
  Reject('case 82', 'GET * HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Reject('case 83', 'CONNECT host:80 HTTP/1.1' + CRLF + 'Host: host:80' + CRLF + CRLF, [405, 501]);
  Reject('case 84 no port', 'CONNECT host HTTP/1.1' + CRLF + 'Host: host' + CRLF + CRLF, [400]);
  Reject('case 84 empty port', 'CONNECT host: HTTP/1.1' + CRLF + 'Host: host' + CRLF + CRLF, [400]);
  Reject('case 74 non-ASCII in the target', 'GET /caf'#$C3#$A9' HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    CRLF, [400]);
  Reject('a fragment in the target', 'GET /a#b HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestSizeLimits;
var
  Many, Path: string;
  I: Integer;
begin
  Reject('case 45 very long method', StringOfChar('G', 10000) + ' / HTTP/1.1' + CRLF + 'Host: a' +
    CRLF + CRLF, [414, 501, 400]);
  Reject('case 45 method over 32 octets', StringOfChar('G', 40) + ' / HTTP/1.1' + CRLF + 'Host: a' +
    CRLF + CRLF, [501]);
  Reject('case 46', 'GET /' + StringOfChar('a', 9000) + ' HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [414]);
  Path := StringOfChar('a', 7975);
  Accept('case 47 a request line of 8000 octets', 'GET /' + Path + ' HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    CRLF, 'H GET /' + Path);
  Reject('case 48 one long line', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: ' +
    StringOfChar('a', 9000) + CRLF + CRLF, [431]);
  Many := '';
  for I := 1 to 101 do
    Many := Many + 'X-' + IntToStr(I) + ': v' + CRLF;
  Reject('case 48 many lines', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + Many + CRLF, [431]);
  Many := '';
  for I := 1 to 20 do
    Many := Many + 'X-' + IntToStr(I) + ': ' + StringOfChar('v', 4000) + CRLF;
  Reject('case 48 a large section', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + Many + CRLF, [431]);
  // case 49: a head that never ends produces no event; the deadline closes it
  AssertEquals('case 49', '', H1RunAll('GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b', FLimits));
end;

procedure THttp1HeadTest.TestLeadingEmptyLines;
begin
  Accept('case 50', CRLF + 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, 'H GET / auth=a');
  Reject('case 51', StringOfChar(#13, 0) + StringReplace(StringOfChar('x', 10), 'x', CRLF, [rfReplaceAll]) +
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, [400]);
end;

procedure THttp1HeadTest.TestPipelinedDefectStopsTheConnection;
var
  T: string;
begin
  // case 70: valid, defective, valid
  T := H1RunAll('GET /one HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF +
    Base + 'Content-Length: 5' + CRLF + 'Content-Length: 6' + CRLF + CRLF + 'hello' +
    'GET /three HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, FLimits);
  AssertTrue('the first request is served: ' + T, Pos('H GET /one', T) = 1);
  AssertTrue('the second is rejected', H1Rejected(T, 400));
  AssertEquals('the third is never processed', 0, Pos('/three', T));
end;

procedure THttp1HeadTest.TestBodyOfAGetRequest;
var
  T: string;
begin
  // case 67: the body is read; the next octets are the next request
  T := H1RunAll('GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5' + CRLF + CRLF +
    'hello' + Second, FLimits);
  AssertTrue(T, Pos('B hello', T) > 0);
  AssertTrue('and the next request follows', Pos('H GET /second', T) > 0);
  // case 68: a body cut short
  T := H1RunAll('POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5' + CRLF + CRLF + 'hel',
    FLimits);
  AssertTrue(T, Pos('partial hel', T) > 0);
  AssertEquals('no complete request', 0, Pos('E' + #10, T));
end;

procedure THttp1HeadTest.TestConnectionTokens;
begin
  Accept('case 71', Base + 'Connection: Content-Length' + CRLF + 'Content-Length: 5' + CRLF + CRLF +
    'hello', 'H POST / auth=a fr=length len=5 v1.1 keep');
  Accept('case 72', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Connection: close' + CRLF + CRLF,
    'H GET / auth=a fr=none len=0 v1.1 close');
  Accept('a list with close', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Connection: te, Close' +
    CRLF + CRLF, 'H GET / auth=a fr=none len=0 v1.1 close');
  Accept('HTTP/1.0 closes by default', 'GET / HTTP/1.0' + CRLF + CRLF, 'H GET / auth= fr=none len=0 v1.0 close');
  Accept('HTTP/1.0 with keep-alive', 'GET / HTTP/1.0' + CRLF + 'Connection: keep-alive' + CRLF + CRLF,
    'H GET / auth= fr=none len=0 v1.0 keep');
  Accept('the hop-by-hop fields stay with the server', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    'Connection: keep-alive' + CRLF + CRLF, 'H GET / auth=a fr=none len=0 v1.1 keep');
end;

procedure THttp1HeadTest.TestNonAsciiOctets;
begin
  Accept('case 73', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: caf'#$C3#$A9 + CRLF + CRLF,
    'H GET / auth=a');
end;

procedure THttp1HeadTest.TestExpectRules;
begin
  Accept('case 75', Base + 'Expect: 100-continue' + CRLF + 'Content-Length: 10' + CRLF + CRLF +
    '0123456789', 'H POST / auth=a fr=length len=10 v1.1 keep e100');
  Accept('case 76 HTTP/1.0 ignores it', 'POST / HTTP/1.0' + CRLF + 'Expect: 100-continue' + CRLF +
    'Content-Length: 1' + CRLF + CRLF + 'x', 'H POST / auth= fr=length len=1 v1.0 close' + #10);
  Reject('case 77', Base + 'Expect: foo' + CRLF + CRLF, [417]);
  Reject('case 78', Base + 'Expect: 100-continue, foo' + CRLF + CRLF, [417]);
  Accept('case 79', Base + 'Expect: 100-continue' + CRLF + 'Content-Length: 0' + CRLF + CRLF,
    'H POST / auth=a fr=none len=0 v1.1 keep e100');
end;

procedure THttp1HeadTest.TestUpgradeIsIgnoredWhereItMust;
begin
  Accept('case 80 HTTP/1.0', 'GET / HTTP/1.0' + CRLF + 'Connection: Upgrade' + CRLF +
    'Upgrade: websocket' + CRLF + CRLF, 'H GET / auth= fr=none len=0 v1.0 close' + #10);
  Accept('a POST with Upgrade', Base + 'Connection: Upgrade' + CRLF + 'Upgrade: websocket' + CRLF +
    CRLF, 'H POST / auth=a fr=none len=0 v1.1 keep' + #10);
  Accept('an Upgrade token that is not websocket', 'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    'Connection: Upgrade' + CRLF + 'Upgrade: h2c' + CRLF + CRLF, 'H GET / auth=a fr=none len=0 v1.1 keep' + #10);
  Accept('a websocket upgrade is flagged', 'GET /chat HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    'Connection: keep-alive, Upgrade' + CRLF + 'Upgrade: websocket' + CRLF + CRLF,
    'H GET /chat auth=a fr=none len=0 v1.1 keep ws');
end;

procedure THttp1HeadTest.TestMethodsAndVersions;
var
  V: string;
begin
  Reject('case 85', 'PRI * HTTP/2.0' + CRLF + CRLF, [505]);
  for V in ['HTTP/2.0', 'HTTP/3.0', 'HTTP/0.9'] do
    Reject('case 88 ' + V, 'GET / ' + V + CRLF + 'Host: a' + CRLF + CRLF, [505]);
  for V in ['http/1.1', 'HTTP/1.01', 'HTTP/1.x', 'HTTP/ 1.1', 'HTTP/1.', 'HTTP/11'] do
    Reject('case 89 ' + V, 'GET / ' + V + CRLF + 'Host: a' + CRLF + CRLF, [400]);
  Accept('case 87', 'GET / HTTP/1.2' + CRLF + 'Host: a' + CRLF + CRLF, 'H GET / auth=a fr=none len=0 v1.1');
  Accept('a method that the server does not know passes to the handler',
    'PURGE /x HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF, 'H PURGE /x auth=a');
end;

procedure THttp1HeadTest.TestSplitDeliveryIsAlwaysTheSame;
var
  S: string;
begin
  S := Base + 'Content-Length: 5' + CRLF + 'X-A: b' + CRLF + CRLF + 'hello' + Second;
  AssertTrue(Pos('B hello', H1RunAll(S, FLimits)) > 0);
end;

initialization
  RegisterTest(THttp1HeadTest);

end.
