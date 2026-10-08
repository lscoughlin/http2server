{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, request, validation
notes:
  - The unit holds the RFC 9113 section 8.1 request-header rules.  The
    connection core calls one function for each completed request header
    block, and the function reports the first fault it finds.
---
}
/// request header block validation (RFC 9113 section 8.1)
unit Http2Server.RequestValidation;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Hpack;

type
  /// the outcome of one request header block check
  TRequestVerdict = record
    /// true when the block obeys every request rule
    Valid: Boolean;
    /// the content-length that the block declares, or -1 when absent
    DeclaredLength: Int64;
  end;

/// check one request header block
/// - AIsTrailer is true for a trailing header block, where the
///   pseudo-headers are forbidden and the request pseudo-headers are not
///   required
function ValidateRequestHeaders(const ABlock: THeaderBlock;
  const AIsTrailer: Boolean): TRequestVerdict;

/// true when AValue is a whole non-negative decimal number, and ALength
/// then holds its value
function ParseContentLength(const AValue: string; out ALength: Int64): Boolean;

implementation

const
  /// the request pseudo-headers of RFC 9113 section 8.3.1
  PseudoMethod    = ':method';
  PseudoScheme    = ':scheme';
  PseudoPath      = ':path';
  PseudoAuthority = ':authority';

  /// HTTP/1.1 connection-specific header fields, forbidden on the HTTP/2
  /// wire (RFC 9113 section 8.1.2.2)
  ForbiddenHeaders: array[0..4] of string = (
    'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding',
    'upgrade');

/// true when C is a token character of RFC 9110 section 5.6.2
function IsTokenChar(const C: Char): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9')) or
    (C in ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.',
           '^', '_', '`', '|', '~']);
end;

/// true when C is an uppercase letter, which a header name forbids
function IsUpperCase(const C: Char): Boolean;
begin
  Result := (C >= 'A') and (C <= 'Z');
end;

/// RFC 9113 section 8.1.2.6: a header name is a lowercase token
function ValidHeaderName(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(AName) = 0 then
    Exit;
  for I := 1 to Length(AName) do
    if IsUpperCase(AName[I]) or (not IsTokenChar(AName[I])) then
      Exit;
  Result := True;
end;

/// RFC 9113 section 8.1.2.6: a field value holds no null, CR or LF
function ValidHeaderValue(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(AValue) do
    if (AValue[I] = #0) or (AValue[I] = #10) or (AValue[I] = #13) then
      Exit;
  Result := True;
end;

function ParseContentLength(const AValue: string; out ALength: Int64): Boolean;
var
  I, Digit: Integer;
begin
  ALength := 0;
  Result := Length(AValue) > 0;
  if not Result then
    Exit;
  for I := 1 to Length(AValue) do
  begin
    if (AValue[I] < '0') or (AValue[I] > '9') then
      Exit(False);
    Digit := Ord(AValue[I]) - Ord('0');
    if ALength > (High(Int64) - Digit) div 10 then
      Exit(False);
    ALength := ALength * 10 + Digit;
  end;
end;

/// true when ALowerName is a connection-specific header field
function IsForbidden(const ALowerName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(ForbiddenHeaders) to High(ForbiddenHeaders) do
    if ALowerName = ForbiddenHeaders[I] then
      Exit(True);
end;

function ValidateRequestHeaders(const ABlock: THeaderBlock;
  const AIsTrailer: Boolean): TRequestVerdict;
var
  I: Integer;
  Name, Value, Lower: string;
  SeenRegular: Boolean;
  HasMethod, HasScheme, HasPath, HasAuthority, HasLength: Boolean;
  Declared: Int64;
begin
  Result.Valid := False;
  Result.DeclaredLength := -1;
  SeenRegular := False;
  HasMethod := False;
  HasScheme := False;
  HasPath := False;
  HasAuthority := False;
  HasLength := False;
  for I := 0 to High(ABlock) do
  begin
    Name := ABlock[I].Name;
    Value := ABlock[I].Value;
    if Length(Name) = 0 then
      Exit;
    if not ValidHeaderValue(Value) then
      Exit;
    if Name[1] = ':' then
    begin
      // RFC 9113 section 8.1.2.1: a pseudo-header follows no regular header
      // field and never appears in a trailer
      if AIsTrailer or SeenRegular then
        Exit;
      if (Name = PseudoMethod) and (not HasMethod) and (Value <> '') then
        HasMethod := True
      else if (Name = PseudoScheme) and (not HasScheme) and (Value <> '') then
        HasScheme := True
      else if (Name = PseudoPath) and (not HasPath) and (Value <> '') then
        HasPath := True
      else if (Name = PseudoAuthority) and (not HasAuthority) then
        HasAuthority := True
      else
        // an unknown pseudo-header, a response pseudo-header, a duplicate or
        // an empty value is a fault
        Exit;
    end
    else
    begin
      SeenRegular := True;
      if not ValidHeaderName(Name) then
        Exit;
      Lower := LowerCase(Name);
      if IsForbidden(Lower) then
        Exit;
      if Lower = 'te' then
      begin
        // RFC 9113 section 8.1.2.2: "te" is the sole exception, and its
        // only legal value is "trailers"
        if not SameText(Value, 'trailers') then
          Exit;
      end
      else if Lower = 'content-length' then
      begin
        if HasLength or (not ParseContentLength(Value, Declared)) then
          Exit;
        HasLength := True;
        Result.DeclaredLength := Declared;
      end;
    end;
  end;
  // RFC 9113 section 8.3.1: a request head carries :method, :scheme and
  // :path exactly once; a trailer carries none of them
  if (not AIsTrailer) and ((not HasMethod) or (not HasScheme) or
     (not HasPath)) then
    Exit;
  Result.Valid := True;
end;

end.