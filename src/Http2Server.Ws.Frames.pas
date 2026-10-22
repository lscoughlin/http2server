{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, rfc 6455, frames, masking, close codes, encoder
notes:
  - This unit holds the frame constants, the mask, the frame encoder and the
    close-payload helpers of RFC 6455. It has no socket, no thread and no mORMot2
    dependency.
  - The mask routine and the close helpers derive from the client unit
    Http2.WebSocket of the sibling repository ../http2client at revision
    dd45cdd. The mORMot2 routine ProcessMask (mormot.net.ws.core.pas, revision
    b2b195da1) is the model of the word-wise loop.
  - The close-code set follows the IANA registry "WebSocket Close Code Number
    Registry" (retrieved 2026-10-22) and not the client unit, which refuses the
    assigned codes 1012 to 1014.
---
}
/// WebSocket frame constants, masking, encoding and close payloads (RFC 6455)
// - the server sends unmasked frames; the masked encoder serves tests and a
//   later client
unit Http2Server.Ws.Frames;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2Server.Errors;

const
  /// frame opcodes (RFC 6455 section 5.2)
  WsOpContinuation = $0;
  WsOpText         = $1;
  WsOpBinary       = $2;
  WsOpClose        = $8;
  WsOpPing         = $9;
  WsOpPong         = $A;

  /// close status codes (RFC 6455 section 7.4.1)
  WsCloseNormal        = 1000;
  WsCloseGoingAway     = 1001;
  WsCloseProtocolError = 1002;
  WsCloseUnsupported   = 1003;
  /// never on the wire: no status code was present
  WsCloseNoStatus      = 1005;
  /// never on the wire: the connection closed without a Close frame
  WsCloseAbnormal      = 1006;
  WsCloseBadData       = 1007;
  WsClosePolicy        = 1008;
  WsCloseTooBig        = 1009;
  WsCloseInternal      = 1011;
  WsCloseRestart       = 1012;
  WsCloseTryAgain      = 1013;

  /// the longest payload of a control frame (RFC 6455 section 5.5)
  WsMaxControlPayload = 125;
  /// the longest reason of a Close frame: 125 minus the two octets of the code
  WsMaxCloseReason = 123;

type
  /// the four octets of a masking key, in wire order
  TWsMaskKey = array[0..3] of Byte;

  /// why a stream of frames failed: the close code to send and a short text
  TWsFailure = record
    Code: Word;
    Reason: string;
  end;

/// true for a code that a peer may put in a Close frame on the wire
// - 1000 to 1003, 1007 to 1014, 3000 to 4999 (the IANA registry); 1004, 1005,
//   1006, 1015 and the unassigned ranges are not on the wire
function WsCloseCodeValid(const ACode: Integer): Boolean;

/// true for a code that this server sends: the valid set without 1010
// - 1010 (mandatory extension) is a client code
function WsCloseCodeSendable(const ACode: Integer): Boolean;

/// the masking key of four octets from a 32-bit value, first octet most significant
function WsMaskKeyFromLongWord(const AValue: LongWord): TWsMaskKey;

/// XOR ABuffer[0..ACount-1] with the key, starting at key index APhase mod 4
// - the same call masks and unmasks; the phase keeps a frame body that arrives
//   in pieces in step with the key
procedure WsApplyMask(const AKey: TWsMaskKey; var ABuffer;
  const ACount: Integer; const APhase: Integer = 0);

/// the header of a frame: the shortest form of the length (RFC 6455 section 5.2)
// - AMasked adds the four octets of AKey after the length
function WsEncodeHeader(const AOpcode: Byte; const AFin: Boolean;
  const APayloadLength: UInt64; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;

/// a whole frame; AMasked masks a copy of the payload
function WsEncodeFrame(const AOpcode: Byte; const AFin: Boolean;
  const APayload: TBytes; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;

/// one message as a run of frames of at most AFrameSize payload octets
// - the first frame carries AOpcode (text or binary), the others are continuation
//   frames, and the last has FIN. An empty message is one empty frame.
// - the frames are not masked, as a server sends them
function WsEncodeMessage(const AOpcode: Byte; const AData: TBytes;
  const AFrameSize: Integer): TBytes;

/// the payload of a Close frame
// - raises EHttpError for a code that is not sendable or a reason over 123 octets
function WsBuildClosePayload(const ACode: Integer;
  const AReason: RawByteString): TBytes;

/// split a Close payload (RFC 6455 section 5.5.1)
// - an empty payload is code 1005 and an empty reason
// - answers an empty failure (Code 0) when the payload is valid; else Code 1002
//   (one octet, or a code that is not on the wire) or 1007 (a reason that is not
//   UTF-8)
function WsParseClosePayload(const APayload: TBytes; out ACode: Integer;
  out AReason: RawByteString): TWsFailure;

implementation

uses
  Http2Server.Ws.Utf8;

function WsCloseCodeValid(const ACode: Integer): Boolean;
begin
  Result := ((ACode >= 1000) and (ACode <= 1003)) or
    ((ACode >= 1007) and (ACode <= 1014)) or
    ((ACode >= 3000) and (ACode <= 4999));
end;

function WsCloseCodeSendable(const ACode: Integer): Boolean;
begin
  Result := WsCloseCodeValid(ACode) and (ACode <> 1010);
end;

function WsMaskKeyFromLongWord(const AValue: LongWord): TWsMaskKey;
begin
  Result[0] := Byte(AValue shr 24);
  Result[1] := Byte(AValue shr 16);
  Result[2] := Byte(AValue shr 8);
  Result[3] := Byte(AValue);
end;

procedure WsApplyMask(const AKey: TWsMaskKey; var ABuffer;
  const ACount: Integer; const APhase: Integer);
var
  P: PByte;
  K: TWsMaskKey;
  Word32, Mask32: LongWord;
  I, Ph: Integer;
begin
  if ACount <= 0 then
    Exit;
  Ph := APhase and 3;
  // rotate the key so that K[0] lines up with the first octet of the buffer
  for I := 0 to 3 do
    K[I] := AKey[(I + Ph) and 3];
  Move(K[0], Mask32, 4);
  P := @ABuffer;
  I := 0;
  while I + 4 <= ACount do
  begin
    Move(P^, Word32, 4);
    Word32 := Word32 xor Mask32;
    Move(Word32, P^, 4);
    Inc(P, 4);
    Inc(I, 4);
  end;
  Ph := 0;
  while I < ACount do
  begin
    P^ := P^ xor K[Ph];
    Inc(P);
    Inc(I);
    Inc(Ph);
  end;
end;

function WsEncodeHeader(const AOpcode: Byte; const AFin: Boolean;
  const APayloadLength: UInt64; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;
var
  Head, Mask, I, P: Integer;
begin
  Result := nil;
  if APayloadLength > UInt64($7FFFFFFFFFFFFFFF) then
    raise EHttpError.Create('a WebSocket payload length has its top bit set');
  if APayloadLength <= 125 then
    Head := 2
  else if APayloadLength <= 65535 then
    Head := 4
  else
    Head := 10;
  if AMasked then
    Mask := 4
  else
    Mask := 0;
  SetLength(Result, Head + Mask);
  Result[0] := AOpcode and $0F;
  if AFin then
    Result[0] := Result[0] or $80;
  if Head = 2 then
    Result[1] := Byte(APayloadLength)
  else if Head = 4 then
  begin
    Result[1] := 126;
    Result[2] := Byte(APayloadLength shr 8);
    Result[3] := Byte(APayloadLength);
  end
  else
  begin
    Result[1] := 127;
    for I := 0 to 7 do
      Result[2 + I] := Byte(APayloadLength shr ((7 - I) * 8));
  end;
  if AMasked then
  begin
    Result[1] := Result[1] or $80;
    P := Head;
    Move(AKey[0], Result[P], 4);
  end;
end;

function WsEncodeFrame(const AOpcode: Byte; const AFin: Boolean;
  const APayload: TBytes; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;
var
  Head: TBytes;
  Body: TBytes;
begin
  Result := nil;
  Head := WsEncodeHeader(AOpcode, AFin, Length(APayload), AMasked, AKey);
  Body := Copy(APayload);
  if AMasked and (Length(Body) > 0) then
    WsApplyMask(AKey, Body[0], Length(Body), 0);
  SetLength(Result, Length(Head) + Length(Body));
  Move(Head[0], Result[0], Length(Head));
  if Length(Body) > 0 then
    Move(Body[0], Result[Length(Head)], Length(Body));
end;

function WsEncodeMessage(const AOpcode: Byte; const AData: TBytes;
  const AFrameSize: Integer): TBytes;
var
  Key: TWsMaskKey;
  Frames, At, N, Op, Total, Head: Integer;
  Frame: TBytes;
  Last: Boolean;
begin
  Result := nil;
  Key := WsMaskKeyFromLongWord(0);
  if AFrameSize < 1 then
    raise EHttpError.Create('the WebSocket frame size is below 1');
  if Length(AData) = 0 then
    Exit(WsEncodeFrame(AOpcode, True, nil, False, Key));
  Frames := (Length(AData) + AFrameSize - 1) div AFrameSize;
  // the size is known: each frame adds a header of 2, 4 or 10 octets
  Total := 0;
  At := 0;
  Result := nil;
  SetLength(Result, 0);
  while At < Length(AData) do
  begin
    N := Length(AData) - At;
    if N > AFrameSize then
      N := AFrameSize;
    Last := At + N >= Length(AData);
    if At = 0 then
      Op := AOpcode
    else
      Op := WsOpContinuation;
    Frame := WsEncodeFrame(Op, Last, Copy(AData, At, N), False, Key);
    Head := Total;
    SetLength(Result, Total + Length(Frame));
    Move(Frame[0], Result[Head], Length(Frame));
    Inc(Total, Length(Frame));
    Inc(At, N);
    Dec(Frames);
  end;
end;

function WsBuildClosePayload(const ACode: Integer;
  const AReason: RawByteString): TBytes;
begin
  Result := nil;
  if not WsCloseCodeSendable(ACode) then
    raise EHttpError.CreateFmt('the close code %d is not sendable', [ACode]);
  if Length(AReason) > WsMaxCloseReason then
    raise EHttpError.Create('a close reason is over 123 octets');
  SetLength(Result, 2 + Length(AReason));
  Result[0] := Byte(ACode shr 8);
  Result[1] := Byte(ACode);
  if Length(AReason) > 0 then
    Move(AReason[1], Result[2], Length(AReason));
end;

function WsParseClosePayload(const APayload: TBytes; out ACode: Integer;
  out AReason: RawByteString): TWsFailure;
begin
  Result.Code := 0;
  Result.Reason := '';
  AReason := '';
  ACode := WsCloseNoStatus;
  if Length(APayload) = 0 then
    Exit;
  if Length(APayload) = 1 then
  begin
    Result.Code := WsCloseProtocolError;
    Result.Reason := 'a Close payload of one octet';
    Exit;
  end;
  ACode := (Integer(APayload[0]) shl 8) or APayload[1];
  if not WsCloseCodeValid(ACode) then
  begin
    Result.Code := WsCloseProtocolError;
    Result.Reason := 'a close code that is not on the wire';
    Exit;
  end;
  if Length(APayload) > 2 then
  begin
    if not WsUtf8IsValid(APayload[2], Length(APayload) - 2) then
    begin
      Result.Code := WsCloseBadData;
      Result.Reason := 'a close reason that is not UTF-8';
      Exit;
    end;
    SetLength(AReason, Length(APayload) - 2);
    Move(APayload[2], AReason[1], Length(APayload) - 2);
  end;
end;

end.
