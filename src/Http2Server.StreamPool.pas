{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream pool, work source, timers, fairness, streaming
notes:
  - This unit holds the streaming pool. A small number of threads runs all
    the application work for detached streams, so the handler pool and its
    admission queue are never used for streaming work.
  - A work source is one ordered task queue, for example one WebSocket session
    or one event stream. A source waits once in the ready queue when it has
    tasks. A pool thread takes a source, runs one task and puts the source back
    at the end of the queue when more tasks wait.
  - One thread works on a source at a time, the tasks of a source keep their
    order, and sources take turns.
  - A timer is a task that becomes ready at a deadline. The deadlines are in a
    min-heap, and a waiting thread parks until the next deadline.
  - The clock is injected, so a test advances time by hand and uses no sleep.
---
}
/// The streaming pool: ordered task queues on a small set of threads
// - lock order: the pool lock is the innermost lock. A caller can post while it
//   holds the connection lock. A pool thread runs a task with no pool lock held.
// - a task that raises never ends a pool thread. The error goes to OnTaskError.
unit Http2Server.StreamPool;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Limits, Http2Server.Seam, Http2Server.Duplex;

type
  /// the report of a task that ended with an exception
  // - the event runs on the pool thread that ran the task
  TStreamTaskErrorEvent = procedure(const AError: Exception) of object;

  /// a snapshot of the counters of a pool
  TStreamPoolStats = record
    /// tasks that ran to the end or raised
    TasksRun: Int64;
    /// timers that became tasks
    TimersFired: Int64;
    /// tasks that raised
    TaskErrors: Int64;
    /// sources that wait for a thread
    ReadySources: Integer;
    /// timers that wait for their deadline, closed sources included
    PendingTimers: Integer;
    /// threads of the pool
    Threads: Integer;
  end;

  TStreamPoolCore = class;

  /// the streaming pool
  TStreamPool = class
  private
    FCore: TStreamPoolCore;
    /// owns the core; the sources hold their own reference too
    FCoreRef: IInterface;
    FThreads: TList;
    FSize: Integer;
    function GetStopped: Boolean;
    function GetOnTaskError: TStreamTaskErrorEvent;
    procedure SetOnTaskError(const AValue: TStreamTaskErrorEvent);
  public
    /// create the pool and start ASize threads
    // - ASize 0 starts no thread: a test then runs tasks with RunOne
    // - a nil clock selects the process clock
    constructor Create(const ASize: Integer; const AClock: IMonotonicClock = nil);
    /// stop the pool and wait for the running tasks
    destructor Destroy; override;
    /// make a new work source
    function NewSource: IStreamSource;
    /// fire the due timers and run at most one ready task on the calling thread
    // - answers False when no task was ready
    // - the pool threads use the same step; a test with ASize 0 calls it
    function RunOne: Boolean;
    /// stop the pool
    // - posts are refused from now on, waiting tasks and timers are dropped, a
    //   running task finishes, and the call waits for the threads
    // - a second call does nothing
    // - a task must not call Stop: the call would wait for itself, so it raises
    procedure Stop;
    function Stats: TStreamPoolStats;
    property Size: Integer read FSize;
    property IsStopped: Boolean read GetStopped;
    property OnTaskError: TStreamTaskErrorEvent
      read GetOnTaskError write SetOnTaskError;
  end;

  /// the shared state of one pool: the lock, the queues and the counters
  // - the sources hold it by an interface reference, so a source stays safe to
  //   call after the pool object is gone
  TStreamPoolCore = class(TInterfacedObject)
  private
    type
      TTimerEntry = record
        Due: QWord;
        Seq: QWord;
        Source: IInterface;
        Task: TStreamTask;
      end;
  private
    FLock: TCriticalSection;
    FWake: PRTLEvent;
    FClock: IMonotonicClock;
    FReady: TQueue<IInterface>;
    FHeap: array of TTimerEntry;
    FHeapCount: Integer;
    FSeq: QWord;
    FStopped: Boolean;
    FOnError: TStreamTaskErrorEvent;
    FTasksRun, FTimersFired, FTaskErrors: Int64;
    FThreadCount: Integer;
    function HeapLess(const A, B: TTimerEntry): Boolean;
    procedure HeapPush(const AEntry: TTimerEntry);
    procedure HeapPop(out AEntry: TTimerEntry);
    procedure FireDueTimersLocked;
    procedure Signal;
    procedure ReportError(const AError: Exception);
  public
    constructor Create(const AClock: IMonotonicClock);
    destructor Destroy; override;
    function PostTask(const ASource: IInterface; const ATask: TStreamTask): Boolean;
    function PostTimer(const ASource: IInterface; const ADelayMs: Cardinal;
      const ATask: TStreamTask): Boolean;
    procedure CloseSource(const ASource: IInterface);
    function SourceClosed(const ASource: IInterface): Boolean;
    function SourcePending(const ASource: IInterface): Integer;
    /// take the next task, if one is ready; AWaitMs is the park for a thread
    function NextTask(out ASource: IInterface; out ATask: TStreamTask;
      out AWaitMs: Integer): Boolean;
    procedure FinishTask(const ASource: IInterface);
    /// run one ready task on the calling thread
    function RunReady: Boolean;
    /// run a task with the pool-thread mark set, then release its source
    procedure ExecuteTask(const ASource: IInterface; const ATask: TStreamTask);
    /// the loop of one pool thread: it returns once the pool has stopped
    function RunStep: Boolean;
    function IsStopped: Boolean;
    procedure SetStopped;
    procedure WakeAll(const ACount: Integer);
    function Snapshot: TStreamPoolStats;
    procedure SetThreadCount(const ACount: Integer);
    property OnError: TStreamTaskErrorEvent read FOnError write FOnError;
    property Stopped: Boolean read IsStopped;
  end;

implementation

const
  /// the longest park of an idle thread, in milliseconds
  // - every post signals the event, so the park is a safety bound only
  cMaxParkMs = 250;

type
  /// the interface that the pool uses to reach the object behind a source
  IStreamSourceInternal = interface(IStreamSource)
    ['{7E1F0C11-0042-4A11-9C72-000000000702}']
    function Inner: TObject;
  end;

  /// one ordered task queue
  TStreamSource = class(TInterfacedObject, IStreamSource, IStreamSourceInternal)
  private
    FCore: TStreamPoolCore;
    /// keeps the core alive while a source exists
    FCoreRef: IInterface;
  public
    FTasks: TQueue<TStreamTask>;
    /// true while the source waits in the ready queue or runs a task
    FQueued: Boolean;
    FClosed: Boolean;
    constructor Create(const ACore: TStreamPoolCore);
    destructor Destroy; override;
    function Post(const ATask: TStreamTask): Boolean;
    function PostAfter(const ADelayMs: Cardinal;
      const ATask: TStreamTask): Boolean;
    procedure Close;
    function IsClosed: Boolean;
    function PendingTasks: Integer;
    function Inner: TObject;
  end;

  /// one thread of the pool
  TStreamPoolThread = class(TThread)
  private
    FCore: TStreamPoolCore;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACore: TStreamPoolCore);
  end;

function SourceOf(const ASource: IInterface): TStreamSource;
var
  Internal: IStreamSourceInternal;
begin
  if (ASource <> nil) and
     (ASource.QueryInterface(IStreamSourceInternal, Internal) = 0) then
    Result := TStreamSource(Internal.Inner)
  else
    Result := nil;
end;

{ TStreamSource }

constructor TStreamSource.Create(const ACore: TStreamPoolCore);
begin
  inherited Create;
  FCore := ACore;
  FCoreRef := ACore;
  FTasks := TQueue<TStreamTask>.Create;
end;

destructor TStreamSource.Destroy;
begin
  FTasks.Free;
  inherited Destroy;
end;

function TStreamSource.Inner: TObject;
begin
  Result := Self;
end;

function TStreamSource.Post(const ATask: TStreamTask): Boolean;
begin
  Result := FCore.PostTask(Self as IStreamSource, ATask);
end;

function TStreamSource.PostAfter(const ADelayMs: Cardinal;
  const ATask: TStreamTask): Boolean;
begin
  Result := FCore.PostTimer(Self as IStreamSource, ADelayMs, ATask);
end;

procedure TStreamSource.Close;
begin
  FCore.CloseSource(Self as IStreamSource);
end;

function TStreamSource.IsClosed: Boolean;
begin
  Result := FCore.SourceClosed(Self as IStreamSource);
end;

function TStreamSource.PendingTasks: Integer;
begin
  Result := FCore.SourcePending(Self as IStreamSource);
end;

{ TStreamPoolThread }

constructor TStreamPoolThread.Create(const ACore: TStreamPoolCore);
begin
  FCore := ACore;
  inherited Create(False);
end;

procedure TStreamPoolThread.Execute;
begin
  while FCore.RunStep do
    ;
end;

{ TStreamPoolCore }

constructor TStreamPoolCore.Create(const AClock: IMonotonicClock);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := RTLEventCreate;
  if AClock = nil then
    FClock := TMonotonicClock.Create
  else
    FClock := AClock;
  FReady := TQueue<IInterface>.Create;
end;

destructor TStreamPoolCore.Destroy;
begin
  FReady.Free;
  FHeap := nil;
  RTLEventDestroy(FWake);
  FLock.Free;
  inherited Destroy;
end;

procedure TStreamPoolCore.Signal;
begin
  RTLEventSetEvent(FWake);
end;

procedure TStreamPoolCore.WakeAll(const ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do
    RTLEventSetEvent(FWake);
end;

function TStreamPoolCore.HeapLess(const A, B: TTimerEntry): Boolean;
begin
  Result := (A.Due < B.Due) or ((A.Due = B.Due) and (A.Seq < B.Seq));
end;

procedure TStreamPoolCore.HeapPush(const AEntry: TTimerEntry);
var
  I, P: Integer;
  Tmp: TTimerEntry;
begin
  if FHeapCount = Length(FHeap) then
    SetLength(FHeap, (FHeapCount * 2) + 8);
  FHeap[FHeapCount] := AEntry;
  I := FHeapCount;
  Inc(FHeapCount);
  while I > 0 do
  begin
    P := (I - 1) div 2;
    if not HeapLess(FHeap[I], FHeap[P]) then
      Break;
    Tmp := FHeap[I];
    FHeap[I] := FHeap[P];
    FHeap[P] := Tmp;
    I := P;
  end;
end;

procedure TStreamPoolCore.HeapPop(out AEntry: TTimerEntry);
var
  I, L, R, M: Integer;
  Tmp: TTimerEntry;
begin
  AEntry := FHeap[0];
  Dec(FHeapCount);
  FHeap[0] := FHeap[FHeapCount];
  // release the references of the vacated slot
  FHeap[FHeapCount].Source := nil;
  FHeap[FHeapCount].Task := nil;
  I := 0;
  while True do
  begin
    L := (2 * I) + 1;
    R := L + 1;
    M := I;
    if (L < FHeapCount) and HeapLess(FHeap[L], FHeap[M]) then
      M := L;
    if (R < FHeapCount) and HeapLess(FHeap[R], FHeap[M]) then
      M := R;
    if M = I then
      Break;
    Tmp := FHeap[I];
    FHeap[I] := FHeap[M];
    FHeap[M] := Tmp;
    I := M;
  end;
end;

procedure TStreamPoolCore.FireDueTimersLocked;
var
  Now: QWord;
  Entry: TTimerEntry;
  S: TStreamSource;
begin
  if FHeapCount = 0 then
    Exit;
  Now := FClock.NowMs;
  while (FHeapCount > 0) and (FHeap[0].Due <= Now) do
  begin
    HeapPop(Entry);
    S := SourceOf(Entry.Source);
    if (S = nil) or S.FClosed or FStopped then
      Continue;
    Inc(FTimersFired);
    S.FTasks.Enqueue(Entry.Task);
    if not S.FQueued then
    begin
      S.FQueued := True;
      FReady.Enqueue(Entry.Source);
    end;
  end;
end;

function TStreamPoolCore.PostTask(const ASource: IInterface;
  const ATask: TStreamTask): Boolean;
var
  S: TStreamSource;
  Wake: Boolean;
begin
  Result := False;
  Wake := False;
  S := SourceOf(ASource);
  FLock.Acquire;
  try
    if FStopped or (S = nil) or S.FClosed then
      Exit;
    S.FTasks.Enqueue(ATask);
    if not S.FQueued then
    begin
      S.FQueued := True;
      FReady.Enqueue(ASource);
      Wake := True;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
  // the event is set outside the lock, so a woken thread meets a free lock
  if Wake then
    Signal;
end;

function TStreamPoolCore.PostTimer(const ASource: IInterface;
  const ADelayMs: Cardinal; const ATask: TStreamTask): Boolean;
var
  S: TStreamSource;
  Entry: TTimerEntry;
begin
  Result := False;
  S := SourceOf(ASource);
  FLock.Acquire;
  try
    if FStopped or (S = nil) or S.FClosed then
      Exit;
    Entry.Due := FClock.NowMs + ADelayMs;
    Inc(FSeq);
    Entry.Seq := FSeq;
    Entry.Source := ASource;
    Entry.Task := ATask;
    HeapPush(Entry);
    Result := True;
  finally
    FLock.Release;
  end;
  // a parked thread computed its park from the old first deadline
  if Result then
    Signal;
end;

procedure TStreamPoolCore.CloseSource(const ASource: IInterface);
var
  S: TStreamSource;
begin
  S := SourceOf(ASource);
  if S = nil then
    Exit;
  FLock.Acquire;
  try
    S.FClosed := True;
    S.FTasks.Clear;
  finally
    FLock.Release;
  end;
end;

function TStreamPoolCore.SourceClosed(const ASource: IInterface): Boolean;
var
  S: TStreamSource;
begin
  S := SourceOf(ASource);
  FLock.Acquire;
  try
    Result := FStopped or (S = nil) or S.FClosed;
  finally
    FLock.Release;
  end;
end;

function TStreamPoolCore.SourcePending(const ASource: IInterface): Integer;
var
  S: TStreamSource;
begin
  S := SourceOf(ASource);
  FLock.Acquire;
  try
    if S = nil then
      Result := 0
    else
      Result := S.FTasks.Count;
  finally
    FLock.Release;
  end;
end;

function TStreamPoolCore.NextTask(out ASource: IInterface;
  out ATask: TStreamTask; out AWaitMs: Integer): Boolean;
var
  S: TStreamSource;
  Gap: QWord;
  Now: QWord;
begin
  Result := False;
  ASource := nil;
  ATask := nil;
  AWaitMs := cMaxParkMs;
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FireDueTimersLocked;
    while FReady.Count > 0 do
    begin
      ASource := FReady.Dequeue;
      S := SourceOf(ASource);
      if (S = nil) or S.FClosed or (S.FTasks.Count = 0) then
      begin
        if S <> nil then
          S.FQueued := False;
        ASource := nil;
        Continue;
      end;
      ATask := S.FTasks.Dequeue;
      Result := True;
      Exit;
    end;
    // nothing is ready: park until the first deadline, at most cMaxParkMs
    if FHeapCount > 0 then
    begin
      Now := FClock.NowMs;
      if FHeap[0].Due > Now then
      begin
        Gap := FHeap[0].Due - Now;
        if Gap < cMaxParkMs then
          AWaitMs := Integer(Gap);
      end
      else
        AWaitMs := 1;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TStreamPoolCore.FinishTask(const ASource: IInterface);
var
  S: TStreamSource;
  Wake: Boolean;
begin
  Wake := False;
  S := SourceOf(ASource);
  FLock.Acquire;
  try
    if S = nil then
      Exit;
    if S.FClosed or FStopped or (S.FTasks.Count = 0) then
      S.FQueued := False
    else
    begin
      // one task per turn: the source goes to the end of the ready queue
      FReady.Enqueue(ASource);
      Wake := True;
    end;
  finally
    FLock.Release;
  end;
  if Wake then
    Signal;
end;

procedure TStreamPoolCore.ReportError(const AError: Exception);
var
  Handler: TStreamTaskErrorEvent;
begin
  FLock.Acquire;
  try
    Inc(FTaskErrors);
    Handler := FOnError;
  finally
    FLock.Release;
  end;
  if Assigned(Handler) then
    try
      Handler(AError);
    except
      // a failing error handler must not end a pool thread
    end;
end;

procedure TStreamPoolCore.ExecuteTask(const ASource: IInterface;
  const ATask: TStreamTask);
begin
  Http2StreamThreadEnter;
  try
    try
      ATask();
    except
      on E: Exception do
        ReportError(E);
    end;
  finally
    Http2StreamThreadLeave;
  end;
  FLock.Acquire;
  try
    Inc(FTasksRun);
  finally
    FLock.Release;
  end;
  FinishTask(ASource);
end;

function TStreamPoolCore.RunReady: Boolean;
var
  Source: IInterface;
  Task: TStreamTask;
  WaitMs: Integer;
begin
  Result := NextTask(Source, Task, WaitMs);
  if Result then
    ExecuteTask(Source, Task);
end;

function TStreamPoolCore.RunStep: Boolean;
var
  Source: IInterface;
  Task: TStreamTask;
  WaitMs: Integer;
begin
  while not IsStopped do
  begin
    if NextTask(Source, Task, WaitMs) then
    begin
      ExecuteTask(Source, Task);
      Source := nil;
    end
    else if not IsStopped then
      RTLEventWaitFor(FWake, WaitMs);
  end;
  Result := False;
end;

function TStreamPoolCore.IsStopped: Boolean;
begin
  FLock.Acquire;
  try
    Result := FStopped;
  finally
    FLock.Release;
  end;
end;

procedure TStreamPoolCore.SetStopped;
var
  Dropped: TTimerEntry;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FStopped := True;
    // drop everything that waits; a running task finishes
    while FReady.Count > 0 do
      FReady.Dequeue;
    while FHeapCount > 0 do
      HeapPop(Dropped);
  finally
    FLock.Release;
  end;
end;

function TStreamPoolCore.Snapshot: TStreamPoolStats;
begin
  FLock.Acquire;
  try
    Result.TasksRun := FTasksRun;
    Result.TimersFired := FTimersFired;
    Result.TaskErrors := FTaskErrors;
    Result.ReadySources := FReady.Count;
    Result.PendingTimers := FHeapCount;
    Result.Threads := FThreadCount;
  finally
    FLock.Release;
  end;
end;

procedure TStreamPoolCore.SetThreadCount(const ACount: Integer);
begin
  FLock.Acquire;
  try
    FThreadCount := ACount;
  finally
    FLock.Release;
  end;
end;

{ TStreamPool }

constructor TStreamPool.Create(const ASize: Integer;
  const AClock: IMonotonicClock);
var
  I: Integer;
begin
  inherited Create;
  if ASize < 0 then
    raise EArgumentOutOfRangeException.Create('the streaming pool size is below 0');
  FSize := ASize;
  FCore := TStreamPoolCore.Create(AClock);
  FCoreRef := FCore;   // the interface reference owns the core
  FThreads := TList.Create;
  FCore.SetThreadCount(ASize);
  for I := 1 to ASize do
    FThreads.Add(TStreamPoolThread.Create(FCore));
end;

destructor TStreamPool.Destroy;
begin
  Stop;
  FThreads.Free;
  FCore := nil;
  FCoreRef := nil;
  inherited Destroy;
end;

function TStreamPool.NewSource: IStreamSource;
begin
  Result := TStreamSource.Create(FCore);
end;

function TStreamPool.RunOne: Boolean;
begin
  Result := FCore.RunReady;
end;

procedure TStreamPool.Stop;
var
  I: Integer;
  T: TStreamPoolThread;
begin
  if Http2IsStreamThread then
    raise EInvalidOperation.Create(
      'a streaming-pool task cannot stop its own pool');
  FCore.SetStopped;
  FCore.WakeAll(FThreads.Count + 1);
  for I := FThreads.Count - 1 downto 0 do
  begin
    T := TStreamPoolThread(FThreads[I]);
    // wake again: a thread may have been between its check and its park
    FCore.WakeAll(1);
    T.WaitFor;
    T.Free;
    FThreads.Delete(I);
  end;
end;

function TStreamPool.Stats: TStreamPoolStats;
begin
  Result := FCore.Snapshot;
end;

function TStreamPool.GetStopped: Boolean;
begin
  Result := FCore.Stopped;
end;

function TStreamPool.GetOnTaskError: TStreamTaskErrorEvent;
begin
  Result := FCore.OnError;
end;

procedure TStreamPool.SetOnTaskError(const AValue: TStreamTaskErrorEvent);
begin
  FCore.OnError := AValue;
end;

end.
