{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, test, peer, flow control, hpack, settings, trailers, padding
notes:
  - This unit is a strict HTTP/2 peer for the tests of the hardening plan. It
    drives TServerConnectionCore in memory, with no socket, so a test is fast
    and has no timing.
  - The peer sends every frame the review needs. These are SETTINGS with chosen
    entries, HEADERS with trailers, padded DATA, PRIORITY, WINDOW_UPDATE with
    any increment, RST_STREAM, PING and GOAWAY.
  - The peer reads every frame the server writes, with type, flags, stream id
    and payload. It decodes header blocks with a table that the test caps, and
    it records a violation when a block cannot be decoded.
  - The peer models its own receive windows and records a violation when the
    server sends more DATA than the windows allow.
---
}
/// A strict in-memory HTTP/2 peer for the connection core
unit Http2Server.H2Peer;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Generics.Collections,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Limits, Http2Server.Connection, Http2Server.Seam,
  Http2Server.Stream;

type
  /// records the events the core raises
  TPeerEvents = class(TInterfacedObject, IConnectionEvents)
  private
    FRequests, FResets, FClosing: Integer;
    FReadyIds: TList<LongWord>;
    FTripped: Boolean;
    FTripKind: TLimitKind;
  public
    constructor Create;
    destructor Destroy; override;
    procedure RequestReady(const AStream: TServerStream);
    procedure StreamReset(const AStream: TServerStream);
    procedure ConnectionClosing;
    procedure LimitTripped(const AKind: TLimitKind);
    /// RequestReady calls so far
    property Requests: Integer read FRequests;
    /// the stream ids in the order of the RequestReady calls
    property ReadyIds: TList<LongWord> read FReadyIds;
    property Resets: Integer read FResets;
    property Closing: Integer read FClosing;
    property Tripped: Boolean read FTripped;
    property TripKind: TLimitKind read FTripKind;
  end;

  /// one received frame with the header list that its block decoded to
  TPeerFrame = record
    Frame: TFrame;
    /// the decoded fields of a HEADERS frame; nil for other frames
    Fields: THeaderBlock;
  end;

  /// the default core options of a peer test
  TPeerOptions = record
    Core: TConnectionCoreOptions;
    /// the control-frame bucket capacity
    BucketCapacity: Integer;
    class function Default: TPeerOptions; static;
  end;

  /// an in-memory client of one server connection core
  TH2Peer = class
  private
    FCore: TServerConnectionCore;
    FEvents: TPeerEvents;
    FEventsRef: IConnectionEvents;
    FClock: TManualMonotonicClock;
    FClockRef: IMonotonicClock;
    FLimits: TConnectionLimits;
    FEnc, FDec: THpackCodec;
    FReceived: TList<TPeerFrame>;
    FViolations: TStringList;
    FConnWindow: Int64;
    FStreamWindow: TDictionary<LongWord, Int64>;
    FInitialWindow: Int64;
    FAutoCredit: Boolean;
    FDecoderCap: LongWord;
    FBlockBuf: TBytes;
    procedure Absorb(const AFrame: TFrame);
    procedure NoteData(const AFrame: TFrame);
    function WindowOf(const AStreamId: LongWord): Int64;
  public
    constructor Create; overload;
    constructor Create(const AOptions: TPeerOptions); overload;
    destructor Destroy; override;

    // ---- what the peer sends ----

    /// feed raw octets to the core
    procedure SendRaw(const AData: TBytes);
    /// feed one frame, and the preface before the first frame when asked
    procedure Send(const AFrame: TFrame);
    procedure SendPreface;
    /// SETTINGS with the given entries only (id, value pairs)
    procedure SendSettings(const AIds: array of Word;
      const AValues: array of LongWord);
    procedure SendSettingsAck;
    /// a header block of fields; stream, flags as given
    procedure SendHeaders(const AStreamId: LongWord; const AFields: THeaderBlock;
      const AEndStream: Boolean = True; const AEndHeaders: Boolean = True);
    /// a plain GET request on the stream
    procedure SendGet(const AStreamId: LongWord; const APath: string = '/';
      const AEndStream: Boolean = True);
    /// a POST request head (no END_STREAM), for body and trailer tests
    procedure SendPostHead(const AStreamId: LongWord; const APath: string = '/');
    /// a trailer block: HEADERS with END_STREAM and the given fields
    procedure SendTrailers(const AStreamId: LongWord; const AFields: THeaderBlock);
    procedure SendData(const AStreamId: LongWord; const ACount: Integer;
      const AEndStream: Boolean = False);
    /// DATA with a pad length octet and APad padding octets
    procedure SendPaddedData(const AStreamId: LongWord; const ACount, APad: Integer;
      const AEndStream: Boolean = False);
    procedure SendWindowUpdate(const AStreamId, AIncrement: LongWord);
    procedure SendPriority(const AStreamId, ADependsOn: LongWord;
      const AWeight: LongWord = 15);
    procedure SendRst(const AStreamId: LongWord; const ACode: THttp2ErrorCode);
    procedure SendPing(const AAck: Boolean = False);
    procedure SendGoAway(const ALastStreamId: LongWord;
      const ACode: THttp2ErrorCode = ecNoError);

    // ---- what the peer reads ----

    /// take the output of the core, parse it, update the models
    // - answers the frames that arrived in this call
    function Pump: TArray<TFrame>;
    /// run a frame through the models as if the server had written it
    // - a test of the peer itself uses this to show that a violation is seen
    procedure Inject(const AFrame: TFrame);
    /// every frame received so far
    property Received: TList<TPeerFrame> read FReceived;
    function CountOf(const AType: TFrameType): Integer;
    function CountOnStream(const AType: TFrameType; const AStreamId: LongWord): Integer;
    /// the first frame of a type, or a frame of type ftData with stream 0 when none
    function Find(const AType: TFrameType; out AFrame: TPeerFrame): Boolean;
    /// the sum of the DATA payload octets that arrived on a stream
    function DataOctets(const AStreamId: LongWord): Int64;
    /// the status field of the first HEADERS on the stream, or ''
    function StatusOf(const AStreamId: LongWord): string;
    /// the error code of the first GOAWAY, and whether one arrived
    function GoAwayCode(out ACode: THttp2ErrorCode): Boolean;
    /// the error code of the first RST_STREAM on the stream
    function ResetCode(const AStreamId: LongWord; out ACode: THttp2ErrorCode): Boolean;

    // ---- the models ----

    /// the receive window the peer holds on the connection now
    property ConnectionWindow: Int64 read FConnWindow;
    function StreamWindow(const AStreamId: LongWord): Int64;
    /// the SETTINGS_HEADER_TABLE_SIZE the peer announces for its decoder
    property DecoderCap: LongWord read FDecoderCap write FDecoderCap;
    /// true to send WINDOW_UPDATE frames for every DATA octet received
    property AutoCredit: Boolean read FAutoCredit write FAutoCredit;
    /// the broken rules the peer saw: window overruns, undecodable blocks
    property Violations: TStringList read FViolations;

    // ---- the server side, for the tests that need a response ----

    /// the response of a handler: headers, ACount body octets, then the end
    procedure Respond(const AStreamId: LongWord; const AStatus: Integer;
      const ACount: Integer);
    /// the same without the flush, so several streams can wait for one drain
    procedure QueueResponse(const AStreamId: LongWord; const AStatus: Integer;
      const ACount: Integer; const AHeaders: THeaderBlock);
    /// the sum of the WINDOW_UPDATE increments received on a stream
    function WindowUpdateSum(const AStreamId: LongWord): Int64;

    property Core: TServerConnectionCore read FCore;
    property Events: TPeerEvents read FEvents;
    property Clock: TManualMonotonicClock read FClock;
    property Encoder: THpackCodec read FEnc;
  end;

/// the fields of a request: method, scheme, path, authority
function RequestFields(const AMethod, APath: string): THeaderBlock;

implementation

const
  cDefaultWindow = 65535;

{ TPeerEvents }

constructor TPeerEvents.Create;
begin
  inherited Create;
  FReadyIds := TList<LongWord>.Create;
end;

destructor TPeerEvents.Destroy;
begin
  FReadyIds.Free;
  inherited Destroy;
end;

procedure TPeerEvents.RequestReady(const AStream: TServerStream);
begin
  Inc(FRequests);
  FReadyIds.Add(AStream.StreamId);
end;

procedure TPeerEvents.StreamReset(const AStream: TServerStream);
begin
  Inc(FResets);
end;

procedure TPeerEvents.ConnectionClosing;
begin
  Inc(FClosing);
end;

procedure TPeerEvents.LimitTripped(const AKind: TLimitKind);
begin
  FTripped := True;
  FTripKind := AKind;
end;

{ TPeerOptions }

class function TPeerOptions.Default: TPeerOptions;
begin
  Result.Core.ConnectionWindow := cDefaultWindow;
  Result.Core.InitialStreamWindow := cDefaultWindow;
  Result.Core.MaxConcurrentStreams := 100;
  Result.Core.MaxFrameSize := 16384;
  Result.Core.MaxHeaderListSize := 16384;
  Result.Core.MaxHeaderTableSize := 4096;
  Result.Core.MaxContinuations := 16;
  Result.Core.MaxHeaderBlockBytes := 262144;
  Result.Core.InboundBufferLimit := cDefaultWindow;
  Result.Core.OutboundBufferLimit := cDefaultWindow;
  Result.Core.ConnectionUpdateThreshold := cDefaultWindow div 2;
  Result.Core.StreamUpdateThreshold := cDefaultWindow div 2;
  Result.Core.ConnectProtocol := False;
  Result.BucketCapacity := 100000;
end;

{ helpers }

function RequestFields(const AMethod, APath: string): THeaderBlock;
begin
  SetLength(Result, 4);
  Result[0].Name := ':method';
  Result[0].Value := AMethod;
  Result[1].Name := ':scheme';
  Result[1].Value := 'https';
  Result[2].Name := ':path';
  Result[2].Value := APath;
  Result[3].Name := ':authority';
  Result[3].Value := 'example.com';
end;

function FrameWire(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

{ TH2Peer }

constructor TH2Peer.Create;
begin
  Create(TPeerOptions.Default);
end;

constructor TH2Peer.Create(const AOptions: TPeerOptions);
var
  R, C: TTokenBucketOptions;
begin
  inherited Create;
  FClock := TManualMonotonicClock.Create;
  FClockRef := FClock;
  FEvents := TPeerEvents.Create;
  FEventsRef := FEvents;
  R := TTokenBucketOptions.Create.WithCapacity(AOptions.BucketCapacity).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(2);
  C := TTokenBucketOptions.Create.WithCapacity(AOptions.BucketCapacity).
    WithRefillPerSecond(0).WithCostBeforeDispatch(1).WithCostAfterDispatch(1);
  FLimits := TConnectionLimits.Create(FClockRef, R, C);
  FCore := TServerConnectionCore.Create(AOptions.Core, FEventsRef, FLimits,
    FClockRef);
  FEnc := THpackCodec.Create;
  FDec := THpackCodec.Create;
  FDecoderCap := 4096;
  FDec.ApplySettings(FDecoderCap);
  FReceived := TList<TPeerFrame>.Create;
  FViolations := TStringList.Create;
  FStreamWindow := TDictionary<LongWord, Int64>.Create;
  FConnWindow := cDefaultWindow;
  FInitialWindow := cDefaultWindow;
end;

destructor TH2Peer.Destroy;
begin
  FStreamWindow.Free;
  FViolations.Free;
  FReceived.Free;
  FDec.Free;
  FEnc.Free;
  FCore := nil;
  FLimits.Free;
  inherited Destroy;
end;

procedure TH2Peer.SendRaw(const AData: TBytes);
begin
  FCore.Feed(AData);
end;

procedure TH2Peer.Send(const AFrame: TFrame);
begin
  FCore.Feed(FrameWire(AFrame));
end;

procedure TH2Peer.SendPreface;
var
  Wire: TBytes;
begin
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  FCore.Feed(Wire);
end;

procedure TH2Peer.SendSettings(const AIds: array of Word;
  const AValues: array of LongWord);
var
  Payload: TBytes;
  I: Integer;
begin
  SetLength(Payload, Length(AIds) * 6);
  for I := 0 to High(AIds) do
  begin
    Payload[I * 6] := AIds[I] shr 8;
    Payload[I * 6 + 1] := AIds[I] and $FF;
    Payload[I * 6 + 2] := AValues[I] shr 24;
    Payload[I * 6 + 3] := (AValues[I] shr 16) and $FF;
    Payload[I * 6 + 4] := (AValues[I] shr 8) and $FF;
    Payload[I * 6 + 5] := AValues[I] and $FF;
    // the models follow what the peer announces for itself
    if AIds[I] = 4 then
      FInitialWindow := AValues[I]
    else if AIds[I] = 1 then
    begin
      FDecoderCap := AValues[I];
      FDec.ApplySettings(FDecoderCap);
    end;
  end;
  Send(TFrame.Create(ftSettings, [], 0, Payload));
end;

procedure TH2Peer.SendSettingsAck;
begin
  Send(BuildSettingsAck);
end;

procedure TH2Peer.SendHeaders(const AStreamId: LongWord;
  const AFields: THeaderBlock; const AEndStream, AEndHeaders: Boolean);
begin
  Send(BuildHeadersFrame(AStreamId, FEnc.Encode(AFields), AEndHeaders,
    AEndStream));
end;

procedure TH2Peer.SendGet(const AStreamId: LongWord; const APath: string;
  const AEndStream: Boolean);
begin
  SendHeaders(AStreamId, RequestFields('GET', APath), AEndStream);
end;

procedure TH2Peer.SendPostHead(const AStreamId: LongWord; const APath: string);
begin
  SendHeaders(AStreamId, RequestFields('POST', APath), False);
end;

procedure TH2Peer.SendTrailers(const AStreamId: LongWord;
  const AFields: THeaderBlock);
begin
  SendHeaders(AStreamId, AFields, True);
end;

procedure TH2Peer.SendData(const AStreamId: LongWord; const ACount: Integer;
  const AEndStream: Boolean);
var
  Payload: TBytes;
begin
  SetLength(Payload, ACount);
  if ACount > 0 then
    FillChar(Payload[0], ACount, Ord('d'));
  Send(BuildDataFrame(AStreamId, Payload, AEndStream));
end;

procedure TH2Peer.SendPaddedData(const AStreamId: LongWord; const ACount,
  APad: Integer; const AEndStream: Boolean);
var
  Payload: TBytes;
  Flags: TFrameFlags;
begin
  // pad length octet, data, padding (RFC 9113 section 6.1)
  SetLength(Payload, 1 + ACount + APad);
  FillChar(Payload[0], Length(Payload), 0);
  Payload[0] := APad;
  if ACount > 0 then
    FillChar(Payload[1], ACount, Ord('d'));
  Flags := [ffPadded];
  if AEndStream then
    Include(Flags, ffEndStream);
  Send(TFrame.Create(ftData, Flags, AStreamId, Payload));
end;

procedure TH2Peer.SendWindowUpdate(const AStreamId, AIncrement: LongWord);
begin
  // the frame builder rejects a zero increment; the tests that need one send
  // the payload by hand
  if AIncrement = 0 then
    Send(TFrame.Create(ftWindowUpdate, [], AStreamId, TBytes.Create(0, 0, 0, 0)))
  else
    Send(BuildWindowUpdateFrame(AStreamId, AIncrement));
  if AStreamId = 0 then
    Inc(FConnWindow, AIncrement)
  else
    FStreamWindow.AddOrSetValue(AStreamId, WindowOf(AStreamId) + AIncrement);
end;

procedure TH2Peer.SendPriority(const AStreamId, ADependsOn, AWeight: LongWord);
begin
  Send(BuildPriorityFrame(AStreamId, ADependsOn, AWeight, False));
end;

procedure TH2Peer.SendRst(const AStreamId: LongWord; const ACode: THttp2ErrorCode);
begin
  Send(BuildRstStreamFrame(AStreamId, ACode));
end;

procedure TH2Peer.SendPing(const AAck: Boolean);
begin
  Send(BuildPingFrame(TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8), AAck));
end;

procedure TH2Peer.SendGoAway(const ALastStreamId: LongWord;
  const ACode: THttp2ErrorCode);
begin
  Send(BuildGoAwayFrame(ALastStreamId, ACode, nil));
end;

function TH2Peer.WindowOf(const AStreamId: LongWord): Int64;
begin
  if not FStreamWindow.TryGetValue(AStreamId, Result) then
    Result := FInitialWindow;
end;

function TH2Peer.StreamWindow(const AStreamId: LongWord): Int64;
begin
  Result := WindowOf(AStreamId);
end;

procedure TH2Peer.NoteData(const AFrame: TFrame);
var
  N: Int64;
  Stream: LongWord;
begin
  // flow control counts the whole payload, padding included (RFC 9113 6.9.1)
  N := Length(AFrame.Payload);
  Stream := AFrame.Header.StreamId;
  Dec(FConnWindow, N);
  FStreamWindow.AddOrSetValue(Stream, WindowOf(Stream) - N);
  if FConnWindow < 0 then
    FViolations.Add(Format('the server overran the connection window by %d on stream %d',
      [-FConnWindow, Stream]));
  if WindowOf(Stream) < 0 then
    FViolations.Add(Format('the server overran the window of stream %d by %d',
      [Stream, -WindowOf(Stream)]));
  if FAutoCredit and (N > 0) then
  begin
    SendWindowUpdate(0, N);
    SendWindowUpdate(Stream, N);
  end;
end;

procedure TH2Peer.Absorb(const AFrame: TFrame);
var
  Entry: TPeerFrame;
  Part: TBytes;
begin
  Entry.Frame := AFrame;
  Entry.Fields := nil;
  case AFrame.Header.FrameType of
    ftHeaders, ftContinuation:
      begin
        // a header block spans HEADERS and the CONTINUATION frames after it; the
        // fields attach to the frame that carries END_HEADERS
        Part := ExtractHeaderBlock(AFrame);
        if AFrame.Header.FrameType = ftHeaders then
          FBlockBuf := nil;
        if Length(Part) > 0 then
        begin
          SetLength(FBlockBuf, Length(FBlockBuf) + Length(Part));
          Move(Part[0], FBlockBuf[Length(FBlockBuf) - Length(Part)], Length(Part));
        end;
        if AFrame.IsEndHeaders then
          try
            Entry.Fields := FDec.Decode(FBlockBuf);
            FBlockBuf := nil;
          except
            on E: Exception do
              FViolations.Add('undecodable header block on stream ' +
                IntToStr(AFrame.Header.StreamId) + ': ' + E.Message);
          end;
      end;
    ftData:
      NoteData(AFrame);
    ftSettings:
      if not AFrame.IsAck then
        Send(BuildSettingsAck);
  end;
  FReceived.Add(Entry);
end;

procedure TH2Peer.Inject(const AFrame: TFrame);
begin
  Absorb(AFrame);
end;

function TH2Peer.Pump: TArray<TFrame>;
var
  Data: TBytes;
  Offset, N: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  Result := nil;
  FCore.TakeOutput(Data);
  Offset := 0;
  while Offset + FrameHeaderSize <= Length(Data) do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(Data[Offset], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    N := FrameHeaderSize + Integer(Header.Length);
    if Offset + N > Length(Data) then
    begin
      FViolations.Add('the server wrote a truncated frame');
      Break;
    end;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(Data[Offset + FrameHeaderSize], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Frame;
    Inc(Offset, N);
    Absorb(Frame);
  end;
end;

function TH2Peer.CountOf(const AType: TFrameType): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FReceived.Count - 1 do
    if FReceived[I].Frame.Header.FrameType = AType then
      Inc(Result);
end;

function TH2Peer.CountOnStream(const AType: TFrameType;
  const AStreamId: LongWord): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FReceived.Count - 1 do
    if (FReceived[I].Frame.Header.FrameType = AType) and
       (FReceived[I].Frame.Header.StreamId = AStreamId) then
      Inc(Result);
end;

function TH2Peer.Find(const AType: TFrameType; out AFrame: TPeerFrame): Boolean;
var
  I: Integer;
begin
  for I := 0 to FReceived.Count - 1 do
    if FReceived[I].Frame.Header.FrameType = AType then
    begin
      AFrame := FReceived[I];
      Exit(True);
    end;
  Result := False;
end;

function TH2Peer.DataOctets(const AStreamId: LongWord): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FReceived.Count - 1 do
    if (FReceived[I].Frame.Header.FrameType = ftData) and
       (FReceived[I].Frame.Header.StreamId = AStreamId) then
      Inc(Result, Length(ExtractDataPayload(FReceived[I].Frame)));
end;

function TH2Peer.StatusOf(const AStreamId: LongWord): string;
var
  I, J: Integer;
begin
  Result := '';
  for I := 0 to FReceived.Count - 1 do
    if (FReceived[I].Frame.Header.FrameType in [ftHeaders, ftContinuation]) and
       (FReceived[I].Frame.Header.StreamId = AStreamId) and
       (FReceived[I].Fields <> nil) then
    begin
      for J := 0 to High(FReceived[I].Fields) do
        if FReceived[I].Fields[J].Name = ':status' then
          Exit(FReceived[I].Fields[J].Value);
      Exit;
    end;
end;

function TH2Peer.GoAwayCode(out ACode: THttp2ErrorCode): Boolean;
var
  P: TPeerFrame;
  Id: LongWord;
  Debug: TBytes;
begin
  Result := Find(ftGoAway, P);
  if Result then
    ParseGoAway(P.Frame, Id, ACode, Debug);
end;

function TH2Peer.ResetCode(const AStreamId: LongWord;
  out ACode: THttp2ErrorCode): Boolean;
var
  I: Integer;
begin
  for I := 0 to FReceived.Count - 1 do
    if (FReceived[I].Frame.Header.FrameType = ftRstStream) and
       (FReceived[I].Frame.Header.StreamId = AStreamId) then
    begin
      ParseRstStream(FReceived[I].Frame, ACode);
      Exit(True);
    end;
  Result := False;
end;

procedure TH2Peer.QueueResponse(const AStreamId: LongWord; const AStatus: Integer;
  const ACount: Integer; const AHeaders: THeaderBlock);
var
  Stream: TServerStream;
  Body: TBytes;
begin
  Stream := FCore.StreamById(AStreamId);
  if Stream = nil then
    raise Exception.CreateFmt('the core holds no stream %d', [AStreamId]);
  Stream.QueueResponseHeaders(AStatus, AHeaders, ACount = 0);
  if ACount > 0 then
  begin
    SetLength(Body, ACount);
    FillChar(Body[0], ACount, Ord('r'));
    if not Stream.TryWrite(Body) then
      raise Exception.CreateFmt('the outbound buffer of stream %d is full',
        [AStreamId]);
    Stream.RequestFinish;
  end;
end;

procedure TH2Peer.Respond(const AStreamId: LongWord; const AStatus: Integer;
  const ACount: Integer);
begin
  QueueResponse(AStreamId, AStatus, ACount, nil);
  FCore.Flush;
  FCore.DrainPending;
end;

function TH2Peer.WindowUpdateSum(const AStreamId: LongWord): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FReceived.Count - 1 do
    if (FReceived[I].Frame.Header.FrameType = ftWindowUpdate) and
       (FReceived[I].Frame.Header.StreamId = AStreamId) then
      Inc(Result, ParseWindowUpdate(FReceived[I].Frame));
end;

end.
