{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, state machine, flow control, hpack
notes:
  - This unit holds the server connection state machine.
  - The unit compiles without the mORMot units, because it touches no socket
    and no TLS. The caller holds the connection lock for every call.
---
}
/// HTTP/2 server connection core
// - Feed takes bytes from the socket and TakeOutput gives bytes for the socket.
// - The core holds no lock of its own: the caller holds the connection lock for
//   the whole of every call, so one thread uses the HPACK encoder and decoder.
// - The options record carries every limit. The core holds no limit literal.
unit Http2Server.Connection;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.FlowControl, Http2Server.Limits, Http2Server.Seam,
  Http2Server.Stream, Http2Server.Headers, Http2Server.Output,
  Http2Server.HpackConnection, Http2Server.RequestValidation;

type
  /// the per-connection values the core needs
  // - the factory fills every field; the core creates no default and holds no
  //   limit literal of its own
  TConnectionCoreOptions = record
    ConnectionWindow: LongInt;
    InitialStreamWindow: LongInt;
    MaxConcurrentStreams: LongWord;
    MaxFrameSize: LongWord;
    MaxHeaderListSize: LongWord;
    MaxHeaderTableSize: LongWord;
    MaxContinuations: LongWord;
    MaxHeaderBlockBytes: LongWord;
    InboundBufferLimit: Integer;
    OutboundBufferLimit: Integer;
    ConnectionUpdateThreshold: LongWord;
    StreamUpdateThreshold: LongWord;
  end;

  /// the core raises one of these events for every state change the server acts on
  IConnectionEvents = interface
    ['{7E1F0C11-0031-4A11-9C72-000000000601}']
    /// a header block ended and the request is complete
    procedure RequestReady(const AStream: TServerStream);
    /// the peer reset the stream
    procedure StreamReset(const AStream: TServerStream);
    /// the peer sent GOAWAY, or the core closed the connection
    procedure ConnectionClosing;
    /// a bucket tripped and the connection must close after its streams drain
    procedure LimitTripped(const AKind: TLimitKind);
  end;

  TServerConnectionCore = class;

  /// The IStreamHost adapter of one core.
  ///
  /// A stream calls OutputPending when a handler wrote, and the adapter asks
  /// the core to wake the IO thread.  The adapter holds the core without an
  /// interface reference, so no reference cycle forms.
  TCoreStreamHost = class(TInterfacedObject, IStreamHost)
  private
    FCore: TServerConnectionCore;   // weak reference; the core owns this
  public
    constructor Create(const ACore: TServerConnectionCore);
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    procedure OutputPending(const AStreamId: LongWord);
  end;

  /// the server connection state machine
  TServerConnectionCore = class(TInterfacedObject)
  private
    FOptions: TConnectionCoreOptions;
    FEvents: IConnectionEvents;
    FLimits: TConnectionLimits;
    FFlow: TFlowControl;
    FOut: TOutputDrain;
    /// the IStreamHost adapter the core hands to every stream
    // - the core cannot be its own host interface: an interface reference to
    //   self inside a TInterfacedObject invites a refcount double-destroy
    FHost: IStreamHost;
    FStreams: TObjectList<TServerStream>;
    FById: TDictionary<LongWord, TServerStream>;
    /// the HPACK state of this connection
    FHpack: THpackConnection;
    FSettings: TConnectionSettings;
    FPeerSettings: TConnectionSettings;
    FInput: TBytes;
    FInputCount: Integer;
    FPreface: TBytes;
    FPrefaceCount: Integer;
    FOutput: TBytes;
    FOutputCount: Integer;
    FLastStreamId: LongWord;
    FClosing: Boolean;
    FGoAwaySent: Boolean;
    FTripKind: TLimitKind;
    FConnUpdatePending: LongWord;
    /// the waker that the IO side installs; nil until the server registers one
    FWaker: IWriteWaker;
    /// true while queued output waits for the IO thread
    // - the flag makes the wake-up edge-triggered: one Signal runs per
    //   transition from "no output" to "output"
    FWakePending: Boolean;
    /// guards FWakePending, because a handler thread sets it and an IO thread
    //   clears it
    FWakeLock: TCriticalSection;
    /// the lock the caller holds; every stream the core creates takes it too,
    /// so a handler buffer operation never races the IO thread
    FConnLock: TCriticalSection;

    procedure HandleTrip(const AKind: TLimitKind);
    procedure LockConn;
    procedure UnlockConn;
    procedure ProcessFrame(const AFrame: TFrame);
    procedure ProcessPriority(const AFrame: TFrame);
    procedure ProcessHeaders(const AFrame: TFrame);
    procedure ProcessContinuation(const AFrame: TFrame);
    procedure CompleteHeaderBlock;
    function ValidateRequestBlock(const AStream: TServerStream;
      const AIsTrailer: Boolean): Boolean;
    procedure ProcessData(const AFrame: TFrame);
    procedure ProcessSettings(const AFrame: TFrame);
    procedure ProcessRstStream(const AFrame: TFrame);
    procedure ProcessPing(const AFrame: TFrame);
    procedure ProcessGoAway(const AFrame: TFrame);
    procedure ProcessWindowUpdate(const AFrame: TFrame);
    function NewStream(const AStreamId: LongWord): TServerStream;
    function FindStream(const AStreamId: LongWord): TServerStream;
    function OpenStreamCount: Integer;
    function CheckStreamId(const AStreamId: LongWord): Boolean;
    procedure QueueFrame(const AFrame: TFrame);
    procedure QueueBytes(const AData: TBytes);
    procedure SendGoAway(const ALastStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode);
    procedure SendRstStream(const AStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode);
    procedure FailConnection(const AMessage: string;
      const AErrorCode: THttp2ErrorCode);
    procedure CloseStream(const AStream: TServerStream);
    procedure ReapClosedStreams;
    procedure FlushLocked;
    procedure FlushPendingHeaders;
    procedure FlushStreamCredits;
    procedure FlushConnectionCredit;
    /// move the bytes the drain produced into the connection output queue
    procedure FlushDrainedOutput;
    procedure EmitHeaderRun(const AStream: TServerStream;
      const AHeaderBlock: TBytes);
  public
    constructor Create(const AOptions: TConnectionCoreOptions;
      const AEvents: IConnectionEvents; const ALimits: TConnectionLimits;
      const AClock: IMonotonicClock);
    destructor Destroy; override;

    /// consume bytes from the socket; a partial frame stays buffered
    procedure Feed(const AData: TBytes);
    /// take bytes for the socket; answers False when the queue is empty
    function TakeOutput(out AData: TBytes): Boolean;
    /// TRUE while bytes wait for the socket
    function HasOutput: Boolean;
    /// encode every pending response header block and queue the frames
    procedure Flush;
    /// the same work under the name the IO side uses before a write
    procedure FlushQueue;
    /// register the waker that the IO side signals when output appears
    procedure SetWriteWaker(const AWaker: IWriteWaker);
    /// ask the IO side to wake, once per transition to "output"
    // - a handler thread calls this from the stream host callback, never under
    //   the connection lock, so the waker may take its own locks
    procedure NotifyWantsWrite;
    /// encode the pending headers and drain the stream buffers into frames
    // - the IO side calls this after a handler wrote, so the frames reach the
    //   output queue with no further input from the peer
    procedure DrainPending;
    /// queue a GOAWAY frame and wake the write side
    // - the graceful stop of the server calls this on every open connection;
    //   the core sends no second GOAWAY
    procedure GracefulGoAway(const ALastStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode);

    /// the stream that owns AStreamId, or nil
    function StreamById(const AStreamId: LongWord): TServerStream;
    /// the octets the peer may still send on the connection window
    function ConnectionWindowSize: Int64;
    /// the octets the peer may still send on one stream window
    function StreamWindowSize(const AStreamId: LongWord): Int64;
    /// the settings the server sent to the peer
    property Settings: TConnectionSettings read FSettings;
    /// the settings the peer sent to the server
    property PeerSettings: TConnectionSettings read FPeerSettings;
    /// true once GOAWAY left the core
    property GoAwaySent: Boolean read FGoAwaySent;
    /// true while the connection winds down after a GOAWAY or a fault
    property IsClosing: Boolean read FClosing;
    /// the number of streams that count against SETTINGS_MAX_CONCURRENT_STREAMS
    property OpenStreams: Integer read OpenStreamCount;
    /// the highest client stream id the core accepted
    property LastProcessedStreamId: LongWord read FLastStreamId;
  end;

implementation

{ TCoreStreamHost }

constructor TCoreStreamHost.Create(const ACore: TServerConnectionCore);
begin
  inherited Create;
  FCore := ACore;
end;

procedure TCoreStreamHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
  // the connection sums the consumed credit and emits one WINDOW_UPDATE; the
  // sum happens under the connection lock inside FlushStreamCredits, which
  // reads the stream counter directly, so no work is needed here
end;

procedure TCoreStreamHost.OutputPending(const AStreamId: LongWord);
begin
  if FCore <> nil then
    FCore.NotifyWantsWrite;
end;

{ TServerConnectionCore }

constructor TServerConnectionCore.Create(const AOptions: TConnectionCoreOptions;
  const AEvents: IConnectionEvents; const ALimits: TConnectionLimits;
  const AClock: IMonotonicClock);
var
  OutOptions: TOutputDrainOptions;
begin
  inherited Create;
  FOptions := AOptions;
  FEvents := AEvents;
  FLimits := ALimits;
  FConnLock := TCriticalSection.Create;
  FFlow := TFlowControl.Create(FOptions.ConnectionWindow,
    FOptions.InitialStreamWindow);
  // the drain turns the handler buffers into DATA frames; the core carries a
  // nil waker because its own edge-triggered flag drives the IO wake-up
  OutOptions.MaxFrameSize := FOptions.MaxFrameSize;
  OutOptions.BytesPerTurn := 0;
  FOut := TOutputDrain.Create(OutOptions, FFlow, nil);
  FWakeLock := TCriticalSection.Create;
  // the host adapter is a borrowed reference to this core, so it forms no
  // reference cycle and its lifetime is the core lifetime
  FHost := TCoreStreamHost.Create(Self);
  FStreams := TObjectList<TServerStream>.Create(False);
  FById := TDictionary<LongWord, TServerStream>.Create;
  FHpack := THpackConnection.Create(FOptions.MaxHeaderListSize,
    FOptions.MaxHeaderTableSize, FOptions.MaxFrameSize);
  FSettings := TConnectionSettings.Defaults;
  FSettings.MaxConcurrentStreams := FOptions.MaxConcurrentStreams;
  FSettings.MaxFrameSize := FOptions.MaxFrameSize;
  FSettings.MaxHeaderListSize := FOptions.MaxHeaderListSize;
  FSettings.HeaderTableSize := FOptions.MaxHeaderTableSize;
  FSettings.InitialWindowSize := LongWord(FOptions.InitialStreamWindow);
  FSettings.EnablePush := False;
  // the peer settings start at the protocol defaults until the peer speaks
  FPeerSettings := TConnectionSettings.Defaults;
  FTripKind := lkReset;
  if FLimits <> nil then
    FLimits.OnTrip := HandleTrip;
end;

procedure TServerConnectionCore.LockConn;
begin
  FConnLock.Acquire;
end;

procedure TServerConnectionCore.UnlockConn;
begin
  FConnLock.Release;
end;

procedure TServerConnectionCore.HandleTrip(const AKind: TLimitKind);
begin
  // RFC 9113 section 10.5: a peer that exceeds an abuse limit is told to stop
  FTripKind := AKind;
  SendGoAway(FLastStreamId, ecEnhanceYourCalm);
  FClosing := True;
  if FEvents <> nil then
  begin
    FEvents.LimitTripped(AKind);
    FEvents.ConnectionClosing;
  end;
end;

destructor TServerConnectionCore.Destroy;
var
  I: Integer;
begin
  FHost := nil;
  FWakeLock.Free;
  FOut.Free;
  FById.Free;
  // each remaining stream holds the core reference; release it, so a stream
  // that a queue entry or a handler still holds is freed on the last release
  for I := 0 to FStreams.Count - 1 do
    FStreams[I].ReleaseRef;
  FStreams.Free;
  FFlow.Free;
  FHpack.Free;
  FConnLock.Free;
  inherited Destroy;
end;

procedure TServerConnectionCore.Feed(const AData: TBytes);
var
  Offset, Total, FrameLen, Need: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  LockConn;
  try
  if Length(AData) > 0 then
  begin
    if FInputCount + Length(AData) > Length(FInput) then
      SetLength(FInput, FInputCount + Length(AData));
    Move(AData[0], FInput[FInputCount], Length(AData));
    Inc(FInputCount, Length(AData));
  end;

  // the client connection preface precedes every frame and arrives in pieces
  if FPrefaceCount < ClientPrefaceSize then
  begin
    Need := ClientPrefaceSize - FPrefaceCount;
    if FInputCount < Need then
      Need := FInputCount;
    if Need > 0 then
    begin
      if FPrefaceCount + Need > Length(FPreface) then
        SetLength(FPreface, FPrefaceCount + Need);
      Move(FInput[0], FPreface[FPrefaceCount], Need);
      Inc(FPrefaceCount, Need);
      Move(FInput[Need], FInput[0], FInputCount - Need);
      Dec(FInputCount, Need);
    end;
    if FPrefaceCount < ClientPrefaceSize then
      Exit;
    if not CheckClientPreface(FPreface) then
    begin
      FailConnection('the client connection preface does not match',
        ecProtocolError);
      Exit;
    end;
    // the server SETTINGS frame is the first frame of the connection
    QueueFrame(BuildServerSettings(FSettings));
  end;

  Offset := 0;
  Total := FInputCount;
  while Offset + FrameHeaderSize <= Total do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(FInput[Offset], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    // RFC 9113 section 4.2: a frame larger than the advertised maximum is a
    // connection error, and its payload is never buffered
    if Header.Length > FSettings.MaxFrameSize then
    begin
      FailConnection('the frame is larger than the server accepts',
        ecFrameSizeError);
      Break;
    end;
    FrameLen := FrameHeaderSize + Integer(Header.Length);
    if Offset + FrameLen > Total then
      Break;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(FInput[Offset + FrameHeaderSize], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    try
      ProcessFrame(Frame);
    except
      on E: EHttpError do
      begin
        // a parser raises with the protocol code that the fault requires, so
        // the code travels unchanged unless the parser left it unset
        if E.ErrorCode = ecInternalError then
          FailConnection(E.Message, ecProtocolError)
        else
          FailConnection(E.Message, E.ErrorCode);
      end;
    end;
    Inc(Offset, FrameLen);
    if FClosing then
      Break;
  end;
  if Offset > 0 then
  begin
    Move(FInput[Offset], FInput[0], Total - Offset);
    Dec(FInputCount, Offset);
    if FInputCount = 0 then
      FInput := nil;
  end;

  FlushLocked;
  finally
    UnlockConn;
  end;
end;

procedure TServerConnectionCore.Flush;
begin
  LockConn;
  try
    FlushLocked;
  finally
    UnlockConn;
  end;
end;

function TServerConnectionCore.HasOutput: Boolean;
begin
  LockConn;
  try
    Result := FOutputCount > 0;
  finally
    UnlockConn;
  end;
end;

procedure TServerConnectionCore.FlushLocked;
begin
  FlushPendingHeaders;
  // the handler buffers turn into DATA frames only here, under the lock
  FOut.Drain(FStreams);
  FlushDrainedOutput;
  FlushStreamCredits;
  FlushConnectionCredit;
  // A stream whose two halves have ended is closed.  FById.Count feeds both
  // the concurrent-stream limit and the GOAWAY drain, so a stream that ended
  // must leave the map, or the count stays high for ever.
  ReapClosedStreams;
end;

procedure TServerConnectionCore.ReapClosedStreams;
var
  I: Integer;
  Stream: TServerStream;
begin
  for I := FStreams.Count - 1 downto 0 do
  begin
    Stream := FStreams[I];
    if (Stream.State = ssClosed) or Stream.IsCancelled then
      CloseStream(Stream);
  end;
end;

procedure TServerConnectionCore.FlushDrainedOutput;
var
  Data: TBytes;
begin
  if FOut.TakeOutput(Data) then
    QueueBytes(Data);
end;

procedure TServerConnectionCore.DrainPending;
begin
  LockConn;
  try
    FlushLocked;
  finally
    UnlockConn;
  end;
end;

procedure TServerConnectionCore.GracefulGoAway(const ALastStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  SendGoAway(ALastStreamId, AErrorCode);
end;

procedure TServerConnectionCore.SetWriteWaker(const AWaker: IWriteWaker);
begin
  FWaker := AWaker;
end;

procedure TServerConnectionCore.NotifyWantsWrite;
var
  First: Boolean;
begin
  FWakeLock.Acquire;
  try
    First := not FWakePending;
    FWakePending := True;
  finally
    FWakeLock.Release;
  end;
  if First and (FWaker <> nil) then
    FWaker.Signal;
end;

function TServerConnectionCore.TakeOutput(out AData: TBytes): Boolean;
begin
  AData := nil;
  // The wake flag clears under the connection lock, in the same section that
  // takes the bytes.  A handler queues its bytes under the connection lock
  // and then signals.  A clear outside that lock could fall between the two,
  // so the handler would see the flag still set and skip the signal, and the
  // IO thread would leave the bytes with no later wake-up.  A clear inside
  // the lock serializes with every queue, so each queued byte either arrives
  // in this take or leaves the flag set for the handler to signal.
  LockConn;
  try
    FWakeLock.Acquire;
    try
      FWakePending := False;
    finally
      FWakeLock.Release;
    end;
    Result := FOutputCount > 0;
    if not Result then
      Exit;
    SetLength(AData, FOutputCount);
    Move(FOutput[0], AData[0], FOutputCount);
    FOutputCount := 0;
  finally
    UnlockConn;
  end;
end;

procedure TServerConnectionCore.QueueBytes(const AData: TBytes);
begin
  if Length(AData) = 0 then
    Exit;
  if FOutputCount + Length(AData) > Length(FOutput) then
    SetLength(FOutput, FOutputCount + Length(AData));
  Move(AData[0], FOutput[FOutputCount], Length(AData));
  Inc(FOutputCount, Length(AData));
end;

procedure TServerConnectionCore.QueueFrame(const AFrame: TFrame);
var
  Header: TBytes;
begin
  SetLength(Header, FrameHeaderSize);
  AFrame.Header.WriteTo(Header);
  QueueBytes(Header);
  QueueBytes(AFrame.Payload);
end;

procedure TServerConnectionCore.SendGoAway(const ALastStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  if FGoAwaySent then
    Exit;
  QueueFrame(BuildGoAwayFrame(ALastStreamId, AErrorCode, nil));
  FGoAwaySent := True;
end;

procedure TServerConnectionCore.SendRstStream(const AStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  QueueFrame(BuildRstStreamFrame(AStreamId, AErrorCode));
end;

procedure TServerConnectionCore.FailConnection(const AMessage: string;
  const AErrorCode: THttp2ErrorCode);
begin
  // a connection error names the last stream the server processed
  SendGoAway(FLastStreamId, AErrorCode);
  FClosing := True;
  if FEvents <> nil then
    FEvents.ConnectionClosing;
end;

function TServerConnectionCore.FindStream(const AStreamId: LongWord): TServerStream;
begin
  if not FById.TryGetValue(AStreamId, Result) then
    Result := nil;
end;

function TServerConnectionCore.StreamById(const AStreamId: LongWord): TServerStream;
begin
  Result := FindStream(AStreamId);
end;

function TServerConnectionCore.OpenStreamCount: Integer;
begin
  LockConn;
  try
    Result := FById.Count;
  finally
    UnlockConn;
  end;
end;

function TServerConnectionCore.ConnectionWindowSize: Int64;
begin
  LockConn;
  try
    Result := FFlow.Connection.Size;
  finally
    UnlockConn;
  end;
end;

function TServerConnectionCore.StreamWindowSize(
  const AStreamId: LongWord): Int64;
var
  W: TWindow;
begin
  LockConn;
  try
    if FFlow.TryGetStream(AStreamId, W) then
      Result := W.Size
    else
      Result := 0;
  finally
    UnlockConn;
  end;
end;

procedure TServerConnectionCore.CloseStream(const AStream: TServerStream);
begin
  if AStream = nil then
    Exit;
  AStream.MarkLocalEnded;
  FFlow.CloseStream(AStream.StreamId);
  FById.Remove(AStream.StreamId);
  FStreams.Extract(AStream);
  // the core drops its reference; a queue entry or a running handler may
  // hold the stream alive a while longer
  AStream.ReleaseRef;
end;

function TServerConnectionCore.CheckStreamId(const AStreamId: LongWord): Boolean;
begin
  // RFC 9113 section 5.1.1: a client stream id is odd and larger than every
  // client stream id seen before
  Result := False;
  if (AStreamId and 1) = 0 then
  begin
    FailConnection('a client stream id is odd', ecProtocolError);
    Exit;
  end;
  if AStreamId <= FLastStreamId then
  begin
    FailConnection('a client stream id increases', ecProtocolError);
    Exit;
  end;
  Result := True;
end;

function TServerConnectionCore.NewStream(const AStreamId: LongWord): TServerStream;
begin
  Result := TServerStream.Create(AStreamId, FConnLock, FHost,
    FOptions.InboundBufferLimit, FOptions.OutboundBufferLimit);
  Result.UpdateThreshold := FOptions.StreamUpdateThreshold;
  FStreams.Add(Result);
  FById.Add(AStreamId, Result);
  FFlow.OpenStream(AStreamId);
  FLastStreamId := AStreamId;
end;

procedure TServerConnectionCore.ProcessFrame(const AFrame: TFrame);
begin
  // RFC 9113 section 4.3: a header block runs to the end of the CONTINUATION
  // run on its stream, so no other frame may stand between them
  if FHpack.InBlock and (AFrame.Header.FrameType <> ftContinuation) then
  begin
    FailConnection('a frame interrupted a header block', ecProtocolError);
    Exit;
  end;
  case AFrame.Header.FrameType of
    ftData: ProcessData(AFrame);
    ftHeaders: ProcessHeaders(AFrame);
    ftPriority: ProcessPriority(AFrame);
    ftRstStream: ProcessRstStream(AFrame);
    ftSettings: ProcessSettings(AFrame);
    ftPushPromise:
      // RFC 9113 section 8.2: a server never receives PUSH_PROMISE
      FailConnection('a server refuses a PUSH_PROMISE frame', ecProtocolError);
    ftPing: ProcessPing(AFrame);
    ftGoAway: ProcessGoAway(AFrame);
    ftWindowUpdate: ProcessWindowUpdate(AFrame);
    ftContinuation: ProcessContinuation(AFrame);
  end;
end;

procedure TServerConnectionCore.ProcessPriority(const AFrame: TFrame);
var
  DependsOn, Weight: LongWord;
  Exclusive: Boolean;
begin
  // RFC 9113 section 6.3 fixes the payload at 5 octets
  ParsePriority(AFrame, DependsOn, Weight, Exclusive);
  if AFrame.Header.StreamId = 0 then
  begin
    FailConnection('a PRIORITY frame needs a stream id', ecProtocolError);
    Exit;
  end;
  // RFC 9113 section 5.3.1: a stream cannot depend on itself, and the fault
  // is a stream error
  if DependsOn = AFrame.Header.StreamId then
  begin
    SendRstStream(AFrame.Header.StreamId, ecProtocolError);
    Exit;
  end;
  // the server keeps no priority tree, so the rest of the frame carries no
  // action and the stream continues
end;

procedure TServerConnectionCore.ProcessHeaders(const AFrame: TFrame);
var
  Stream: TServerStream;
  Block: TBytes;
begin
  // a HEADERS frame needs a stream id, and stream zero is not one
  if AFrame.Header.StreamId = 0 then
  begin
    FailConnection('a HEADERS frame needs a stream id', ecProtocolError);
    Exit;
  end;
  Stream := FindStream(AFrame.Header.StreamId);
  if Stream <> nil then
  begin
    // RFC 9113 section 5.1: once the peer ended its half, only trailers may
    // arrive, and a HEADERS frame there is a connection error
    if Stream.State in [ssHalfClosedRemote, ssClosed] then
    begin
      FailConnection('a HEADERS frame arrived after the peer ended its half',
        ecStreamClosed);
      Exit;
    end;
    if (Length(Stream.RemoteHeaders) > 0) and (not AFrame.IsEndStream) then
    begin
      FailConnection('a second HEADERS frame needs END_STREAM',
        ecProtocolError);
      Exit;
    end;
  end
  else
  begin
    // RFC 9113 section 5.1.1: a stream id that does not increase is a fault
    if not CheckStreamId(AFrame.Header.StreamId) then
      Exit;
    if OpenStreamCount >= Integer(FOptions.MaxConcurrentStreams) then
    begin
      // RFC 9113 section 5.1.2: a stream above the limit is refused, and the
      // connection stays open
      SendRstStream(AFrame.Header.StreamId, ecRefusedStream);
      Exit;
    end;
    Stream := NewStream(AFrame.Header.StreamId);
  end;
  // RFC 9113 section 5.3.1: a HEADERS frame may carry a priority block, and
  // a stream that depends on itself is a stream error
  if AFrame.IsPriority then
  begin
    if HeaderPriorityDependsOn(AFrame) = AFrame.Header.StreamId then
    begin
      SendRstStream(AFrame.Header.StreamId, ecProtocolError);
      Exit;
    end;
  end;
  Block := ExtractHeaderBlock(AFrame);
  FHpack.BeginBlock(AFrame.Header.StreamId, AFrame.IsEndStream, Block);
  if AFrame.IsEndHeaders then
    CompleteHeaderBlock;
end;

procedure TServerConnectionCore.ProcessContinuation(const AFrame: TFrame);
var
  Block: TBytes;
begin
  if not FHpack.InBlock then
  begin
    FailConnection('a CONTINUATION frame arrived with no header block',
      ecProtocolError);
    Exit;
  end;
  if AFrame.Header.StreamId <> FHpack.BlockStreamId then
  begin
    FailConnection('a CONTINUATION frame changed the stream',
      ecProtocolError);
    Exit;
  end;
  if FHpack.ContinuationCount + 1 > FOptions.MaxContinuations then
  begin
    FailConnection('too many CONTINUATION frames for one header block',
      ecEnhanceYourCalm);
    Exit;
  end;
  if FLimits <> nil then
    FLimits.Charge(lkContinuation, 1);
  Block := ExtractHeaderBlock(AFrame);
  // the count and the payload join the block only after the size check
  if FHpack.BlockByteLength + Length(Block) >
     Integer(FOptions.MaxHeaderBlockBytes) then
  begin
    FailConnection('the header block is larger than the server accepts',
      ecEnhanceYourCalm);
    Exit;
  end;
  FHpack.AddBlockPart(Block);
  if AFrame.IsEndHeaders then
    CompleteHeaderBlock;
end;

procedure TServerConnectionCore.CompleteHeaderBlock;
var
  Stream: TServerStream;
  Block: TBytes;
  Headers: THeaderBlock;
  IsTrailer: Boolean;
begin
  Stream := FindStream(FHpack.BlockStreamId);
  Block := FHpack.TakeBlock;
  if Stream = nil then
    Exit;
  try
    Headers := FHpack.Decode(Block);
  except
    on E: EHttpProtocolError do
    begin
      // the dynamic table state is lost, so the connection cannot continue
      FailConnection(E.Message, E.ErrorCode);
      Exit;
    end;
    on E: EHttpError do
    begin
      FailConnection(E.Message, ecCompressionError);
      Exit;
    end;
  end;
  // the first header block of a stream is the request head; a later block
  // is the trailer, because ProcessHeaders refuses any other second block
  IsTrailer := Stream.HasRequestHead;
  Stream.SetRemoteHeaders(Headers);
  if FHpack.BlockEndStream then
    Stream.MarkRemoteEnded;
  if not ValidateRequestBlock(Stream, IsTrailer) then
    Exit;
  if FEvents <> nil then
    FEvents.RequestReady(Stream);
end;

function TServerConnectionCore.ValidateRequestBlock(
  const AStream: TServerStream; const AIsTrailer: Boolean): Boolean;
var
  Verdict: TRequestVerdict;
begin
  Verdict := ValidateRequestHeaders(AStream.RemoteHeaders, AIsTrailer);
  if not Verdict.Valid then
  begin
    // RFC 9113 section 8.1.2.6: a malformed request is a stream error, so
    // only this stream ends and the connection stays open
    SendRstStream(AStream.StreamId, ecProtocolError);
    AStream.Cancel(ecProtocolError);
    CloseStream(AStream);
    Exit(False);
  end;
  // a trailer carries no content-length, so the head declaration stands
  if not AIsTrailer then
  begin
    AStream.SetDeclaredLength(Verdict.DeclaredLength);
    AStream.MarkRequestHead;
  end;
  Result := True;
end;

procedure TServerConnectionCore.ProcessData(const AFrame: TFrame);
var
  Stream: TServerStream;
  Payload: TBytes;
  N: LongWord;
begin
  Payload := ExtractDataPayload(AFrame);
  N := LongWord(Length(Payload));
  if N = 0 then
  begin
    if FLimits <> nil then
      FLimits.Charge(lkEmptyData, 1);
  end;
  if AFrame.Header.StreamId = 0 then
  begin
    if N > 0 then
      FailConnection('a DATA frame needs a stream id', ecProtocolError);
    Exit;
  end;
  Stream := FindStream(AFrame.Header.StreamId);
  if Stream = nil then
  begin
    // RFC 9113 section 5.1: DATA on an idle or a closed stream is a
    // connection error, and the two states take different codes
    if AFrame.Header.StreamId > FLastStreamId then
      FailConnection('a DATA frame arrived on an idle stream',
        ecProtocolError)
    else
      FailConnection('a DATA frame arrived on a closed stream',
        ecStreamClosed);
    Exit;
  end;
  if (N > 0) and (Stream.State in [ssHalfClosedRemote, ssClosed]) then
  begin
    // the peer already ended this half, so no further DATA may arrive
    FailConnection('a DATA frame arrived after the peer ended its half',
      ecStreamClosed);
    Exit;
  end;
  if N > 0 then
  begin
    if not Stream.CountReceivedBody(N) then
    begin
      // RFC 9113 section 8.1.2.6: the body passed the declared content-length,
      // so this stream ends and the connection stays open
      SendRstStream(AFrame.Header.StreamId, ecProtocolError);
      Stream.Cancel(ecProtocolError);
      CloseStream(Stream);
      Exit;
    end;
    if Stream.InboundWouldOverflow(Length(Payload)) then
    begin
      // the handler is behind, so this stream ends and the connection stays
      SendRstStream(AFrame.Header.StreamId, ecFlowControlError);
      Stream.Cancel(ecFlowControlError);
      CloseStream(Stream);
      Exit;
    end;
    if not FFlow.TryConsume(AFrame.Header.StreamId, N) then
    begin
      FailConnection('a DATA frame overran a flow-control window',
        ecFlowControlError);
      Exit;
    end;
    // the connection credit returns as soon as the bytes are buffered, so a
    // handler that is slow on one stream stalls only that stream
    Inc(FConnUpdatePending, N);
    Stream.DeliverData(Payload, AFrame.IsEndStream);
  end
  else if AFrame.IsEndStream then
    Stream.MarkRemoteEnded;
  if AFrame.IsEndStream and (not Stream.DeclaredLengthMatches) then
  begin
    // the body length differs from the declared content-length
    SendRstStream(AFrame.Header.StreamId, ecProtocolError);
    Stream.Cancel(ecProtocolError);
    CloseStream(Stream);
  end;
end;

procedure TServerConnectionCore.ProcessSettings(const AFrame: TFrame);
var
  NewSettings: TConnectionSettings;
  Delta: Int64;
begin
  if AFrame.IsAck and (Length(AFrame.Payload) > 0) then
  begin
    // RFC 9113 section 6.5: a SETTINGS acknowledgment carries no payload
    FailConnection('a SETTINGS acknowledgment carries no payload',
      ecFrameSizeError);
    Exit;
  end;
  if AFrame.IsAck then
    Exit;
  if AFrame.Header.StreamId <> 0 then
  begin
    FailConnection('a SETTINGS frame needs stream zero', ecProtocolError);
    Exit;
  end;
  if FLimits <> nil then
    FLimits.Charge(lkSettings, 1);
  NewSettings := TConnectionSettings.Decode(AFrame.Payload);
  if (NewSettings.MaxFrameSize < MinAllowedFrameSize) or
     (NewSettings.MaxFrameSize > MaxAllowedFrameSize) then
  begin
    FailConnection('the peer sent a frame size outside the protocol range',
      ecProtocolError);
    Exit;
  end;
  Delta := Int64(NewSettings.InitialWindowSize) -
    Int64(FPeerSettings.InitialWindowSize);
  FPeerSettings := NewSettings;
  FHpack.ApplyPeerTableSize(FPeerSettings.HeaderTableSize);
  // the drain obeys the smaller of the two frame sizes
  FOut.ApplyPeerFrameSize(FPeerSettings.MaxFrameSize);
  // RFC 9113 section 6.9.2: a change reaches every stream that is open
  if Delta <> 0 then
    FFlow.ApplyInitialWindowDelta(Delta);
  QueueFrame(BuildSettingsAck);
end;

procedure TServerConnectionCore.ProcessRstStream(const AFrame: TFrame);
var
  Stream: TServerStream;
  Code: THttp2ErrorCode;
begin
  if AFrame.Header.StreamId = 0 then
  begin
    FailConnection('an RST_STREAM frame needs a stream id', ecProtocolError);
    Exit;
  end;
  ParseRstStream(AFrame, Code);
  Stream := FindStream(AFrame.Header.StreamId);
  if FLimits <> nil then
    // a reset that reached a handler costs more than one for an idle stream
    // - the charge precedes the idle check, so a flood of resets on idle
    //   streams still trips the bucket and answers ENHANCE_YOUR_CALM
    FLimits.ChargeReset(Stream <> nil);
  if (Stream = nil) and (AFrame.Header.StreamId > FLastStreamId) then
  begin
    // RFC 9113 section 5.1: RST_STREAM on an idle stream is a fault
    FailConnection('an RST_STREAM frame arrived on an idle stream',
      ecProtocolError);
    Exit;
  end;
  if Stream = nil then
    Exit;
  Stream.Cancel(Code);
  if FEvents <> nil then
    FEvents.StreamReset(Stream);
  CloseStream(Stream);
end;

procedure TServerConnectionCore.ProcessPing(const AFrame: TFrame);
var
  Payload: TBytes;
begin
  if AFrame.Header.StreamId <> 0 then
  begin
    FailConnection('a PING frame needs stream zero', ecProtocolError);
    Exit;
  end;
  if FLimits <> nil then
    FLimits.Charge(lkPing, 1);
  if AFrame.IsAck then
    Exit;
  Payload := ParsePing(AFrame);
  QueueFrame(BuildPingFrame(Payload, True));
end;

procedure TServerConnectionCore.ProcessGoAway(const AFrame: TFrame);
var
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
  Stream: TServerStream;
  I: Integer;
begin
  if AFrame.Header.StreamId <> 0 then
  begin
    FailConnection('a GOAWAY frame needs stream zero', ecProtocolError);
    Exit;
  end;
  ParseGoAway(AFrame, Id, Code, Debug);
  // the peer opens no stream after GOAWAY, so every open stream is cancelled
  for I := FStreams.Count - 1 downto 0 do
  begin
    Stream := FStreams[I];
    Stream.Cancel(Code);
    if FEvents <> nil then
      FEvents.StreamReset(Stream);
    CloseStream(Stream);
  end;
  FClosing := True;
  if FEvents <> nil then
    FEvents.ConnectionClosing;
end;

procedure TServerConnectionCore.ProcessWindowUpdate(const AFrame: TFrame);
var
  Increment: LongWord;
begin
  if FLimits <> nil then
    FLimits.Charge(lkWindowUpdate, 1);
  Increment := ParseWindowUpdate(AFrame);
  if AFrame.Header.StreamId = 0 then
    FFlow.ApplyConnectionUpdate(Increment)
  else
  begin
    if FindStream(AFrame.Header.StreamId) = nil then
    begin
      if AFrame.Header.StreamId > FLastStreamId then
        // RFC 9113 section 5.1: WINDOW_UPDATE on an idle stream is a fault
        FailConnection('a WINDOW_UPDATE arrived on an idle stream',
          ecProtocolError);
      // a closed stream needs no window, so the frame carries no action
      Exit;
    end;
    try
      FFlow.ApplyStreamUpdate(AFrame.Header.StreamId, Increment);
    except
      // RFC 9113 section 6.9.1: a stream window above the maximum ends the
      // stream, and the connection stays open
      on E: EHttpProtocolError do
      begin
        SendRstStream(AFrame.Header.StreamId, ecFlowControlError);
        Exit;
      end;
    end;
  end;
end;

procedure TServerConnectionCore.EmitHeaderRun(const AStream: TServerStream;
  const AHeaderBlock: TBytes);
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  // the HPACK unit frames the header block, because the wire order of the
  // HEADERS frame and its CONTINUATION frames follows the encoder state
  Frames := FHpack.BuildHeaderRun(AStream.StreamId, AHeaderBlock);
  for I := 0 to Length(Frames) - 1 do
    QueueFrame(Frames[I]);
end;

procedure TServerConnectionCore.FlushQueue;
begin
  FlushLocked;
end;

procedure TServerConnectionCore.FlushPendingHeaders;
var
  I: Integer;
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
  Encoded: TBytes;
begin
  for I := 0 to FStreams.Count - 1 do
  begin
    Stream := FStreams[I];
    if not Stream.HasPendingHeaders then
      Continue;
    if not Stream.TakePendingHeaders(Status, Headers, EndStream) then
      Continue;
    Encoded := FHpack.EncodeResponse(Status, Headers);
    EmitHeaderRun(Stream, Encoded);
    if EndStream then
    begin
      QueueFrame(BuildDataFrame(Stream.StreamId, nil, True));
      Stream.MarkLocalEnded;
    end;
  end;
end;

procedure TServerConnectionCore.FlushStreamCredits;
var
  I: Integer;
  Stream: TServerStream;
  Credit: LongWord;
begin
  // the handler thread adds to ConsumedSinceUpdate under the stream lock; the
  // IO thread reads it here, so the two threads share no container
  for I := 0 to FStreams.Count - 1 do
  begin
    Stream := FStreams[I];
    Credit := Stream.ConsumedSinceUpdate;
    if Credit < FOptions.StreamUpdateThreshold then
      Continue;
    Stream.ClearConsumed;
    QueueFrame(BuildWindowUpdateFrame(Stream.StreamId, Credit));
    FFlow.ApplyStreamUpdate(Stream.StreamId, Credit);
  end;
end;

procedure TServerConnectionCore.FlushConnectionCredit;
begin
  if FConnUpdatePending < FOptions.ConnectionUpdateThreshold then
  begin
    // an empty window stalls every stream, so it is refilled at once
    if (FConnUpdatePending > 0) and (FFlow.Connection.Size <= 0) then
    begin
      QueueFrame(BuildWindowUpdateFrame(0, FConnUpdatePending));
      FFlow.ApplyConnectionUpdate(FConnUpdatePending);
      FConnUpdatePending := 0;
    end;
    Exit;
  end;
  QueueFrame(BuildWindowUpdateFrame(0, FConnUpdatePending));
  FFlow.ApplyConnectionUpdate(FConnUpdatePending);
  FConnUpdatePending := 0;
end;

end.
