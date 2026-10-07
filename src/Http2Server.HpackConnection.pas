{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, hpack, header block, connection
notes:
  - This unit holds the HPACK state of one connection.
  - The encoder and the decoder live here, not in the connection state
    machine, so one concept occupies one file.
  - The unit compiles without the mORMot units, because it touches no socket
    and no TLS.  The caller holds the connection lock for every call.
---
}
/// The HPACK codec of one server connection
// - The encoder and the decoder are stateful and a connection keeps them for
//   its whole life, because the dynamic table follows the wire order.
// - One thread uses this object: the caller holds the connection lock for the
//   whole of every call.
// - The frame size arrives from the options record. The unit holds no limit
//   literal of its own.
unit Http2Server.HpackConnection;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Http2Server.Frames, Http2Server.Hpack, Http2Server.Headers;

type
  /// the HPACK encoder and decoder of one connection
  THpackConnection = class
  private
    FEncoder: THpackCodec;
    FDecoder: THpackCodec;
    FMaxFrameSize: LongWord;
    /// the request header block under assembly
    // - a HEADERS frame starts a block and CONTINUATION frames extend it, so
    //   the bytes arrive in pieces and wait here until the block ends
    FBlock: TBytes;
    FBlockCount: Integer;
    FBlockStreamId: LongWord;
    FBlockEndStream: Boolean;
    FBlocks: LongWord;
    FBlockActive: Boolean;
  public
    /// build both codecs and apply the server settings
    constructor Create(const AMaxHeaderListSize, AMaxHeaderTableSize,
      AMaxFrameSize: LongWord);
    destructor Destroy; override;

    /// apply the header table size the peer sent
    // - RFC 9113 section 6.5.2: the new size changes both directions
    procedure ApplyPeerTableSize(const ATableSize: LongWord);

    /// TRUE while a header block waits for its CONTINUATION frames
    function InBlock: Boolean;
    /// the stream of the block under assembly
    function BlockStreamId: LongWord;
    /// the END_STREAM flag that the opening HEADERS frame carried
    function BlockEndStream: Boolean;
    /// how many CONTINUATION frames the block has seen
    function ContinuationCount: LongWord;
    /// the octets the block holds so far
    function BlockByteLength: Integer;
    /// start a block from the payload of a HEADERS frame
    procedure BeginBlock(const AStreamId: LongWord; const AEndStream: Boolean;
      const AData: TBytes);
    /// count one CONTINUATION frame and add its payload
    procedure AddBlockPart(const AData: TBytes);
    /// the block bytes, and a return to the idle state
    function TakeBlock: TBytes;

    /// decode one complete request header block
    // - a protocol error or a compression error leaves as an exception; the
    //   dynamic table state is lost, so the connection cannot continue
    function Decode(const ABlock: TBytes): THeaderBlock;

    /// encode one response header block
    // - the status comes first as the `:status` field, then the headers
    function EncodeResponse(const AStatus: Integer;
      const AHeaders: THeaderBlock): TBytes;

    /// turn an encoded response header block into wire frames
    // - one HEADERS frame and any CONTINUATION frames follow each other with
    //   no other frame between them, because the decoder state of the peer
    //   follows wire order
    // - the frames arrive in order, ready for the connection output queue
    function BuildHeaderRun(const AStreamId: LongWord;
      const AHeaderBlock: TBytes): TArray<TFrame>;
  end;

implementation

constructor THpackConnection.Create(const AMaxHeaderListSize,
  AMaxHeaderTableSize, AMaxFrameSize: LongWord);
begin
  inherited Create;
  FMaxFrameSize := AMaxFrameSize;
  FDecoder := THpackCodec.Create;
  FEncoder := THpackCodec.Create;
  FDecoder.MaxHeaderListSize := AMaxHeaderListSize;
  FDecoder.ApplySettings(AMaxHeaderTableSize);
  FEncoder.ApplySettings(AMaxHeaderTableSize);
end;

destructor THpackConnection.Destroy;
begin
  FEncoder.Free;
  FDecoder.Free;
  inherited Destroy;
end;

procedure THpackConnection.ApplyPeerTableSize(const ATableSize: LongWord);
begin
  FDecoder.ApplySettings(ATableSize);
  FEncoder.ApplySettings(ATableSize);
end;

function THpackConnection.InBlock: Boolean;
begin
  Result := FBlockActive;
end;

function THpackConnection.BlockStreamId: LongWord;
begin
  Result := FBlockStreamId;
end;

function THpackConnection.BlockEndStream: Boolean;
begin
  Result := FBlockEndStream;
end;

function THpackConnection.ContinuationCount: LongWord;
begin
  Result := FBlocks;
end;

function THpackConnection.BlockByteLength: Integer;
begin
  Result := FBlockCount;
end;

procedure THpackConnection.BeginBlock(const AStreamId: LongWord;
  const AEndStream: Boolean; const AData: TBytes);
begin
  FBlockStreamId := AStreamId;
  FBlockEndStream := AEndStream;
  FBlockCount := Length(AData);
  SetLength(FBlock, FBlockCount);
  if FBlockCount > 0 then
    Move(AData[0], FBlock[0], FBlockCount);
  FBlocks := 0;
  FBlockActive := True;
end;

procedure THpackConnection.AddBlockPart(const AData: TBytes);
begin
  Inc(FBlocks);
  if Length(AData) = 0 then
    Exit;
  SetLength(FBlock, FBlockCount + Length(AData));
  Move(AData[0], FBlock[FBlockCount], Length(AData));
  Inc(FBlockCount, Length(AData));
end;

function THpackConnection.TakeBlock: TBytes;
begin
  FBlockActive := False;
  SetLength(Result, FBlockCount);
  if FBlockCount > 0 then
    Move(FBlock[0], Result[0], FBlockCount);
  FBlockCount := 0;
  FBlocks := 0;
end;

function THpackConnection.Decode(const ABlock: TBytes): THeaderBlock;
begin
  Result := FDecoder.Decode(ABlock);
end;

function THpackConnection.EncodeResponse(const AStatus: Integer;
  const AHeaders: THeaderBlock): TBytes;
var
  Block: THeaderBlock;
  I: Integer;
begin
  SetLength(Block, Length(AHeaders) + 1);
  Block[0].Name := HeaderStatus;
  Block[0].Value := IntToStr(AStatus);
  for I := 0 to Length(AHeaders) - 1 do
    Block[I + 1] := AHeaders[I];
  Result := FEncoder.Encode(Block);
end;

function THpackConnection.BuildHeaderRun(const AStreamId: LongWord;
  const AHeaderBlock: TBytes): TArray<TFrame>;
var
  Offset, Chunk, Count: Integer;
  Slice: TBytes;
  First, Last: Boolean;
begin
  SetLength(Result, 0);
  Offset := 0;
  First := True;
  Count := 0;
  repeat
    Chunk := Length(AHeaderBlock) - Offset;
    if Chunk > Integer(FMaxFrameSize) then
      Chunk := Integer(FMaxFrameSize);
    SetLength(Slice, Chunk);
    if Chunk > 0 then
      Move(AHeaderBlock[Offset], Slice[0], Chunk);
    Inc(Offset, Chunk);
    Last := Offset >= Length(AHeaderBlock);
    SetLength(Result, Count + 1);
    if First then
      Result[Count] := BuildHeadersFrame(AStreamId, Slice, Last, False)
    else
      Result[Count] := BuildContinuationFrame(AStreamId, Slice, Last);
    Inc(Count);
    First := False;
  until Last;
end;

end.
