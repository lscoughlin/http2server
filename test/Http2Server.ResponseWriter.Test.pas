{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: response, date header, header safety, status line, test, fpcunit
notes:
  - This unit tests the response rules that both protocols share.
---
}
/// Unit tests for Http2Server.ResponseWriter and Http2Server.Http1.Status
unit Http2Server.ResponseWriter.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.ResponseWriter,
  Http2Server.Http1.Status;

type
  TResponseWriterTest = class(TTestCase)
  private
    function One(const AName, AValue: string): THeaderBlock;
    procedure ExpectRejected(const AHeaders: THeaderBlock; const AName: string);
  published
    procedure TestHttpDateOfTheRfcExample;
    procedure TestHttpDateNowHasTheRfcShape;
    procedure TestDateIsAddedToFinalResponses;
    procedure TestDateIsNotAddedToAnInformationalResponse;
    procedure TestHandlerDateIsNeverReplaced;
    procedure TestHandlerDateInOtherCaseIsNeverReplaced;
    procedure TestHeaderInjectionIsRejected;
    procedure TestStatusLine;
  end;

implementation

function TResponseWriterTest.One(const AName, AValue: string): THeaderBlock;
begin
  SetLength(Result, 1);
  Result[0].Name := AName;
  Result[0].Value := AValue;
  Result[0].Sensitive := False;
end;

procedure TResponseWriterTest.ExpectRejected(const AHeaders: THeaderBlock;
  const AName: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    CheckResponseHeaders(AHeaders);
  except
    on EHttpError do
      Raised := True;
  end;
  AssertTrue(AName + ' is rejected', Raised);
end;

procedure TResponseWriterTest.TestHttpDateOfTheRfcExample;
begin
  // RFC 9110 section 5.6.7: Sun, 06 Nov 1994 08:49:37 GMT
  AssertEquals('Sun, 06 Nov 1994 08:49:37 GMT',
    HttpDateOf(EncodeDate(1994, 11, 6) + EncodeTime(8, 49, 37, 0)));
  AssertEquals('Thu, 01 Jan 1970 00:00:00 GMT',
    HttpDateOf(EncodeDate(1970, 1, 1)));
end;

procedure TResponseWriterTest.TestHttpDateNowHasTheRfcShape;
var
  S: string;
begin
  S := HttpDateNow;
  AssertEquals(29, Length(S));
  AssertEquals(', ', Copy(S, 4, 2));
  AssertEquals(' GMT', Copy(S, 26, 4));
  AssertEquals('the value is cached within a second', S = HttpDateNow, True);
end;

procedure TResponseWriterTest.TestDateIsAddedToFinalResponses;
var
  H: THeaderBlock;
begin
  H := WithDate(nil, 200);
  AssertEquals(1, Length(H));
  AssertEquals('date', H[0].Name);
  AssertTrue(ResponseHasHeader(WithDate(nil, 404), 'Date'));
  AssertTrue(ResponseHasHeader(WithDate(nil, 503), 'date'));
  AssertTrue(ResponseHasHeader(WithDate(One('x', 'y'), 302), 'date'));
  AssertEquals('the other fields stay', 2, Length(WithDate(One('x', 'y'), 302)));
end;

procedure TResponseWriterTest.TestDateIsNotAddedToAnInformationalResponse;
begin
  AssertEquals(0, Length(WithDate(nil, 100)));
  AssertEquals(0, Length(WithDate(nil, 101)));
end;

procedure TResponseWriterTest.TestHandlerDateIsNeverReplaced;
var
  H: THeaderBlock;
begin
  H := WithDate(One('date', 'Mon, 01 Jan 2001 00:00:00 GMT'), 200);
  AssertEquals(1, Length(H));
  AssertEquals('Mon, 01 Jan 2001 00:00:00 GMT', H[0].Value);
end;

procedure TResponseWriterTest.TestHandlerDateInOtherCaseIsNeverReplaced;
var
  H: THeaderBlock;
begin
  H := WithDate(One('Date', 'x'), 200);
  AssertEquals(1, Length(H));
  AssertEquals('x', H[0].Value);
end;

procedure TResponseWriterTest.TestHeaderInjectionIsRejected;
begin
  ExpectRejected(One('x', 'a'#13#10'set-cookie: evil'), 'CRLF in a value');
  ExpectRejected(One('x', 'a'#10'b'), 'LF in a value');
  ExpectRejected(One('x', 'a'#13'b'), 'CR in a value');
  ExpectRejected(One('x', 'a'#0'b'), 'NUL in a value');
  ExpectRejected(One('x'#13#10'y', 'v'), 'CRLF in a name');
  ExpectRejected(One('x y', 'v'), 'a space in a name');
  ExpectRejected(One('x:y', 'v'), 'a colon in a name');
  ExpectRejected(One('', 'v'), 'an empty name');
  CheckResponseHeaders(One('x-ok', 'a value with spaces and tab'#9'ok'));
end;

procedure TResponseWriterTest.TestStatusLine;
begin
  AssertEquals('HTTP/1.1 200 OK'#13#10, Http1StatusLine(200));
  AssertEquals('HTTP/1.0 404 Not Found'#13#10, Http1StatusLine(404, 0));
  AssertEquals('the space after an unknown code stays', 'HTTP/1.1 299 '#13#10,
    Http1StatusLine(299));
  AssertEquals('Request Header Fields Too Large', Http1ReasonPhrase(431));
end;

initialization
  RegisterTest(TResponseWriterTest);

end.
