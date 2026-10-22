{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, origin, same-origin, allow-list, rfc 6454, cross-site
notes:
  - This unit decides whether the Origin header of an upgrade request passes the
    origin policy of the server. It has no socket and no state.
  - RFC 6454 defines the origin (scheme, host, port) and the Origin header (section
    7). It gives a server no rule, so each rule here is a policy choice that the
    document doc/design/websocket.md states. The RFC was checked on 2026-10-22 at
    https://www.rfc-editor.org/info/rfc6454.
  - The server builds its own origin from the transport scheme and from the Host
    field or the authority of the request. It compares the full triple, not the
    registered domain, and does no IDNA mapping.
  - A request without an Origin field passes every policy, because a client that is
    not a browser sends none. The check protects against a browser of another
    origin and nothing else.
---
}
/// The origin policy of a WebSocket upgrade
unit Http2Server.Ws.Origin;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// what the server does with the Origin field of an upgrade request
  TWsOriginPolicy = (
    /// the origin is absent, or equals the origin of the server (the default)
    opSameOrAbsent,
    /// as opSameOrAbsent, and an origin from the allow-list passes too
    opAllowList,
    /// the origin is absent, or is in the allow-list; the origin of the server
    /// passes only when the list holds it
    opAllowListOnly,
    /// every origin passes
    opAny,
    /// the server makes no check; the application decides in Init
    opNone);

  /// the answer of the origin check
  TWsOriginVerdict = record
    Accept: Boolean;
    /// the status for a refusal: 403, or 400 for a value that is not an origin
    Status: Integer;
    Reason: string;
  end;

  /// an origin as a triple
  TWsOrigin = record
    Scheme: string;
    Host: string;
    Port: Integer;
  end;

/// parse one serialized origin (RFC 6454 section 7.1), with the lower case rules
// - answers False for any value that is not a scheme, '://', a host and a port
function WsParseOrigin(const AText: string; out AOrigin: TWsOrigin): Boolean;

/// the default port of a scheme; 0 for another scheme
function WsDefaultPort(const AScheme: string): Integer;

/// the origin of the server from the transport scheme and the authority
// - AAuthority is the Host field or the :authority value, with an optional port
function WsServerOrigin(const AScheme, AAuthority: string;
  out AOrigin: TWsOrigin): Boolean;

/// the verdict of the policy
// - AOriginValues holds the values of the Origin fields of the request, one entry
//   for each field; more than one field is refused
function WsCheckOrigin(const APolicy: TWsOriginPolicy;
  const AAllowed: TArray<string>; const AScheme, AAuthority: string;
  const AOriginValues: TArray<string>): TWsOriginVerdict;

implementation

uses
  SysUtils;

function WsDefaultPort(const AScheme: string): Integer;
begin
  if AScheme = 'http' then
    Result := 80
  else if AScheme = 'https' then
    Result := 443
  else
    Result := 0;
end;

function Lower(const AText: string): string;
var
  I: Integer;
begin
  Result := AText;
  for I := 1 to Length(Result) do
    if (Result[I] >= 'A') and (Result[I] <= 'Z') then
      Result[I] := Chr(Ord(Result[I]) + 32);
end;

function IsDigits(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := AText <> '';
  for I := 1 to Length(AText) do
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit(False);
end;

/// split 'host[:port]' of an authority; the host may be a bracketed IPv6 literal
function SplitHostPort(const AText: string; out AHost, APort: string;
  out AHasPort: Boolean): Boolean;
var
  P: Integer;
begin
  Result := False;
  AHasPort := False;
  APort := '';
  if AText = '' then
    Exit;
  if AText[1] = '[' then
  begin
    P := Pos(']', AText);
    if P < 3 then
      Exit;
    AHost := Copy(AText, 1, P);
    if P < Length(AText) then
    begin
      if AText[P + 1] <> ':' then
        Exit;
      AHasPort := True;
      APort := Copy(AText, P + 2, MaxInt);
    end;
    Exit(True);
  end;
  P := Pos(':', AText);
  if P = 0 then
    AHost := AText
  else
  begin
    AHost := Copy(AText, 1, P - 1);
    AHasPort := True;
    APort := Copy(AText, P + 1, MaxInt);
  end;
  Result := AHost <> '';
end;

function ValidHostText(const AHost: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := AHost <> '';
  for I := 1 to Length(AHost) do
  begin
    C := AHost[I];
    // ASCII only (an A-label, never a raw Unicode host), and no character that
    // would end the authority or start userinfo, a path, a query or a fragment
    if (C <= ' ') or (C >= #127) or (C in ['/', '?', '#', '@', ',', '\', '"', '<', '>', '|', '^', '`', '{', '}']) then
      Exit(False);
  end;
end;

function ParsePort(const APort: string; const AScheme: string; out AValue: Integer): Boolean;
begin
  Result := False;
  AValue := 0;
  if not IsDigits(APort) then
    Exit;
  // no leading zero (RFC 3986 allows it, a user agent never writes it), and at
  // most 65535
  if (Length(APort) > 1) and (APort[1] = '0') then
    Exit;
  if Length(APort) > 5 then
    Exit;
  AValue := StrToInt(APort);
  Result := AValue <= 65535;
end;

function WsParseOrigin(const AText: string; out AOrigin: TWsOrigin): Boolean;
var
  P, I: Integer;
  Scheme, Rest, Host, PortText: string;
  HasPort: Boolean;
begin
  AOrigin := Default(TWsOrigin);
  Result := False;
  P := Pos('://', AText);
  if P < 2 then
    Exit;
  Scheme := Lower(Copy(AText, 1, P - 1));
  Rest := Copy(AText, P + 3, MaxInt);
  // scheme = ALPHA *( ALPHA / DIGIT / '+' / '-' / '.' )
  if not (Scheme[1] in ['a'..'z']) then
    Exit;
  for I := 2 to Length(Scheme) do
    if not (Scheme[I] in ['a'..'z', '0'..'9', '+', '-', '.']) then
      Exit;
  if not SplitHostPort(Rest, Host, PortText, HasPort) then
    Exit;
  Host := Lower(Host);
  if not ValidHostText(Host) then
    Exit;
  if HasPort then
  begin
    if not ParsePort(PortText, Scheme, AOrigin.Port) then
      Exit;
  end
  else
    AOrigin.Port := WsDefaultPort(Scheme);
  AOrigin.Scheme := Scheme;
  AOrigin.Host := Host;
  Result := True;
end;

function WsServerOrigin(const AScheme, AAuthority: string; out AOrigin: TWsOrigin): Boolean;
var
  Host, PortText: string;
  HasPort: Boolean;
begin
  AOrigin := Default(TWsOrigin);
  Result := False;
  if not SplitHostPort(Trim(AAuthority), Host, PortText, HasPort) then
    Exit;
  Host := Lower(Host);
  if not ValidHostText(Host) then
    Exit;
  if HasPort then
  begin
    if not ParsePort(PortText, AScheme, AOrigin.Port) then
      Exit;
  end
  else
    AOrigin.Port := WsDefaultPort(AScheme);
  AOrigin.Scheme := Lower(AScheme);
  AOrigin.Host := Host;
  Result := True;
end;

function SameOrigin(const A, B: TWsOrigin): Boolean;
begin
  Result := (A.Scheme = B.Scheme) and (A.Host = B.Host) and (A.Port = B.Port);
end;

function Refuse(const AStatus: Integer; const AReason: string): TWsOriginVerdict;
begin
  Result.Accept := False;
  Result.Status := AStatus;
  Result.Reason := AReason;
end;

function Allow: TWsOriginVerdict;
begin
  Result.Accept := True;
  Result.Status := 0;
  Result.Reason := '';
end;

/// the members of an Origin value after trimming OWS: 'null' or an origin list
function SplitOriginList(const AValue: string; out AMembers: TArray<string>): Boolean;
var
  S: string;
  A, I, N: Integer;
begin
  AMembers := nil;
  Result := False;
  S := AValue;
  // OWS around the value (RFC 6454 section 7.1)
  while (S <> '') and (S[1] in [' ', #9]) do
    Delete(S, 1, 1);
  while (S <> '') and (S[Length(S)] in [' ', #9]) do
    Delete(S, Length(S), 1);
  if S = '' then
    Exit;
  N := 0;
  A := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = ' ') then
    begin
      // exactly one SP between origins, so an empty member is malformed
      if I = A then
        Exit;
      Inc(N);
      SetLength(AMembers, N);
      AMembers[N - 1] := Copy(S, A, I - A);
      A := I + 1;
    end;
  Result := True;
end;

function WsCheckOrigin(const APolicy: TWsOriginPolicy;
  const AAllowed: TArray<string>; const AScheme, AAuthority: string;
  const AOriginValues: TArray<string>): TWsOriginVerdict;
var
  Members: TArray<string>;
  Server, Item, Entry: TWsOrigin;
  HaveServer, InList: Boolean;
  I, J: Integer;
begin
  if (APolicy = opAny) or (APolicy = opNone) then
    Exit(Allow);
  if Length(AOriginValues) = 0 then
    Exit(Allow);   // a client that is not a browser sends none
  if Length(AOriginValues) > 1 then
    Exit(Refuse(400, 'more than one Origin field'));
  if not SplitOriginList(AOriginValues[0], Members) then
    Exit(Refuse(400, 'the Origin field is empty or malformed'));
  if (Length(Members) = 1) and (Members[0] = 'null') then
    Exit(Refuse(403, 'the origin is null'));
  HaveServer := WsServerOrigin(AScheme, AAuthority, Server);
  for I := 0 to High(Members) do
  begin
    if Members[I] = 'null' then
      Exit(Refuse(400, 'null inside a list of origins'));
    if not WsParseOrigin(Members[I], Item) then
      Exit(Refuse(400, 'the Origin field is not a list of origins'));
    InList := False;
    if APolicy in [opAllowList, opAllowListOnly] then
      for J := 0 to High(AAllowed) do
        if WsParseOrigin(AAllowed[J], Entry) and SameOrigin(Item, Entry) then
        begin
          InList := True;
          Break;
        end;
    if InList then
      Continue;
    if APolicy = opAllowListOnly then
      Exit(Refuse(403, 'the origin is not in the allow-list'));
    // the same-origin test needs an origin of the server
    if not HaveServer then
      Exit(Refuse(403, 'the server has no usable host to compare the origin with'));
    if not SameOrigin(Item, Server) then
      Exit(Refuse(403, 'the origin differs from the origin of the server'));
  end;
  Result := Allow;
end;

end.
