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
  Http2Server.Hpack, Http2Server.Duplex, Http2Server.StreamHost,
  Http2Server.ClientCert, Http2Server.Stream.Meta;

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

  /// The bounded buffers and the wait state of one stream.
  ///
  /// The connection lock of the owning connection guards every method that
  /// touches a buffer.  A handler-side call takes that lock for the length of
  /// one buffer operation only, so the IO thread is never blocked by a
  /// handler that sleeps in its own code.
  TServerStream = class(TStreamMeta)
  private
    /// the refusal channel; the core sets it, a bare test stream leaves it nil
    FRefusalHost: IRefusalHost;
    FWaiter: IStreamWaiter;
    FRemoteAddress: string;
    FClientCertificate: IClientCertificate;
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
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    FConsumedSinceUpdate: LongWord;
    FUpdateThreshold: LongWord;
    /// the receiver of a detached stream; nil for an ordinary stream
    // - with a sink set, inbound DATA goes to the sink and not into the buffer
    FSink: IChannelSink;
    /// true after a write was refused for a full buffer, until the drain
    FWriteBlocked: Boolean;
    /// the outbound byte count at or below which a blocked writer is told
    FDrainLowWater: Integer;

    function DoRead(var ABuffer; const ACount: Integer): Integer;
    function DoWrite(const ABuffer; const ACount: Integer): Boolean;
    /// raise EStreamCancelled when the waiter reports a cancellation
    procedure RaiseIfCancelled;
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
    /// reset the stream: set the flag, wake a blocked handler and queue the
    /// cancel hook of the stream on a cancel-worker thread
    // - True means this call performed the reset; a second call answers
    //   False and leaves the state alone
    function Cancel(const AErrorCode: THttp2ErrorCode): Boolean;

    /// cancel the stream and tell the peer, with an RST_STREAM that names
    /// AErrorCode
    // - This is the refusal path.  Cancel alone is silent, because the
    //   callers that queue their own frame (a malformed request, a
    //   flow-control fault) and the paths that answer a frame from the peer
    //   (its RST_STREAM, its GOAWAY) must not echo one
    procedure Refuse(const AErrorCode: THttp2ErrorCode);

    /// name the connection that carries the refusal frames of this stream
    procedure SetRefusalHost(const AHost: IRefusalHost);

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

    // ---- the detached side (see Http2Server.Duplex) ----

    /// hold a reference that keeps the connection lock alive
    procedure SetLockOwner(const AOwner: IInterface);
    /// set the receiver of the inbound bytes; nil restores the buffered mode
    procedure SetSink(const ASink: IChannelSink);
    /// append bytes to the outbound buffer without blocking; False when the
    /// buffer is over its limit (the sink then hears WriteDrained later)
    function TryWrite(const AData: TBytes): Boolean;
    /// add receive credit for ACount inbound bytes and wake the IO side
    procedure AddCredit(const ACount: LongWord);
    /// true once the peer ended its half of the stream
    function HasRemoteEnded: Boolean;
    /// the outbound byte count at or below which a refused writer is told
    property DrainLowWater: Integer read FDrainLowWater write FDrainLowWater;
    /// the peer address and the client certificate, set by the connection events
    property RemoteAddress: string read FRemoteAddress write FRemoteAddress;
    property ClientCertificate: IClientCertificate read FClientCertificate write FClientCertificate;
    /// the state of the RFC 9113 section 5.1 machine
    function State: TStreamState;
    /// inbound bytes buffered and not yet read
    function InboundCount: Integer;
    /// outbound bytes buffered and not yet taken
    function OutboundCount: Integer;
    /// the inbound limit of this stream
    property InboundLimit: Integer read FInboundLimit;
    /// the outbound limit of this stream
    property OutboundLimit: Integer read FOutboundLimit write FOutboundLimit;
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
  inherited Create(AStreamId, ALock, AHost);
  FInboundLimit := AInboundLimit;
  FOutboundLimit := AOutboundLimit;
  FWaiter := TBlockingWaiter.Create;
  FResetCode := ecNoError;
  FReadTimeoutMs := DefaultReadTimeoutMs;
  FWriteTimeoutMs := DefaultWriteTimeoutMs;
  FUpdateThreshold := DefaultUpdateThreshold;
  FDrainLowWater := AOutboundLimit div 2;
end;

destructor TServerStream.Destroy;
begin
  FWaiter := nil;
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
  Sink: IChannelSink;
begin
  N := Length(AData);
  Woke := False;
  Sink := nil;
  LockStream;
  try
    if FReset then
      Exit;
    Sink := FSink;
    if Sink <> nil then
    begin
      // a detached stream keeps no inbound buffer: the bytes go to the sink
      if AEndStream then
        FRemoteEnded := True;
    end
    else
    begin
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
    end;
  finally
    UnlockStream;
  end;
  if Sink <> nil then
  begin
    // the caller holds the connection lock, so the sink runs on the IO thread
    if N > 0 then
      Sink.BytesReceived(AData[0], N);
    if AEndStream then
      Sink.PeerClosed(True);
    Exit;
  end;
  // the signal runs outside the stream lock; the waiter has its own lock
  if Woke then
    FWaiter.Signal;
end;

function TServerStream.TakeOutbound(out AData: TBytes;
  const AMaxBytes: Integer): Boolean;
var
  N: Integer;
  Told: IChannelSink;
begin
  AData := nil;
  N := 0;
  Told := nil;
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
    // a writer that was refused hears once that the buffer fell to the low mark
    if FWriteBlocked and (FOutboundCount <= FDrainLowWater) then
    begin
      FWriteBlocked := False;
      Told := FSink;
    end;
  finally
    UnlockStream;
  end;
  // a handler blocked on a full outbound buffer wakes on this drain
  FWaiter.Signal;
  if Told <> nil then
    Told.WriteDrained;
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

function TServerStream.Cancel(const AErrorCode: THttp2ErrorCode): Boolean;
var
  Sink: IChannelSink;
begin
  Result := False;
  Sink := nil;
  LockStream;
  try
    if FReset then
      Exit;
    FReset := True;
    FResetCode := AErrorCode;
    FRemoteEnded := True;
    Sink := FSink;
    Result := True;
  finally
    UnlockStream;
  end;
  // the waiter sets the flag, wakes a blocked wait, then queues the hook on a
  // cancel-worker thread; no exception crosses a thread boundary here
  FWaiter.Cancel;
  FWaiter.Signal;
  // a detached stream ended without END_STREAM: tell the sink once
  if Sink <> nil then
    Sink.PeerClosed(False);
end;

procedure TServerStream.Refuse(const AErrorCode: THttp2ErrorCode);
begin
  // Cancel answers True to one caller only, so two threads that refuse the
  // same stream cannot queue the same RST_STREAM twice
  if not Cancel(AErrorCode) then
    Exit;
  // A stream built by a test holds no refusal host, and a unit that does not
  // speak HTTP has no frame to send, so the failure is silent there
  if Assigned(FRefusalHost) then
    FRefusalHost.QueueRefusal(FStreamId, AErrorCode);
end;

procedure TServerStream.SetRefusalHost(const AHost: IRefusalHost);
begin
  FRefusalHost := AHost;
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
    begin
      FWriteBlocked := True;
      Exit(False);
    end;
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
var
  Deadline: QWord;
  Remaining: Integer;
begin
  if ACount <= 0 then
    Exit;
  // the same rule as Read: one blocked call waits at most the write timeout, so
  // a peer that stops reading cannot hold a handler thread for ever
  Deadline := GetTickCount64 + QWord(FWriteTimeoutMs);
  while True do
  begin
    RaiseIfCancelled;
    if DoWrite(ABuffer, ACount) then
      Exit;
    Remaining := Integer(Deadline - GetTickCount64);
    if Remaining <= 0 then
      raise EHttpTimeout.Create('the response body write timed out');
    if FWaiter.Wait(Remaining) = wrCancelled then
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

procedure TServerStream.SetLockOwner(const AOwner: IInterface);
begin
  FLockOwner := AOwner;
end;

procedure TServerStream.SetSink(const ASink: IChannelSink);
begin
  LockStream;
  try
    FSink := ASink;
  finally
    UnlockStream;
  end;
end;

function TServerStream.TryWrite(const AData: TBytes): Boolean;
begin
  if Length(AData) = 0 then
    Exit(True);
  Result := DoWrite(AData[0], Length(AData));
end;

procedure TServerStream.AddCredit(const ACount: LongWord);
begin
  if ACount = 0 then
    Exit;
  LockStream;
  try
    Inc(FConsumedSinceUpdate, ACount);
  finally
    UnlockStream;
  end;
  // the IO side emits the WINDOW_UPDATE when it next flushes; the wake-up makes
  // that happen although the peer may be silent while it waits for credit
  if Assigned(FHost) then
    FHost.OutputPending(FStreamId);
end;

function TServerStream.HasRemoteEnded: Boolean;
begin
  LockStream;
  try
    Result := FRemoteEnded;
  finally
    UnlockStream;
  end;
end;

end.
