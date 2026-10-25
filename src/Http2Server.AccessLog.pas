{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: access log, common log format, principal, writer
notes:
  - This unit holds the structured record of one finished request, the
    IAccessLogWriter interface that receives it, and the Apache Common Log
    Format text of a record.
  - The default writer prints one Common Log Format line to standard output.
  - The factory holds the writer. A nil writer means the server writes no log.
---
}
/// The access log of the server: the record, the writer and the text format
unit Http2Server.AccessLog;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs,
  Http2Server.Hpack;

type
  /// the structured record of one finished request
  TAccessLogRecord = record
    /// the address of the peer; an empty text when unknown
    RemoteAddress: string;
    /// the authenticated principal; an empty text when none
    Principal: string;
    /// the time the request started, in local time
    StartTime: TDateTime;
    /// the offset of StartTime from UTC in minutes, east positive
    UtcOffsetMinutes: Integer;
    Method: string;
    /// the request target as received: the path and the query
    Target: string;
    /// 'HTTP/1.0', 'HTTP/1.1' or 'HTTP/2.0'
    Protocol: string;
    /// the response status; 0 when no status was sent
    Status: Integer;
    /// the octets of the response body, without any framing
    BodyOctets: Int64;
    /// the time from the start of the handler to its return, in milliseconds
    DurationMs: Int64;
    /// the stream id of HTTP/2, or the ordinal of an HTTP/1.1 exchange
    StreamId: LongWord;
    /// the `user-agent` header of the request; an empty text when absent
    UserAgent: string;
    /// the `referer` header of the request; an empty text when absent
    Referer: string;
  end;

  /// the receiver of the access log records
  // - Write runs on a handler-pool thread, and many threads can call it at the
  //   same time, so an implementation guards its own state
  // - the record of a refused request is written on the thread that refuses it,
  //   which is an IO thread when the queue is full
  // - Write returns at once or soon: a slow writer slows the calling thread
  // - an exception of Write is caught and dropped by the server
  IAccessLogWriter = interface
    ['{7E1F0C11-00D1-4A11-9C72-000000001001}']
    procedure Write(const ARecord: TAccessLogRecord);
  end;

  /// what a response tells the access log; the server responses implement it
  IAccessLogProbe = interface
    ['{7E1F0C11-00D2-4A11-9C72-000000001002}']
    /// the status of the response headers, or 0 when none went out
    function LoggedStatus: Integer;
    /// the response body octets handed to the transport so far
    function LoggedBodyOctets: Int64;
    /// the address of the peer
    function LoggedRemoteAddress: string;
    /// the protocol text for the request line
    function LoggedProtocol: string;
  end;

  /// what the connection events use to tell an exchange the address of its peer
  IAccessLogRemoteSink = interface
    ['{7E1F0C11-00D3-4A11-9C72-000000001003}']
    procedure SetLoggedRemoteAddress(const AValue: string);
  end;

  /// the default writer: one Common Log Format line on standard output
  TStdOutAccessLogWriter = class(TInterfacedObject, IAccessLogWriter)
  private
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Write(const ARecord: TAccessLogRecord);
  end;

/// the Apache Common Log Format line of a record, without a line ending
// - the format is `%h %l %u %t "%r" %>s %b`
// - an empty value, a zero status and a zero body size appear as `-`
// - a character outside the printable ASCII range, a quote and a backslash
//   appear as \xHH escapes
function FormatCommonLog(const ARecord: TAccessLogRecord): string;

/// the user name of a `Basic` credential in the `authorization` header, or an
/// empty text when the header is absent, is not Basic or is malformed
// - the password is dropped and never copied (RFC 7617 section 2)
// - the name is not verified: a client can send any name
function BasicAuthUser(const AHeaders: THeaderBlock): string;

/// the offset of local time from UTC in minutes, east positive
function LocalUtcOffsetMinutes: Integer;

implementation

uses
  mormot.core.base, mormot.core.buffers;

const
  MonthNames: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function Escaped(const AText: string): string;
const
  Hex: string = '0123456789abcdef';
var
  I: Integer;
  C: Byte;
begin
  Result := '';
  for I := 1 to Length(AText) do
  begin
    C := Byte(AText[I]);
    if (C < $20) or (C > $7E) or (C = Ord('"')) or (C = Ord('\')) then
      Result := Result + '\x' + Hex[(C shr 4) + 1] + Hex[(C and 15) + 1]
    else
      Result := Result + AText[I];
  end;
end;

function Dash(const AText: string): string;
begin
  if AText = '' then
    Result := '-'
  else
    Result := AText;
end;

function TwoDigits(const AValue: Integer): string;
begin
  Result := IntToStr(AValue);
  if Length(Result) < 2 then
    Result := '0' + Result;
end;

function FormatTime(const ARecord: TAccessLogRecord): string;
var
  Y, M, D, H, N, S, Ms: Word;
  Offset: Integer;
  Sign: string;
begin
  DecodeDate(ARecord.StartTime, Y, M, D);
  DecodeTime(ARecord.StartTime, H, N, S, Ms);
  Offset := ARecord.UtcOffsetMinutes;
  if Offset < 0 then
  begin
    Sign := '-';
    Offset := -Offset;
  end
  else
    Sign := '+';
  Result := TwoDigits(D) + '/' + MonthNames[M] + '/' + IntToStr(Y) + ':' +
    TwoDigits(H) + ':' + TwoDigits(N) + ':' + TwoDigits(S) + ' ' + Sign +
    TwoDigits(Offset div 60) + TwoDigits(Offset mod 60);
end;

function FormatCommonLog(const ARecord: TAccessLogRecord): string;
var
  Principal, Status, Size: string;
begin
  Principal := Escaped(ARecord.Principal);
  // a space in a principal would split the field
  Principal := StringReplace(Principal, ' ', '\x20', [rfReplaceAll]);
  if ARecord.Status > 0 then
    Status := IntToStr(ARecord.Status)
  else
    Status := '-';
  if ARecord.BodyOctets > 0 then
    Size := IntToStr(ARecord.BodyOctets)
  else
    Size := '-';
  Result := Dash(Escaped(ARecord.RemoteAddress)) + ' - ' + Dash(Principal) +
    ' [' + FormatTime(ARecord) + '] "' + Escaped(ARecord.Method) + ' ' +
    Escaped(ARecord.Target) + ' ' + Escaped(ARecord.Protocol) + '" ' + Status +
    ' ' + Size;
end;

function BasicAuthUser(const AHeaders: THeaderBlock): string;
const
  Scheme = 'basic ';
var
  I, Colon: Integer;
  Value: string;
  Raw: RawByteString;
begin
  Result := '';
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, 'authorization') then
    begin
      Value := Trim(AHeaders[I].Value);
      if (Length(Value) <= Length(Scheme)) or
         (LowerCase(Copy(Value, 1, Length(Scheme))) <> Scheme) then
        Exit;
      Value := Trim(Copy(Value, Length(Scheme) + 1, MaxInt));
      Raw := '';
      if not Base64ToBinSafe(PAnsiChar(RawByteString(Value)), Length(Value), Raw) then
        Exit;
      Colon := Pos(':', string(Raw));
      if Colon > 0 then
        Result := Copy(string(Raw), 1, Colon - 1)
      else
        Result := string(Raw);
      Exit;
    end;
end;

function LocalUtcOffsetMinutes: Integer;
begin
  // GetLocalTimeOffset answers the minutes to add to local time to get UTC
  Result := -GetLocalTimeOffset;
end;

{ TStdOutAccessLogWriter }

constructor TStdOutAccessLogWriter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TStdOutAccessLogWriter.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TStdOutAccessLogWriter.Write(const ARecord: TAccessLogRecord);
var
  Line: string;
begin
  Line := FormatCommonLog(ARecord);
  // one lock for one whole line, so the lines of two threads never mix
  FLock.Acquire;
  try
    System.Writeln(Line);
    Flush(Output);
  finally
    FLock.Release;
  end;
end;

end.
