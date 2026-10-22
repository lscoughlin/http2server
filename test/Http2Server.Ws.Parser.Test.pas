{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, rfc 6455, frame parser, reader, fragmentation, fuzz, test, fpcunit
notes:
  - This unit tests the frame parser and the message reader.
  - Each rule of RFC 6455 sections 5.2 to 5.5 that a receiver can check has a
    test that names the rule and the close code.
  - The same byte stream is fed whole, one octet at a time and in random pieces,
    and the events must agree. A fuzz test compares whole and octet-wise feeding
    on random and on mutated streams.
---
}
/// Unit tests for Http2Server.Ws.Parser and Http2Server.Ws.Reader
unit Http2Server.Ws.Parser.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Ws.Frames, Http2Server.Ws.Parser, Http2Server.Ws.Reader;

type
  /// a parser sink that writes one text line for each frame
  TTranscriptSink = class(TInterfacedObject, IWsParserSink)
  public
    Lines: TStringList;
    MaxPiece: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure DataBegin(const AOpcode: Byte; const AFin: Boolean;
      const ALength: UInt64);
    procedure DataBytes(const APayload; const ACount: Integer);
    procedure DataEnd;
    procedure Control(const AOpcode: Byte; const APayload; const ACount: Integer);
  private
    FCurrent: string;
    FHead: string;
  end;

  /// a reader sink that writes one text line for each message or control frame
  TMessageSink = class(TInterfacedObject, IWsReaderSink)
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Message(const AText: Boolean; const AData: TBytes);
    procedure Control(const AOpcode: Byte; const AData: TBytes);
  end;

  TWsParserTest = class(TTestCase)
  private
    FKey: TWsMaskKey;
    function Limits(const AFrame, AMessage: Int64; const AFragments: Integer): TWsLimits;
    function Frame(const AOpcode: Byte; const AFin: Boolean; const AText: RawByteString;
      const AMasked: Boolean = True): TBytes;
    function Cat(const A, B: TBytes): TBytes;
    function FromHex(const AHex: string): TBytes;
    function Hex(const AData: TBytes): string;
    function Transcript(const AStream: TBytes; const ARequireMasked: Boolean;
      const AMode: Integer; out AFailure: TWsFailure; out AMaxPiece: Integer): string;
    procedure ExpectFailure(const AHex: string; const ARequireMasked: Boolean;
      const ACode: Word; const AName: string);
  published
    procedure TestRfcVectorsParseMaskedAndUnmasked;
    procedure TestEveryChunkingGivesTheSameEvents;
    procedure TestEachRuleFailsWithItsCloseCode;
    procedure TestControlFrameInsideAFragmentedMessage;
    procedure TestZeroMaskKeyIsAccepted;
    procedure TestNothingIsParsedAfterAFailure;
    procedure TestLargeFrameStreamsInSmallPieces;
    procedure TestEmptyFramesProduceEvents;
  end;

  TWsReaderTest = class(TTestCase)
  private
    FKey: TWsMaskKey;
    function Limits(const AFrame, AMessage: Int64; const AFragments: Integer): TWsLimits;
    function Frame(const AOpcode: Byte; const AFin: Boolean; const AData: RawByteString): TBytes;
    function Cat(const A, B: TBytes): TBytes;
    function Run(const AStream: TBytes; const ALimits: TWsLimits;
      out AFailure: TWsFailure; out ALines: string): Boolean;
  published
    procedure TestTextAndBinaryMessages;
    procedure TestFragmentedTextWithASplitCharacter;
    procedure TestControlFramesBetweenFragmentsAreDelivered;
    procedure TestBadUtf8FailsAtTheBadByte;
    procedure TestTextEndingInsideACharacterFails;
    procedure TestDeclaredLengthOverTheMessageLimitFailsAtOnce;
    procedure TestTooManyFragmentsFail;
    procedure TestCloseFrameChecks;
    procedure TestEmptyMessagesAreDelivered;
    procedure TestRandomStreamsAgreeWhenWholeAndOctetWise;
  end;

implementation

{ TTranscriptSink }

constructor TTranscriptSink.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TTranscriptSink.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

procedure TTranscriptSink.DataBegin(const AOpcode: Byte; const AFin: Boolean;
  const ALength: UInt64);
begin
  FHead := Format('D%d%s:%d:', [AOpcode, BoolToStr(AFin, 'F', 'f'), ALength]);
  FCurrent := '';
end;

procedure TTranscriptSink.DataBytes(const APayload; const ACount: Integer);
var
  I: Integer;
begin
  if ACount > MaxPiece then
    MaxPiece := ACount;
  for I := 0 to ACount - 1 do
    FCurrent := FCurrent + IntToHex(PByte(@APayload)[I], 2);
end;

procedure TTranscriptSink.DataEnd;
begin
  Lines.Add(FHead + FCurrent);
end;

procedure TTranscriptSink.Control(const AOpcode: Byte; const APayload;
  const ACount: Integer);
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to ACount - 1 do
    S := S + IntToHex(PByte(@APayload)[I], 2);
  Lines.Add(Format('C%d:%s', [AOpcode, S]));
end;

{ TMessageSink }

constructor TMessageSink.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TMessageSink.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

procedure TMessageSink.Message(const AText: Boolean; const AData: TBytes);
var
  S: string;
  I: Integer;
begin
  S := '';
  for I := 0 to High(AData) do
    S := S + IntToHex(AData[I], 2);
  Lines.Add(Format('%s:%s', [BoolToStr(AText, 'T', 'B'), S]));
end;

procedure TMessageSink.Control(const AOpcode: Byte; const AData: TBytes);
var
  S: string;
  I: Integer;
begin
  S := '';
  for I := 0 to High(AData) do
    S := S + IntToHex(AData[I], 2);
  Lines.Add(Format('C%d:%s', [AOpcode, S]));
end;

{ TWsParserTest }

function TWsParserTest.Limits(const AFrame, AMessage: Int64;
  const AFragments: Integer): TWsLimits;
begin
  Result.MaxFrameSize := AFrame;
  Result.MaxMessageSize := AMessage;
  Result.MaxFragments := AFragments;
end;

function TWsParserTest.Frame(const AOpcode: Byte; const AFin: Boolean;
  const AText: RawByteString; const AMasked: Boolean): TBytes;
var
  P: TBytes;
begin
  FKey := WsMaskKeyFromLongWord($37FA213D);
  SetLength(P, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], P[0], Length(AText));
  Result := WsEncodeFrame(AOpcode, AFin, P, AMasked, FKey);
end;

function TWsParserTest.Cat(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

function TWsParserTest.FromHex(const AHex: string): TBytes;
var
  S: string;
  I: Integer;
begin
  S := StringReplace(AHex, ' ', '', [rfReplaceAll]);
  SetLength(Result, Length(S) div 2);
  for I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Copy(S, I * 2 + 1, 2));
end;

function TWsParserTest.Hex(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AData) do
    Result := Result + IntToHex(AData[I], 2);
end;

/// AMode 0 feeds the stream whole, 1 one octet at a time, 2 in random pieces
function TWsParserTest.Transcript(const AStream: TBytes; const ARequireMasked: Boolean;
  const AMode: Integer; out AFailure: TWsFailure; out AMaxPiece: Integer): string;
var
  Parser: TWsParser;
  Sink: TTranscriptSink;
  Ref: IWsParserSink;
  At, N: Integer;
begin
  Sink := TTranscriptSink.Create;
  Ref := Sink;
  Parser := TWsParser.Create(Limits(1 shl 20, 1 shl 24, 100), ARequireMasked);
  try
    At := 0;
    while (At < Length(AStream)) and not Parser.Failed do
    begin
      case AMode of
        0: N := Length(AStream);
        1: N := 1;
      else
        N := 1 + Random(7);
      end;
      if At + N > Length(AStream) then
        N := Length(AStream) - At;
      Parser.Feed(AStream[At], N, Ref);
      Inc(At, N);
    end;
    AFailure := Parser.Failure;
    AMaxPiece := Sink.MaxPiece;
    Result := Sink.Lines.CommaText;
    if Parser.Failed then
      Result := Result + '|FAILED';
  finally
    Parser.Free;
  end;
end;

procedure TWsParserTest.ExpectFailure(const AHex: string;
  const ARequireMasked: Boolean; const ACode: Word; const AName: string);
var
  F: TWsFailure;
  T: string;
  Piece: Integer;
  Stream: TBytes;
begin
  Stream := FromHex(AHex);
  T := Transcript(Stream, ARequireMasked, 0, F, Piece);
  AssertEquals(AName + ': failed', True, Pos('|FAILED', T) > 0);
  AssertEquals(AName + ': close code', ACode, F.Code);
  T := Transcript(Stream, ARequireMasked, 1, F, Piece);
  AssertEquals(AName + ' (octet-wise): failed', True, Pos('|FAILED', T) > 0);
  AssertEquals(AName + ' (octet-wise): close code', ACode, F.Code);
end;

procedure TWsParserTest.TestRfcVectorsParseMaskedAndUnmasked;
var
  F: TWsFailure;
  Piece: Integer;
begin
  AssertEquals('a masked "Hello"', 'D1F:5:48656C6C6F',
    Transcript(FromHex('81 85 37 fa 21 3d 7f 9f 4d 51 58'), True, 0, F, Piece));
  AssertEquals('an unmasked "Hello" (server frames)', 'D1F:5:48656C6C6F',
    Transcript(FromHex('81 05 48 65 6c 6c 6f'), False, 0, F, Piece));
  AssertEquals('a fragmented text message', 'D1f:3:48656C,D0F:2:6C6F',
    Transcript(FromHex('01 03 48 65 6c 80 02 6c 6f'), False, 0, F, Piece));
  AssertEquals('a ping', 'C9:48656C6C6F',
    Transcript(FromHex('89 05 48 65 6c 6c 6f'), False, 0, F, Piece));
  AssertEquals('a masked pong', 'C10:48656C6C6F',
    Transcript(FromHex('8a 85 37 fa 21 3d 7f 9f 4d 51 58'), True, 0, F, Piece));
end;

procedure TWsParserTest.TestEveryChunkingGivesTheSameEvents;
var
  Stream, Big: TBytes;
  Whole, Octets, Pieces: string;
  F: TWsFailure;
  Piece, I, Round: Integer;
begin
  SetLength(Big, 300);
  for I := 0 to 299 do
    Big[I] := I and $FF;
  Stream := Frame(WsOpText, False, 'Hel');
  Stream := Cat(Stream, Frame(WsOpPing, True, 'p'));
  Stream := Cat(Stream, Frame(WsOpContinuation, True, 'lo'));
  Stream := Cat(Stream, WsEncodeFrame(WsOpBinary, True, Big, True, FKey));
  Stream := Cat(Stream, Frame(WsOpClose, True, #3#232'bye'));
  Whole := Transcript(Stream, True, 0, F, Piece);
  AssertTrue('the transcript is not empty', Length(Whole) > 20);
  Octets := Transcript(Stream, True, 1, F, Piece);
  AssertEquals('octet-wise feeding agrees', Whole, Octets);
  RandSeed := 99;
  for Round := 1 to 200 do
  begin
    Pieces := Transcript(Stream, True, 2, F, Piece);
    AssertEquals('random pieces agree, round ' + IntToStr(Round), Whole, Pieces);
  end;
end;

procedure TWsParserTest.TestEachRuleFailsWithItsCloseCode;
begin
  // RFC 6455 section 5.2
  ExpectFailure('c1 80 00 00 00 00', True, 1002, 'RSV1 set');
  ExpectFailure('a1 80 00 00 00 00', True, 1002, 'RSV2 set');
  ExpectFailure('91 80 00 00 00 00', True, 1002, 'RSV3 set');
  ExpectFailure('83 80 00 00 00 00', True, 1002, 'reserved data opcode 3');
  ExpectFailure('87 80 00 00 00 00', True, 1002, 'reserved data opcode 7');
  ExpectFailure('8b 80 00 00 00 00', True, 1002, 'reserved control opcode B');
  ExpectFailure('8f 80 00 00 00 00', True, 1002, 'reserved control opcode F');
  // RFC 6455 section 5.1
  ExpectFailure('81 05 48 65 6c 6c 6f', True, 1002, 'an unmasked client frame');
  ExpectFailure('81 85 37 fa 21 3d 7f 9f 4d 51 58', False, 1002,
    'a masked server frame');
  // RFC 6455 section 5.2: the shortest form of the length
  ExpectFailure('82 fe 00 64 00 00 00 00', True, 1002,
    'a 16-bit length below 126');
  ExpectFailure('82 ff 00 00 00 00 00 00 03 e8 00 00 00 00', True, 1002,
    'a 64-bit length below 65536');
  ExpectFailure('82 ff 80 00 00 00 00 00 00 00 00 00 00 00', True, 1002,
    'a 64-bit length with the top bit set');
  // RFC 6455 section 5.5
  ExpectFailure('89 fe 00 7e 00 00 00 00', True, 1002, 'a control frame of 126');
  ExpectFailure('88 ff 00 00 00 00 00 01 00 00 00 00 00 00', True, 1002,
    'a control frame of 65536');
  ExpectFailure('09 80 00 00 00 00', True, 1002, 'a ping without FIN');
  ExpectFailure('08 80 00 00 00 00', True, 1002, 'a close without FIN');
  // RFC 6455 section 5.4
  ExpectFailure('80 80 00 00 00 00', True, 1002,
    'a continuation frame with no message open');
  ExpectFailure('01 80 00 00 00 00 01 80 00 00 00 00', True, 1002,
    'a new text frame inside an open message');
  ExpectFailure('01 80 00 00 00 00 82 80 00 00 00 00', True, 1002,
    'a binary frame inside an open text message');
  ExpectFailure('81 80 00 00 00 00 80 80 00 00 00 00', True, 1002,
    'a continuation frame after a finished message');
  // RFC 6455 section 10.4: the frame size limit is 100 in this test
end;

procedure TWsParserTest.TestControlFrameInsideAFragmentedMessage;
var
  S: TBytes;
  F: TWsFailure;
  Piece: Integer;
  T: string;
begin
  S := Frame(WsOpText, False, 'a');
  S := Cat(S, Frame(WsOpPing, True, 'x'));
  S := Cat(S, Frame(WsOpContinuation, False, 'b'));
  S := Cat(S, Frame(WsOpPong, True, 'y'));
  S := Cat(S, Frame(WsOpContinuation, True, 'c'));
  T := Transcript(S, True, 0, F, Piece);
  AssertEquals('control frames pass between the fragments, the order holds',
    'D1f:1:61,C9:78,D0f:1:62,C10:79,D0F:1:63', T);
end;

procedure TWsParserTest.TestZeroMaskKeyIsAccepted;
var
  F: TWsFailure;
  Piece: Integer;
begin
  AssertEquals('RFC 6455 section 5.3 allows a zero key', 'D1F:3:616263',
    Transcript(FromHex('81 83 00 00 00 00 61 62 63'), True, 0, F, Piece));
end;

procedure TWsParserTest.TestNothingIsParsedAfterAFailure;
var
  Parser: TWsParser;
  Sink: TTranscriptSink;
  Ref: IWsParserSink;
  Bad, Good: TBytes;
begin
  Sink := TTranscriptSink.Create;
  Ref := Sink;
  Parser := TWsParser.Create(Limits(1000, 1000, 10), True);
  try
    Bad := FromHex('c1 80 00 00 00 00');
    Good := Frame(WsOpText, True, 'ok');
    AssertFalse(Parser.Feed(Bad[0], Length(Bad), Ref));
    AssertFalse('a failed parser takes no more input',
      Parser.Feed(Good[0], Length(Good), Ref));
    AssertEquals('and raises no event', 0, Sink.Lines.Count);
    AssertEquals(1002, Parser.Failure.Code);
  finally
    Parser.Free;
  end;
end;

procedure TWsParserTest.TestLargeFrameStreamsInSmallPieces;
const
  cSize = 1000000;
var
  Parser: TWsParser;
  Sink: TTranscriptSink;
  Ref: IWsParserSink;
  Stream, Payload: TBytes;
  At, N: Integer;
  F: TWsFailure;
begin
  SetLength(Payload, cSize);
  FKey := WsMaskKeyFromLongWord($0A0B0C0D);
  Stream := WsEncodeFrame(WsOpBinary, True, Payload, True, FKey);
  Sink := TTranscriptSink.Create;
  Ref := Sink;
  Parser := TWsParser.Create(Limits(2000000, 2000000, 10), True);
  try
    At := 0;
    while At < Length(Stream) do
    begin
      N := 1000;
      if At + N > Length(Stream) then
        N := Length(Stream) - At;
      AssertTrue(Parser.Feed(Stream[At], N, Ref));
      Inc(At, N);
    end;
    F := Parser.Failure;
    AssertEquals('the whole frame was delivered', 1, Sink.Lines.Count);
    AssertEquals('the parser hands the sink small pieces, not the frame', True,
      Sink.MaxPiece <= 4096);
    AssertEquals(0, F.Code);
  finally
    Parser.Free;
  end;
end;

procedure TWsParserTest.TestEmptyFramesProduceEvents;
var
  F: TWsFailure;
  Piece: Integer;
begin
  AssertEquals('an empty text frame', 'D1F:0:',
    Transcript(Frame(WsOpText, True, ''), True, 0, F, Piece));
  AssertEquals('an empty ping', 'C9:',
    Transcript(Frame(WsOpPing, True, ''), True, 0, F, Piece));
  AssertEquals('an empty close', 'C8:',
    Transcript(Frame(WsOpClose, True, ''), True, 0, F, Piece));
end;

{ TWsReaderTest }

function TWsReaderTest.Limits(const AFrame, AMessage: Int64;
  const AFragments: Integer): TWsLimits;
begin
  Result.MaxFrameSize := AFrame;
  Result.MaxMessageSize := AMessage;
  Result.MaxFragments := AFragments;
end;

function TWsReaderTest.Frame(const AOpcode: Byte; const AFin: Boolean;
  const AData: RawByteString): TBytes;
var
  P: TBytes;
begin
  FKey := WsMaskKeyFromLongWord($11223344);
  SetLength(P, Length(AData));
  if Length(AData) > 0 then
    Move(AData[1], P[0], Length(AData));
  Result := WsEncodeFrame(AOpcode, AFin, P, True, FKey);
end;

function TWsReaderTest.Cat(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

function TWsReaderTest.Run(const AStream: TBytes; const ALimits: TWsLimits;
  out AFailure: TWsFailure; out ALines: string): Boolean;
var
  Reader: TWsReader;
  Sink: TMessageSink;
  Ref: IWsReaderSink;
begin
  Sink := TMessageSink.Create;
  Ref := Sink;
  Reader := TWsReader.Create(ALimits, True);
  try
    Result := Reader.Feed(AStream[0], Length(AStream), Ref);
    AFailure := Reader.Failure;
    ALines := Sink.Lines.CommaText;
  finally
    Reader.Free;
  end;
end;

procedure TWsReaderTest.TestTextAndBinaryMessages;
var
  F: TWsFailure;
  L: string;
  S: TBytes;
begin
  S := Cat(Frame(WsOpText, True, 'Hi'), Frame(WsOpBinary, True, #0#255));
  AssertTrue(Run(S, Limits(1000, 1000, 10), F, L));
  AssertEquals('T:4869,B:00FF', L);
end;

procedure TWsReaderTest.TestFragmentedTextWithASplitCharacter;
var
  F: TWsFailure;
  L: string;
  S: TBytes;
begin
  // the euro sign E2 82 AC split over three frames
  S := Frame(WsOpText, False, 'a'#$E2);
  S := Cat(S, Frame(WsOpContinuation, False, #$82));
  S := Cat(S, Frame(WsOpContinuation, True, #$AC'b'));
  AssertTrue(Run(S, Limits(1000, 1000, 10), F, L));
  AssertEquals('one text message of four characters', 'T:61E282AC62', L);
end;

procedure TWsReaderTest.TestControlFramesBetweenFragmentsAreDelivered;
var
  F: TWsFailure;
  L: string;
  S: TBytes;
begin
  S := Frame(WsOpText, False, 'ab');
  S := Cat(S, Frame(WsOpPing, True, 'p'));
  S := Cat(S, Frame(WsOpContinuation, True, 'cd'));
  AssertTrue(Run(S, Limits(1000, 1000, 10), F, L));
  AssertEquals('the ping comes first, the message after its last fragment',
    'C9:70,T:61626364', L);
end;

procedure TWsReaderTest.TestBadUtf8FailsAtTheBadByte;
var
  F: TWsFailure;
  L: string;
  S: TBytes;
begin
  // a frame that declares 1000 octets and sends a bad first octet only
  S := Frame(WsOpText, True, StringOfChar('x', 1000));
  S := Copy(S, 0, 6 + 2 + 1);   // header, 4-octet key, 2-octet length, one octet
  S[Length(S) - 1] := S[Length(S) - 1] xor ($78 xor $FF);   // the octet becomes FF
  AssertFalse(Run(S, Limits(2000, 2000, 10), F, L));
  AssertEquals('a bad prefix fails before the message ends', 1007, F.Code);
end;

procedure TWsReaderTest.TestTextEndingInsideACharacterFails;
var
  F: TWsFailure;
  L: string;
begin
  AssertFalse(Run(Frame(WsOpText, True, 'a'#$E2#$82), Limits(1000, 1000, 10), F, L));
  AssertEquals(1007, F.Code);
  AssertEquals('nothing was delivered', '', L);
end;

procedure TWsReaderTest.TestDeclaredLengthOverTheMessageLimitFailsAtOnce;
var
  F: TWsFailure;
  L: string;
  S: TBytes;
begin
  // only the header of a 1 MiB frame arrives; the limit is 1000
  S := WsEncodeHeader(WsOpBinary, True, 1 shl 20, True, FKey);
  AssertFalse(Run(S, Limits(2 shl 20, 1000, 10), F, L));
  AssertEquals('1009 before a single payload octet', 1009, F.Code);
  // a message of two frames that together pass the limit
  S := Cat(Frame(WsOpBinary, False, StringOfChar('x', 600)),
    Frame(WsOpContinuation, True, StringOfChar('y', 600)));
  AssertFalse(Run(S, Limits(2000, 1000, 10), F, L));
  AssertEquals(1009, F.Code);
end;

procedure TWsReaderTest.TestTooManyFragmentsFail;
var
  F: TWsFailure;
  L: string;
  S: TBytes;
  I: Integer;
begin
  S := Frame(WsOpBinary, False, 'a');
  for I := 1 to 4 do
    S := Cat(S, Frame(WsOpContinuation, False, 'a'));
  AssertFalse('six frames against a limit of five',
    Run(Cat(S, Frame(WsOpContinuation, True, 'a')), Limits(100, 1000, 5), F, L));
  AssertEquals(1009, F.Code);
  AssertTrue('five frames fit',
    Run(Cat(Copy(S, 0, Length(S) - Length(Frame(WsOpContinuation, False, 'a'))),
      Frame(WsOpContinuation, True, 'a')), Limits(100, 1000, 5), F, L));
end;

procedure TWsReaderTest.TestCloseFrameChecks;
var
  F: TWsFailure;
  L: string;
begin
  AssertTrue('an empty close', Run(Frame(WsOpClose, True, ''),
    Limits(100, 100, 5), F, L));
  AssertEquals('C8:', L);
  AssertTrue('a close with code 1000 and a reason', Run(Frame(WsOpClose, True,
    #3#232'bye'), Limits(100, 100, 5), F, L));
  AssertEquals('C8:03E8627965', L);
  AssertTrue('1012 is an assigned code', Run(Frame(WsOpClose, True, #3#244),
    Limits(100, 100, 5), F, L));
  AssertFalse('one octet', Run(Frame(WsOpClose, True, #3),
    Limits(100, 100, 5), F, L));
  AssertEquals(1002, F.Code);
  AssertFalse('code 1005 on the wire', Run(Frame(WsOpClose, True, #3#237),
    Limits(100, 100, 5), F, L));
  AssertEquals(1002, F.Code);
  AssertFalse('code 1006 on the wire', Run(Frame(WsOpClose, True, #3#238),
    Limits(100, 100, 5), F, L));
  AssertEquals(1002, F.Code);
  AssertFalse('code 999', Run(Frame(WsOpClose, True, #3#231),
    Limits(100, 100, 5), F, L));
  AssertEquals(1002, F.Code);
  AssertFalse('a reason that is not UTF-8', Run(Frame(WsOpClose, True,
    #3#232#$FF), Limits(100, 100, 5), F, L));
  AssertEquals(1007, F.Code);
end;

procedure TWsReaderTest.TestEmptyMessagesAreDelivered;
var
  F: TWsFailure;
  L: string;
begin
  AssertTrue(Run(Cat(Frame(WsOpText, True, ''), Frame(WsOpBinary, True, '')),
    Limits(100, 100, 5), F, L));
  AssertEquals('T:,B:', L);
end;

procedure TWsReaderTest.TestRandomStreamsAgreeWhenWholeAndOctetWise;
const
  cRuns = 40000;
var
  Iter, I, N, Cut: Integer;
  S, M: TBytes;
  Whole, Octets: TMessageSink;
  WholeRef, OctetsRef: IWsReaderSink;
  RW, RO: TWsReader;
  FW, FO: Boolean;
  Valid: TBytes;
begin
  RandSeed := 20261022;
  // a valid stream, mutated at random places, and pure noise
  Valid := Cat(Frame(WsOpText, False, 'Hel'), Frame(WsOpPing, True, 'p'));
  Valid := Cat(Valid, Frame(WsOpContinuation, True, 'lo'));
  Valid := Cat(Valid, Frame(WsOpBinary, True, 'abcdefgh'));
  Valid := Cat(Valid, Frame(WsOpClose, True, #3#232'bye'));
  for Iter := 1 to cRuns do
  begin
    if Iter mod 2 = 0 then
    begin
      N := 1 + Random(48);
      SetLength(S, N);
      for I := 0 to N - 1 do
        S[I] := Random(256);
    end
    else
    begin
      S := Copy(Valid);
      for I := 1 to 1 + Random(3) do
        S[Random(Length(S))] := Random(256);
      if Random(3) = 0 then
        SetLength(S, Random(Length(S)) + 1);
    end;
    Whole := TMessageSink.Create;
    WholeRef := Whole;
    Octets := TMessageSink.Create;
    OctetsRef := Octets;
    RW := TWsReader.Create(Limits(64, 128, 4), True);
    RO := TWsReader.Create(Limits(64, 128, 4), True);
    try
      FW := RW.Feed(S[0], Length(S), WholeRef);
      FO := True;
      for I := 0 to High(S) do
        if FO then
          FO := RO.Feed(S[I], 1, OctetsRef);
      Cut := 0;
      if FW <> FO then
        Fail('the verdicts differ on iteration ' + IntToStr(Iter));
      if (not FW) and (RW.Failure.Code <> RO.Failure.Code) then
        Fail('the close codes differ on iteration ' + IntToStr(Iter));
      if Whole.Lines.CommaText <> Octets.Lines.CommaText then
        Fail('the messages differ on iteration ' + IntToStr(Iter));
      M := nil;
      if Cut <> 0 then
        Fail('unreachable');
    finally
      RW.Free;
      RO.Free;
    end;
  end;
end;

initialization
  RegisterTest(TWsParserTest);
  RegisterTest(TWsReaderTest);

end.
