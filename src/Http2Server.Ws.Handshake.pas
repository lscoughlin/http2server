{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, handshake, accept key, subprotocol, origin, tokens, rfc 6455, rfc 7936
notes:
  - This unit holds the parts of the WebSocket handshake that do not depend on the
    protocol under it. These are the accept key, the check of the key, the lists of
    tokens in a field, the choice of the subprotocol and the check of the origin.
  - The accept key is base64(SHA-1(key + GUID)) with the GUID of RFC 6455 section 1.3.
    The RFC gives the test vector dGhlIHNhbXBsZSBub25jZQ== for s3pPLMBiTxaQ9kYGzzhZRbK+xOo=.
    SHA-1 and base64 come from mORMot2.
  - A subprotocol is matched as a case-sensitive token (RFC 6455 section 4.2.2 and
    RFC 7936). RFC 6455 and RFC 7936 were checked on 2026-10-22 at
    https://www.rfc-editor.org/info/rfc6455 and https://www.rfc-editor.org/info/rfc7936.
---
}
/// The protocol-neutral part of the WebSocket handshake
unit Http2Server.Ws.Handshake;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2Server.Hpack, Http2Server.Ws.Options, Http2Server.Ws.Origin;

const
  /// the GUID that RFC 6455 section 1.3 adds to the key
  cWsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// the Sec-WebSocket-Accept value for a Sec-WebSocket-Key value
function WsAcceptKey(const AKey: string): string;

/// true when AKey is base64 of exactly 16 octets (RFC 6455 section 4.2.1)
function WsKeyIsValid(const AKey: string): Boolean;

/// the values of every field of AName, split at commas, with white space trimmed
// - empty members are dropped
function WsFieldTokens(const AHeaders: THeaderBlock; const AName: string): TArray<string>;

/// true when AList holds AToken; the compare is case-sensitive when ACase is set
function WsHasToken(const AList: TArray<string>; const AToken: string;
  const ACase: Boolean = False): Boolean;

/// the first value of the field AName, or an empty text
function WsFirstField(const AHeaders: THeaderBlock; const AName: string): string;

/// how many fields of that name the block holds
function WsFieldCount(const AHeaders: THeaderBlock; const AName: string): Integer;

/// the subprotocols that the client offered and the server accepts
// - the client list is in Sec-WebSocket-Protocol. When the server list is empty,
//   every offered token is passed on, so the application chooses; else only the
//   tokens that the server list holds are passed on, in the order of the client
function WsOfferedSubprotocols(const AHeaders: THeaderBlock;
  const AServerList: TArray<string>): TArray<string>;

/// the verdict of the origin policy for the fields of an upgrade request
function WsCheckUpgradeOrigin(const AOptions: TWsOptions; const AScheme, AAuthority: string;
  const AHeaders: THeaderBlock): TWsOriginVerdict;

implementation

uses
  mormot.core.base, mormot.core.buffers, mormot.crypt.core;

function WsAcceptKey(const AKey: string): string;
var
  Sha: TSha1;
  Digest: TSha1Digest;
  Raw: RawByteString;
begin
  Raw := RawByteString(Trim(AKey) + cWsGuid);
  Sha.Full(PAnsiChar(Raw), Length(Raw), Digest);
  SetString(Raw, PAnsiChar(@Digest), SizeOf(Digest));
  Result := string(BinToBase64(Raw));
end;

function WsKeyIsValid(const AKey: string): Boolean;
var
  S: string;
  Bin: RawByteString;
begin
  S := Trim(AKey);
  // 16 octets encode as 24 characters of base64 with two padding characters
  if (Length(S) <> 24) or (Copy(S, 23, 2) <> '==') then
    Exit(False);
  Bin := Base64ToBin(RawByteString(S));
  Result := Length(Bin) = 16;
end;

function WsFieldTokens(const AHeaders: THeaderBlock; const AName: string): TArray<string>;
var
  I, A, J, N: Integer;
  V, Item: string;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
    begin
      V := AHeaders[I].Value;
      A := 1;
      for J := 1 to Length(V) + 1 do
        if (J > Length(V)) or (V[J] = ',') then
        begin
          Item := Trim(Copy(V, A, J - A));
          if Item <> '' then
          begin
            SetLength(Result, N + 1);
            Result[N] := Item;
            Inc(N);
          end;
          A := J + 1;
        end;
    end;
end;

function WsHasToken(const AList: TArray<string>; const AToken: string;
  const ACase: Boolean): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if (ACase and (AList[I] = AToken)) or ((not ACase) and SameText(AList[I], AToken)) then
      Exit(True);
  Result := False;
end;

function WsFirstField(const AHeaders: THeaderBlock; const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
      Exit(AHeaders[I].Value);
  Result := '';
end;

function WsFieldCount(const AHeaders: THeaderBlock; const AName: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
      Inc(Result);
end;

function WsOfferedSubprotocols(const AHeaders: THeaderBlock;
  const AServerList: TArray<string>): TArray<string>;
var
  Client: TArray<string>;
  I, N: Integer;
begin
  Client := WsFieldTokens(AHeaders, 'sec-websocket-protocol');
  if Length(AServerList) = 0 then
    Exit(Client);
  Result := nil;
  N := 0;
  for I := 0 to High(Client) do
    if WsHasToken(AServerList, Client[I], {ACase=}True) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Client[I];
      Inc(N);
    end;
end;

function WsCheckUpgradeOrigin(const AOptions: TWsOptions; const AScheme, AAuthority: string;
  const AHeaders: THeaderBlock): TWsOriginVerdict;
var
  Values: TArray<string>;
  I, N: Integer;
begin
  Values := nil;
  N := 0;
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, 'origin') then
    begin
      SetLength(Values, N + 1);
      Values[N] := AHeaders[I].Value;
      Inc(N);
    end;
  Result := WsCheckOrigin(AOptions.OriginPolicy, AOptions.AllowedOrigins, AScheme,
    AAuthority, Values);
end;

end.
