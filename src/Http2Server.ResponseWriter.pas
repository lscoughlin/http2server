{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: response, date header, header safety, http1, http2
notes:
  - This unit holds the response rules that both protocols share. It adds the
    Date field when the handler did not set one, and it rejects a header name or
    value that holds CR, LF or NUL, so a handler cannot split a response.
  - RFC 9110 section 6.6.1 requires a Date field in every 2xx, 3xx and 4xx
    response of an origin server that has a clock. The server adds it to every
    final response. A Date field that the handler set is never replaced.
  - The HTTP-date is cached and changes once a second.
---
}
/// The response rules that HTTP/1.1 and HTTP/2 share
unit Http2Server.ResponseWriter;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Errors, Http2Server.Hpack;

/// the current time as an HTTP-date, for example 'Sun, 06 Nov 1994 08:49:37 GMT'
// - cached; the value changes once a second
function HttpDateNow: string;

/// the HTTP-date of a moment given in UTC
function HttpDateOf(const AUtc: TDateTime): string;

/// true when AHeaders holds a field with this name; the compare ignores case
function ResponseHasHeader(const AHeaders: THeaderBlock; const AName: string): Boolean;

/// raise EHttpError when a name or a value holds CR, LF or NUL
// - a name must also be non-empty and hold no space, colon or other control octet
procedure CheckResponseHeaders(const AHeaders: THeaderBlock);

/// the response fields of an HTTP/2 response
// - RFC 9113 section 8.2: a field name is lower case. The result holds every
//   name in lower case
// - RFC 9113 section 8.2.2: a field that is specific to one HTTP/1.1 connection
//   (connection, keep-alive, proxy-connection, transfer-encoding, upgrade) is
//   not legal in HTTP/2, so the call raises EHttpError for it
function PrepareH2ResponseHeaders(const AHeaders: THeaderBlock): THeaderBlock;

/// AHeaders with the Date field added for a final response that has none
function WithDate(const AHeaders: THeaderBlock; const AStatus: Integer): THeaderBlock;

implementation

uses
  SyncObjs, DateUtils;

var
  GLock: TCriticalSection;
  GSecond: Int64 = -1;
  GText: string = '';

const
  cDays: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  cMonths: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function HttpDateOf(const AUtc: TDateTime): string;
var
  Y, M, D, H, N, S, MS: Word;
begin
  DecodeDate(AUtc, Y, M, D);
  DecodeTime(AUtc, H, N, S, MS);
  Result := Format('%s, %.2d %s %.4d %.2d:%.2d:%.2d GMT',
    [cDays[DayOfWeek(AUtc)], D, cMonths[M], Y, H, N, S]);
end;

function HttpDateNow: string;
var
  Now_: TDateTime;
  Sec: Int64;
begin
  Now_ := NowUTC;
  Sec := DateTimeToUnix(Now_);
  GLock.Acquire;
  try
    if Sec <> GSecond then
    begin
      GText := HttpDateOf(Now_);
      GSecond := Sec;
    end;
    Result := GText;
  finally
    GLock.Release;
  end;
end;

function ResponseHasHeader(const AHeaders: THeaderBlock; const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
      Exit(True);
  Result := False;
end;

procedure CheckResponseHeaders(const AHeaders: THeaderBlock);
var
  I, J: Integer;
  C: Char;
begin
  for I := 0 to High(AHeaders) do
  begin
    if AHeaders[I].Name = '' then
      raise EHttpError.Create('a response header name is empty');
    for J := 1 to Length(AHeaders[I].Name) do
    begin
      C := AHeaders[I].Name[J];
      if (C <= ' ') or (C = ':') or (C = #127) then
        raise EHttpError.Create('a response header name holds a control octet, a space or a colon');
    end;
    for J := 1 to Length(AHeaders[I].Value) do
    begin
      C := AHeaders[I].Value[J];
      if (C = #13) or (C = #10) or (C = #0) then
        raise EHttpError.Create('a response header value holds CR, LF or NUL');
    end;
  end;
end;

function PrepareH2ResponseHeaders(const AHeaders: THeaderBlock): THeaderBlock;
var
  I: Integer;
  Lower: string;
begin
  Result := Copy(AHeaders);
  for I := 0 to High(Result) do
  begin
    Lower := LowerCase(Result[I].Name);
    if (Lower = 'connection') or (Lower = 'keep-alive') or
       (Lower = 'proxy-connection') or (Lower = 'transfer-encoding') or
       (Lower = 'upgrade') then
      raise EHttpError.Create('the response field ' + Lower +
        ' is specific to one HTTP/1.1 connection and is not legal in HTTP/2');
    Result[I].Name := Lower;
  end;
end;

function WithDate(const AHeaders: THeaderBlock; const AStatus: Integer): THeaderBlock;
var
  N: Integer;
begin
  Result := AHeaders;
  // a 1xx response is not final, and the handler's own Date stays
  if (AStatus < 200) or ResponseHasHeader(AHeaders, 'date') then
    Exit;
  N := Length(Result);
  SetLength(Result, N + 1);
  Result[N].Name := 'date';
  Result[N].Value := HttpDateNow;
  Result[N].Sensitive := False;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
