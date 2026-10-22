{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, guard, request smuggling, framing, content-length, transfer-encoding, chunked
notes:
  - This unit holds the strict rules that sit on top of the HTTP/1.1 parser of
    mORMot2. It has no socket and no parser state, so a test calls it directly.
  - The parser of mORMot2 is lenient in places that matter for request smuggling
    (a list in Content-Length, a Transfer-Encoding that is not exactly chunked, a
    chunk-size line with trailing garbage). Each rule here closes one of those
    gaps. Where an RFC allows two answers, the guard takes the stricter one,
    because the parser is a security boundary.
  - The rules and their section numbers are in RFC 9112 (HTTP/1.1) and RFC 9110
    (HTTP semantics), checked on 2026-10-22.
---
}
/// Strict HTTP/1.1 request rules
unit Http2Server.Http1.Guard;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2Server.Hpack, Http2Server.Http1.Limits;

type
  /// the answer of a guard rule
  TH1Verdict = record
    /// 0 when the message is accepted; else the status to answer before the close
    Status: Integer;
    /// a short text for the observer and the log; never sent to the peer
    Reason: string;
  end;

  /// how the body of a request is framed (RFC 9112 section 6.3)
  TH1Framing = (bfNone, bfLength, bfChunked);

  /// the request line after the checks
  TH1RequestLine = record
    Method: string;
    /// the path with its query for the origin-form; the whole target otherwise
    Target: string;
    /// the authority of an absolute-form target; empty otherwise
    TargetAuthority: string;
    /// the scheme of an absolute-form target; empty otherwise
    TargetScheme: string;
    /// the minor version: 0 or 1 (a higher minor counts as 1)
    Minor: Integer;
    /// the target was the asterisk form
    Asterisk: Boolean;
  end;

  /// a request head after all checks
  TH1Head = record
    Line: TH1RequestLine;
    /// the fields that a handler sees; the names are lower case
    Fields: THeaderBlock;
    Authority: string;
    Framing: TH1Framing;
    ContentLength: Int64;
    /// the connection stays open after the response, if the response allows it
    KeepAlive: Boolean;
    /// the client waits for a 100 Continue before it sends the body
    Expect100: Boolean;
    /// a WebSocket upgrade request (GET, HTTP/1.1, Connection: Upgrade, Upgrade: websocket)
    WebSocketUpgrade: Boolean;
  end;

const
  /// the greatest number of empty lines before a request line
  cH1MaxLeadingEmptyLines = 4;

/// accept the verdict
function H1Ok: TH1Verdict;
/// a verdict that refuses with AStatus
function H1Refuse(const AStatus: Integer; const AReason: string): TH1Verdict;

/// check and split the request line (RFC 9112 section 3)
function H1CheckRequestLine(const ALine: RawByteString;
  const ALimits: THttp11Limits; out ARequest: TH1RequestLine): TH1Verdict;

/// check the header section and decide framing, persistence and the fields
// - ARaw holds the header lines separated by CRLF, with no blank line at the end
function H1CheckHead(const ARequest: TH1RequestLine; const ARaw: RawByteString;
  const ALimits: THttp11Limits; out AHead: TH1Head): TH1Verdict;

/// check a chunk-size line; ASize is the size when the line is valid
function H1CheckChunkLine(const ALine: RawByteString;
  const ALimits: THttp11Limits; out ASize: Int64): TH1Verdict;

/// check the trailer section that follows the last chunk
// - ARaw holds the lines after the 0 chunk line, up to and excluding the blank line
function H1CheckTrailer(const ARaw: RawByteString;
  const ALimits: THttp11Limits): TH1Verdict;

/// true for a token character (RFC 9110 section 5.6.2)
function H1IsTokenChar(const AChar: AnsiChar): Boolean;

implementation

function H1Ok: TH1Verdict;
begin
  Result.Status := 0;
  Result.Reason := '';
end;

function H1Refuse(const AStatus: Integer; const AReason: string): TH1Verdict;
begin
  Result.Status := AStatus;
  Result.Reason := AReason;
end;

function H1IsTokenChar(const AChar: AnsiChar): Boolean;
begin
  case AChar of
    '0'..'9', 'A'..'Z', 'a'..'z',
    '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~':
      Result := True;
  else
    Result := False;
  end;
end;

/// copy the bytes of a raw text into a string without any code page change
function BytesToStr(const ARaw: RawByteString): string;
begin
  SetString(Result, PAnsiChar(ARaw), Length(ARaw));
end;

function IsToken(const AText: RawByteString): Boolean;
var
  I: Integer;
begin
  Result := AText <> '';
  for I := 1 to Length(AText) do
    if not H1IsTokenChar(AText[I]) then
      Exit(False);
end;

function IsDigits(const AText: RawByteString): Boolean;
var
  I: Integer;
begin
  Result := AText <> '';
  for I := 1 to Length(AText) do
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit(False);
end;

function LowerRaw(const AText: RawByteString): RawByteString;
var
  I: Integer;
begin
  Result := AText;
  for I := 1 to Length(Result) do
    if (Result[I] >= 'A') and (Result[I] <= 'Z') then
      Result[I] := AnsiChar(Ord(Result[I]) + 32);
end;

function TrimOws(const AText: RawByteString): RawByteString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(AText);
  while (A <= B) and (AText[A] in [' ', #9]) do
    Inc(A);
  while (B >= A) and (AText[B] in [' ', #9]) do
    Dec(B);
  Result := Copy(AText, A, B - A + 1);
end;

/// a host: reg-name or IPv4 or bracketed IP literal, with an optional port
function ValidHost(const AHost: RawByteString): Boolean;
var
  H, P: RawByteString;
  Colon, I: Integer;
begin
  Result := False;
  if AHost = '' then
    Exit;
  H := AHost;
  P := '';
  if H[1] = '[' then
  begin
    Colon := Pos(']', H);
    if Colon < 3 then
      Exit;
    for I := 2 to Colon - 1 do
      if not (H[I] in ['0'..'9', 'a'..'f', 'A'..'F', ':', '.']) then
        Exit;
    if Colon < Length(H) then
    begin
      if H[Colon + 1] <> ':' then
        Exit;
      P := Copy(H, Colon + 2, MaxInt);
    end;
    if (P <> '') and not IsDigits(P) then
      Exit;
    Exit((Length(P) <= 5) and ((P = '') or (StrToInt(string(P)) <= 65535)));
  end;
  Colon := Pos(':', H);
  if Colon > 0 then
  begin
    P := Copy(H, Colon + 1, MaxInt);
    H := Copy(H, 1, Colon - 1);
    // a port can be empty (RFC 3986), but a non-digit is not valid
    if (P <> '') and not IsDigits(P) then
      Exit;
    if Length(P) > 5 then
      Exit;
    if (P <> '') and (StrToInt(string(P)) > 65535) then
      Exit;
  end;
  if H = '' then
    Exit;
  for I := 1 to Length(H) do
    if not (H[I] in ['0'..'9', 'a'..'z', 'A'..'Z', '-', '.', '_', '~', '%', '!',
      '$', '&', '''', '(', ')', '*', '+', ',', ';', '=']) then
      Exit;
  Result := True;
end;

function H1CheckRequestLine(const ALine: RawByteString;
  const ALimits: THttp11Limits; out ARequest: TH1RequestLine): TH1Verdict;
var
  S1, S2, I, Slash: Integer;
  Method, Target, Version, Rest: RawByteString;
  C: AnsiChar;
begin
  ARequest := Default(TH1RequestLine);
  ARequest.Minor := 1;
  if Length(ALine) > ALimits.MaxRequestLine then
    Exit(H1Refuse(414, 'the request line is too long'));
  for I := 1 to Length(ALine) do
  begin
    C := ALine[I];
    if (C < ' ') or (C = #127) then
      Exit(H1Refuse(400, 'the request line holds a control octet'));
  end;
  S1 := Pos(' ', ALine);
  if S1 < 2 then
    Exit(H1Refuse(400, 'the request line has no method'));
  Method := Copy(ALine, 1, S1 - 1);
  Rest := Copy(ALine, S1 + 1, MaxInt);
  S2 := Pos(' ', Rest);
  if S2 < 2 then
    Exit(H1Refuse(400, 'the request line has no version'));
  Target := Copy(Rest, 1, S2 - 1);
  Version := Copy(Rest, S2 + 1, MaxInt);
  if (Pos(' ', Version) > 0) or (Version = '') then
    Exit(H1Refuse(400, 'the request line has extra parts'));
  if not IsToken(Method) then
    Exit(H1Refuse(400, 'the method is not a token'));
  if Length(Method) > 32 then
    Exit(H1Refuse(501, 'the method is too long'));

  // the version: 'HTTP/' DIGIT '.' DIGIT, in upper case only
  if (Length(Version) <> 8) or (Copy(Version, 1, 5) <> 'HTTP/') or
     (Version[7] <> '.') or not (Version[6] in ['0'..'9']) or
     not (Version[8] in ['0'..'9']) then
    Exit(H1Refuse(400, 'the version is malformed'));
  if Version[6] <> '1' then
    Exit(H1Refuse(505, 'the major version is not 1'));
  if Version[8] = '0' then
    ARequest.Minor := 0
  else
    ARequest.Minor := 1;

  if Method = 'CONNECT' then
  begin
    // authority-form: host ':' port, both needed
    Slash := Pos(':', Target);
    if (Slash < 2) or (Slash = Length(Target)) or not IsDigits(Copy(Target, Slash + 1, MaxInt)) then
      Exit(H1Refuse(400, 'the CONNECT target is not host:port'));
    Exit(H1Refuse(501, 'CONNECT is not supported'));
  end;

  for I := 1 to Length(Target) do
  begin
    C := Target[I];
    if (C <= ' ') or (C >= #127) or (C = '#') then
      Exit(H1Refuse(400, 'the target holds a space, a control octet, a fragment or a non-ASCII octet'));
  end;
  if Target = '*' then
  begin
    if Method <> 'OPTIONS' then
      Exit(H1Refuse(400, 'the asterisk target is for OPTIONS only'));
    ARequest.Method := BytesToStr(Method);
    ARequest.Target := '*';
    ARequest.Asterisk := True;
    Exit(H1Ok);
  end;
  ARequest.Method := BytesToStr(Method);
  if Target[1] = '/' then
  begin
    ARequest.Target := BytesToStr(Target);
    Exit(H1Ok);
  end;
  // absolute-form: scheme '://' authority [path]
  if LowerRaw(Copy(Target, 1, 7)) = 'http://' then
  begin
    ARequest.TargetScheme := 'http';
    Rest := Copy(Target, 8, MaxInt);
  end
  else if LowerRaw(Copy(Target, 1, 8)) = 'https://' then
  begin
    ARequest.TargetScheme := 'https';
    Rest := Copy(Target, 9, MaxInt);
  end
  else
    Exit(H1Refuse(400, 'the target is not in a known form'));
  Slash := Pos('/', Rest);
  if Slash = 0 then
  begin
    Target := Rest;
    Rest := '/';
  end
  else
  begin
    Target := Copy(Rest, 1, Slash - 1);
    Rest := Copy(Rest, Slash, MaxInt);
  end;
  if (Pos('@', Target) > 0) or not ValidHost(Target) then
    Exit(H1Refuse(400, 'the authority of the target is not valid'));
  ARequest.TargetAuthority := BytesToStr(Target);
  ARequest.Target := BytesToStr(Rest);
  Result := H1Ok;
end;

type
  TRawField = record
    Name: RawByteString;   // lower case
    Value: RawByteString;  // trimmed
  end;

function SplitFields(const ARaw: RawByteString; const ALimits: THttp11Limits;
  out AFields: TArray<TRawField>): TH1Verdict;
var
  Pos0, E, Colon, I, N: Integer;
  Line, Name: RawByteString;
  C: AnsiChar;
begin
  AFields := nil;
  N := 0;
  if ARaw = '' then
    Exit(H1Ok);
  if Length(ARaw) > ALimits.MaxHeaderOctets then
    Exit(H1Refuse(431, 'the header section is too large'));
  Pos0 := 1;
  while Pos0 <= Length(ARaw) do
  begin
    E := Pos0;
    while (E <= Length(ARaw)) and not ((ARaw[E] = #13) and (E < Length(ARaw)) and (ARaw[E + 1] = #10)) do
      Inc(E);
    Line := Copy(ARaw, Pos0, E - Pos0);
    if E <= Length(ARaw) then
      Pos0 := E + 2
    else
      Pos0 := E;
    if Length(Line) > ALimits.MaxHeaderLine then
      Exit(H1Refuse(431, 'a header line is too long'));
    if Line = '' then
      Exit(H1Refuse(400, 'an empty line inside the header section'));
    if Line[1] in [' ', #9] then
      Exit(H1Refuse(400, 'obsolete line folding or a line that starts with white space'));
    Colon := Pos(':', Line);
    if Colon < 2 then
      Exit(H1Refuse(400, 'a header line with no name or no colon'));
    Name := Copy(Line, 1, Colon - 1);
    if not IsToken(Name) then
      Exit(H1Refuse(400, 'a header name is not a token'));
    for I := Colon + 1 to Length(Line) do
    begin
      C := Line[I];
      if ((C < ' ') and (C <> #9)) or (C = #127) then
        Exit(H1Refuse(400, 'a header value holds a control octet'));
    end;
    Inc(N);
    if N > ALimits.MaxHeaderCount then
      Exit(H1Refuse(431, 'too many header lines'));
    SetLength(AFields, N);
    AFields[N - 1].Name := LowerRaw(Name);
    AFields[N - 1].Value := TrimOws(Copy(Line, Colon + 1, MaxInt));
  end;
  Result := H1Ok;
end;

/// split a comma list into trimmed, lower-case members; empty members stay
function SplitList(const AValue: RawByteString): TArray<RawByteString>;
var
  A, I, N: Integer;
begin
  Result := nil;
  N := 0;
  A := 1;
  for I := 1 to Length(AValue) + 1 do
    if (I > Length(AValue)) or (AValue[I] = ',') then
    begin
      Inc(N);
      SetLength(Result, N);
      Result[N - 1] := LowerRaw(TrimOws(Copy(AValue, A, I - A)));
      A := I + 1;
    end;
end;

function H1CheckHead(const ARequest: TH1RequestLine; const ARaw: RawByteString;
  const ALimits: THttp11Limits; out AHead: TH1Head): TH1Verdict;
var
  Fields: TArray<TRawField>;
  I, J, CLCount, TECount, HostCount, ExpectCount: Integer;
  CLValue, TEValue, HostValue: RawByteString;
  Members: TArray<RawByteString>;
  Close_, Keep, Upgrade_, UpgradeWs, Chunked: Boolean;
  Drop: Boolean;
  Len: Int64;
begin
  AHead := Default(TH1Head);
  AHead.Line := ARequest;
  Result := SplitFields(ARaw, ALimits, Fields);
  if Result.Status <> 0 then
    Exit;

  CLCount := 0;
  TECount := 0;
  HostCount := 0;
  ExpectCount := 0;
  Close_ := False;
  Keep := False;
  Upgrade_ := False;
  UpgradeWs := False;
  for I := 0 to High(Fields) do
  begin
    if Fields[I].Name = 'content-length' then
    begin
      Inc(CLCount);
      CLValue := Fields[I].Value;
    end
    else if Fields[I].Name = 'transfer-encoding' then
    begin
      Inc(TECount);
      TEValue := Fields[I].Value;
    end
    else if Fields[I].Name = 'host' then
    begin
      Inc(HostCount);
      HostValue := Fields[I].Value;
    end
    else if Fields[I].Name = 'expect' then
      Inc(ExpectCount)
    else if Fields[I].Name = 'connection' then
    begin
      Members := SplitList(Fields[I].Value);
      for J := 0 to High(Members) do
      begin
        if Members[J] = 'close' then
          Close_ := True
        else if Members[J] = 'keep-alive' then
          Keep := True
        else if Members[J] = 'upgrade' then
          Upgrade_ := True;
      end;
    end
    else if Fields[I].Name = 'upgrade' then
    begin
      Members := SplitList(Fields[I].Value);
      for J := 0 to High(Members) do
        if Members[J] = 'websocket' then
          UpgradeWs := True;
    end;
  end;

  // framing (RFC 9112 section 6.3): the request message gets one length rule
  if (TECount > 0) and (CLCount > 0) then
    Exit(H1Refuse(400, 'Content-Length together with Transfer-Encoding'));
  AHead.Framing := bfNone;
  AHead.ContentLength := 0;
  if TECount > 0 then
  begin
    if TECount > 1 then
      Exit(H1Refuse(400, 'more than one Transfer-Encoding field'));
    if ARequest.Minor = 0 then
      Exit(H1Refuse(400, 'Transfer-Encoding in an HTTP/1.0 request'));
    TEValue := LowerRaw(TEValue);
    Chunked := TEValue = 'chunked';
    if not Chunked then
    begin
      if TEValue = '' then
        Exit(H1Refuse(400, 'an empty Transfer-Encoding'));
      // only the single value chunked is accepted. A list that holds chunked,
      // chunked with parameters, or a coding before chunked is refused as a
      // malformed message. A coding that the server does not know is 501
      if Pos('chunked', TEValue) > 0 then
        Exit(H1Refuse(400, 'chunked is not the only transfer coding'));
      Exit(H1Refuse(501, 'an unknown transfer coding'));
    end;
    AHead.Framing := bfChunked;
    if ALimits.MaxBodySize = 0 then
      Exit(H1Refuse(413, 'the server accepts no request body'));
  end
  else if CLCount > 0 then
  begin
    if CLCount > 1 then
      Exit(H1Refuse(400, 'more than one Content-Length field'));
    if not IsDigits(CLValue) then
      Exit(H1Refuse(400, 'Content-Length is not 1*DIGIT'));
    // more than 18 digits cannot fit in 63 bits: refuse without a conversion
    if Length(CLValue) > 18 then
    begin
      I := 1;
      while (I < Length(CLValue)) and (CLValue[I] = '0') do
        Inc(I);
      if Length(CLValue) - I + 1 > 18 then
        Exit(H1Refuse(413, 'Content-Length is too large'));
    end;
    Len := StrToInt64(string(CLValue));
    if Len > ALimits.MaxBodySize then
      Exit(H1Refuse(413, 'Content-Length is over the body limit'));
    if Len > 0 then
    begin
      AHead.Framing := bfLength;
      AHead.ContentLength := Len;
    end;
  end;

  // Host (RFC 9112 section 3.2)
  if ARequest.Minor = 1 then
  begin
    if HostCount <> 1 then
      Exit(H1Refuse(400, 'an HTTP/1.1 request needs exactly one Host field'));
  end
  else if HostCount > 1 then
    Exit(H1Refuse(400, 'more than one Host field'));
  if HostCount = 1 then
  begin
    if (HostValue = '') and (ARequest.TargetAuthority = '') then
      Exit(H1Refuse(400, 'the Host field is empty'));
    if (HostValue <> '') and not ValidHost(HostValue) then
      Exit(H1Refuse(400, 'the Host field is not valid'));
  end;
  if ARequest.TargetAuthority <> '' then
    AHead.Authority := ARequest.TargetAuthority
  else
    AHead.Authority := BytesToStr(HostValue);

  // Expect (RFC 9110 section 10.1.1)
  if (ExpectCount > 0) and (ARequest.Minor = 1) then
  begin
    for I := 0 to High(Fields) do
      if Fields[I].Name = 'expect' then
      begin
        if LowerRaw(Fields[I].Value) <> '100-continue' then
          Exit(H1Refuse(417, 'an expectation other than 100-continue'));
        AHead.Expect100 := True;
      end;
  end;

  // persistence (RFC 9112 section 9.3)
  if ARequest.Minor = 1 then
    AHead.KeepAlive := not Close_
  else
    AHead.KeepAlive := Keep and not Close_;

  AHead.WebSocketUpgrade := (ARequest.Minor = 1) and (ARequest.Method = 'GET') and
    Upgrade_ and UpgradeWs;

  // the fields that a handler sees: the hop-by-hop fields stay with the server
  for I := 0 to High(Fields) do
  begin
    Drop := (Fields[I].Name = 'connection') or (Fields[I].Name = 'keep-alive') or
      (Fields[I].Name = 'proxy-connection') or (Fields[I].Name = 'transfer-encoding') or
      (Fields[I].Name = 'upgrade') or (Fields[I].Name = 'host') or
      (Fields[I].Name = 'expect');
    if Drop then
      Continue;
    J := Length(AHead.Fields);
    SetLength(AHead.Fields, J + 1);
    AHead.Fields[J].Name := BytesToStr(Fields[I].Name);
    AHead.Fields[J].Value := BytesToStr(Fields[I].Value);
    AHead.Fields[J].Sensitive := False;
  end;
  Result := H1Ok;
end;

function H1CheckChunkLine(const ALine: RawByteString;
  const ALimits: THttp11Limits; out ASize: Int64): TH1Verdict;
var
  I, N, A: Integer;
  Ext, Name, Val: RawByteString;
  Semi: Integer;

  function HexVal(const C: AnsiChar): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - 48;
      'a'..'f': Result := Ord(C) - 87;
      'A'..'F': Result := Ord(C) - 55;
    else
      Result := -1;
    end;
  end;

  function SkipBws(var P: Integer; const S: RawByteString): Boolean;
  begin
    while (P <= Length(S)) and (S[P] in [' ', #9]) do
      Inc(P);
    Result := True;
  end;

begin
  ASize := 0;
  N := 0;
  I := 1;
  while (I <= Length(ALine)) and (HexVal(ALine[I]) >= 0) do
  begin
    Inc(N);
    // 15 hex digits is far above any limit and still fits in 63 bits
    if N > 15 then
      Exit(H1Refuse(413, 'the chunk size is too large'));
    ASize := ASize * 16 + HexVal(ALine[I]);
    Inc(I);
  end;
  if N = 0 then
    Exit(H1Refuse(400, 'the chunk size line has no hex digits'));
  if ASize > ALimits.MaxChunkSize then
    Exit(H1Refuse(413, 'the chunk is over the chunk size limit'));
  // the rest: BWS, then optional extensions
  A := I;
  SkipBws(A, ALine);
  if A > Length(ALine) then
    Exit(H1Ok);
  if ALine[A] <> ';' then
    Exit(H1Refuse(400, 'garbage after the chunk size'));
  Ext := Copy(ALine, A, MaxInt);
  if Length(Ext) > ALimits.MaxChunkExtension then
    Exit(H1Refuse(400, 'the chunk extension is too long'));
  // chunk-ext = *( BWS ';' BWS name [ BWS '=' BWS ( token / quoted-string ) ] )
  I := A;
  while I <= Length(ALine) do
  begin
    if ALine[I] <> ';' then
      Exit(H1Refuse(400, 'a malformed chunk extension'));
    Inc(I);
    SkipBws(I, ALine);
    Semi := I;
    while (I <= Length(ALine)) and H1IsTokenChar(ALine[I]) do
      Inc(I);
    Name := Copy(ALine, Semi, I - Semi);
    if Name = '' then
      Exit(H1Refuse(400, 'a chunk extension with no name'));
    A := I;
    SkipBws(A, ALine);
    if (A <= Length(ALine)) and (ALine[A] = '=') then
    begin
      Inc(A);
      SkipBws(A, ALine);
      if (A <= Length(ALine)) and (ALine[A] = '"') then
      begin
        Inc(A);
        while (A <= Length(ALine)) and (ALine[A] <> '"') do
        begin
          if ALine[A] = '\' then
            Inc(A);
          Inc(A);
        end;
        if A > Length(ALine) then
          Exit(H1Refuse(400, 'an unterminated quoted string in a chunk extension'));
        Inc(A);
        Val := 'q';
      end
      else
      begin
        Semi := A;
        while (A <= Length(ALine)) and H1IsTokenChar(ALine[A]) do
          Inc(A);
        Val := Copy(ALine, Semi, A - Semi);
      end;
      if Val = '' then
        Exit(H1Refuse(400, 'a chunk extension with an empty value'));
      I := A;
      SkipBws(I, ALine);
    end
    else
      I := A;
    if (I <= Length(ALine)) and (ALine[I] <> ';') then
      Exit(H1Refuse(400, 'a malformed chunk extension'));
  end;
  Result := H1Ok;
end;

function H1CheckTrailer(const ARaw: RawByteString;
  const ALimits: THttp11Limits): TH1Verdict;
var
  Fields: TArray<TRawField>;
  Limits: THttp11Limits;
begin
  if Length(ARaw) > ALimits.MaxTrailerOctets then
    Exit(H1Refuse(431, 'the trailer section is too large'));
  // the same field syntax as the header section; the fields are dropped
  Limits := ALimits.WithMaxHeaderOctets(ALimits.MaxTrailerOctets);
  Result := SplitFields(ARaw, Limits, Fields);
end;

end.
