{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, admission, queue, handler pool, rapid reset
notes:
  - This unit holds the bounded request queue and the handler pool.
  - The queue is the one admission point of the server.  A stream enters the
    queue before a handler thread takes it.
  - The queue uses a TCriticalSection and an RTLEvent.  FPC 3.2.4 has no
    TThreadedQueue and no TMonitor, and a TEvent fails on macOS.
  - RTLEventSetEvent and RTLEventResetEvent are procedures on this RTL and
    return no value.  This unit never assigns their result.
  - The handler-side request and response adapters wrap one TServerStream.
    The pool builds a fresh pair for each dispatch.
---
}
/// The bounded request queue and the handler pool
// - the queue bounds how many requests wait for a handler.  A stream count
//   does not bound handler occupancy: a peer can reset a stream, which frees
//   the stream slot, while the handler of that stream keeps running.  The
//   queue is the real bound, and it is the answer to CVE-2023-44487.
// - the handler pool owns N worker threads.  Each thread takes one entry and
//   runs IHttp2Handler.Handle on it.
// - a stream that a peer cancels while it waits in the queue leaves the queue
//   at once and its handler never runs.
unit Http2Server.Admission;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors,
  Http2Server.Hpack,
  Http2Server.Headers,
  Http2Server.Limits,
  Http2Server.Seam,
  Http2Server.Stream,
  Http2Server.Waiter,
  Http2Server.Config,
  Http2Server.Observer;

type
  /// the outcome of one admission attempt
  TAdmitResult = (
    /// the request waits in the queue
    asQueued,
    /// the queue is full, or it no longer accepts work
    asRefused);

  /// the outcome of one dequeue
  TDequeueResult = (
    /// the entry is ready for a handler
    drDispatch,
    /// the entry waited longer than the queue wait limit
    drTimedOut);

  /// one queue entry: the stream and the time it entered the queue
  TQueueEntry = record
    Stream: TServerStream;
    EnqueueMs: QWord;
  end;

  /// A bounded FIFO of requests that wait for a handler.
  ///
  /// TryEnqueue adds an entry while the queue holds fewer entries than Depth.
  /// A full queue, and a stopped queue, refuse the entry.  Dequeue blocks for
  /// a bounded time.  At dequeue the entry age is compared with MaxWaitMs; an
  /// entry past the limit is a timeout, not a dispatch.
  TRequestQueue = class
  private
    FLock: TCriticalSection;
    FWake: PRTLEvent;
    FEntries: TQueue<TQueueEntry>;
    FDepth: Integer;
    FMaxWaitMs: Integer;
    FClock: IMonotonicClock;
    FStopped: Boolean;
  public
    /// create a queue of ADepth entries and a wait limit of AMaxWaitMs
    constructor Create(const ADepth, AMaxWaitMs: Integer;
      const AClock: IMonotonicClock);
    destructor Destroy; override;

    /// add AStream to the queue
    function TryEnqueue(const AStream: TServerStream): TAdmitResult;
    /// take the oldest entry; False means the queue is stopped and empty
    // - a dispatch carries the stream; a timeout carries an aged entry that
    //   the caller answers with a refusal
    function Dequeue(out AStream: TServerStream;
      out AResult: TDequeueResult): Boolean;
    /// remove the entry of AStreamId; False when no entry matches
    function RemoveStream(const AStreamId: LongWord): Boolean;
    /// remove and answer every waiting entry
    function DrainAll: TArray<TServerStream>;
    /// the entries held now
    function Count: Integer;
    /// stop accepting work and wake every parked consumer
    procedure Stop;

    /// the greatest number of waiting entries
    property Depth: Integer read FDepth;
    /// the greatest wait of one entry, in milliseconds
    property MaxWaitMs: Integer read FMaxWaitMs;
    /// true once Stop has run
    property Stopped: Boolean read FStopped;
  end;

  /// The request as one handler sees it, backed by one TServerStream.
  ///
  /// The adapter is byte-oriented, as the seam requires.  The pseudo-headers
  /// come from the decoded request block of the stream.
  TServerStreamRequest = class(TInterfacedObject, IServerRequest)
  private
    FStream: TServerStream;
    function PseudoValue(const AName: string): string;
  public
    constructor Create(const AStream: TServerStream);
    function Method: string;
    function Scheme: string;
    function Authority: string;
    function Path: string;
    function Headers: THeaderBlock;
    function Read(var ABuffer; const ACount: Integer): Integer;
    function ReadChunk(out AChunk: TBytes): Boolean;
    function BodyIsComplete: Boolean;
    function IsCancelled: Boolean;
    function StreamId: LongWord;
  end;

  /// The response as one handler writes it, backed by one TServerStream.
  ///
  /// SendHeaders holds the response block for the IO side, which owns the
  /// HPACK encoder.  A body writer is pulled when the handler calls Finish.
  TServerStreamResponse = class(TInterfacedObject, IServerResponse)
  private
    FStream: TServerStream;
    FBodyWriter: IBodyWriter;
    FHeadersSent: Boolean;
  public
    constructor Create(const AStream: TServerStream);
    procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure Write(const AData: TBytes); overload;
    procedure Write(const ABuffer; const ACount: Integer); overload;
    procedure SetBodyWriter(const AWriter: IBodyWriter);
    procedure Finish;
    procedure RegisterCancelHook(const AHook: TCancelHook);
    function IsCancelled: Boolean;
    function StreamId: LongWord;
    /// true once the handler sent the response headers
    property HeadersSent: Boolean read FHeadersSent;
  end;

  /// the report of a handler that ended with an exception
  ///
  /// The core later answers with a 500 when ABeforeHeaders is true, and with
  /// RST_STREAM when it is false.
  THandlerErrorEvent = procedure(const AStream: TServerStream;
    const ABeforeHeaders: Boolean) of object;

  THandlerPool = class;

  /// one worker thread of the handler pool
  THandlerThread = class(TThread)
  private
    FPool: THandlerPool;
  protected
    procedure Execute; override;
  public
    constructor Create(const APool: THandlerPool);
  end;

  /// The pool that runs the handlers.
  ///
  /// Each worker takes one entry from the queue and calls
  /// IHttp2Handler.Handle.  EStreamCancelled ends a handler quietly.  Any
  /// other exception reaches OnHandlerError.  Stop stops acceptance, refuses
  /// the waiting entries, waits for the running handlers up to the graceful
  /// timeout and then cancels them.
  THandlerPool = class
  private
    FOptions: TQueueOptions;
    FQueue: TRequestQueue;
    FHandler: IHttp2Handler;
    FThreads: TObjectList<THandlerThread>;
    FLock: TCriticalSection;
    FActive: TList<TServerStream>;
    FBusy: Integer;
    FRefused: Integer;
    FTimedOut: Integer;
    FDropped: Integer;
    FPoolStopped: Boolean;
    FGracefulTimeoutMs: Integer;
    FOnHandlerError: THandlerErrorEvent;
    /// the observer of the server; nil when the server set none
    // - every event runs on the worker thread that raised it
    FObserver: IHttp2ServerObserver;
    procedure Notify(const AKind: TServerEventKind;
      const AStream: TServerStream; const ADetail: string);
    function TakeOne: Boolean;
    procedure AnswerRefusal(const AStream: TServerStream);
    procedure ReportError(const AStream: TServerStream;
      const ABeforeHeaders: Boolean);
    procedure MarkBusy(const AStream: TServerStream);
    procedure MarkIdle(const AStream: TServerStream);
    function SnapshotActive: TArray<TServerStream>;
    function GetBusyHandlers: Integer;
    function GetRefusedTotal: Integer;
    function GetTimedOutTotal: Integer;
    function GetDroppedBeforeDispatch: Integer;
  public
    /// create the pool from the server factory
    // - the handler thread count, the queue settings and the clock come from
    //   the factory
    constructor Create(const AFactory: THttp2ServerFactory);
    destructor Destroy; override;

    /// offer AStream to the queue
    // - a refusal answers the stream at once, per the refusal mode
    function Admit(const AStream: TServerStream): TAdmitResult;
    /// remove the queued entry of AStreamId, as a reset does
    function RemoveStream(const AStreamId: LongWord): Boolean;
    /// stop acceptance, refuse the waiting entries and end the workers
    procedure Stop;
    /// the worker threads that have not finished
    function AliveThreadCount: Integer;

    /// the underlying queue (test and wire-up seam)
    property Queue: TRequestQueue read FQueue;
    /// handlers that run now
    property BusyHandlers: Integer read GetBusyHandlers;
    /// entries that wait now
    function QueueLength: Integer;
    /// requests refused because the queue was full
    property RefusedTotal: Integer read GetRefusedTotal;
    /// entries that passed the queue wait limit
    property TimedOutTotal: Integer read GetTimedOutTotal;
    /// entries removed or found cancelled before a handler ran
    property DroppedBeforeDispatch: Integer read GetDroppedBeforeDispatch;
    /// the number of worker threads
    function HandlerThreadCount: Integer;
    /// the report of a handler that raised
    property OnHandlerError: THandlerErrorEvent read FOnHandlerError
      write FOnHandlerError;
    /// the observer of the server (test and wire-up seam)
    property Observer: IHttp2ServerObserver read FObserver write FObserver;
  end;

implementation

const
  /// the longest park of a waiting consumer, in milliseconds
  // - a short park makes Stop and the wait limit take effect quickly
  cQueueParkMs = 20;

{ TRequestQueue }

constructor TRequestQueue.Create(const ADepth, AMaxWaitMs: Integer;
  const AClock: IMonotonicClock);
begin
  inherited Create;
  FDepth := ADepth;
  FMaxWaitMs := AMaxWaitMs;
  FClock := AClock;
  FEntries := TQueue<TQueueEntry>.Create;
  FLock := TCriticalSection.Create;
  FWake := RTLEventCreate;
  FStopped := False;
end;

destructor TRequestQueue.Destroy;
begin
  RTLEventDestroy(FWake);
  FLock.Free;
  FEntries.Free;
  inherited Destroy;
end;

function TRequestQueue.TryEnqueue(const AStream: TServerStream): TAdmitResult;
var
  E: TQueueEntry;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit(asRefused);
    if (FDepth <= 0) or (FEntries.Count >= FDepth) then
      Exit(asRefused);
    E.Stream := AStream;
    E.EnqueueMs := FClock.NowMs;
    FEntries.Enqueue(E);
  finally
    FLock.Release;
  end;
  // one wake releases one parked consumer
  RTLEventSetEvent(FWake);
  Result := asQueued;
end;

function TRequestQueue.Dequeue(out AStream: TServerStream;
  out AResult: TDequeueResult): Boolean;
var
  E: TQueueEntry;
  Now, Deadline: QWord;
begin
  AStream := nil;
  AResult := drDispatch;
  while True do
  begin
    FLock.Acquire;
    try
      if FStopped then
        Exit(False);
      if FEntries.Count > 0 then
      begin
        E := FEntries.Dequeue;
        AStream := E.Stream;
        Now := FClock.NowMs;
        Deadline := E.EnqueueMs + QWord(FMaxWaitMs);
        // an entry that waited past the limit is a timeout, not a dispatch
        if (FMaxWaitMs > 0) and (Now >= Deadline) then
          AResult := drTimedOut
        else
          AResult := drDispatch;
        Exit(True);
      end;
    finally
      FLock.Release;
    end;
    // the queue is empty; park for a bounded time, then look again
    RTLEventWaitFor(FWake, cQueueParkMs);
  end;
end;

function TRequestQueue.RemoveStream(const AStreamId: LongWord): Boolean;
var
  Kept: TQueue<TQueueEntry>;
  E: TQueueEntry;
begin
  FLock.Acquire;
  try
    Result := False;
    if FEntries.Count = 0 then
      Exit;
    Kept := TQueue<TQueueEntry>.Create;
    try
      while FEntries.Count > 0 do
      begin
        E := FEntries.Dequeue;
        if (not Result) and (E.Stream.StreamId = AStreamId) then
          Result := True
        else
          Kept.Enqueue(E);
      end;
      while Kept.Count > 0 do
        FEntries.Enqueue(Kept.Dequeue);
    finally
      Kept.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TRequestQueue.DrainAll: TArray<TServerStream>;
var
  E: TQueueEntry;
  N: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    SetLength(Result, FEntries.Count);
    N := 0;
    while FEntries.Count > 0 do
    begin
      E := FEntries.Dequeue;
      Result[N] := E.Stream;
      Inc(N);
    end;
  finally
    FLock.Release;
  end;
end;

function TRequestQueue.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FEntries.Count;
  finally
    FLock.Release;
  end;
end;

procedure TRequestQueue.Stop;
begin
  FLock.Acquire;
  try
    FStopped := True;
  finally
    FLock.Release;
  end;
  // a parked consumer notices the stop at the next short park; one wake
  // releases the consumer that is parked at this instant
  RTLEventSetEvent(FWake);
end;

{ TServerStreamRequest }

constructor TServerStreamRequest.Create(const AStream: TServerStream);
begin
  inherited Create;
  FStream := AStream;
end;

function TServerStreamRequest.PseudoValue(const AName: string): string;
var
  H: THeaderBlock;
  I: Integer;
begin
  Result := '';
  H := FStream.RemoteHeaders;
  for I := 0 to High(H) do
    if H[I].Name = AName then
      Exit(H[I].Value);
end;

function TServerStreamRequest.Method: string;
begin
  Result := PseudoValue(HeaderMethod);
end;

function TServerStreamRequest.Scheme: string;
begin
  Result := PseudoValue(HeaderScheme);
end;

function TServerStreamRequest.Authority: string;
begin
  Result := PseudoValue(HeaderAuthority);
end;

function TServerStreamRequest.Path: string;
begin
  Result := PseudoValue(HeaderPath);
end;

function TServerStreamRequest.Headers: THeaderBlock;
var
  H: THeaderBlock;
  I, N: Integer;
begin
  Result := nil;
  H := FStream.RemoteHeaders;
  SetLength(Result, Length(H));
  N := 0;
  for I := 0 to High(H) do
    if (Length(H[I].Name) = 0) or (H[I].Name[1] <> ':') then
    begin
      Result[N] := H[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

function TServerStreamRequest.Read(var ABuffer;
  const ACount: Integer): Integer;
begin
  Result := FStream.Read(ABuffer, ACount);
end;

function TServerStreamRequest.ReadChunk(out AChunk: TBytes): Boolean;
begin
  Result := FStream.ReadChunk(AChunk);
end;

function TServerStreamRequest.BodyIsComplete: Boolean;
begin
  Result := FStream.BodyIsComplete;
end;

function TServerStreamRequest.IsCancelled: Boolean;
begin
  Result := FStream.IsCancelled;
end;

function TServerStreamRequest.StreamId: LongWord;
begin
  Result := FStream.StreamId;
end;

{ TServerStreamResponse }

constructor TServerStreamResponse.Create(const AStream: TServerStream);
begin
  inherited Create;
  FStream := AStream;
end;

procedure TServerStreamResponse.SendHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
begin
  FHeadersSent := True;
  FStream.QueueResponseHeaders(AStatus, AHeaders, AEndStream);
end;

procedure TServerStreamResponse.Write(const AData: TBytes);
begin
  FStream.Write(AData);
end;

procedure TServerStreamResponse.Write(const ABuffer; const ACount: Integer);
begin
  FStream.Write(ABuffer, ACount);
end;

procedure TServerStreamResponse.SetBodyWriter(const AWriter: IBodyWriter);
begin
  FBodyWriter := AWriter;
end;

procedure TServerStreamResponse.Finish;
var
  Chunk: TBytes;
begin
  if FBodyWriter <> nil then
    while FBodyWriter.NextChunk(Chunk) do
      FStream.Write(Chunk);
  FStream.RequestFinish;
end;

procedure TServerStreamResponse.RegisterCancelHook(const AHook: TCancelHook);
var
  W: IStreamWaiter;
begin
  W := FStream.Waiter;
  // the default waiter is a TBlockingWaiter and holds the hook slot; another
  // IStreamWaiter has no hook slot
  if W is TBlockingWaiter then
    (W as TBlockingWaiter).RegisterHook(AHook);
end;

function TServerStreamResponse.IsCancelled: Boolean;
begin
  Result := FStream.IsCancelled;
end;

function TServerStreamResponse.StreamId: LongWord;
begin
  Result := FStream.StreamId;
end;

{ THandlerThread }

constructor THandlerThread.Create(const APool: THandlerPool);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure THandlerThread.Execute;
begin
  while FPool.TakeOne do
    ;
end;

{ THandlerPool }

constructor THandlerPool.Create(const AFactory: THttp2ServerFactory);
var
  I, N: Integer;
begin
  inherited Create;
  FOptions := AFactory.Queue;
  FHandler := AFactory.Handler;
  FGracefulTimeoutMs := AFactory.GracefulStopTimeoutMs;
  FPoolStopped := False;
  FLock := TCriticalSection.Create;
  FActive := TList<TServerStream>.Create;
  FThreads := TObjectList<THandlerThread>.Create(True);
  FQueue := TRequestQueue.Create(FOptions.Depth, FOptions.MaxWaitMs,
    AFactory.Clock);
  N := AFactory.HandlerThreads;
  if N < 1 then
    N := 1;
  // the workers start last, so every field they read is set
  for I := 1 to N do
    FThreads.Add(THandlerThread.Create(Self));
end;

destructor THandlerPool.Destroy;
begin
  Stop;
  FThreads.Free;
  FActive.Free;
  FQueue.Free;
  FLock.Free;
  inherited Destroy;
end;

function THandlerPool.HandlerThreadCount: Integer;
begin
  Result := FThreads.Count;
end;

function THandlerPool.AliveThreadCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FThreads.Count - 1 do
    if not FThreads[I].Finished then
      Inc(Result);
end;

function THandlerPool.GetBusyHandlers: Integer;
begin
  FLock.Acquire;
  try
    Result := FBusy;
  finally
    FLock.Release;
  end;
end;

function THandlerPool.GetRefusedTotal: Integer;
begin
  FLock.Acquire;
  try
    Result := FRefused;
  finally
    FLock.Release;
  end;
end;

function THandlerPool.GetTimedOutTotal: Integer;
begin
  FLock.Acquire;
  try
    Result := FTimedOut;
  finally
    FLock.Release;
  end;
end;

function THandlerPool.GetDroppedBeforeDispatch: Integer;
begin
  FLock.Acquire;
  try
    Result := FDropped;
  finally
    FLock.Release;
  end;
end;

function THandlerPool.QueueLength: Integer;
begin
  Result := FQueue.Count;
end;

procedure THandlerPool.MarkBusy(const AStream: TServerStream);
begin
  FLock.Acquire;
  try
    Inc(FBusy);
    FActive.Add(AStream);
  finally
    FLock.Release;
  end;
end;

procedure THandlerPool.MarkIdle(const AStream: TServerStream);
begin
  FLock.Acquire;
  try
    Dec(FBusy);
    FActive.Remove(AStream);
  finally
    FLock.Release;
  end;
end;

function THandlerPool.SnapshotActive: TArray<TServerStream>;
var
  I: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    SetLength(Result, FActive.Count);
    for I := 0 to FActive.Count - 1 do
      Result[I] := FActive[I];
  finally
    FLock.Release;
  end;
end;

procedure THandlerPool.AnswerRefusal(const AStream: TServerStream);
begin
  case FOptions.RefusalMode of
    rmRefuseStream:
      AStream.Cancel(ecRefusedStream);
    rmHttp503:
      AStream.QueueResponseHeaders(503, nil, True);
  end;
end;

procedure THandlerPool.ReportError(const AStream: TServerStream;
  const ABeforeHeaders: Boolean);
begin
  Notify(seHandlerException, AStream, 'the handler raised');
  if Assigned(FOnHandlerError) then
    FOnHandlerError(AStream, ABeforeHeaders);
end;

procedure THandlerPool.Notify(const AKind: TServerEventKind;
  const AStream: TServerStream; const ADetail: string);
var
  Event: TServerEvent;
begin
  if FObserver = nil then
    Exit;
  Event.Kind := AKind;
  Event.StreamId := 0;
  if AStream <> nil then
    Event.StreamId := AStream.StreamId;
  Event.LimitKind := lkReset;
  Event.ErrorCode := ecNoError;
  Event.Detail := ADetail;
  FObserver.OnEvent(Event);
end;

function THandlerPool.TakeOne: Boolean;
var
  Stream: TServerStream;
  Outcome: TDequeueResult;
  Req: TServerStreamRequest;
  Res: TServerStreamResponse;
begin
  Result := False;
  if not FQueue.Dequeue(Stream, Outcome) then
    Exit;
  Result := True;
  if Outcome = drTimedOut then
  begin
    FLock.Acquire;
    try
      Inc(FTimedOut);
    finally
      FLock.Release;
    end;
    Notify(seRequestTimedOut, Stream, 'the queue wait limit passed');
    AnswerRefusal(Stream);
    Exit;
  end;
  if Stream.IsCancelled then
  begin
    FLock.Acquire;
    try
      Inc(FDropped);
    finally
      FLock.Release;
    end;
    Exit;
  end;
  if FHandler = nil then
  begin
    FLock.Acquire;
    try
      Inc(FDropped);
    finally
      FLock.Release;
    end;
    Exit;
  end;
  MarkBusy(Stream);
  Req := TServerStreamRequest.Create(Stream);
  Res := TServerStreamResponse.Create(Stream);
  try
    try
      // a handler must never run on an IO thread: it would hold the connection
      // lock and would stall the whole IO pool
      Http2AssertHandlerThread('THandlerPool.TakeOne');
      FHandler.Handle(Req, Res);
    except
      on E: EStreamCancelled do
        ; // the cancellation ends the handler quietly
      on E: Exception do
        ReportError(Stream, not Res.HeadersSent);
    end;
  finally
    Res.Free;
    Req.Free;
    MarkIdle(Stream);
    Notify(seStreamCompleted, Stream, 'the handler returned');
  end;
end;

function THandlerPool.Admit(const AStream: TServerStream): TAdmitResult;
begin
  Result := FQueue.TryEnqueue(AStream);
  if Result = asRefused then
  begin
    FLock.Acquire;
    try
      Inc(FRefused);
    finally
      FLock.Release;
    end;
    Notify(seQueueFull, AStream, 'the queue was full');
    Notify(seStreamRefused, AStream, 'the queue was full');
    AnswerRefusal(AStream);
  end;
end;

function THandlerPool.RemoveStream(const AStreamId: LongWord): Boolean;
begin
  Result := FQueue.RemoveStream(AStreamId);
  if Result then
  begin
    FLock.Acquire;
    try
      Inc(FDropped);
    finally
      FLock.Release;
    end;
  end;
end;

procedure THandlerPool.Stop;
var
  Deadline: QWord;
  I: Integer;
  Streams: TArray<TServerStream>;
begin
  FLock.Acquire;
  try
    if FPoolStopped then
      Exit;
    FPoolStopped := True;
  finally
    FLock.Release;
  end;

  // stop acceptance; a parked worker leaves the loop at the next park
  FQueue.Stop;
  // every entry that still waits is refused, per the refusal mode
  Streams := FQueue.DrainAll;
  for I := 0 to High(Streams) do
    AnswerRefusal(Streams[I]);

  // wait for the workers up to the graceful timeout.  A worker that runs a
  // handler is not finished until that handler returns.
  Deadline := GetTickCount64 + QWord(FGracefulTimeoutMs);
  while (AliveThreadCount > 0) and (GetTickCount64 < Deadline) do
    Sleep(1);

  // then cancel whatever still runs, so a handler that waits on its stream
  // sees the cancellation
  if AliveThreadCount > 0 then
  begin
    Streams := SnapshotActive;
    for I := 0 to High(Streams) do
      Streams[I].Cancel(ecCancel);
    Deadline := GetTickCount64 + QWord(FGracefulTimeoutMs);
    while (AliveThreadCount > 0) and (GetTickCount64 < Deadline) do
      Sleep(1);
  end;

  for I := 0 to FThreads.Count - 1 do
    FThreads[I].WaitFor;
end;

end.
