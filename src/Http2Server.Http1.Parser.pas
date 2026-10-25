{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, parser, mormot2, THttpRequestContext, guard, chunked, pipelining
notes:
  - This unit adapts the request parser of mORMot2 (THttpRequestContext in
    mormot.net.http.pas, revision b2b195da1) to the guard rules of
    Http2Server.Http1.Guard.
  - The parser of mORMot2 reads the request line, the header lines and the body.
    This unit stops it at each change of state, so the guard sees the request
    line before the header lines, the head before the body, each chunk-size line
    before the chunk, and the end of the chunked body. The trailer section is read
    here, because the parser of mORMot2 reads it as one line.
  - The body goes to the sink as it arrives, through a stream object, so no body
    is held by the parser. The unit works on one request at a time. Bytes of the
    next requests wait in the buffer until NextRequest.
  - The parser writes into the buffer that it reads (it replaces a CR by NUL), so
    this unit owns a private copy of the bytes.
---
}
/// The HTTP/1.1 request parser with the guard rules
unit Http2Server.Http1.Parser;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes,
  mormot.core.base, mormot.net.http,
  Http2Server.Http1.Limits, Http2Server.Http1.Guard;

type
  /// The receiver of the parser.
  IH1ParserSink = interface
    ['{7E1F0C11-0081-4A11-9C72-000000000B01}']
    /// the head passed every check
    procedure HeadComplete(const AHead: TH1Head);
    /// body octets, already de-chunked
    procedure BodyBytes(const AData; const ACount: Integer);
    /// the request is complete: the body ended, or there was none
    procedure BodyEnd;
    /// a rule failed; the parser takes no more input
    procedure Rejected(const AVerdict: TH1Verdict);
  end;

  TH1ParserState = (
    /// reading the request line, the header lines or the body
    pwReading,
    /// the request is complete; later bytes wait for NextRequest
    pwDone,
    /// a rule failed
    pwFailed);

  TH1Parser = class;

  /// the stream that the parser of mORMot2 writes the body into
  TH1BodyStream = class(TStream)
  private
    FOwner: TH1Parser;
  public
    constructor Create(const AOwner: TH1Parser);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
  end;

  /// the request parser of one connection
  TH1Parser = class
  private
    FLimits: THttp11Limits;
    FSink: IH1ParserSink;
    FCtx: THttpRequestContext;
    FBody: TH1BodyStream;
    FBuf: TBytes;
    FStart, FEnd: Integer;
    FState: TH1ParserState;
    FHeadDone: Boolean;
    FLineChecked: Boolean;
    FLeadingEmpty: Integer;
    FRequest: TH1RequestLine;
    // the octets from FScanAt on, FScanLen of them, hold no CR (a scan memo)
    FScanAt, FScanLen: Integer;
    FScanWork: Int64;
    function Unparsed: Integer;
    function FirstCr(const AFrom, AEnd: Integer): Integer;
    procedure Fail(const AVerdict: TH1Verdict);
    procedure Compact;
    procedure Run;
    function LineTooLong(const ALimit: Integer): Boolean;
    function HeaderRegionExceeds: Boolean;
    function SkipLeadingEmptyLines: Boolean;
    function TakeTrailer: Boolean;
    function CheckHead: Boolean;
    function MapError: TH1Verdict;
    procedure EmitBody(const AData; const ACount: Integer);
    procedure ResetContext;
  public
    constructor Create(const ALimits: THttp11Limits; const ASink: IH1ParserSink);
    destructor Destroy; override;
    /// consume ACount octets; the sink is called as the request takes shape
    procedure Feed(const AData; const ACount: Integer);
    /// the response ended and the connection stays open: parse the next request
    // - the bytes that arrived in the meantime are parsed now
    procedure NextRequest;
    /// octets held in the buffer that no request consumed
    function Buffered: Integer;
    /// the octets that the line scans looked at so far (a test reads it)
    property ScanWork: Int64 read FScanWork;
  end;

implementation

{ TH1BodyStream }

constructor TH1BodyStream.Create(const AOwner: TH1Parser);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TH1BodyStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TH1BodyStream.Write(const Buffer; Count: Longint): Longint;
begin
  FOwner.EmitBody(Buffer, Count);
  Result := Count;
end;

function TH1BodyStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

{ TH1Parser }

constructor TH1Parser.Create(const ALimits: THttp11Limits;
  const ASink: IH1ParserSink);
begin
  inherited Create;
  FLimits := ALimits;
  FSink := ASink;
  FBody := TH1BodyStream.Create(Self);
  FState := pwReading;
  ResetContext;
end;

destructor TH1Parser.Destroy;
begin
  FCtx.ContentStream := nil;
  FBody.Free;
  inherited Destroy;
end;

procedure TH1Parser.ResetContext;
begin
  FCtx.ContentStream := nil;
  FCtx.Reset;
  FCtx.State := hrsGetCommand;
  FCtx.Options := [hroHeadersUnfiltered, hroHeadersSanitize];
  FCtx.ContentStream := FBody;
  FCtx.ContentMaxSize := FLimits.MaxBodySize;
  FHeadDone := False;
  FLineChecked := False;
  FLeadingEmpty := 0;
  FScanLen := 0;
end;

/// the offset of the first CR in [AFrom, AEnd), or AEnd when there is none
// - a scan of the unfinished line at the start of the buffer resumes where the
//   last scan stopped, so a slow sender costs one comparison for each octet
function TH1Parser.FirstCr(const AFrom, AEnd: Integer): Integer;
var
  I, From: Integer;
begin
  From := AFrom;
  if (AFrom = 0) and (FScanLen > 0) and (FScanAt = FStart) and (FScanLen <= AEnd) then
    From := FScanLen;
  I := From;
  while (I < AEnd) and (FBuf[FStart + I] <> 13) do
    Inc(I);
  Inc(FScanWork, I - From);
  if (AFrom = 0) and (I = AEnd) then
  begin
    FScanAt := FStart;
    FScanLen := AEnd;
  end;
  Result := I;
end;

function TH1Parser.Unparsed: Integer;
begin
  Result := FEnd - FStart;
end;

function TH1Parser.Buffered: Integer;
begin
  Result := Unparsed;
end;

procedure TH1Parser.Fail(const AVerdict: TH1Verdict);
begin
  FState := pwFailed;
  FSink.Rejected(AVerdict);
end;

procedure TH1Parser.Compact;
begin
  if FStart = FEnd then
  begin
    FStart := 0;
    FEnd := 0;
    FScanLen := 0;
  end
  else if FStart > 4096 then
  begin
    FScanLen := 0;
    Move(FBuf[FStart], FBuf[0], FEnd - FStart);
    Dec(FEnd, FStart);
    FStart := 0;
  end;
end;

procedure TH1Parser.EmitBody(const AData; const ACount: Integer);
begin
  if ACount > 0 then
    FSink.BodyBytes(AData, ACount);
end;

procedure TH1Parser.Feed(const AData; const ACount: Integer);
var
  Need: Integer;
begin
  if (FState = pwFailed) or (ACount <= 0) then
    Exit;
  if FState = pwDone then
    // later requests wait; the count of waiting octets is bounded
    if Unparsed + ACount > FLimits.MaxPipelinedOctets then
    begin
      Fail(H1Refuse(400, 'the pipelined octets are over the limit'));
      Exit;
    end;
  Compact;
  Need := FEnd + ACount;
  if Need > Length(FBuf) then
    SetLength(FBuf, Need + Need div 2 + 256);
  Move(AData, FBuf[FEnd], ACount);
  FEnd := Need;
  if FState = pwReading then
    Run;
end;

procedure TH1Parser.NextRequest;
begin
  if FState = pwFailed then
    Exit;
  FState := pwReading;
  ResetContext;
  Compact;
  if Unparsed > 0 then
    Run;
end;

/// true when the unfinished line is already longer than ALimit
function TH1Parser.LineTooLong(const ALimit: Integer): Boolean;
var
  I, N: Integer;
begin
  N := Unparsed;
  I := FirstCr(0, N);
  if I < N then
    Result := I > ALimit
  else
    Result := N > ALimit;
end;

/// true when a header line, or the header section so far, passes its limit
// - the scan stops at the blank line that ends the head, so body octets that
//   arrived in the same read are never counted as header octets
function TH1Parser.HeaderRegionExceeds: Boolean;
var
  P, I, N, Len, Total: Integer;
begin
  Result := False;
  N := Unparsed;
  P := 0;
  Total := FCtx.Head.Len;
  while P < N do
  begin
    I := FirstCr(P, N);
    Len := I - P;
    if Len > FLimits.MaxHeaderLine then
      Exit(True);
    if I >= N then
    begin
      // an unfinished line: it counts, and the next read decides
      Inc(Total, Len);
      Break;
    end;
    if Len = 0 then
      Break;   // the blank line: the head ends here
    Inc(Total, Len + 2);
    P := I + 2;
  end;
  Result := Total > FLimits.MaxHeaderOctets;
end;

/// skip the empty lines before a request line; false when there are too many
function TH1Parser.SkipLeadingEmptyLines: Boolean;
begin
  Result := True;
  while (Unparsed >= 2) and (FBuf[FStart] = 13) and (FBuf[FStart + 1] = 10) do
  begin
    Inc(FStart, 2);
    Inc(FLeadingEmpty);
    if FLeadingEmpty > cH1MaxLeadingEmptyLines then
      Exit(False);
  end;
end;

function TH1Parser.MapError: TH1Verdict;
begin
  case FCtx.State of
    hrsErrorPayloadTooLarge:
      Result := H1Refuse(413, 'the body is over the limit');
    hrsErrorContentStreamWrite:
      Result := H1Refuse(500, 'the body could not be stored');
  else
    Result := H1Refuse(400, 'the message is malformed');
  end;
end;

/// find the end of the trailer section and check it; false when more input is due
function TH1Parser.TakeTrailer: Boolean;
var
  I, N: Integer;
  Raw: RawByteString;
  V: TH1Verdict;
begin
  Result := False;
  N := Unparsed;
  if N >= 2 then
    if (FBuf[FStart] = 13) and (FBuf[FStart + 1] = 10) then
    begin
      // no trailer field
      Inc(FStart, 2);
      Exit(True);
    end;
  for I := 0 to N - 4 do
    if (FBuf[FStart + I] = 13) and (FBuf[FStart + I + 1] = 10) and
       (FBuf[FStart + I + 2] = 13) and (FBuf[FStart + I + 3] = 10) then
    begin
      SetLength(Raw, I);
      if I > 0 then
        Move(FBuf[FStart], Raw[1], I);
      V := H1CheckTrailer(Raw, FLimits);
      if V.Status <> 0 then
      begin
        Fail(V);
        Exit(False);
      end;
      // the trailer fields are dropped, never merged into the head
      Inc(FStart, I + 4);
      Exit(True);
    end;
  if N > FLimits.MaxTrailerOctets + 4 then
    Fail(H1Refuse(431, 'the trailer section is too large'));
end;

function TH1Parser.CheckHead: Boolean;
var
  Head: TH1Head;
  V: TH1Verdict;
  Raw: RawByteString;
  Framing: TH1Framing;
begin
  Result := False;
  FCtx.ParseHeaderFinalize;
  Raw := FCtx.Headers;
  V := H1CheckHead(FRequest, Raw, FLimits, Head);
  if V.Status <> 0 then
  begin
    Fail(V);
    Exit;
  end;
  // the parser and the guard must agree on how the body is framed; a request
  // where they differ is the request that smuggling needs
  if hfTransferChunked in FCtx.HeaderFlags then
    Framing := bfChunked
  else if FCtx.ContentLength > 0 then
    Framing := bfLength
  else
    Framing := bfNone;
  if (Framing <> Head.Framing) or
     ((Framing = bfLength) and (FCtx.ContentLength <> Head.ContentLength)) then
  begin
    Fail(H1Refuse(400, 'the parser and the guard read the body framing differently'));
    Exit;
  end;
  FHeadDone := True;
  FSink.HeadComplete(Head);
  Result := FState <> pwFailed;
end;

procedure TH1Parser.Run;
var
  St: TProcessParseLine;
  Prev: THttpRequestState;
  Line: RawByteString;
  V: TH1Verdict;
  Size: Int64;
  Progressed: Boolean;
begin
  while FState = pwReading do
  begin
    Prev := FCtx.State;
    // the tail of a chunked body: the trailer section is read here
    if Prev = hrsGetBodyChunkedDataLastLine then
    begin
      if not TakeTrailer then
        Break;
      FCtx.State := hrsWaitProcessing;
      FState := pwDone;
      FSink.BodyEnd;
      Break;
    end;
    if Prev in [hrsGetCommand, hrsGetHeaders] then
    begin
      if Prev = hrsGetCommand then
      begin
        if not SkipLeadingEmptyLines then
        begin
          Fail(H1Refuse(400, 'too many empty lines before the request line'));
          Break;
        end;
        if Unparsed = 0 then
          Break;
        // a single CR may be the start of an empty line; wait for its LF
        if (Unparsed = 1) and (FBuf[FStart] = 13) then
          Break;
        if LineTooLong(FLimits.MaxRequestLine) then
        begin
          Fail(H1Refuse(414, 'the request line is too long'));
          Break;
        end;
      end
      else if HeaderRegionExceeds then
      begin
        Fail(H1Refuse(431, 'a header line or the header section is too large'));
        Break;
      end;
    end;
    // a chunk-size line and the line after chunk data have a bound too
    if ((Prev = hrsGetBodyChunkedHexFirst) or (Prev = hrsGetBodyChunkedHexNext)) and
       LineTooLong(FLimits.MaxChunkExtension + 24) then
    begin
      Fail(H1Refuse(400, 'a chunk-size line is too long'));
      Break;
    end;
    if (Prev = hrsGetBodyChunkedDataVoidLine) and LineTooLong(8) then
    begin
      Fail(H1Refuse(400, 'chunk data is not followed by CRLF'));
      Break;
    end;
    if Unparsed = 0 then
      Break;
    St.P := PUtf8Char(@FBuf[FStart]);
    St.Len := Unparsed;
    St.Line := nil;
    St.LineLen := 0;
    Progressed := FCtx.ProcessRead(St, {returnOnStateChange=}True);
    FStart := PtrUInt(St.P) - PtrUInt(@FBuf[0]);
    // an error state ends the message
    if FCtx.State >= hrsErrorPayloadTooLarge then
    begin
      Fail(MapError);
      Break;
    end;
    if FCtx.State <> Prev then
    begin
      case Prev of
        hrsGetCommand:
          begin
            // FCtx.CommandUri holds the whole request line at this point
            Line := FCtx.CommandUri;
            V := H1CheckRequestLine(Line, FLimits, FRequest);
            if V.Status <> 0 then
            begin
              Fail(V);
              Break;
            end;
            FLineChecked := True;
          end;
        hrsGetBodyChunkedHexFirst, hrsGetBodyChunkedHexNext:
          begin
            SetString(Line, St.Line, St.LineLen);
            V := H1CheckChunkLine(Line, FLimits, Size);
            if V.Status <> 0 then
            begin
              Fail(V);
              Break;
            end;
          end;
        hrsGetBodyChunkedDataVoidLine:
          if St.LineLen <> 0 then
          begin
            Fail(H1Refuse(400, 'chunk data is not followed by CRLF'));
            Break;
          end;
      end;
      // the head ends where the state first becomes a body state or the end
      if (not FHeadDone) and FLineChecked and
         (FCtx.State in [hrsGetBodyChunkedHexFirst, hrsGetBodyContentLengthFirst,
           hrsWaitProcessing]) then
        if not CheckHead then
          Break;
      if FCtx.State = hrsWaitProcessing then
      begin
        FState := pwDone;
        FSink.BodyEnd;
        Break;
      end;
    end
    else if not Progressed then
      Break;   // not enough input
  end;
  Compact;
end;

end.
