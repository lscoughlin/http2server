{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, detach, channel, duplex, sink, credit, registry
notes:
  - This unit holds the interfaces of a detached stream. A handler calls Detach
    on its response and receives an IDuplexChannel. The server then keeps the
    stream open and moves bytes in both directions without a thread for the
    stream.
  - The unit has no socket, no thread and no dependency on the stream unit, so
    the interfaces serve every transport.
  - The registry counts the live channels against a limit and closes them all
    when the server stops.
---
}
/// The duplex channel of a detached stream
// - Send never blocks. A producer thread can call it at any time.
// - The sink never blocks. Its data calls run on an IO thread under the connection
//   lock, and PeerClosed can run on any thread.
// - ReturnCredit is the only source of receive credit for a detached stream: the
//   channel returns no credit by itself, so a slow consumer slows its peer.
unit Http2Server.Duplex;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Hpack;

const
  /// the greatest period or timeout of an event stream: one hour, in milliseconds
  cSseMaxMs = 3600000;

type
  /// the answer of Send
  TSendResult = (
    /// the bytes joined the outbound queue
    srQueued,
    /// the outbound queue is over its limit; the bytes did not join the queue
    srFull,
    /// the channel is closed or the stream ended
    srClosed);

  /// how Close ends a channel
  TChannelClose = (
    /// send the queued bytes, then END_STREAM
    ccGraceful,
    /// reset the stream at once and drop the queued bytes
    ccAbort);

  /// one unit of work for a work source
  TStreamTask = procedure of object;

  /// one ordered task queue of the streaming pool
  // - every method is safe to call from any thread, also from inside a task
  IStreamSource = interface
    ['{7E1F0C11-0041-4A11-9C72-000000000701}']
    /// queue a task; it runs after the earlier tasks of this source
    // - answers False when the source is closed or the pool has stopped
    function Post(const ATask: TStreamTask): Boolean;
    /// queue a task that becomes ready ADelayMs milliseconds from now
    // - the task then queues behind the tasks that are already waiting
    function PostAfter(const ADelayMs: Cardinal;
      const ATask: TStreamTask): Boolean;
    /// drop the waiting tasks and the timers, and refuse later posts
    // - a task that runs at this instant finishes
    procedure Close;
    /// true once Close ran or the pool stopped
    function IsClosed: Boolean;
    /// the number of tasks that wait in the queue of this source
    function PendingTasks: Integer;
  end;

  /// the maker of work sources; the server points it at the streaming pool
  TNewSourceFunc = function: IStreamSource of object;

  IChannelRegistry = interface;

  /// the phase of a channel
  TChannelState = (
    /// detached before the response headers: no response has left yet
    csPending,
    /// the response headers have left and bytes move in both directions
    csActive,
    /// the stream ended, or Close ran
    csClosed);

  /// The receiver of the inbound bytes of a channel.
  ///
  /// BytesReceived and WriteDrained run on an IO thread while the connection lock
  /// is held. PeerClosed can run on any thread: the IO thread, the owner thread
  /// that aborts the channel, a handler-pool thread that refuses the stream, or
  /// the thread that frees the connection. No call blocks, so the sink does its
  /// work quickly. A sink that needs application work queues a task on a work
  /// source of the streaming pool.
  IChannelSink = interface
    ['{7E1F0C11-0051-4A11-9C72-000000000801}']
    /// ACount bytes arrived; the bytes are valid for the length of the call
    procedure BytesReceived(const AData; const ACount: Integer);
    /// the channel ended: the peer sent END_STREAM or reset the stream, the
    /// connection closed, or the owner aborted the channel
    // - AClean is True when the peer closed its half with END_STREAM
    procedure PeerClosed(const AClean: Boolean);
    /// the outbound queue was full and has fallen below the low-water mark
    procedure WriteDrained;
  end;

  /// A detached stream: bytes in both directions without a handler thread.
  IDuplexChannel = interface
    ['{7E1F0C11-0052-4A11-9C72-000000000802}']
    /// queue bytes for the peer; any thread; never blocks
    function Send(const AData: TBytes): TSendResult;
    /// end the channel
    procedure Close(const AMode: TChannelClose);
    /// true while the channel is neither closed nor ended
    function IsOpen: Boolean;
    function State: TChannelState;
    /// the outbound bytes that wait for the peer
    function QueuedBytes: Int64;
    /// set the receiver of the inbound bytes
    // - bytes that arrived before this call are delivered to the sink at once
    procedure SetSink(const ASink: IChannelSink);
    /// tell the peer that ACount inbound bytes were consumed; any thread
    // - a WINDOW_UPDATE leaves when the credit passes the update threshold
    procedure ReturnCredit(const ACount: Int64);
    /// pending channels only: answer with an ordinary response and end the channel
    // - the connection stays open and serves its other streams
    procedure Complete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    /// pending channels only: send the response headers and open the data path
    procedure Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
    /// the registry of the server that holds this channel; nil when none
    // - a stream layer reads its work source and its settings from here
    function Registry: IChannelRegistry;
  end;

  /// the registry refused a detach because the limit of detached streams is
  /// reached
  EDetachRefused = class(EHttpError);

  /// The count and the list of the live channels of one server.
  IChannelRegistry = interface
    ['{7E1F0C11-0053-4A11-9C72-000000000803}']
    /// reserve a slot; False when the limit is reached
    function TryAcquire: Boolean;
    /// give a reserved slot back
    procedure Release;
    /// remember an open channel, so that CloseAll reaches it
    procedure Add(const AChannel: IDuplexChannel);
    /// forget a channel that has ended
    procedure Remove(const AChannel: IDuplexChannel);
    /// close every registered channel
    procedure CloseAll(const AMode: TChannelClose);
    /// the number of reserved slots
    function Count: Integer;
    function Limit: Integer;
    /// the outbound queue limit of a detached stream, in bytes; 0 keeps the
    /// limit that the stream already has
    function QueueLimit: Integer;
    /// the queued byte count at or below which a refused writer is told
    function LowWater: Integer;
    /// a new work source of the streaming pool; nil when the server has none
    function NewSource: IStreamSource;
    /// the period of the keep-alive comment of an event stream; 0 means none
    function SseKeepAliveMs: Integer;
    /// how long a full event stream may stay full before the server closes it
    function SseStallTimeoutMs: Integer;
  end;

  /// the registry of one server
  TChannelRegistry = class(TInterfacedObject, IChannelRegistry)
  private
    FLock: TCriticalSection;
    FLimit: Integer;
    FQueueLimit: Integer;
    FLowWater: Integer;
    FCount: Integer;
    FChannels: TList<IDuplexChannel>;
    FSourceProvider: TNewSourceFunc;
    FSseKeepAliveMs: Integer;
    FSseStallMs: Integer;
  public
    /// ALimit is the greatest number of live channels; 0 refuses every detach
    constructor Create(const ALimit: Integer; const AQueueLimit: Integer = 0;
      const ALowWater: Integer = 0);
    destructor Destroy; override;
    function TryAcquire: Boolean;
    procedure Release;
    procedure Add(const AChannel: IDuplexChannel);
    procedure Remove(const AChannel: IDuplexChannel);
    procedure CloseAll(const AMode: TChannelClose);
    function Count: Integer;
    function Limit: Integer;
    function QueueLimit: Integer;
    function LowWater: Integer;
    function NewSource: IStreamSource;
    function SseKeepAliveMs: Integer;
    function SseStallTimeoutMs: Integer;
    /// the maker of work sources; set once, before the first channel
    property SourceProvider: TNewSourceFunc read FSourceProvider
      write FSourceProvider;
    property KeepAliveMs: Integer write FSseKeepAliveMs;
    property StallTimeoutMs: Integer write FSseStallMs;
  end;

implementation

{ TChannelRegistry }

constructor TChannelRegistry.Create(const ALimit, AQueueLimit, ALowWater: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLimit := ALimit;
  FQueueLimit := AQueueLimit;
  FLowWater := ALowWater;
  FChannels := TList<IDuplexChannel>.Create;
end;

destructor TChannelRegistry.Destroy;
begin
  FChannels.Free;
  FLock.Free;
  inherited Destroy;
end;

function TChannelRegistry.TryAcquire: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCount < FLimit;
    if Result then
      Inc(FCount);
  finally
    FLock.Release;
  end;
end;

procedure TChannelRegistry.Release;
begin
  FLock.Acquire;
  try
    if FCount > 0 then
      Dec(FCount);
  finally
    FLock.Release;
  end;
end;

procedure TChannelRegistry.Add(const AChannel: IDuplexChannel);
begin
  FLock.Acquire;
  try
    FChannels.Add(AChannel);
  finally
    FLock.Release;
  end;
end;

procedure TChannelRegistry.Remove(const AChannel: IDuplexChannel);
begin
  FLock.Acquire;
  try
    FChannels.Remove(AChannel);
  finally
    FLock.Release;
  end;
end;

procedure TChannelRegistry.CloseAll(const AMode: TChannelClose);
var
  Copy: TArray<IDuplexChannel>;
  I: Integer;
begin
  // close outside the lock: Close calls back into Remove
  FLock.Acquire;
  try
    Copy := FChannels.ToArray;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Copy) do
    Copy[I].Close(AMode);
end;

function TChannelRegistry.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

function TChannelRegistry.Limit: Integer;
begin
  Result := FLimit;
end;

function TChannelRegistry.QueueLimit: Integer;
begin
  Result := FQueueLimit;
end;

function TChannelRegistry.LowWater: Integer;
begin
  Result := FLowWater;
end;

function TChannelRegistry.NewSource: IStreamSource;
begin
  if Assigned(FSourceProvider) then
    Result := FSourceProvider()
  else
    Result := nil;
end;

function TChannelRegistry.SseKeepAliveMs: Integer;
begin
  Result := FSseKeepAliveMs;
end;

function TChannelRegistry.SseStallTimeoutMs: Integer;
begin
  Result := FSseStallMs;
end;

end.
