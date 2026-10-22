{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, rfc 6455, frame parser, resumable, streaming, masking
notes:
  - This unit holds the resumable frame parser. A caller feeds bytes in pieces
    of any size, and the parser calls a sink as the frames arrive.
  - The parser keeps at most 14 octets of header and the payload of one control
    frame. It buffers no data frame. The payload of a data frame goes to the sink
    as it arrives, already unmasked. The work of one Feed call is linear in the
    number of octets and never loops without consuming input.
  - The parser enforces the rules of RFC 6455 sections 5.2 to 5.5 that a single
    frame and the order of the frames allow. The assembly of a message and its
    UTF-8 check are in Http2Server.Ws.Reader.
  - The state machine takes its shape from TWebProcessInFrame of mORMot2
    (mormot.net.ws.core.pas, revision b2b195da1) and the checks from the client
    unit Http2.WebSocket of ../http2client at revision dd45cdd. It adds the rules
    that the mORMot2 parser lacks, and the push model that avoids the whole-frame
    buffer of the client parser.
---
}
/// The resumable WebSocket frame parser (RFC 6455 section 5)
unit Http2Server.Ws.Parser;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Ws.Frames;

type
  /// the limits that the parser and the reader enforce
  // - the factory fills them; the unit holds no default
  TWsLimits = record
    /// the greatest payload of one data frame, in octets
    MaxFrameSize: Int64;
    /// the greatest message, summed over its fragments, in octets
    MaxMessageSize: Int64;
    /// the greatest number of frames of one message
    MaxFragments: Integer;
  end;

  /// The receiver of the parser.
  ///
  /// A data frame arrives as DataBegin, any number of DataBytes calls and
  /// DataEnd. A control frame arrives whole, in one Control call. The payload is
  /// already unmasked, and it is valid for the length of the call only.
  IWsParserSink = interface
    ['{7E1F0C11-0061-4A11-9C72-000000000901}']
    /// a data frame starts; AOpcode is 0 for a continuation frame
    procedure DataBegin(const AOpcode: Byte; const AFin: Boolean;
      const ALength: UInt64);
    procedure DataBytes(const APayload; const ACount: Integer);
    procedure DataEnd;
    /// a whole control frame: Close, Ping or Pong
    procedure Control(const AOpcode: Byte; const APayload; const ACount: Integer);
  end;

  /// the frame parser of one connection
  TWsParser = class
  private
    type
      TState = (psHead, psPayload, psFailed);
  private
    FLimits: TWsLimits;
    FRequireMasked: Boolean;
    FState: TState;
    FHead: array[0..13] of Byte;
    FHeadLen: Integer;
    FHeadNeed: Integer;
    FOpcode: Byte;
    FFin: Boolean;
    FIsControl: Boolean;
    FMasked: Boolean;
    FKey: TWsMaskKey;
    FRemaining: UInt64;
    FPhase: Integer;
    FControl: array[0..WsMaxControlPayload - 1] of Byte;
    FControlLen: Integer;
    /// true between the first frame of a data message and its last frame
    FInMessage: Boolean;
    FFailure: TWsFailure;
    function Fail(const ACode: Word; const AReason: string): Boolean;
    function ParseHead(const ASink: IWsParserSink): Boolean;
    function GetFailed: Boolean;
    procedure EndFrame(const ASink: IWsParserSink);
  public
    /// ARequireMasked is True for the frames that a client sends (the server
    /// parser); False for the frames that a server sends
    constructor Create(const ALimits: TWsLimits; const ARequireMasked: Boolean);
    /// consume ACount octets and call the sink as frames arrive
    // - answers False once a rule is broken; Failure then holds the close code
    //   and a short text, and the parser takes no more input
    function Feed(const AData; const ACount: Integer;
      const ASink: IWsParserSink): Boolean;
    property Failed: Boolean read GetFailed;
    property Failure: TWsFailure read FFailure;
    /// true while a data message is open (a frame without FIN has arrived)
    property InMessage: Boolean read FInMessage;
  end;

implementation

const
  /// the largest block that the parser unmasks in one step
  cChunk = 4096;

constructor TWsParser.Create(const ALimits: TWsLimits;
  const ARequireMasked: Boolean);
begin
  inherited Create;
  FLimits := ALimits;
  FRequireMasked := ARequireMasked;
  FState := psHead;
  FHeadNeed := 2;
end;

function TWsParser.Fail(const ACode: Word; const AReason: string): Boolean;
begin
  FState := psFailed;
  FFailure.Code := ACode;
  FFailure.Reason := AReason;
  Result := False;
end;

function TWsParser.GetFailed: Boolean;
begin
  Result := FState = psFailed;
end;

function TWsParser.ParseHead(const ASink: IWsParserSink): Boolean;
var
  Len7: Integer;
  Len: UInt64;
  At, I: Integer;
begin
  FFin := (FHead[0] and $80) <> 0;
  if (FHead[0] and $70) <> 0 then
    Exit(Fail(WsCloseProtocolError, 'a reserved bit is set with no extension'));
  FOpcode := FHead[0] and $0F;
  case FOpcode of
    WsOpContinuation, WsOpText, WsOpBinary, WsOpClose, WsOpPing, WsOpPong: ;
  else
    Exit(Fail(WsCloseProtocolError, 'a reserved opcode'));
  end;
  FIsControl := (FOpcode and $08) <> 0;
  FMasked := (FHead[1] and $80) <> 0;
  if FRequireMasked and (not FMasked) then
    Exit(Fail(WsCloseProtocolError, 'a client frame is not masked'));
  if (not FRequireMasked) and FMasked then
    Exit(Fail(WsCloseProtocolError, 'a server frame is masked'));
  Len7 := FHead[1] and $7F;
  At := 2;
  if Len7 <= 125 then
    Len := Len7
  else if Len7 = 126 then
  begin
    Len := (UInt64(FHead[2]) shl 8) or FHead[3];
    if Len < 126 then
      Exit(Fail(WsCloseProtocolError, 'a length that is not in its shortest form'));
    At := 4;
  end
  else
  begin
    if (FHead[2] and $80) <> 0 then
      Exit(Fail(WsCloseProtocolError, 'a 64-bit length with its top bit set'));
    Len := 0;
    for I := 2 to 9 do
      Len := (Len shl 8) or FHead[I];
    if Len < 65536 then
      Exit(Fail(WsCloseProtocolError, 'a length that is not in its shortest form'));
    At := 10;
  end;
  if FMasked then
    Move(FHead[At], FKey[0], 4);
  if FIsControl then
  begin
    if not FFin then
      Exit(Fail(WsCloseProtocolError, 'a fragmented control frame'));
    if Len > WsMaxControlPayload then
      Exit(Fail(WsCloseProtocolError, 'a control frame over 125 octets'));
  end
  else
  begin
    if FOpcode = WsOpContinuation then
    begin
      if not FInMessage then
        Exit(Fail(WsCloseProtocolError,
          'a continuation frame with no message open'));
    end
    else if FInMessage then
      Exit(Fail(WsCloseProtocolError, 'a new data frame inside an open message'));
    if Len > UInt64(FLimits.MaxFrameSize) then
      Exit(Fail(WsCloseTooBig, 'a frame over the frame size limit'));
  end;
  FRemaining := Len;
  FPhase := 0;
  FControlLen := 0;
  if not FIsControl then
  begin
    FInMessage := not FFin;
    ASink.DataBegin(FOpcode, FFin, Len);
  end;
  FState := psPayload;
  Result := True;
  if Len = 0 then
    EndFrame(ASink);
end;

procedure TWsParser.EndFrame(const ASink: IWsParserSink);
begin
  if FIsControl then
    ASink.Control(FOpcode, FControl[0], FControlLen)
  else
    ASink.DataEnd;
  FState := psHead;
  FHeadLen := 0;
  FHeadNeed := 2;
end;

function TWsParser.Feed(const AData; const ACount: Integer;
  const ASink: IWsParserSink): Boolean;
var
  P: PByte;
  N, Take: Integer;
  Block: array[0..cChunk - 1] of Byte;
begin
  P := @AData;
  N := ACount;
  while (N > 0) and (FState <> psFailed) do
  begin
    if FState = psHead then
    begin
      FHead[FHeadLen] := P^;
      Inc(FHeadLen);
      Inc(P);
      Dec(N);
      if FHeadLen = 2 then
      begin
        // the first two octets tell how many more the header needs
        case FHead[1] and $7F of
          126: FHeadNeed := 4;
          127: FHeadNeed := 10;
        else
          FHeadNeed := 2;
        end;
        if (FHead[1] and $80) <> 0 then
          Inc(FHeadNeed, 4);
      end;
      if FHeadLen = FHeadNeed then
        ParseHead(ASink);
    end
    else
    begin
      // psPayload
      if UInt64(N) < FRemaining then
        Take := N
      else
        Take := Integer(FRemaining);
      if Take > cChunk then
        Take := cChunk;
      if FIsControl then
      begin
        Move(P^, FControl[FControlLen], Take);
        if FMasked then
          WsApplyMask(FKey, FControl[FControlLen], Take, FPhase);
        Inc(FControlLen, Take);
      end
      else
      begin
        Move(P^, Block[0], Take);
        if FMasked then
          WsApplyMask(FKey, Block[0], Take, FPhase);
        ASink.DataBytes(Block[0], Take);
      end;
      Inc(FPhase, Take);
      Inc(P, Take);
      Dec(N, Take);
      Dec(FRemaining, Take);
      if FRemaining = 0 then
        EndFrame(ASink);
    end;
  end;
  Result := FState <> psFailed;
end;

end.
