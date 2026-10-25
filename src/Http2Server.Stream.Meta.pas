{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream, locks, reference count, request head, response head
notes:
  - This unit holds the base of the server stream. It owns the per-stream lock,
    the reference count, the request head and body length accounting, and the
    response header block that waits for the IO thread.
  - The buffers, the wait state and the handler calls are in Http2Server.Stream,
    which derives TServerStream from the base class of this unit.
  - The lock order is the connection lock first and the stream lock second.
---
}
/// The base of the server stream: locks, reference count and heads
unit Http2Server.Stream.Meta;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Http2Server.Hpack, Http2Server.StreamHost;

type
  /// The locks, the reference count and the head state of one stream.
  ///
  /// The connection lock of the owning connection guards every method that
  /// touches state shared with the IO thread. A handler-side call takes that
  /// lock for the length of one operation only.
  TStreamMeta = class
  private
    /// how many holders keep this stream alive
    // - the core holds one, a queue entry holds one, and a running handler
    //   holds one, so the stream is freed when the last holder releases it
    FRefCount: Integer;
    /// how many nested holds of the per-stream lock are live now
    FLockDepth: Integer;
    /// the deepest hold of the per-stream lock seen so far (test seam)
    FMaxLockDepth: Integer;
    /// the per-stream lock; a handler takes it with the connection lock for one
    /// buffer operation and never holds either across a wait
    FStreamLock: TCriticalSection;
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
  protected
    /// the connection lock, shared by every stream of one connection
    FConnLock: TCriticalSection;
    /// keeps the connection lock alive
    FLockOwner: IInterface;
    FHost: IStreamHost;
    FStreamId: LongWord;
    /// take the connection lock and the per-stream lock, in that order
    procedure LockStream;
    /// release the per-stream lock and the connection lock
    procedure UnlockStream;
  public
    /// create a stream of AStreamId
    // - ALock is the connection lock, shared by every stream of a connection
    constructor Create(const AStreamId: LongWord; const ALock: TCriticalSection;
      const AHost: IStreamHost);
    destructor Destroy; override;

    /// take one reference; the stream is freed when the last one is released
    procedure AddRef;
    /// release one reference and free the stream at zero
    procedure ReleaseRef;

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
    property StreamId: LongWord read FStreamId;
    /// the deepest hold of the per-stream lock seen so far
    // - a handler call holds the lock for one buffer operation only, so a
    //   value above one would mean a lock held across a nested operation, and
    //   a value of zero at the wait point means no lock is held across a wait
    property MaxLockDepth: Integer read FMaxLockDepth;
  end;

implementation

constructor TStreamMeta.Create(const AStreamId: LongWord;
  const ALock: TCriticalSection; const AHost: IStreamHost);
begin
  inherited Create;
  FConnLock := ALock;
  FStreamLock := TCriticalSection.Create;
  FHost := AHost;
  FStreamId := AStreamId;
  // the core holds the first reference
  FRefCount := 1;
end;

destructor TStreamMeta.Destroy;
begin
  FStreamLock.Free;
  inherited Destroy;
end;

procedure TStreamMeta.AddRef;
begin
  InterlockedIncrement(FRefCount);
end;

procedure TStreamMeta.ReleaseRef;
begin
  // the last holder frees the stream.  The stream lock is not held, because
  // the lock object dies with the stream.
  if InterlockedDecrement(FRefCount) = 0 then
    Self.Free;
end;

procedure TStreamMeta.LockStream;
begin
  // the connection lock comes first, so the IO thread and a handler thread
  // always take the two locks in the same order
  if FConnLock <> nil then
    FConnLock.Acquire;
  FStreamLock.Acquire;
  Inc(FLockDepth);
  if FLockDepth > FMaxLockDepth then
    FMaxLockDepth := FLockDepth;
end;

procedure TStreamMeta.UnlockStream;
begin
  Dec(FLockDepth);
  FStreamLock.Release;
  if FConnLock <> nil then
    FConnLock.Release;
end;

procedure TStreamMeta.SetRemoteHeaders(const AHeaders: THeaderBlock);
begin
  LockStream;
  try
    FRemoteHeaders := AHeaders;
  finally
    UnlockStream;
  end;
end;

function TStreamMeta.RemoteHeaders: THeaderBlock;
begin
  LockStream;
  try
    Result := FRemoteHeaders;
  finally
    UnlockStream;
  end;
end;

procedure TStreamMeta.SetDeclaredLength(const ALength: Int64);
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

function TStreamMeta.CountReceivedBody(const ACount: Integer): Boolean;
begin
  LockStream;
  try
    FReceivedLength := FReceivedLength + ACount;
    Result := (not FHasDeclaredLength) or (FReceivedLength <= FDeclaredLength);
  finally
    UnlockStream;
  end;
end;

function TStreamMeta.DeclaredLengthMatches: Boolean;
begin
  LockStream;
  try
    Result := (not FHasDeclaredLength) or (FReceivedLength = FDeclaredLength);
  finally
    UnlockStream;
  end;
end;

function TStreamMeta.HasRequestHead: Boolean;
begin
  LockStream;
  try
    Result := FHasRequestHead;
  finally
    UnlockStream;
  end;
end;

procedure TStreamMeta.MarkRequestHead;
begin
  LockStream;
  try
    FHasRequestHead := True;
  finally
    UnlockStream;
  end;
end;

procedure TStreamMeta.QueueResponseHeaders(const AStatus: Integer;
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

function TStreamMeta.TakePendingHeaders(out AStatus: Integer;
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

procedure TStreamMeta.RequestFinish;
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

function TStreamMeta.HasPendingHeaders: Boolean;
begin
  LockStream;
  try
    Result := FHasPendingHeaders;
  finally
    UnlockStream;
  end;
end;

function TStreamMeta.WantsFinish: Boolean;
begin
  LockStream;
  try
    Result := FFinishRequested;
  finally
    UnlockStream;
  end;
end;

procedure TStreamMeta.ClearFinish;
begin
  LockStream;
  try
    FFinishRequested := False;
  finally
    UnlockStream;
  end;
end;

end.
