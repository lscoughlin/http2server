{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, fuzz, mutation, request smuggling, oracle, test, fpcunit
notes:
  - This unit runs random and mutated request heads through the parser and the
    guard. It checks three properties. The parser never raises. Whole feeding and
    octet-wise feeding give the same transcript. A head that the parser accepts
    passes an independent strict check that this unit holds.
  - The mutations start from valid requests and from the hostile requests of the
    research notes, so most inputs sit next to a boundary.
  - The count of runs is 20000 in the normal suite. The environment variable
    HTTP1_FUZZ_RUNS sets another count; the recorded run uses 1000000.
---
}
/// Fuzz test of the HTTP/1.1 parser and the guard
unit Http2Server.Http1.Fuzz.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Http1.Limits, Http2Server.Http1.Guard, Http2Server.Http1.TestKit;

type
  THttp1FuzzTest = class(TTestCase)
  private
    function Mutate(const ASeed: string): string;
    function RawHeadOf(const AInput: string): string;
    function StrictViolation(const ARawHead: string): string;
  published
    procedure TestMutatedHeadsKeepTheInvariants;
    procedure TestRandomNoiseNeverRaises;
  end;

implementation

const
  CRLF = #13#10;
  Seeds: array[0..28] of string = (
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF,
    'POST /x HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5' + CRLF + CRLF + 'hello',
    'POST /x HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
      '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF,
    'POST /x HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
      '3;a=b' + CRLF + 'abc' + CRLF + '0' + CRLF + 'X-T: 1' + CRLF + CRLF,
    'GET /a?b=c HTTP/1.0' + CRLF + 'Connection: keep-alive' + CRLF + CRLF,
    'GET http://h/p HTTP/1.1' + CRLF + 'Host: other' + CRLF + CRLF,
    'OPTIONS * HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF,
    'GET /ws HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Connection: Upgrade' + CRLF + 'Upgrade: websocket' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5' + CRLF + 'Content-Length: 6' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5, 5' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length : 5' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding:chunked' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked, gzip' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b' + CRLF + ' Content-Length: 5' + CRLF + CRLF,
    'GET / HTTP/1.1'#10'Host: a'#10#10,
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b'#13'c' + CRLF + CRLF,
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b'#0'c' + CRLF + CRLF,
    'GET / HTTP/1.1' + CRLF + CRLF,
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Host: b' + CRLF + CRLF,
    'GET /a b HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF,
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Expect: 100-continue' + CRLF + CRLF,
    'CONNECT h:80 HTTP/1.1' + CRLF + 'Host: h:80' + CRLF + CRLF,
    'PRI * HTTP/2.0' + CRLF + CRLF + 'SM' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
      'zz' + CRLF + 'GET /smuggled HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF,
    'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
      '0' + CRLF + 'Content-Length: 99' + CRLF + CRLF + 'GET /n HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF,
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: ' + #200#201 + CRLF + CRLF,
    'GET /' + #1 + ' HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF,
    'GET / HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X: y' + CRLF + 'Connection: close' + CRLF + CRLF);

function RunsFromEnvironment: Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable('HTTP1_FUZZ_RUNS'), 20000);
end;

function THttp1FuzzTest.Mutate(const ASeed: string): string;
var
  I, N, P, Q: Integer;
  Pool: string;
begin
  Result := ASeed;
  Pool := #0#9#10#13' :;,"\/@[]%+-.aAfF05zZ' + #127#128#255;
  N := 1 + Random(3);
  for I := 1 to N do
  begin
    if Result = '' then
      Break;
    P := 1 + Random(Length(Result));
    case Random(6) of
      0: Result[P] := Pool[1 + Random(Length(Pool))];
      1: Insert(Pool[1 + Random(Length(Pool))], Result, P);
      2: Delete(Result, P, 1 + Random(3));
      3:
        begin
          // duplicate a slice
          Q := 1 + Random(Length(Result) - P + 1);
          Insert(Copy(Result, P, Q), Result, P);
        end;
      4: Result := Copy(Result, 1, P);   // truncate
      5: Insert(CRLF, Result, P);
    end;
  end;
end;

/// the head of the first request of AInput, as a raw text; '' when it has none
function THttp1FuzzTest.RawHeadOf(const AInput: string): string;
var
  S: string;
  P: Integer;
begin
  S := AInput;
  // the parser skips up to four empty lines before the request line
  while (Copy(S, 1, 2) = CRLF) do
    Delete(S, 1, 2);
  P := Pos(CRLF + CRLF, S);
  if P = 0 then
    Exit('');
  Result := Copy(S, 1, P + 1);
end;

/// an independent strict check; answers the first rule that the head breaks
function THttp1FuzzTest.StrictViolation(const ARawHead: string): string;
var
  Lines: TStringList;
  I, P, CL, TE: Integer;
  Line, Name, Value, First: string;
  C: Char;

  function TokenOnly(const S: string): Boolean;
  var
    K: Integer;
  begin
    Result := S <> '';
    for K := 1 to Length(S) do
      if not (S[K] in ['0'..'9', 'A'..'Z', 'a'..'z', '!', '#', '$', '%', '&', '''',
        '*', '+', '-', '.', '^', '_', '`', '|', '~']) then
        Exit(False);
  end;

begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.LineBreak := CRLF;
    Lines.Text := ARawHead;
    if Lines.Count = 0 then
      Exit('no lines');
    First := Lines[0];
    for C in First do
      if (C < ' ') or (C = #127) then
        Exit('a control octet in the request line');
    if (Copy(First, Length(First) - 7, 6) <> ' HTTP/') and
       (Copy(First, Length(First) - 8, 6) <> ' HTTP/') then
      Exit('the request line has no HTTP version');
    CL := 0;
    TE := 0;
    for I := 1 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Line = '' then
        Continue;
      if Line[1] in [' ', #9] then
        Exit('a folded or indented header line');
      P := Pos(':', Line);
      if P < 2 then
        Exit('a header line with no name');
      Name := Copy(Line, 1, P - 1);
      Value := Trim(Copy(Line, P + 1, MaxInt));
      if not TokenOnly(Name) then
        Exit('a header name that is not a token');
      for C in Value do
        if ((C < ' ') and (C <> #9)) or (C = #127) then
          Exit('a control octet in a header value');
      if SameText(Name, 'content-length') then
      begin
        Inc(CL);
        if Value = '' then
          Exit('an empty Content-Length');
        for C in Value do
          if not (C in ['0'..'9']) then
            Exit('a Content-Length that is not digits');
      end;
      if SameText(Name, 'transfer-encoding') then
      begin
        Inc(TE);
        if not SameText(Value, 'chunked') then
          Exit('a Transfer-Encoding other than chunked');
      end;
    end;
    if CL > 1 then
      Exit('more than one Content-Length');
    if TE > 1 then
      Exit('more than one Transfer-Encoding');
    if (CL > 0) and (TE > 0) then
      Exit('Content-Length with Transfer-Encoding');
  finally
    Lines.Free;
  end;
end;

procedure THttp1FuzzTest.TestMutatedHeadsKeepTheInvariants;
var
  L: THttp11Limits;
  Runs, Iter: Integer;
  Input, Whole, Octets, Raw, Why: string;
  Accepted: Integer;
begin
  L := THttp11Limits.Create;
  Runs := RunsFromEnvironment;
  Accepted := 0;
  RandSeed := 20261022;
  for Iter := 1 to Runs do
  begin
    Input := Mutate(Seeds[Random(Length(Seeds))]);
    try
      Whole := H1Run(Input, L, fmWhole, False);
      Octets := H1Run(Input, L, fmOctets, False);
    except
      on E: Exception do
        Fail('the parser raised ' + E.ClassName + ' on iteration ' + IntToStr(Iter) +
          ': ' + E.Message);
    end;
    if Whole <> Octets then
      Fail('whole and octet-wise feeding differ on iteration ' + IntToStr(Iter) +
        '. whole: ' + Whole + ' octets: ' + Octets);
    if Copy(Whole, 1, 2) = 'H ' then
    begin
      Inc(Accepted);
      Raw := RawHeadOf(Input);
      Why := StrictViolation(Raw);
      if Why <> '' then
        Fail('an accepted head breaks a strict rule (' + Why + ') on iteration ' +
          IntToStr(Iter));
    end;
  end;
  // the mutations keep a share of the inputs valid, or the check proves nothing
  AssertTrue('some inputs are accepted: ' + IntToStr(Accepted), Accepted > Runs div 50);
end;

procedure THttp1FuzzTest.TestRandomNoiseNeverRaises;
var
  L: THttp11Limits;
  Iter, I, N: Integer;
  Input: string;
begin
  L := THttp11Limits.Create;
  RandSeed := 77;
  for Iter := 1 to RunsFromEnvironment div 4 do
  begin
    N := Random(200);
    SetLength(Input, N);
    for I := 1 to N do
      Input[I] := Chr(Random(256));
    try
      H1Run(Input, L, fmWhole, True);
      H1Run(Input, L, fmRandom, True);
    except
      on E: Exception do
        Fail('the parser raised ' + E.ClassName + ' on noise, iteration ' + IntToStr(Iter));
    end;
  end;
end;

initialization
  RegisterTest(THttp1FuzzTest);

end.
