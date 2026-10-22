{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, output queue, stream table, locks
notes:
  - This unit holds the base of the server connection core. It owns the
    fields, the locks, the output queue, the write wake-up and the stream table.
  - The frame handlers are in Http2Server.Connection, which derives
    TServerConnectionCore from the base class of this unit.
  - The unit compiles without the mORMot units, because it touches no socket
    and no TLS. The caller holds the connection lock for every call.
---
}
/// Base of the HTTP/2 server connection core
// - The base class holds the state that every frame handler shares. A class
//   cannot span two units, so the frame handlers sit in a derived class.
// - The core holds no lock of its own: the caller holds the connection lock for
//   the whole of every call, so one thread uses the HPACK encoder and decoder.
// - The options record carries every limit. The core holds no limit literal.
unit Http2Server.Connection.Core;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.FlowControl, Http2Server.Limits, Http2Server.Seam,
  Http2Server.Stream, Http2Server.StreamHost, Http2Server.Headers,
  Http2Server.Output,
  Http2Server.HpackConnection;

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

  TConnectionCoreBase = class;

  /// The IStreamHost adapter of one core.
  ///
  /// A stream calls OutputPending when a handler wrote, and the adapter asks
  /// the core to wake the IO thread.  The adapter holds the core without an
  /// interface reference, so no reference cycle forms.
  TCoreStreamHost = class(TInterfacedObject, IStreamHost, IRefusalHost)
  private
    FCore: TConnectionCoreBase;   // weak reference; the core owns this
    /// guards the read of FCore; no call into the core runs under it, because a
    /// call takes the connection lock and the lock order is connection first
    FHostLock: TCriticalSection;
    /// the calls into the core that run now; Orphan waits for them to end
    FInFlight: Integer;
    function Enter: TConnectionCoreBase;
    procedure Leave;
  public
    constructor Create(const ACore: TConnectionCoreBase);
    destructor Destroy; override;
    /// forget the core; later calls do nothing
    // - the core calls this before it frees anything a stream callback uses. A
    //   detached stream can outlive its core, and its owner may still write
    procedure Orphan;
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    procedure OutputPending(const AStreamId: LongWord);
    procedure QueueRefusal(const AStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode);
  end;

  /// the base of the server connection state machine
  // - the fields and the helpers are protected, so the derived class of
  //   Http2Server.Connection reaches them
  TConnectionCoreBase = class(TInterfacedObject)
  protected
    FOptions: TConnectionCoreOptions;
    FEvents: IConnectionEvents;
    FLimits: TConnectionLimits;
    FFlow: TFlowControl;
    FOut: TOutputDrain;
    /// the IStreamHost adapter the core hands to every stream
    // - the core cannot be its own host interface: an interface reference to
    //   self inside a TInterfacedObject invites a refcount double-destroy
    FHost: IStreamHost;
    /// the same adapter, seen as the refusal channel
    // - a stream learns the refusal channel from this field, so a stream that
    //   no interface owns is quiet
    FRefusalHost: IRefusalHost;
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
    /// the peer sent GOAWAY, so the read loop continues to its last stream
    FPeerGoAway: Boolean;
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
    /// owns the connection lock; the streams hold a reference too
    FLockOwner: IInterface;
    /// the host adapter, kept as a class so that the destructor can orphan it
    FHostImpl: TCoreStreamHost;

    procedure HandleTrip(const AKind: TLimitKind);
    procedure LockConn;
    procedure UnlockConn;
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
    /// queue an RST_STREAM for a stream that the local side refused
    // - the handler pool calls this from a worker thread, and the frame
    //   enters the outbound queue under the connection lock
    procedure QueueRefusalFrame(const AStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode);
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
    /// cancel every open stream because the socket closed
    // - a handler that waits on a stream wakes with EStreamCancelled, the cancel
    //   hooks run, and the sink of a detached stream hears PeerClosed(False)
    // - the call is safe to repeat; a cancelled stream stays cancelled
    procedure ConnectionLost;
    /// cut the stream callbacks from this core
    // - a call in flight finishes first, and every later call does nothing. The
    //   async connection calls this before it frees what a callback reaches
    procedure ReleaseHost;
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

const
  /// the longest wait of Orphan for a call in flight, in milliseconds
  cOrphanWaitMs = 10000;

{ TCoreStreamHost }

constructor TCoreStreamHost.Create(const ACore: TConnectionCoreBase);
begin
  inherited Create;
  FHostLock := TCriticalSection.Create;
  FCore := ACore;
end;

destructor TCoreStreamHost.Destroy;
begin
  FHostLock.Free;
  inherited Destroy;
end;

function TCoreStreamHost.Enter: TConnectionCoreBase;
begin
  FHostLock.Acquire;
  try
    Result := FCore;
    if Result <> nil then
      InterlockedIncrement(FInFlight);
  finally
    FHostLock.Release;
  end;
end;

procedure TCoreStreamHost.Leave;
begin
  InterlockedDecrement(FInFlight);
end;

procedure TCoreStreamHost.Orphan;
var
  Waited: Integer;
begin
  FHostLock.Acquire;
  try
    FCore := nil;
  finally
    FHostLock.Release;
  end;
  // a call that entered before this point finishes; none starts after it. The
  // caller holds no connection lock, so a call that waits for that lock ends.
  // The wait is bounded, so a destructor never hangs on a stuck caller
  Waited := 0;
  while (InterlockedCompareExchange(FInFlight, 0, 0) <> 0) and
        (Waited < cOrphanWaitMs) do
  begin
    Sleep(1);
    Inc(Waited);
  end;
end;

procedure TCoreStreamHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
  // the connection sums the consumed credit and emits one WINDOW_UPDATE; the
  // sum happens under the connection lock inside FlushStreamCredits, which
  // reads the stream counter directly, so no work is needed here
end;

procedure TCoreStreamHost.OutputPending(const AStreamId: LongWord);
var
  Core: TConnectionCoreBase;
begin
  Core := Enter;
  if Core = nil then
    Exit;
  try
    Core.NotifyWantsWrite;
  finally
    Leave;
  end;
end;

procedure TCoreStreamHost.QueueRefusal(const AStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
var
  Core: TConnectionCoreBase;
begin
  // the pool calls this from a worker thread, so the frame enters the queue
  // under the connection lock and the write waker carries it to the IO thread
  Core := Enter;
  if Core = nil then
    Exit;
  try
    Core.QueueRefusalFrame(AStreamId, AErrorCode);
  finally
    Leave;
  end;
end;

{ TConnectionCoreBase }

constructor TConnectionCoreBase.Create(const AOptions: TConnectionCoreOptions;
  const AEvents: IConnectionEvents; const ALimits: TConnectionLimits;
  const AClock: IMonotonicClock);
var
  Holder: TConnectionLock;
  OutOptions: TOutputDrainOptions;
begin
  inherited Create;
  FOptions := AOptions;
  FEvents := AEvents;
  FLimits := ALimits;
  Holder := TConnectionLock.Create;
  FLockOwner := Holder;
  FConnLock := Holder.Lock;
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
  FHostImpl := TCoreStreamHost.Create(Self);
  FHost := FHostImpl;
  FRefusalHost := FHost as IRefusalHost;
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

procedure TConnectionCoreBase.LockConn;
begin
  FConnLock.Acquire;
end;

procedure TConnectionCoreBase.UnlockConn;
begin
  FConnLock.Release;
end;

procedure TConnectionCoreBase.HandleTrip(const AKind: TLimitKind);
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

procedure TConnectionCoreBase.ReleaseHost;
begin
  if FHostImpl <> nil then
    FHostImpl.Orphan;
end;

procedure TConnectionCoreBase.ConnectionLost;
var
  Open: TArray<TServerStream>;
  I: Integer;
begin
  LockConn;
  try
    FClosing := True;
    // Cancel runs the sink of a detached stream, so the list is copied first
    Open := FStreams.ToArray;
    for I := 0 to High(Open) do
      Open[I].Cancel(ecCancel);
  finally
    UnlockConn;
  end;
end;

destructor TConnectionCoreBase.Destroy;
var
  I: Integer;
begin
  // a stream that a handler or a channel still holds must learn that the
  // connection is gone
  ConnectionLost;
  // a detached stream outlives this core, and its owner may still write: cut
  // the callbacks first, then free what they reach
  ReleaseHost;
  FHost := nil;
  FRefusalHost := nil;
  FHostImpl := nil;
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
  // the lock lives on while a stream holds the owner
  FConnLock := nil;
  FLockOwner := nil;
  inherited Destroy;
end;

procedure TConnectionCoreBase.Flush;
begin
  LockConn;
  try
    FlushLocked;
  finally
    UnlockConn;
  end;
end;

function TConnectionCoreBase.HasOutput: Boolean;
begin
  LockConn;
  try
    Result := FOutputCount > 0;
  finally
    UnlockConn;
  end;
end;

procedure TConnectionCoreBase.FlushLocked;
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

procedure TConnectionCoreBase.ReapClosedStreams;
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

procedure TConnectionCoreBase.QueueRefusalFrame(const AStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  // the handler pool calls this from a worker thread; the connection lock
  // keeps the queue consistent with the IO thread's flush
  LockConn;
  try
    SendRstStream(AStreamId, AErrorCode);
    NotifyWantsWrite;
  finally
    UnlockConn;
  end;
end;

procedure TConnectionCoreBase.FlushDrainedOutput;
var
  Data: TBytes;
begin
  if FOut.TakeOutput(Data) then
    QueueBytes(Data);
end;

procedure TConnectionCoreBase.DrainPending;
begin
  LockConn;
  try
    FlushLocked;
  finally
    UnlockConn;
  end;
end;

procedure TConnectionCoreBase.GracefulGoAway(const ALastStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  SendGoAway(ALastStreamId, AErrorCode);
end;

procedure TConnectionCoreBase.SetWriteWaker(const AWaker: IWriteWaker);
begin
  FWaker := AWaker;
end;

procedure TConnectionCoreBase.NotifyWantsWrite;
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

function TConnectionCoreBase.TakeOutput(out AData: TBytes): Boolean;
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

procedure TConnectionCoreBase.QueueBytes(const AData: TBytes);
begin
  if Length(AData) = 0 then
    Exit;
  if FOutputCount + Length(AData) > Length(FOutput) then
    SetLength(FOutput, FOutputCount + Length(AData));
  Move(AData[0], FOutput[FOutputCount], Length(AData));
  Inc(FOutputCount, Length(AData));
end;

procedure TConnectionCoreBase.QueueFrame(const AFrame: TFrame);
var
  Header: TBytes;
begin
  SetLength(Header, FrameHeaderSize);
  AFrame.Header.WriteTo(Header);
  QueueBytes(Header);
  QueueBytes(AFrame.Payload);
end;

procedure TConnectionCoreBase.SendGoAway(const ALastStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  if FGoAwaySent then
    Exit;
  QueueFrame(BuildGoAwayFrame(ALastStreamId, AErrorCode, nil));
  FGoAwaySent := True;
end;

procedure TConnectionCoreBase.SendRstStream(const AStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode);
begin
  QueueFrame(BuildRstStreamFrame(AStreamId, AErrorCode));
end;

procedure TConnectionCoreBase.FailConnection(const AMessage: string;
  const AErrorCode: THttp2ErrorCode);
var
  I: Integer;
  Stream: TServerStream;
begin
  // a connection error names the last stream the server processed
  SendGoAway(FLastStreamId, AErrorCode);
  // RFC 9113 section 5.4.1: after sending the GOAWAY frame for an error
  // condition, the endpoint MUST close the TCP connection.  The IO side
  // closes only when no stream is open, so every open stream ends here.  A
  // connection error that left a stream open would send its GOAWAY and then
  // hold the socket, and the peer would wait for a close that never comes.
  for I := FStreams.Count - 1 downto 0 do
  begin
    Stream := FStreams[I];
    Stream.Cancel(AErrorCode);
    if FEvents <> nil then
      FEvents.StreamReset(Stream);
    CloseStream(Stream);
  end;
  FClosing := True;
  if FEvents <> nil then
    FEvents.ConnectionClosing;
end;

function TConnectionCoreBase.FindStream(const AStreamId: LongWord): TServerStream;
begin
  if not FById.TryGetValue(AStreamId, Result) then
    Result := nil;
end;

function TConnectionCoreBase.StreamById(const AStreamId: LongWord): TServerStream;
begin
  Result := FindStream(AStreamId);
end;

function TConnectionCoreBase.OpenStreamCount: Integer;
begin
  LockConn;
  try
    Result := FById.Count;
  finally
    UnlockConn;
  end;
end;

function TConnectionCoreBase.ConnectionWindowSize: Int64;
begin
  LockConn;
  try
    Result := FFlow.Connection.Size;
  finally
    UnlockConn;
  end;
end;

function TConnectionCoreBase.StreamWindowSize(
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

procedure TConnectionCoreBase.CloseStream(const AStream: TServerStream);
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

function TConnectionCoreBase.CheckStreamId(const AStreamId: LongWord): Boolean;
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

function TConnectionCoreBase.NewStream(const AStreamId: LongWord): TServerStream;
begin
  Result := TServerStream.Create(AStreamId, FConnLock, FHost,
    FOptions.InboundBufferLimit, FOptions.OutboundBufferLimit);
  Result.SetRefusalHost(FRefusalHost);
  Result.SetLockOwner(FLockOwner);
  Result.UpdateThreshold := FOptions.StreamUpdateThreshold;
  FStreams.Add(Result);
  FById.Add(AStreamId, Result);
  FFlow.OpenStream(AStreamId);
  FLastStreamId := AStreamId;
end;

procedure TConnectionCoreBase.EmitHeaderRun(const AStream: TServerStream;
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

procedure TConnectionCoreBase.FlushQueue;
begin
  FlushLocked;
end;

procedure TConnectionCoreBase.FlushPendingHeaders;
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

procedure TConnectionCoreBase.FlushStreamCredits;
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

procedure TConnectionCoreBase.FlushConnectionCredit;
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
