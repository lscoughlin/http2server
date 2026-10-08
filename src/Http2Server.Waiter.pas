{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, waiter, cancellation, rtl event
notes:
  - This unit holds the blocking implementation of IStreamWaiter.
  - The wait uses an RTLEvent, because a TEvent fails on macOS.
  - The unit also holds the cancel-worker pool that runs the cancel hooks.
  - A handler that blocks inside a database call without a cancel hook runs
    on to completion.  The hook is the only way to interrupt such a handler.
---
}
/// The blocking stream waiter and the cancel-worker pool
// - TBlockingWaiter is the concrete IStreamWaiter of the first release.  It
//   pairs an RTLEvent with a cancel flag.
// - an RTLEvent wakes one waiter at a time and consumes the signal in the
//   first wait that observes it.  TBlockingWaiter keeps its own pending flag
//   under its lock, so a Signal that arrives with no waiter parked stays
//   pending for the next Wait.
// - RTLEventSetEvent and RTLEventResetEvent are procedures on this RTL and
//   return no value.  The unit never assigns their result.
// - TCancelWorkerPool runs the cancel hooks on its own threads.  A hook never
//   runs on the thread that called Cancel and it runs at most once.
unit Http2Server.Waiter;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Seam;

type
  TCancelWorkerPool = class;

  /// The blocking IStreamWaiter.
  ///
  /// The IO side creates the waiter and calls Signal and Cancel.  A handler
  /// thread blocks on Wait.  Cancel sets the flag before it wakes the waiter,
  /// so a Wait that returns for any reason already sees the new flag.
  TBlockingWaiter = class(TInterfacedObject, IStreamWaiter)
  private
    FLock: TCriticalSection;
    FEvent: PRTLEvent;
    FPending: Boolean;
    FCancelled: Boolean;
    FHook: TCancelHook;
    FPool: TCancelWorkerPool;    // weak reference; the owner frees the pool
    FWaitCount: Integer;
    FSignalCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    /// register the pool that runs the cancel hooks
    // - the pool must outlive the waiter; the waiter holds no reference
    procedure AttachCancelPool(const APool: TCancelWorkerPool);
    /// register the cancel hook of this stream
    procedure RegisterHook(const AHook: TCancelHook);

    // IStreamWaiter
    function Wait(const ATimeoutMs: Integer): TWaitResult;
    procedure Signal;
    procedure Cancel;
    function IsCancelled: Boolean;

    /// completed Wait calls (test seam)
    property WaitCount: Integer read FWaitCount;
    /// Signal calls (test seam)
    property SignalCount: Integer read FSignalCount;
  end;

  /// One cancel-worker thread of the pool.
  ///
  /// The thread takes hooks from the shared queue and runs them.  A hook that
  /// blocks delays the hooks behind it in the same queue.
  TCancelWorker = class(TThread)
  private
    FPool: TCancelWorkerPool;    // weak reference
  protected
    procedure Execute; override;
  public
    constructor Create(const APool: TCancelWorkerPool);
  end;

  /// The pool that runs cancel hooks.
  ///
  /// A hook runs on one of the pool threads, never on the thread that called
  /// Cancel.  The queue is unbounded because a hook is small and a
  /// cancellation is rare; the pool size bounds how many hooks run at once.
  TCancelWorkerPool = class
  private
    FLock: TCriticalSection;
    FWake: PRTLEvent;
    FHooks: TQueue<TCancelHook>;
    FWorkers: TObjectList<TCancelWorker>;
    FStopped: Boolean;
    FRunning: Integer;
    FMaxRunning: Integer;
    FCompleted: Integer;
  public
    /// create AThreadCount cancel workers; a count below one creates one
    constructor Create(const AThreadCount: Integer);
    destructor Destroy; override;

    /// queue one hook; the call returns at once and never runs the hook
    procedure QueueHook(const AHook: TCancelHook);
    /// take one hook from the queue; blocks while the queue is empty and
    /// answers False once the pool has stopped
    function TakeHook(out AHook: TCancelHook): Boolean;
    /// record the end of one hook
    procedure HookFinished;
    /// end the pool and wake every worker
    procedure Stop;

    /// hooks that have finished (test seam)
    function CompletedCount: Integer;
    /// the largest number of hooks that ran at one time (test seam)
    function MaxRunningCount: Integer;
    /// the number of workers (test seam)
    function WorkerCount: Integer;
  end;

implementation

{ TBlockingWaiter }

constructor TBlockingWaiter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEvent := RTLEventCreate;
end;

destructor TBlockingWaiter.Destroy;
begin
  RTLEventDestroy(FEvent);
  FLock.Free;
  inherited Destroy;
end;

procedure TBlockingWaiter.AttachCancelPool(const APool: TCancelWorkerPool);
begin
  FLock.Acquire;
  try
    FPool := APool;
  finally
    FLock.Release;
  end;
end;

procedure TBlockingWaiter.RegisterHook(const AHook: TCancelHook);
begin
  FLock.Acquire;
  try
    FHook := AHook;
  finally
    FLock.Release;
  end;
end;

function TBlockingWaiter.Wait(const ATimeoutMs: Integer): TWaitResult;
var
  Hook: TCancelHook;
  Pool: TCancelWorkerPool;
begin
  Hook := nil;
  Pool := nil;
  FLock.Acquire;
  try
    if FCancelled then
    begin
      Inc(FWaitCount);
      Exit(wrCancelled);
    end;
    if FPending then
    begin
      FPending := False;
      Inc(FWaitCount);
      Exit(wrSignalled);
    end;
  finally
    FLock.Release;
  end;

  RTLEventWaitFor(FEvent, ATimeoutMs);

  FLock.Acquire;
  try
    Inc(FWaitCount);
    if FCancelled then
    begin
      // the cancel path owns the hook; a wait never runs it here
      FPending := False;
      Hook := FHook;
      Pool := FPool;
      Result := wrCancelled;
    end
    else if FPending then
    begin
      FPending := False;
      Result := wrSignalled;
    end
    else
      Result := wrTimeout;
  finally
    FLock.Release;
  end;
  // a cancellation that found no pool can only be reported, never hooked
  if (Pool = nil) and Assigned(Hook) then
    Hook := nil;
end;

procedure TBlockingWaiter.Signal;
begin
  FLock.Acquire;
  try
    FPending := True;
    Inc(FSignalCount);
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FEvent);
end;

procedure TBlockingWaiter.Cancel;
var
  Hook: TCancelHook;
  Pool: TCancelWorkerPool;
begin
  Hook := nil;
  Pool := nil;
  FLock.Acquire;
  try
    if FCancelled then
      Exit;
    FCancelled := True;
    FPending := True;
    Hook := FHook;
    Pool := FPool;
  finally
    FLock.Release;
  end;
  // the flag is set, then the waiter wakes, then the hook is queued
  RTLEventSetEvent(FEvent);
  if Assigned(Hook) and (Pool <> nil) then
    Pool.QueueHook(Hook);
end;

function TBlockingWaiter.IsCancelled: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCancelled;
  finally
    FLock.Release;
  end;
end;

{ TCancelWorker }

constructor TCancelWorker.Create(const APool: TCancelWorkerPool);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TCancelWorker.Execute;
var
  Hook: TCancelHook;
begin
  while FPool.TakeHook(Hook) do
  begin
    try
      if Assigned(Hook) then
        Hook();
    except
      // a hook that raises must not stop the worker; the pool stays usable
    end;
    FPool.HookFinished;
  end;
end;

{ TCancelWorkerPool }

constructor TCancelWorkerPool.Create(const AThreadCount: Integer);
var
  I, N: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := RTLEventCreate;
  FHooks := TQueue<TCancelHook>.Create;
  FWorkers := TObjectList<TCancelWorker>.Create(True);
  N := AThreadCount;
  if N < 1 then
    N := 1;
  for I := 1 to N do
    FWorkers.Add(TCancelWorker.Create(Self));
end;

destructor TCancelWorkerPool.Destroy;
begin
  Stop;
  FWorkers.Free;
  FHooks.Free;
  RTLEventDestroy(FWake);
  FLock.Free;
  inherited Destroy;
end;

function TCancelWorkerPool.WorkerCount: Integer;
begin
  Result := FWorkers.Count;
end;

function TCancelWorkerPool.CompletedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FCompleted;
  finally
    FLock.Release;
  end;
end;

function TCancelWorkerPool.MaxRunningCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FMaxRunning;
  finally
    FLock.Release;
  end;
end;

procedure TCancelWorkerPool.QueueHook(const AHook: TCancelHook);
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FHooks.Enqueue(AHook);
  finally
    FLock.Release;
  end;
  // one wake releases one worker.  The worker that consumed the hook wakes
  // the next worker in HookFinished, so a chain of queued hooks all run.
  RTLEventSetEvent(FWake);
end;

function TCancelWorkerPool.TakeHook(out AHook: TCancelHook): Boolean;
begin
  AHook := nil;
  while True do
  begin
    FLock.Acquire;
    try
      if FHooks.Count > 0 then
      begin
        AHook := FHooks.Dequeue;
        Inc(FRunning);
        if FRunning > FMaxRunning then
          FMaxRunning := FRunning;
        Exit(True);
      end;
      if FStopped then
        Exit(False);
    finally
      FLock.Release;
    end;
    RTLEventWaitFor(FWake, 20);
  end;
end;

procedure TCancelWorkerPool.HookFinished;
var
  More: Boolean;
begin
  FLock.Acquire;
  try
    Dec(FRunning);
    Inc(FCompleted);
    More := FHooks.Count > 0;
  finally
    FLock.Release;
  end;
  if More then
    RTLEventSetEvent(FWake);
end;

procedure TCancelWorkerPool.Stop;
begin
  FLock.Acquire;
  try
    FStopped := True;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FWake);
end;

end.
