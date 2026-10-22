{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, utf-8, validator, incremental, rfc 6455, rfc 3629
notes:
  - This unit validates UTF-8 one buffer at a time. The state is three bytes, so
    a text message that arrives in many fragments, with a character split
    across two fragments, needs no buffer.
  - The rules are those of RFC 3629 section 4. A sequence with an overlong
    form, a surrogate or a value above U+10FFFF is invalid.
  - The ranges of the second byte follow the client unit Http2.WebSocket
    (WsUtf8Check) of the sibling repository ../http2client at revision dd45cdd.
    This unit adds the resumable state.
---
}
/// Incremental UTF-8 validation for WebSocket text
// - RFC 6455 section 8.1: invalid UTF-8 in a text message or in a close reason
//   fails the connection.
unit Http2Server.Ws.Utf8;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// the resumable state of a UTF-8 validation
  TWsUtf8Validator = record
  private
    /// continuation bytes still to come in the current sequence
    FNeed: Byte;
    /// the range of the next continuation byte
    FLo, FHi: Byte;
  public
    /// start a new text; also the state of a validator that was just declared
    procedure Reset;
    /// validate ACount more bytes
    // - False means that the bytes can never be valid UTF-8
    // - True means that they are valid so far; a sequence may stay open
    function Feed(const ABuffer; const ACount: Integer): Boolean;
    /// true when no sequence is open, so the text ends at a character boundary
    function IsComplete: Boolean;
  end;

/// true when the whole buffer is valid UTF-8
function WsUtf8IsValid(const ABuffer; const ACount: Integer): Boolean;

implementation

procedure TWsUtf8Validator.Reset;
begin
  FNeed := 0;
  FLo := $80;
  FHi := $BF;
end;

function TWsUtf8Validator.IsComplete: Boolean;
begin
  Result := FNeed = 0;
end;

function TWsUtf8Validator.Feed(const ABuffer; const ACount: Integer): Boolean;
var
  P: PByte;
  I: Integer;
  B: Byte;
begin
  Result := False;
  P := @ABuffer;
  for I := 0 to ACount - 1 do
  begin
    B := P[I];
    if FNeed > 0 then
    begin
      if (B < FLo) or (B > FHi) then
        Exit;
      // only the first continuation byte has a special range
      FLo := $80;
      FHi := $BF;
      Dec(FNeed);
      Continue;
    end;
    if B < $80 then
      Continue;
    FLo := $80;
    FHi := $BF;
    if (B >= $C2) and (B <= $DF) then
      FNeed := 1
    else if (B >= $E0) and (B <= $EF) then
    begin
      FNeed := 2;
      if B = $E0 then FLo := $A0;
      if B = $ED then FHi := $9F;
    end
    else if (B >= $F0) and (B <= $F4) then
    begin
      FNeed := 3;
      if B = $F0 then FLo := $90;
      if B = $F4 then FHi := $8F;
    end
    else
      Exit;
  end;
  Result := True;
end;

function WsUtf8IsValid(const ABuffer; const ACount: Integer): Boolean;
var
  V: TWsUtf8Validator;
begin
  V.Reset;
  Result := V.Feed(ABuffer, ACount) and V.IsComplete;
end;

end.
