{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: sse, server-sent events, encoder, whatwg, injection
notes:
  - This unit encodes one server-sent event or one comment into bytes. It holds
    no socket and no thread.
  - The rules are those of the WHATWG HTML Living Standard, section 9.2 (the
    plain-text copy is doc/references/whatwg-html-server-sent-events.txt).
  - The format has no escape. A line break in a field value would end the line,
    so the encoder splits the data at every break and rejects a break in every
    other value. A caller can then not inject a field or a blank line.
  - A default-initialised TSseEvent writes one empty data field. The Retry value
    0 means that no retry field is written.
---
}
/// Server-sent event encoder (WHATWG HTML section 9.2)
unit Http2Server.Sse.Encoder;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2Server.Errors;

const
  /// the greatest value of a retry field: one day in milliseconds
  cSseMaxRetryMs = 24 * 60 * 60 * 1000;

type
  /// a value that the format cannot carry
  ESseError = class(EHttpError);

  /// one event
  // - Id and Event are UTF-8 text; Data is UTF-8 bytes
  TSseEvent = record
    /// the last event ID; empty writes no id field
    Id: UTF8String;
    /// the event type; empty writes no event field
    Event: UTF8String;
    /// the data; every line break starts a new data field, and empty data
    /// writes one empty data field
    Data: TBytes;
    /// the reconnection time in milliseconds; 0 writes no retry field
    Retry: Integer;
    /// an event with the given text as data
    class function Text(const AData: UTF8String): TSseEvent; static;
  end;

/// the bytes of one event, ended by a blank line
// - raises ESseError for a CR or LF in Id or Event, a NUL in Id, a NUL in the
//   data, text that is not UTF-8, or a Retry that is negative or over the cap
function SseEncodeEvent(const AEvent: TSseEvent): TBytes;

/// the bytes of one comment: a colon, a space and the text
// - raises ESseError for a CR, LF or text that is not UTF-8
function SseEncodeComment(const AText: UTF8String): TBytes;

/// a Last-Event-ID header value made safe
// - answers an empty text when the value is not UTF-8 or holds CR, LF or NUL
function SseCleanLastEventId(const AValue: string): UTF8String;

implementation

uses
  Http2Server.Ws.Utf8;

class function TSseEvent.Text(const AData: UTF8String): TSseEvent;
begin
  Result.Id := '';
  Result.Event := '';
  Result.Retry := 0;
  SetLength(Result.Data, Length(AData));
  if Length(AData) > 0 then
    Move(AData[1], Result.Data[0], Length(AData));
end;

function IsUtf8(const AText: RawByteString): Boolean;
begin
  if AText = '' then
    Exit(True);
  Result := WsUtf8IsValid(AText[1], Length(AText));
end;

function HasByte(const AText: RawByteString; const AByte: Byte): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(AText) do
    if Byte(AText[I]) = AByte then
      Exit(True);
end;

function HasBreak(const AText: RawByteString): Boolean;
begin
  Result := HasByte(AText, 10) or HasByte(AText, 13);
end;

function SseEncodeEvent(const AEvent: TSseEvent): TBytes;
var
  Out_, Data: RawByteString;
  I, Start: Integer;

  procedure AddField(const AName: RawByteString; const AValue: RawByteString);
  begin
    if AValue = '' then
      Out_ := Out_ + AName + ':'#10
    else
      Out_ := Out_ + AName + ': ' + AValue + #10;
  end;

begin
  Result := nil;
  if (AEvent.Retry < 0) or (AEvent.Retry > cSseMaxRetryMs) then
    raise ESseError.Create('an SSE retry value is outside 0 to one day');
  if HasBreak(AEvent.Id) or HasByte(AEvent.Id, 0) then
    raise ESseError.Create('an SSE id holds CR, LF or NUL');
  if HasBreak(AEvent.Event) then
    raise ESseError.Create('an SSE event type holds CR or LF');
  if (not IsUtf8(AEvent.Id)) or (not IsUtf8(AEvent.Event)) then
    raise ESseError.Create('an SSE id or event type is not UTF-8');
  SetLength(Data, Length(AEvent.Data));
  if Length(AEvent.Data) > 0 then
    Move(AEvent.Data[0], Data[1], Length(AEvent.Data));
  if HasByte(Data, 0) then
    raise ESseError.Create('SSE data holds NUL');
  if not IsUtf8(Data) then
    raise ESseError.Create('SSE data is not UTF-8');

  Out_ := '';
  if AEvent.Retry > 0 then
    Out_ := Out_ + 'retry: ' + RawByteString(IntToStr(AEvent.Retry)) + #10;
  if AEvent.Id <> '' then
    AddField('id', AEvent.Id);
  if AEvent.Event <> '' then
    AddField('event', AEvent.Event);

  // split the data at CR, LF and CRLF; the last part follows the last break,
  // so data that ends with a break writes a final empty data field
  Start := 1;
  I := 1;
  while I <= Length(Data) do
  begin
    if (Data[I] = #10) or (Data[I] = #13) then
    begin
      AddField('data', Copy(Data, Start, I - Start));
      if (Data[I] = #13) and (I < Length(Data)) and (Data[I + 1] = #10) then
        Inc(I);
      Start := I + 1;
    end;
    Inc(I);
  end;
  AddField('data', Copy(Data, Start, Length(Data) - Start + 1));
  Out_ := Out_ + #10;

  SetLength(Result, Length(Out_));
  Move(Out_[1], Result[0], Length(Out_));
end;

function SseEncodeComment(const AText: UTF8String): TBytes;
var
  S: RawByteString;
begin
  Result := nil;
  if HasBreak(AText) then
    raise ESseError.Create('an SSE comment holds CR or LF');
  if not IsUtf8(AText) then
    raise ESseError.Create('an SSE comment is not UTF-8');
  // the blank line after the comment dispatches nothing, and it lets a proxy
  // that reads whole events pass the comment on
  S := ': ' + RawByteString(AText) + #10#10;
  SetLength(Result, Length(S));
  Move(S[1], Result[0], Length(S));
end;

function SseCleanLastEventId(const AValue: string): UTF8String;
var
  S: RawByteString;
begin
  S := RawByteString(AValue);
  if HasBreak(S) or HasByte(S, 0) or (not IsUtf8(S)) then
    Exit('');
  Result := UTF8String(S);
end;

end.
