{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream, buffers, cancellation, flow control
notes:
  - This unit holds the per-stream buffers of the HTTP/2 server.
  - The IO side calls the buffer methods under the connection lock.
  - The handler side holds the connection lock for one buffer operation and
    never across a wait.
  - The server sends WINDOW_UPDATE for a stream only when the handler reads.
---
}
/// The server stream: the bounded buffers and the wait state of one stream
// - TServerStream owns the stream id, the half-close state, the bounded
//   inbound buffer, the bounded outbound buffer, the IStreamWaiter, the
//   cancel flag and the receive credit that the handler has consumed.
// - the IO side calls DeliverData, TakeOutbound and Cancel under the
//   connection lock.  The handler side calls Read, ReadChunk and Write.
// - a handler read is the only event that asks for a stream WINDOW_UPDATE, so
//   the receive window of a queued or slow request stays closed and the
//   inbound buffer stays bounded.
// - every handler-side call raises EStreamCancelled after a cancellation.
unit Http2Server.Stream;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  mormot.core.base, mormot.core.os,
  Http2Server.Errors, Http2Server.Seam, Http2Server.Waiter,
  Http2Server.Hpack;

type
  /// the RFC 9113 section 5.1 state of one stream, as the server sees it
  TStreamState = (
    /// the stream id is known and no frame has arrived
    ssIdle,
    /// both sides may send
    ssOpen,
    /// the peer sent END_STREAM
    ssHalfClosedRemote,
    /// the handler sent END_STREAM
    ssHalfClosedLocal,
    /// both sides have ended
    ssClosed,
    /// the peer or the connection reset the stream
    ssResetting);

  /// The IO side of the connection, as one stream needs it.
  ///
  /// TServerStream calls WindowUpdatePending when a handler read has consumed
  /// inbound bytes.  The connection sums the pending credit of a stream and
  /// emits one WINDOW_UPDATE, so the wait interface of a handler carries no
  /// flow-control knowledge.
  ///
  /// TServerStream calls OutputPending when a handler write has added bytes
  /// to the outbound buffer.  The connection then asks its write waker to
  /// signal the IO thread, so output that appears while no client byte is in
  /// flight still reaches the socket.
  IStreamHost = interface
    ['{7E1F0C11-0006-4A11-9C72-000000000506}']
    /// the handler consumed AIncrement inbound bytes of AStreamId
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    /// a handler added outbound bytes to AStreamId
    procedure OutputPending(const AStreamId: LongWord);
  end;

  /// The bounded buffers and the wait state of one stream.
  ///
  /// The connection lock of the owning connection guards every method that
  /// touches a buffer.  A handler-side call takes that lock for the length of
  /// one buffer operation only, so the IO thread is never blocked by a
  /// handler that sleeps in its own code.
  TServerStream = class
  private
    /// the connection lock, shared by every stream of one connection
    FConnLock: TCriticalSection;
    /// the per-stream lock; a handler takes it together with the connection
    /// lock for one buffer operation and never holds either across a wait, so
    /// a blocked handler read leaves the connection open to the IO thread
    FStreamLock: TCriticalSection;
    FLockNested: Boolean;
    FHost: IStreamHost;
    FWaiter: IStreamWaiter;
    FStreamId: LongWord;
    FInbound: TBytes;
    FInboundStart: Integer;
    FInboundCount: Integer;
    FInboundLimit: Integer;
    FOutbound: TBytes;
    FOutboundStart: Integer;
    FOutboundCount: Integer;
    FOutboundLimit: Integer;
    FRemoteEnded: Boolean;
    FLocalEnded: Boolean;
    FReset: Boolean;
    FResetCode: THttp2ErrorCode;
    /// how many nested holds of the per-stream lock are live now
    FLockDepth: Integer;
    /// the deepest hold of the per-stream lock seen so far (test seam)
    FMaxLockDepth: Integer;
    /// how many holders keep this stream alive
    // - the core holds one, a queue entry holds one, and a running handler
    //   holds one, so the stream is freed when the last holder releases it
    FRefCount: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    FConsumedSinceUpdate: LongWord;
    FUpdateThreshold: LongWord;
    FDeclaredLength: Int64;
    FReceivedLength: Int64;
    FHasDeclaredLength: Boolean;
    FHasRequestHead: Boolean;
    FRemoteHeaders: THeaderBlock;
    FPendingStatus: Integer;
    FPendingHeaders: THeaderBlock;
    FPendingEndStream: Boolean;
    FHasPendingHeaders: Boolean;
    FFinishRequested: Boolean;

    function DoRead(var ABuffer; const ACount: Integer): Integer;
    function DoWrite(const ABuffer; const ACount: Integer): Boolean;
    /// raise EStreamCancelled when the waiter reports a cancellation
    procedure RaiseIfCancelled;
    /// take the per-stream lock and count the hold
    procedure LockStream;
    /// release the per-stream lock and count the release
    procedure UnlockStream;
    procedure CompactInbound;
    procedure CompactOutbound;
  public
    /// create a stream of AStreamId
    // - ALock is the connection lock, shared by every stream of a connection
    // - AInboundLimit and AOutboundLimit bound the two buffers
    // - AStreamId 0 has no meaning; the connection never opens it
    constructor Create(const AStreamId: LongWord; const ALock: TCriticalSection;
      const AHost: IStreamHost; const AInboundLimit, AOutboundLimit: Integer);
    destructor Destroy; override;

    /// take one reference; the stream is freed when the last one is released
    procedure AddRef;
    /// release one reference and free the stream at zero
    procedure ReleaseRef;
    /// register the waiter; the default is a TBlockingWaiter
    procedure SetWaiter(const AWaiter: IStreamWaiter);
    /// the waiter of this stream
    function Waiter: IStreamWaiter;

    // ---- the IO side, under the connection lock ----

    /// add inbound bytes to the buffer; AEndStream records a peer half-close
    // - the caller obeys InboundWouldOverflow before it delivers, because the
    //   receive window is the real bound: the server grants stream credit
    //   only as the handler reads
    procedure DeliverData(const AData: TBytes; const AEndStream: Boolean);
    /// true when ACount inbound bytes would pass the inbound limit
    function InboundWouldOverflow(const ACount: Integer): Boolean;
    /// remove up to AMaxBytes of outbound bytes; False when the buffer is dry
    function TakeOutbound(out AData: TBytes; const AMaxBytes: Integer): Boolean;
    /// true once both sides have ended or the stream is reset
    function IsFinished: Boolean;
    /// mark the local side as ended, as a sent END_STREAM does
    procedure MarkLocalEnded;
    /// mark the remote side as ended, as a received END_STREAM does
    procedure MarkRemoteEnded;
    /// take the request header block the decoder produced
    procedure SetRemoteHeaders(const AHeaders: THeaderBlock);
    /// the request header block of this stream
    function RemoteHeaders: THeaderBlock;
    /// record the content-length that the request headers declared
    // - ALength below zero clears the record, which a trailer never carries
    procedure SetDeclaredLength(const ALength: Int64);
    /// count ACount body bytes, and report a content-length fault
    function CountReceivedBody(const ACount: Integer): Boolean;
    /// report a fault when the body length differs from the declaration
    function DeclaredLengthMatches: Boolean;
    /// true once the request head of this stream arrived
    function HasRequestHead: Boolean;
    /// record that the request head of this stream arrived
    procedure MarkRequestHead;
    /// hold a plain response header block until the IO thread encodes it
    procedure QueueResponseHeaders(const AStatus: Integer;
      const AHeaders: THeaderBlock; const AEndStream: Boolean);
    /// take the pending response header block; False when none is pending
    // - the IO thread calls this under the connection lock and then encodes
    //   the block itself, because the HPACK encoder is connection state
    function TakePendingHeaders(out AStatus: Integer; out AHeaders: THeaderBlock;
      out AEndStream: Boolean): Boolean;
    /// record that the handler asked for the end of the response
    procedure RequestFinish;
    /// true when the handler asked for the end of the response
    function WantsFinish: Boolean;
    /// true when a plain response header block waits for the IO thread
    function HasPendingHeaders: Boolean;
    /// clear the end-of-response request, after the last frame carried it
    procedure ClearFinish;
    /// reset the stream: set the flag, wake a blocked handler and queue the
    /// cancel hook of the stream on a cancel-worker thread
    procedure Cancel(const AErrorCode: THttp2ErrorCode);

    // ---- the handler side ----

    /// block until bytes arrive, the body ends, the deadline expires or the
    /// stream is cancelled; 0 means the body has ended
    function Read(var ABuffer; const ACount: Integer): Integer;
    /// answer with the next buffered chunk; False means the body has ended
    function ReadChunk(out AChunk: TBytes): Boolean;
    /// block while the outbound buffer is full, then append the bytes
    procedure Write(const AData: TBytes); overload;
    /// block while the outbound buffer is full, then append ACount bytes
    procedure Write(const ABuffer; const ACount: Integer); overload;
    /// true once the request body has ended
    function BodyIsComplete: Boolean;
    /// true once the stream is cancelled
    function IsCancelled: Boolean;

    // ---- state ----

    property StreamId: LongWord read FStreamId;
    /// the state of the RFC 9113 section 5.1 machine
    function State: TStreamState;
    /// inbound bytes buffered and not yet read
    function InboundCount: Integer;
    /// outbound bytes buffered and not yet taken
    function OutboundCount: Integer;
    /// the inbound limit of this stream
    property InboundLimit: Integer read FInboundLimit;
    /// the outbound limit of this stream
    property OutboundLimit: Integer read FOutboundLimit;
    /// inbound bytes the handler consumed since the last WINDOW_UPDATE
    function ConsumedSinceUpdate: LongWord;
    /// clear the consumed counter, as an emitted WINDOW_UPDATE does
    procedure ClearConsumed;
    /// the wire error code of a reset, or ecNoError while no reset happened
    property ResetCode: THttp2ErrorCode read FResetCode;
    /// the read deadline of a blocked handler read, in milliseconds
    property ReadTimeoutMs: Integer read FReadTimeoutMs write FReadTimeoutMs;
    /// the write deadline of a blocked handler write, in milliseconds
    property WriteTimeoutMs: Integer read FWriteTimeoutMs write FWriteTimeoutMs;
    /// the consumed amount that asks for a stream WINDOW_UPDATE
    property UpdateThreshold: LongWord read FUpdateThreshold
      write FUpdateThreshold;
    /// the deepest hold of the per-stream lock seen so far
    // - a handler call holds the lock for one buffer operation only, so a
    //   value above one would mean a lock held across a nested operation, and
    //   a value of zero at the wait point means no lock is held across a wait
    property MaxLockDepth: Integer read FMaxLockDepth;
  end;

implementation

const
  /// the read deadline of a blocked handler read, until the factory sets one
  DefaultReadTimeoutMs = 30000;
  /// the write deadline of a blocked handler write, until the factory sets it
  DefaultWriteTimeoutMs = 30000;
  /// the consumed amount that asks for a stream WINDOW_UPDATE
  DefaultUpdateThreshold = 32768;

constructor TServerStream.Create(const AStreamId: LongWord;
  const ALock: TCriticalSection; const AHost: IStreamHost;
  const AInboundLimit, AOutboundLimit: Integer);
begin
  inherited Create;
  FConnLock := ALock;
  FStreamLock := TCriticalSection.Create;
  FHost := AHost;
  FStreamId := AStreamId;
  FInboundLimit := AInboundLimit;
  FOutboundLimit := AOutboundLimit;
  FWaiter := TBlockingWaiter.Create;
  FResetCode := ecNoError;
  FReadTimeoutMs := DefaultReadTimeoutMs;
  FWriteTimeoutMs := DefaultWriteTimeoutMs;
  FUpdateThreshold := DefaultUpdateThreshold;
  // the core holds the first reference
  FRefCount := 1;
end;

procedure TServerStream.AddRef;
begin
  InterlockedIncrement(FRefCount);
end;

procedure TServerStream.ReleaseRef;
begin
  // the last holder frees the stream.  The stream lock is not held, because
  // the lock object dies with the stream.
  if InterlockedDecrement(FRefCount) = 0 then
    Self.Free;
end;

destructor TServerStream.Destroy;
begin
  FWaiter := nil;
  FStreamLock.Free;
  inherited Destroy;
end;

procedure TServerStream.SetWaiter(const AWaiter: IStreamWaiter);
begin
  FWaiter := AWaiter;
end;

function TServerStream.Waiter: IStreamWaiter;
begin
  Result := FWaiter;
end;

function TServerStream.State: TStreamState;
begin
  LockStream;
  try
    if FReset then
      Result := ssResetting
    else if FLocalEnded and FRemoteEnded then
      Result := ssClosed
    else if FRemoteEnded then
      Result := ssHalfClosedRemote
    else if FLocalEnded then
      Result := ssHalfClosedLocal
    else
      Result := ssOpen;
  finally
    UnlockStream;
  end;
end;

function TServerStream.InboundCount: Integer;
begin
  LockStream;
  try
    Result := FInboundCount;
  finally
    UnlockStream;
  end;
end;

function TServerStream.OutboundCount: Integer;
begin
  LockStream;
  try
    Result := FOutboundCount;
  finally
    UnlockStream;
  end;
end;

function TServerStream.ConsumedSinceUpdate: LongWord;
begin
  LockStream;
  try
    Result := FConsumedSinceUpdate;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.ClearConsumed;
begin
  LockStream;
  try
    FConsumedSinceUpdate := 0;
  finally
    UnlockStream;
  end;
end;

/// move the live bytes to the front and release the tail
// - Move handles the overlap of the two ranges, so the shift is in place
procedure TServerStream.CompactInbound;
begin
  if FInboundStart = 0 then
    Exit;
  if FInboundCount = 0 then
  begin
    FInboundStart := 0;
    FInbound := nil;
    Exit;
  end;
  Move(FInbound[FInboundStart], FInbound[0], FInboundCount);
  FInboundStart := 0;
  SetLength(FInbound, FInboundCount);
end;

/// the outbound twin of CompactInbound
procedure TServerStream.CompactOutbound;
begin
  if FOutboundStart = 0 then
    Exit;
  if FOutboundCount = 0 then
  begin
    FOutboundStart := 0;
    FOutbound := nil;
    Exit;
  end;
  Move(FOutbound[FOutboundStart], FOutbound[0], FOutboundCount);
  FOutboundStart := 0;
  SetLength(FOutbound, FOutboundCount);
end;

function TServerStream.InboundWouldOverflow(const ACount: Integer): Boolean;
begin
  LockStream;
  try
    Result := (FInboundLimit > 0) and (FInboundCount + ACount > FInboundLimit);
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.DeliverData(const AData: TBytes;
  const AEndStream: Boolean);
var
  N: Integer;
  Woke: Boolean;
begin
  N := Length(AData);
  Woke := False;
  LockStream;
  try
    if FReset then
      Exit;
    if N > 0 then
    begin
      CompactInbound;
      SetLength(FInbound, FInboundCount + N);
      Move(AData[0], FInbound[FInboundCount], N);
      Inc(FInboundCount, N);
      Woke := True;
    end;
    if AEndStream then
    begin
      FRemoteEnded := True;
      Woke := True;
    end;
  finally
    UnlockStream;
  end;
  // the signal runs outside the stream lock; the waiter has its own lock
  if Woke then
    FWaiter.Signal;
end;

function TServerStream.TakeOutbound(out AData: TBytes;
  const AMaxBytes: Integer): Boolean;
var
  N: Integer;
begin
  AData := nil;
  N := 0;
  LockStream;
  try
    if FOutboundCount = 0 then
      Exit(False);
    N := FOutboundCount;
    if (AMaxBytes > 0) and (N > AMaxBytes) then
      N := AMaxBytes;
    SetLength(AData, N);
    Move(FOutbound[FOutboundStart], AData[0], N);
    Inc(FOutboundStart, N);
    Dec(FOutboundCount, N);
    CompactOutbound;
  finally
    UnlockStream;
  end;
  // a handler blocked on a full outbound buffer wakes on this drain
  FWaiter.Signal;
  Result := True;
end;

procedure TServerStream.MarkRemoteEnded;
begin
  LockStream;
  try
    FRemoteEnded := True;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.SetRemoteHeaders(const AHeaders: THeaderBlock);
begin
  LockStream;
  try
    FRemoteHeaders := AHeaders;
  finally
    UnlockStream;
  end;
end;

function TServerStream.RemoteHeaders: THeaderBlock;
begin
  LockStream;
  try
    Result := FRemoteHeaders;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.SetDeclaredLength(const ALength: Int64);
begin
  LockStream;
  try
    FDeclaredLength := ALength;
    FReceivedLength := 0;
    FHasDeclaredLength := ALength >= 0;
  finally
    UnlockStream;
  end;
end;

function TServerStream.CountReceivedBody(const ACount: Integer): Boolean;
begin
  LockStream;
  try
    FReceivedLength := FReceivedLength + ACount;
    Result := (not FHasDeclaredLength) or (FReceivedLength <= FDeclaredLength);
  finally
    UnlockStream;
  end;
end;

function TServerStream.DeclaredLengthMatches: Boolean;
begin
  LockStream;
  try
    Result := (not FHasDeclaredLength) or (FReceivedLength = FDeclaredLength);
  finally
    UnlockStream;
  end;
end;

function TServerStream.HasRequestHead: Boolean;
begin
  LockStream;
  try
    Result := FHasRequestHead;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.MarkRequestHead;
begin
  LockStream;
  try
    FHasRequestHead := True;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.QueueResponseHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
begin
  LockStream;
  try
    FPendingStatus := AStatus;
    FPendingHeaders := AHeaders;
    FPendingEndStream := AEndStream;
    FHasPendingHeaders := True;
  finally
    UnlockStream;
  end;
  // the handler queued headers, so the IO side must wake to encode them
  if Assigned(FHost) then
    FHost.OutputPending(FStreamId);
end;

function TServerStream.TakePendingHeaders(out AStatus: Integer;
  out AHeaders: THeaderBlock; out AEndStream: Boolean): Boolean;
begin
  LockStream;
  try
    Result := FHasPendingHeaders;
    if not Result then
      Exit;
    AStatus := FPendingStatus;
    AHeaders := FPendingHeaders;
    AEndStream := FPendingEndStream;
    FHasPendingHeaders := False;
    FPendingHeaders := nil;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.RequestFinish;
begin
  LockStream;
  try
    FFinishRequested := True;
  finally
    UnlockStream;
  end;
  // a finish with an empty buffer still owes the peer an END_STREAM frame
  if Assigned(FHost) then
    FHost.OutputPending(FStreamId);
end;

function TServerStream.HasPendingHeaders: Boolean;
begin
  LockStream;
  try
    Result := FHasPendingHeaders;
  finally
    UnlockStream;
  end;
end;

function TServerStream.WantsFinish: Boolean;
begin
  LockStream;
  try
    Result := FFinishRequested;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.ClearFinish;
begin
  LockStream;
  try
    FFinishRequested := False;
  finally
    UnlockStream;
  end;
end;

function TServerStream.IsFinished: Boolean;
begin
  LockStream;
  try
    Result := FReset or (FLocalEnded and FRemoteEnded);
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.MarkLocalEnded;
begin
  LockStream;
  try
    FLocalEnded := True;
  finally
    UnlockStream;
  end;
end;

procedure TServerStream.Cancel(const AErrorCode: THttp2ErrorCode);
begin
  LockStream;
  try
    if FReset then
      Exit;
    FReset := True;
    FResetCode := AErrorCode;
    FRemoteEnded := True;
  finally
    UnlockStream;
  end;
  // the waiter sets the flag, wakes a blocked wait, then queues the hook on a
  // cancel-worker thread; no exception crosses a thread boundary here
  FWaiter.Cancel;
  FWaiter.Signal;
end;

procedure TServerStream.LockStream;
begin
  // the connection lock comes first, so the IO thread and a handler thread
  // always take the two locks in the same order
  if (FConnLock <> nil) and not FLockNested then
    FConnLock.Acquire;
  FStreamLock.Acquire;
  Inc(FLockDepth);
  if FLockDepth > FMaxLockDepth then
    FMaxLockDepth := FLockDepth;
end;

procedure TServerStream.UnlockStream;
begin
  Dec(FLockDepth);
  FStreamLock.Release;
  if (FConnLock <> nil) and not FLockNested then
    FConnLock.Release;
end;

procedure TServerStream.RaiseIfCancelled;
var
  Code: THttp2ErrorCode;
begin
  if not FWaiter.IsCancelled then
    Exit;
  LockStream;
  try
    Code := FResetCode;
  finally
    UnlockStream;
  end;
  raise EStreamCancelled.Create('the stream was cancelled', FStreamId, Code);
end;

function TServerStream.BodyIsComplete: Boolean;
begin
  LockStream;
  try
    Result := (FRemoteEnded and (FInboundCount = 0)) or FReset;
  finally
    UnlockStream;
  end;
end;

function TServerStream.IsCancelled: Boolean;
begin
  Result := FWaiter.IsCancelled;
end;

function TServerStream.DoRead(var ABuffer; const ACount: Integer): Integer;
var
  N, Consumed: Integer;
begin
  N := 0;
  Consumed := 0;
  LockStream;
  try
    if FInboundCount > 0 then
    begin
      N := ACount;
      if N > FInboundCount then
        N := FInboundCount;
      Move(FInbound[FInboundStart], ABuffer, N);
      Inc(FInboundStart, N);
      Dec(FInboundCount, N);
      CompactInbound;
      Inc(FConsumedSinceUpdate, N);
      Consumed := N;
    end;
  finally
    UnlockStream;
  end;
  if Consumed > 0 then
  begin
    // the handler read is the only source of stream receive credit
    if Assigned(FHost) then
      FHost.WindowUpdatePending(FStreamId, Consumed);
  end;
  Result := N;
end;

function TServerStream.Read(var ABuffer; const ACount: Integer): Integer;
var
  Deadline: QWord;
  Remaining: Integer;
  R: TWaitResult;
begin
  if ACount <= 0 then
    Exit(0);
  Deadline := GetTickCount64 + QWord(FReadTimeoutMs);
  while True do
  begin
    RaiseIfCancelled;
    Result := DoRead(ABuffer, ACount);
    if Result > 0 then
      Exit;
    if BodyIsComplete then
      Exit(0);
    // a delivery that races this check is not lost: Signal leaves a pending
    // mark in the waiter, so the park below returns at once
    Remaining := Integer(Deadline - GetTickCount64);
    if Remaining <= 0 then
      raise EHttpTimeout.Create('the request body read timed out');
    R := FWaiter.Wait(Remaining);
    if R = wrCancelled then
      raise EStreamCancelled.Create('the stream was cancelled',
        FStreamId, FResetCode);
  end;
end;

function TServerStream.ReadChunk(out AChunk: TBytes): Boolean;
var
  N: Integer;
begin
  AChunk := nil;
  RaiseIfCancelled;
  LockStream;
  try
    if FInboundCount > 0 then
    begin
      N := FInboundCount;
      SetLength(AChunk, N);
      Move(FInbound[FInboundStart], AChunk[0], N);
      FInboundStart := 0;
      FInboundCount := 0;
      CompactInbound;
      Inc(FConsumedSinceUpdate, N);
    end
    else
      N := 0;
  finally
    UnlockStream;
  end;
  if N > 0 then
  begin
    if Assigned(FHost) then
      FHost.WindowUpdatePending(FStreamId, N);
    Exit(True);
  end;
  Result := not BodyIsComplete;
end;

function TServerStream.DoWrite(const ABuffer; const ACount: Integer): Boolean;
begin
  LockStream;
  try
    // The limit is backpressure, not a hard cap.  A write is refused only
    // when the buffer already holds bytes, so a single write always makes
    // progress.  A caller that writes more than the whole limit then waits
    // for the drain to empty the buffer, and the buffer never grows past the
    // limit plus the one write that found it empty.
    if (FOutboundLimit > 0) and (FOutboundCount > 0) and
       (FOutboundCount + ACount > FOutboundLimit) then
      Exit(False);
    CompactOutbound;
    SetLength(FOutbound, FOutboundCount + ACount);
    if ACount > 0 then
      Move(ABuffer, FOutbound[FOutboundCount], ACount);
    Inc(FOutboundCount, ACount);
  finally
    UnlockStream;
  end;
  // the handler queued output, so the IO side must wake to drain it
  if Assigned(FHost) then
    FHost.OutputPending(FStreamId);
  Result := True;
end;

procedure TServerStream.Write(const ABuffer; const ACount: Integer);
begin
  if ACount <= 0 then
    Exit;
  while True do
  begin
    RaiseIfCancelled;
    if DoWrite(ABuffer, ACount) then
      Exit;
    if FWaiter.Wait(FWriteTimeoutMs) = wrCancelled then
      raise EStreamCancelled.Create('the stream was cancelled',
        FStreamId, FResetCode);
  end;
end;

procedure TServerStream.Write(const AData: TBytes);
begin
  if Length(AData) = 0 then
    Exit;
  Write(AData[0], Length(AData));
end;

end.
