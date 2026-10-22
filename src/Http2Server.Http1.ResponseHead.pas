{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, response head, framing, chunked, content-length, persistence, date
notes:
  - This unit builds the head of an HTTP/1.1 response and decides how the body is
    framed (RFC 9112 section 6.3). It holds no state, so a test calls it directly.
  - A response that the handler gives a Content-Length is sent with that length.
    Any other response to an HTTP/1.1 request is chunked. An HTTP/1.0 client gets a
    response that ends with the close of the connection. A response to HEAD and a
    204 or 304 response have no body.
  - The handler never sets Connection, Keep-Alive, Transfer-Encoding, Upgrade or
    Proxy-Connection. The server owns them. The server adds Date unless the handler
    set one (RFC 9110 section 6.6.1).
---
}
/// The head of an HTTP/1.1 response and its framing
unit Http2Server.Http1.ResponseHead;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2Server.Errors, Http2Server.Hpack;

type
  /// how the response body is framed
  TH1ResponseFraming = record
    /// the response has no body: HEAD, 204, 304
    NoBody: Boolean;
    /// the body is chunked
    Chunked: Boolean;
    /// the end of the connection ends the body (HTTP/1.0 client)
    CloseDelimited: Boolean;
    /// the octets that the handler promised with Content-Length
    Remaining: Int64;
    /// the connection stays open after the response
    Keep: Boolean;
  end;

/// the bytes of a response head, and the framing that it announces
// - AMethod and AMinor describe the request; ARequestKeep is the persistence that
//   the request allows
// - raises EHttpError for a header that a handler must not set, for a bad
//   Content-Length, and for a name or value with CR, LF or NUL
function H1BuildResponseHead(const AMethod: string; const AMinor: Integer;
  const ARequestKeep: Boolean; const AStatus: Integer;
  const AHeaders: THeaderBlock; out AFraming: TH1ResponseFraming): TBytes;

/// a complete response with no body, for an error before or instead of a handler
// - the response closes the connection and has Content-Length 0
function H1ErrorResponse(const AStatus, AMinor: Integer;
  const AExtra: THeaderBlock): TBytes;

/// the 100 Continue interim response
function H1ContinueResponse: TBytes;

/// the octets of a text
function H1TextBytes(const AText: string): TBytes;

implementation

uses
  Http2Server.Http1.Status, Http2Server.ResponseWriter;

function H1TextBytes(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function H1ContinueResponse: TBytes;
begin
  Result := H1TextBytes('HTTP/1.1 100 Continue'#13#10#13#10);
end;

function H1ErrorResponse(const AStatus, AMinor: Integer;
  const AExtra: THeaderBlock): TBytes;
var
  S: string;
  I: Integer;
begin
  S := Http1StatusLine(AStatus, AMinor);
  for I := 0 to High(AExtra) do
    S := S + AExtra[I].Name + ': ' + AExtra[I].Value + #13#10;
  S := S + 'content-length: 0'#13#10'connection: close'#13#10'date: ' + HttpDateNow +
    #13#10#13#10;
  Result := H1TextBytes(S);
end;

function H1BuildResponseHead(const AMethod: string; const AMinor: Integer;
  const ARequestKeep: Boolean; const AStatus: Integer;
  const AHeaders: THeaderBlock; out AFraming: TH1ResponseFraming): TBytes;
var
  I: Integer;
  S, N: string;
  HasLength: Boolean;
  Len: Int64;
begin
  AFraming := Default(TH1ResponseFraming);
  CheckResponseHeaders(AHeaders);
  HasLength := False;
  Len := 0;
  S := '';
  for I := 0 to High(AHeaders) do
  begin
    N := LowerCase(AHeaders[I].Name);
    if (N = 'connection') or (N = 'keep-alive') or (N = 'transfer-encoding') or
       (N = 'upgrade') or (N = 'proxy-connection') then
      raise EHttpError.Create('a handler never sets the connection field ' + N);
    if N = 'content-length' then
    begin
      if (AStatus = 204) or (AStatus < 200) then
        Continue;
      if HasLength then
        raise EHttpError.Create('a handler set Content-Length twice');
      if not TryStrToInt64(Trim(AHeaders[I].Value), Len) or (Len < 0) then
        raise EHttpError.Create('Content-Length is not a number');
      HasLength := True;
    end;
    S := S + AHeaders[I].Name + ': ' + AHeaders[I].Value + #13#10;
  end;

  AFraming.NoBody := (AMethod = 'HEAD') or (AStatus = 204) or (AStatus = 304);
  AFraming.Keep := ARequestKeep;
  if HasLength then
    AFraming.Remaining := Len
  else if not AFraming.NoBody then
  begin
    if AMinor = 1 then
    begin
      AFraming.Chunked := True;
      S := S + 'transfer-encoding: chunked'#13#10;
    end
    else
      AFraming.CloseDelimited := True;
  end;

  // persistence: the connection stays open when the request allows it and the
  // end of the response is known to the client
  if AFraming.CloseDelimited then
    AFraming.Keep := False;
  if (AMinor = 0) and AFraming.Keep then
    S := S + 'connection: keep-alive'#13#10;
  if not AFraming.Keep then
    S := S + 'connection: close'#13#10;

  // RFC 9110 section 6.6.1: the server adds Date unless the handler set one
  if not ResponseHasHeader(AHeaders, 'date') then
    S := S + 'date: ' + HttpDateNow + #13#10;
  Result := H1TextBytes(Http1StatusLine(AStatus, AMinor) + S + #13#10);
end;

end.
