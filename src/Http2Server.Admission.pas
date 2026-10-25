{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
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
  - The handler-side request and response adapters are in
    Http2Server.StreamAdapters. The pool builds a fresh pair for each dispatch.
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
  Http2Server.AccessLog, Http2Server.AccessLog.Handler,
  Http2Server.Hpack,
  Http2Server.Headers,
  Http2Server.Limits,
  Http2Server.Seam,
  Http2Server.ResponseWriter,
  Http2Server.Stream,
  Http2Server.Duplex,
  Http2Server.StreamAdapters,
  Http2Server.Waiter,
  Http2Server.Config,
  Http2Server.Observer,
  Http2Server.HandlerJob;

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
    /// the HTTP/2 stream of the entry; nil when the entry is a job
    Stream: TServerStream;
    /// the job of the entry; nil when the entry is an HTTP/2 stream
    Job: IHandlerJob;
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
    /// add a job to the queue; the same depth and wait limit apply
    function TryEnqueueJob(const AJob: IHandlerJob): TAdmitResult;
    /// take the next entry, a stream or a job
    function DequeueEntry(out AEntry: TQueueEntry;
      out AResult: TDequeueResult): Boolean;
    /// take every entry out of the queue
    function DrainEntries: TArray<TQueueEntry>;
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
    /// the writer for the records of refused requests; nil writes none
    FAccessLog: IAccessLogWriter;
    FThreads: TObjectList<THandlerThread>;
    FLock: TCriticalSection;
    FActive: TList<TServerStream>;
    FActiveJobs: TList<IHandlerJob>;
    FBusy: Integer;
    FRefused: Integer;
    FTimedOut: Integer;
    FDropped: Integer;
    FPoolStopped: Boolean;
    FGracefulTimeoutMs: Integer;
    FOnHandlerError: THandlerErrorEvent;
    /// the registry of detached streams; nil detaches without a limit
    FChannelRegistry: IChannelRegistry;
    /// the observer of the server; nil when the server set none
    // - every event runs on the worker thread that raised it
    FObserver: IHttp2ServerObserver;
    procedure Notify(const AKind: TServerEventKind;
      const AStream: TServerStream; const ADetail: string);
    procedure DetachNotify(const AStream: TServerStream; const ARefused: Boolean);
    function TakeOne: Boolean;
    procedure AnswerRefusal(const AStream: TServerStream);
    procedure LogJobRefusal(const AJob: IHandlerJob);
    procedure ReportError(const AStream: TServerStream;
      const ABeforeHeaders: Boolean);
    procedure MarkBusy(const AStream: TServerStream);
    procedure MarkIdle(const AStream: TServerStream);
    function SnapshotActive: TArray<TServerStream>;
    procedure RunJob(const AEntry: TQueueEntry; const AResult: TDequeueResult);
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
    /// queue an HTTP/1.1 request; a refusal is answered by the job itself
    function AdmitJob(const AJob: IHandlerJob): TAdmitResult;
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
    /// the registry that limits and lists the detached streams of the server
    property ChannelRegistry: IChannelRegistry read FChannelRegistry
      write FChannelRegistry;
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
    // the queue entry holds one reference until the entry leaves the queue
    AStream.AddRef;
  finally
    FLock.Release;
  end;
  // one wake releases one parked consumer
  RTLEventSetEvent(FWake);
  Result := asQueued;
end;

function TRequestQueue.TryEnqueueJob(const AJob: IHandlerJob): TAdmitResult;
var
  E: TQueueEntry;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit(asRefused);
    if (FDepth <= 0) or (FEntries.Count >= FDepth) then
      Exit(asRefused);
    E.Stream := nil;
    E.Job := AJob;
    E.EnqueueMs := FClock.NowMs;
    FEntries.Enqueue(E);
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FWake);
  Result := asQueued;
end;

function TRequestQueue.DequeueEntry(out AEntry: TQueueEntry;
  out AResult: TDequeueResult): Boolean;
var
  Now, Deadline: QWord;
begin
  AEntry := Default(TQueueEntry);
  AResult := drDispatch;
  while True do
  begin
    FLock.Acquire;
    try
      if FStopped then
        Exit(False);
      if FEntries.Count > 0 then
      begin
        AEntry := FEntries.Dequeue;
        Now := FClock.NowMs;
        Deadline := AEntry.EnqueueMs + QWord(FMaxWaitMs);
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

function TRequestQueue.Dequeue(out AStream: TServerStream;
  out AResult: TDequeueResult): Boolean;
var
  E: TQueueEntry;
begin
  Result := DequeueEntry(E, AResult);
  AStream := E.Stream;
end;

function TRequestQueue.DrainEntries: TArray<TQueueEntry>;
var
  N: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    SetLength(Result, FEntries.Count);
    N := 0;
    while FEntries.Count > 0 do
    begin
      Result[N] := FEntries.Dequeue;
      Inc(N);
    end;
  finally
    FLock.Release;
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
        if (not Result) and (E.Stream <> nil) and (E.Stream.StreamId = AStreamId) then
        begin
          Result := True;
          // the removed entry drops its reference
          E.Stream.ReleaseRef;
        end
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
  Entries: TArray<TQueueEntry>;
  I, N: Integer;
begin
  // the streams only; DrainEntries also returns the jobs
  Entries := DrainEntries;
  Result := nil;
  SetLength(Result, Length(Entries));
  N := 0;
  for I := 0 to High(Entries) do
    if Entries[I].Stream <> nil then
    begin
      Result[N] := Entries[I].Stream;
      Inc(N);
    end;
  SetLength(Result, N);
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
  // a nil writer leaves the handler as it is: no wrapper, no cost
  FAccessLog := AFactory.AccessLogWriter;
  if (FHandler <> nil) and (AFactory.AccessLogWriter <> nil) then
    FHandler :=TAccessLoggingHandler.Create(FHandler, AFactory.AccessLogWriter);
  FGracefulTimeoutMs := AFactory.GracefulStopTimeoutMs;
  FPoolStopped := False;
  FLock := TCriticalSection.Create;
  FActive := TList<TServerStream>.Create;
  FActiveJobs := TList<IHandlerJob>.Create;
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
  FActiveJobs.Free;
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
  // the active handler drops its reference
  AStream.ReleaseRef;
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

procedure THandlerPool.LogJobRefusal(const AJob: IHandlerJob);
var
  Req: IServerRequest;
  Probe: IAccessLogProbe;
begin
  if FAccessLog = nil then
    Exit;
  if not Supports(AJob, IServerRequest, Req) then
    Exit;
  if not Supports(AJob, IAccessLogProbe, Probe) then
    Probe := nil;
  // an HTTP/1.1 job always answers 503
  WriteRefusalRecord(FAccessLog, Req, Probe, 503);
end;

procedure THandlerPool.AnswerRefusal(const AStream: TServerStream);
var
  Req: IServerRequest;
  Probe: IAccessLogProbe;
begin
  if FAccessLog <> nil then
  begin
    // the record comes first: the answer can end the stream
    Req := TServerStreamRequest.Create(AStream);
    Probe := TServerStreamResponse.Create(AStream);
    if FOptions.RefusalMode = rmHttp503 then
      WriteRefusalRecord(FAccessLog, Req, Probe, 503)
    else
      WriteRefusalRecord(FAccessLog, Req, Probe, 0);
    Probe := nil;
    Req := nil;
  end;
  case FOptions.RefusalMode of
    rmRefuseStream:
      // Refuse, not Cancel: the peer learns of the refusal only from the
      // RST_STREAM that Refuse asks the connection to queue
      AStream.Refuse(ecRefusedStream);
    rmHttp503:
      AStream.QueueResponseHeaders(503, WithDate(nil, 503), True);
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

procedure THandlerPool.DetachNotify(const AStream: TServerStream;
  const ARefused: Boolean);
begin
  if ARefused then
    Notify(seStreamDetachRefused, AStream,
      'the limit of detached streams is reached')
  else
    Notify(seStreamDetached, AStream, 'the handler detached the stream');
end;

procedure THandlerPool.RunJob(const AEntry: TQueueEntry;
  const AResult: TDequeueResult);
var
  Job: IHandlerJob;
begin
  Job := AEntry.Job;
  if AResult = drTimedOut then
  begin
    FLock.Acquire;
    try
      Inc(FTimedOut);
    finally
      FLock.Release;
    end;
    Notify(seRequestTimedOut, nil, 'the queue wait limit passed');
    LogJobRefusal(Job);
    Job.Refuse(jrTimedOut);
    Exit;
  end;
  if Job.IsCancelled or (FHandler = nil) then
  begin
    FLock.Acquire;
    try
      Inc(FDropped);
    finally
      FLock.Release;
    end;
    Exit;
  end;
  FLock.Acquire;
  try
    Inc(FBusy);
    FActiveJobs.Add(Job);
  finally
    FLock.Release;
  end;
  try
    try
      Http2AssertHandlerThread('THandlerPool.RunJob');
      Job.Run(FHandler, FChannelRegistry);
    except
      on E: EStreamCancelled do
        ; // the cancellation ends the handler quietly
      on E: Exception do
        // the job answers its own peer; the pool only reports
        Notify(seHandlerException, nil, 'the handler raised');
    end;
  finally
    FLock.Acquire;
    try
      Dec(FBusy);
      FActiveJobs.Remove(Job);
    finally
      FLock.Release;
    end;
    Notify(seStreamCompleted, nil, 'the handler returned');
  end;
end;

function THandlerPool.AdmitJob(const AJob: IHandlerJob): TAdmitResult;
begin
  Result := FQueue.TryEnqueueJob(AJob);
  if Result = asRefused then
  begin
    FLock.Acquire;
    try
      Inc(FRefused);
    finally
      FLock.Release;
    end;
    Notify(seQueueFull, nil, 'the queue was full');
    LogJobRefusal(AJob);
    AJob.Refuse(jrQueueFull);
  end;
end;

function THandlerPool.TakeOne: Boolean;
var
  Entry: TQueueEntry;
  Stream: TServerStream;
  Outcome: TDequeueResult;
  Req: TServerStreamRequest;
  Res: TServerStreamResponse;
  ReqRef: IServerRequest;
  ResRef: IServerResponse;
begin
  Result := False;
  if not FQueue.DequeueEntry(Entry, Outcome) then
    Exit;
  Result := True;
  if Entry.Job <> nil then
  begin
    RunJob(Entry, Outcome);
    Exit;
  end;
  Stream := Entry.Stream;
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
    // this branch never reaches MarkBusy, so the queue reference drops here
    Stream.ReleaseRef;
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
    Stream.ReleaseRef;
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
    Stream.ReleaseRef;
    Exit;
  end;
  MarkBusy(Stream);
  Req := TServerStreamRequest.Create(Stream);
  Res := TServerStreamResponse.Create(Stream, FChannelRegistry);
  Res.OnDetach := DetachNotify;
  // the pair holds one reference each for the whole call: a handler that takes an
  // interface of its own (Supports, an assignment) would otherwise bring the count
  // to zero on release and destroy the object while this method still uses it
  ReqRef := Req;
  ResRef := Res;
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
        if Res.Detached then
          // the channel owns the stream: an error answer here would put a second
          // HEADERS block on the wire, or reset a stream the owner means to keep
          Notify(seHandlerException, Stream, 'the handler raised after Detach')
        else
          ReportError(Stream, not Res.HeadersSent);
    end;
  finally
    // the last reference destroys the pair
    ResRef := nil;
    ReqRef := nil;
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
  Entries: TArray<TQueueEntry>;
  Jobs: TArray<IHandlerJob>;
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
  Entries := FQueue.DrainEntries;
  for I := 0 to High(Entries) do
    if Entries[I].Job <> nil then
    begin
      LogJobRefusal(Entries[I].Job);
      Entries[I].Job.Refuse(jrStopped);
    end
    else
    begin
      AnswerRefusal(Entries[I].Stream);
      // each drained entry drops its queue reference
      Entries[I].Stream.ReleaseRef;
    end;

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
    FLock.Acquire;
    try
      Jobs := FActiveJobs.ToArray;
    finally
      FLock.Release;
    end;
    for I := 0 to High(Jobs) do
      Jobs[I].Cancel;
    Deadline := GetTickCount64 + QWord(FGracefulTimeoutMs);
    while (AliveThreadCount > 0) and (GetTickCount64 < Deadline) do
      Sleep(1);
  end;

  for I := 0 to FThreads.Count - 1 do
    FThreads[I].WaitFor;
end;

end.
