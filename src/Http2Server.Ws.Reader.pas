{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, rfc 6455, message assembly, utf-8, limits, reader
notes:
  - This unit assembles the frames of Http2Server.Ws.Parser into messages. A
    caller feeds bytes and receives whole messages and whole control frames.
  - A message grows as its bytes arrive and never as its declared length says,
    so a peer that declares a huge frame and sends nothing costs no memory. The
    reader refuses a frame whose declared length would pass the message limit
    before it buffers a byte.
  - A text message is checked for UTF-8 as the bytes arrive, so a bad prefix fails
    before the message ends, and a character split across fragments is legal.
  - A Close frame is checked here. One octet, a code that is not on the wire, and
    a reason that is not UTF-8 fail the connection (RFC 6455 sections 5.5.1, 7.4).
  - The assembly rules follow the client unit Http2.WebSocket of ../http2client
    at revision dd45cdd. This unit accumulates a whole message where the client
    unit delivers each fragment.
---
}
/// Whole WebSocket messages from a stream of bytes (RFC 6455 sections 5.4, 6.2, 8.1)
unit Http2Server.Ws.Reader;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Ws.Frames, Http2Server.Ws.Parser, Http2Server.Ws.Utf8;

type
  /// The receiver of the reader.
  IWsReaderSink = interface
    ['{7E1F0C11-0062-4A11-9C72-000000000902}']
    /// a whole message; the text of a text message is valid UTF-8
    procedure Message(const AText: Boolean; const AData: TBytes);
    /// a whole Ping, Pong or Close frame; a Close payload passed the checks
    procedure Control(const AOpcode: Byte; const AData: TBytes);
  end;

  /// The reader of one connection: a parser plus the assembly of messages.
  ///
  /// The reader is a plain object. It implements the parser sink without a
  /// reference count, so an owner frees it with Free.
  TWsReader = class(TObject, IWsParserSink)
  private
    FParser: TWsParser;
    FLimits: TWsLimits;
    FSink: IWsReaderSink;
    FBuf: TBytes;
    FLen: Integer;
    FText: Boolean;
    FFragments: Integer;
    FTotal: UInt64;
    FUtf8: TWsUtf8Validator;
    FFailure: TWsFailure;
    FFailed: Boolean;
    function Fail(const ACode: Word; const AReason: string): Boolean;
    // IUnknown without a count
    function QueryInterface(constref IID: TGuid; out Obj): LongInt;
      {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    function _AddRef: LongInt; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    function _Release: LongInt; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    // IWsParserSink
    procedure DataBegin(const AOpcode: Byte; const AFin: Boolean;
      const ALength: UInt64);
    procedure DataBytes(const APayload; const ACount: Integer);
    procedure DataEnd;
    procedure Control(const AOpcode: Byte; const APayload; const ACount: Integer);
    function GetFailed: Boolean;
    function GetFailure: TWsFailure;
  public
    /// ARequireMasked is True for the reader of a server (client frames)
    constructor Create(const ALimits: TWsLimits; const ARequireMasked: Boolean);
    destructor Destroy; override;
    /// consume ACount octets; the sink receives the messages that complete
    // - answers False once a rule is broken; Failure holds the close code and a
    //   short text, and the reader takes no more input
    function Feed(const AData; const ACount: Integer;
      const ASink: IWsReaderSink): Boolean;
    property Failed: Boolean read GetFailed;
    property Failure: TWsFailure read GetFailure;
  end;

implementation

constructor TWsReader.Create(const ALimits: TWsLimits;
  const ARequireMasked: Boolean);
begin
  inherited Create;
  FLimits := ALimits;
  FParser := TWsParser.Create(ALimits, ARequireMasked);
  FUtf8.Reset;
end;

destructor TWsReader.Destroy;
begin
  FParser.Free;
  inherited Destroy;
end;

function TWsReader.QueryInterface(constref IID: TGuid; out Obj): LongInt;
begin
  if GetInterface(IID, Obj) then
    Result := 0
  else
    Result := LongInt($80004002);
end;

function TWsReader._AddRef: LongInt;
begin
  Result := -1;
end;

function TWsReader._Release: LongInt;
begin
  Result := -1;
end;

function TWsReader.Fail(const ACode: Word; const AReason: string): Boolean;
begin
  if not FFailed then
  begin
    FFailed := True;
    FFailure.Code := ACode;
    FFailure.Reason := AReason;
  end;
  Result := False;
end;

function TWsReader.GetFailed: Boolean;
begin
  Result := FFailed or FParser.Failed;
end;

function TWsReader.GetFailure: TWsFailure;
begin
  // the reader fails first in time: the parser may go on to the end of the
  // buffer after that and meet a later rule, which must not hide the first
  if FFailed then
    Result := FFailure
  else
    Result := FParser.Failure;
end;

function TWsReader.Feed(const AData; const ACount: Integer;
  const ASink: IWsReaderSink): Boolean;
begin
  if GetFailed then
    Exit(False);
  FSink := ASink;
  try
    // the parser reads to the end of the buffer. Once the assembly broke a
    // rule the reader is failed, and every later sink call returns without work
    Result := FParser.Feed(AData, ACount, Self);
    if FFailed then
      Result := False;
  finally
    FSink := nil;
  end;
end;

procedure TWsReader.DataBegin(const AOpcode: Byte; const AFin: Boolean;
  const ALength: UInt64);
begin
  if FFailed then
    Exit;
  if AOpcode <> WsOpContinuation then
  begin
    // a new message
    FText := AOpcode = WsOpText;
    FLen := 0;
    FFragments := 0;
    FTotal := 0;
    FUtf8.Reset;
  end;
  Inc(FFragments);
  if (FLimits.MaxFragments > 0) and (FFragments > FLimits.MaxFragments) then
  begin
    Fail(WsCloseTooBig, 'a message of too many frames');
    Exit;
  end;
  // the declared length counts before a byte arrives
  if FTotal + ALength > UInt64(FLimits.MaxMessageSize) then
    Fail(WsCloseTooBig, 'a message over the message size limit');
end;

procedure TWsReader.DataBytes(const APayload; const ACount: Integer);
var
  Need: Integer;
begin
  if FFailed or (ACount <= 0) then
    Exit;
  if FText and not FUtf8.Feed(APayload, ACount) then
  begin
    Fail(WsCloseBadData, 'a text message that is not valid UTF-8');
    Exit;
  end;
  Need := FLen + ACount;
  if Need > Length(FBuf) then
  begin
    // grow with the bytes that arrived, never with a declared length
    if Length(FBuf) * 2 > Need then
      SetLength(FBuf, Length(FBuf) * 2)
    else
      SetLength(FBuf, Need);
  end;
  Move(APayload, FBuf[FLen], ACount);
  FLen := Need;
  Inc(FTotal, ACount);
end;

procedure TWsReader.DataEnd;
var
  Whole: TBytes;
begin
  if FFailed then
    Exit;
  // the last frame of the message has FIN; the parser knows, the reader asks it
  if FParser.InMessage then
    Exit;
  if FText and not FUtf8.IsComplete then
  begin
    Fail(WsCloseBadData, 'a text message that ends inside a character');
    Exit;
  end;
  SetLength(Whole, FLen);
  if FLen > 0 then
    Move(FBuf[0], Whole[0], FLen);
  // release a big buffer after a big message, so an idle connection holds little
  if Length(FBuf) > 65536 then
    FBuf := nil;
  FLen := 0;
  FSink.Message(FText, Whole);
end;

procedure TWsReader.Control(const AOpcode: Byte; const APayload;
  const ACount: Integer);
var
  Data: TBytes;
  Code: Integer;
  Reason: RawByteString;
  F: TWsFailure;
begin
  if FFailed then
    Exit;
  SetLength(Data, ACount);
  if ACount > 0 then
    Move(APayload, Data[0], ACount);
  if AOpcode = WsOpClose then
  begin
    F := WsParseClosePayload(Data, Code, Reason);
    if F.Code <> 0 then
    begin
      Fail(F.Code, F.Reason);
      Exit;
    end;
  end;
  FSink.Control(AOpcode, Data);
end;

end.
