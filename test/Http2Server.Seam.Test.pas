{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, seam, waiter, cancellation, test, fpcunit
notes:
  - This unit tests the seam interfaces, the blocking waiter and the
    cancel-worker pool.
  - The tests drive the waiters from real threads, because the contract is
    about which thread observes an event.
---
}
/// Unit tests for the seam interfaces, TBlockingWaiter and TCancelWorkerPool
// - run with `make test`.
// - no test depends on wall-clock time beyond a generous deadline that a
//   working implementation meets in a few milliseconds.
// - the interface-shape test is the compilation of TShapeProbe below: the
//   class lists the four members of IStreamWaiter and no more, so an added
//   member would leave it abstract and stop the build.
unit Http2Server.Seam.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Seam, Http2Server.Waiter;

type
  /// a class that lists exactly the four members of IStreamWaiter
  // - this is the acceptance check that the interface stayed narrow
  TShapeProbe = class(TInterfacedObject, IStreamWaiter)
  public
    function Wait(const ATimeoutMs: Integer): TWaitResult;
    procedure Signal;
    procedure Cancel;
    function IsCancelled: Boolean;
  end;

  /// the shape probe records nothing; the four members are stubs
  TSeamShapeTest = class(TTestCase)
  published
    procedure TestWaiterHasFourMembers;
    procedure TestWaitResultOrdinals;
  end;

  /// a writer thread that parks in Wait and records the outcome
  TWaitProbe = class(TThread)
  private
    FWaiter: IStreamWaiter;
    FTimeoutMs: Integer;
    FResult: TWaitResult;
    FDone: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AWaiter: IStreamWaiter; const ATimeoutMs: Integer);
    /// poll until the probe thread has finished its Wait, or the deadline
    /// passes; the RTL wait procedure returns no value, so the flag is the
    /// only portable signal
    function AwaitDone(const ATimeoutMs: Integer): Boolean;
    property WaitResult: TWaitResult read FResult;
  end;

  /// tests of TBlockingWaiter
  TBlockingWaiterTest = class(TTestCase)
  private
    FPool: TCancelWorkerPool;
    FHookRuns: Integer;
    FHookThread: TThreadID;
  public
    procedure SetUp; override;
    procedure TearDown; override;
    procedure CountHook;
  published
    procedure TestTimeoutReturnsTimeout;
    procedure TestSignalWakesParkedWait;
    procedure TestSignalBeforeWaitStaysPending;
    procedure TestCancelBeforeWaitReturnsCancelled;
    procedure TestCancelWakesParkedWait;
    procedure TestLateWaitAfterCancelIsCancelled;
    procedure TestCancelHookRunsOnceOnWorkerThread;
    procedure TestCancelWithoutHookIsSafe;
  end;

  /// tests of TCancelWorkerPool
  TCancelWorkerPoolTest = class(TTestCase)
  private
    FPool: TCancelWorkerPool;
    FHookRuns: Integer;
    FLastThread: TThreadID;
    FLock: TCriticalSection;
  public
    procedure SetUp; override;
    procedure TearDown; override;
    procedure CountHook;
  published
    procedure TestQueuedHookRunsOnAWorkerThread;
    procedure TestManyHooksAllRun;
    procedure TestPoolSizeIsHonoured;
  end;

implementation

{ TShapeProbe }

function TShapeProbe.Wait(const ATimeoutMs: Integer): TWaitResult;
begin
  Result := wrTimeout;
end;

procedure TShapeProbe.Signal;
begin
end;

procedure TShapeProbe.Cancel;
begin
end;

function TShapeProbe.IsCancelled: Boolean;
begin
  Result := False;
end;

{ TSeamShapeTest }

procedure TSeamShapeTest.TestWaiterHasFourMembers;
var
  W: IStreamWaiter;
  R: TWaitResult;
begin
  // the assignment compiles only while TShapeProbe implements every member of
  // IStreamWaiter; an added member makes TShapeProbe abstract and fails here
  W := TShapeProbe.Create;
  R := W.Wait(0);
  AssertEquals('the stub answers a timeout', Ord(wrTimeout), Ord(R));
  W.Signal;
  W.Cancel;
  AssertTrue('the stub reports no cancellation', not W.IsCancelled);
end;

procedure TSeamShapeTest.TestWaitResultOrdinals;
begin
  AssertEquals('wrSignalled is first', 0, Ord(wrSignalled));
  AssertEquals('wrTimeout is second', 1, Ord(wrTimeout));
  AssertEquals('wrCancelled is third', 2, Ord(wrCancelled));
end;

{ TWaitProbe }

constructor TWaitProbe.Create(const AWaiter: IStreamWaiter;
  const ATimeoutMs: Integer);
begin
  FWaiter := AWaiter;
  FTimeoutMs := ATimeoutMs;
  FResult := wrSignalled;
  FDone := False;
  inherited Create(False);
end;

procedure TWaitProbe.Execute;
begin
  FResult := FWaiter.Wait(FTimeoutMs);
  FDone := True;
end;

function TWaitProbe.AwaitDone(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (not Finished) and (GetTickCount64 < Deadline) do
    Sleep(2);
  Result := Finished;
end;

{ TBlockingWaiterTest }

procedure TBlockingWaiterTest.SetUp;
begin
  inherited SetUp;
  FPool := TCancelWorkerPool.Create(2);
  FHookRuns := 0;
  FHookThread := TThreadID(0);
end;

procedure TBlockingWaiterTest.TearDown;
begin
  FPool.Free;
  inherited TearDown;
end;

procedure TBlockingWaiterTest.CountHook;
begin
  Inc(FHookRuns);
  FHookThread := GetCurrentThreadId;
end;

procedure TBlockingWaiterTest.TestTimeoutReturnsTimeout;
var
  W: TBlockingWaiter;
begin
  W := TBlockingWaiter.Create;
  try
    AssertEquals('the wait times out', Ord(wrTimeout), Ord(W.Wait(40)));
    AssertEquals('no signal was recorded', 0, W.SignalCount);
  finally
    W.Free;
  end;
end;

procedure TBlockingWaiterTest.TestSignalWakesParkedWait;
var
  W: TBlockingWaiter;
  I: IStreamWaiter;
  Probe: TWaitProbe;
begin
  W := TBlockingWaiter.Create;
  I := W;
  Probe := TWaitProbe.Create(I, 5000);
  try
    Sleep(30);
    W.Signal;
    AssertTrue('the parked wait woke', Probe.AwaitDone(2000));
    AssertEquals('the wait reports a signal', Ord(wrSignalled),
      Ord(Probe.WaitResult));
    AssertEquals('one wait ran', 1, W.WaitCount);
  finally
    Probe.WaitFor;
    Probe.Free;
  end;
end;

procedure TBlockingWaiterTest.TestSignalBeforeWaitStaysPending;
var
  W: TBlockingWaiter;
begin
  W := TBlockingWaiter.Create;
  try
    // a signal with no parked waiter is not lost
    W.Signal;
    AssertEquals('the next wait sees the pending signal', Ord(wrSignalled),
      Ord(W.Wait(50)));
    AssertEquals('a later wait times out', Ord(wrTimeout), Ord(W.Wait(40)));
  finally
    W.Free;
  end;
end;

procedure TBlockingWaiterTest.TestCancelBeforeWaitReturnsCancelled;
var
  W: TBlockingWaiter;
begin
  W := TBlockingWaiter.Create;
  try
    W.Cancel;
    AssertTrue('the waiter reports the cancellation', W.IsCancelled);
    AssertEquals('the wait reports the cancellation', Ord(wrCancelled),
      Ord(W.Wait(50)));
  finally
    W.Free;
  end;
end;

procedure TBlockingWaiterTest.TestCancelWakesParkedWait;
var
  W: TBlockingWaiter;
  I: IStreamWaiter;
  Probe: TWaitProbe;
begin
  W := TBlockingWaiter.Create;
  I := W;
  Probe := TWaitProbe.Create(I, 5000);
  try
    Sleep(30);
    W.Cancel;
    AssertTrue('the parked wait woke', Probe.AwaitDone(2000));
    AssertEquals('the wait reports the cancellation', Ord(wrCancelled),
      Ord(Probe.WaitResult));
  finally
    Probe.WaitFor;
    Probe.Free;
  end;
end;

procedure TBlockingWaiterTest.TestLateWaitAfterCancelIsCancelled;
var
  W: TBlockingWaiter;
  I: IStreamWaiter;
  Probe: TWaitProbe;
begin
  W := TBlockingWaiter.Create;
  I := W;
  Probe := TWaitProbe.Create(I, 5000);
  try
    Sleep(30);
    W.Cancel;
    AssertTrue('the first wait woke', Probe.AwaitDone(2000));
  finally
    Probe.WaitFor;
    Probe.Free;
  end;
  AssertEquals('every later wait is cancelled too', Ord(wrCancelled),
    Ord(W.Wait(30)));
end;

procedure TBlockingWaiterTest.TestCancelHookRunsOnceOnWorkerThread;
var
  W: TBlockingWaiter;
  CallerThread: TThreadID;
  Waited: Integer;
begin
  W := TBlockingWaiter.Create;
  try
    W.AttachCancelPool(FPool);
    W.RegisterHook(CountHook);
    CallerThread := GetCurrentThreadId;
    W.Cancel;
    Waited := 0;
    while (FPool.CompletedCount = 0) and (Waited < 2000) do
    begin
      Sleep(5);
      Inc(Waited, 5);
    end;
    AssertEquals('the hook ran once', 1, FHookRuns);
    AssertEquals('the pool recorded one finished hook', 1,
      FPool.CompletedCount);
    AssertTrue('the hook did not run on the caller thread',
      FHookThread <> CallerThread);
    // a second Cancel must not run the hook again
    W.Cancel;
    Sleep(30);
    AssertEquals('the hook still ran once', 1, FHookRuns);
  finally
    W.Free;
  end;
end;

procedure TBlockingWaiterTest.TestCancelWithoutHookIsSafe;
var
  W: TBlockingWaiter;
begin
  W := TBlockingWaiter.Create;
  try
    W.AttachCancelPool(FPool);
    W.Cancel;
    AssertTrue('the waiter reports the cancellation', W.IsCancelled);
    AssertEquals('no hook ran', 0, FHookRuns);
  finally
    W.Free;
  end;
end;

{ TCancelWorkerPoolTest }

procedure TCancelWorkerPoolTest.SetUp;
begin
  inherited SetUp;
  FLock := TCriticalSection.Create;
  FHookRuns := 0;
  FLastThread := TThreadID(0);
end;

procedure TCancelWorkerPoolTest.TearDown;
begin
  if FPool <> nil then
  begin
    FPool.Free;
    FPool := nil;
  end;
  FLock.Free;
  inherited TearDown;
end;

procedure TCancelWorkerPoolTest.CountHook;
begin
  FLock.Acquire;
  try
    Inc(FHookRuns);
    FLastThread := GetCurrentThreadId;
  finally
    FLock.Release;
  end;
end;

procedure TCancelWorkerPoolTest.TestQueuedHookRunsOnAWorkerThread;
var
  CallerThread: TThreadID;
  Waited: Integer;
begin
  FPool := TCancelWorkerPool.Create(1);
  CallerThread := GetCurrentThreadId;
  FPool.QueueHook(CountHook);
  Waited := 0;
  while (FPool.CompletedCount = 0) and (Waited < 2000) do
  begin
    Sleep(5);
    Inc(Waited, 5);
  end;
  AssertEquals('the hook ran', 1, FHookRuns);
  AssertTrue('the hook ran on a worker thread', FLastThread <> CallerThread);
  AssertEquals('one worker exists', 1, FPool.WorkerCount);
end;

procedure TCancelWorkerPoolTest.TestManyHooksAllRun;
var
  I, Waited: Integer;
begin
  FPool := TCancelWorkerPool.Create(3);
  for I := 1 to 50 do
    FPool.QueueHook(CountHook);
  Waited := 0;
  while (FPool.CompletedCount < 50) and (Waited < 4000) do
  begin
    Sleep(5);
    Inc(Waited, 5);
  end;
  AssertEquals('every queued hook ran', 50, FHookRuns);
  AssertEquals('the pool counted every hook', 50, FPool.CompletedCount);
  AssertTrue('the pool never ran more hooks than its size',
    FPool.MaxRunningCount <= 3);
end;

procedure TCancelWorkerPoolTest.TestPoolSizeIsHonoured;
begin
  FPool := TCancelWorkerPool.Create(4);
  AssertEquals('four workers were created', 4, FPool.WorkerCount);
  FPool.Free;
  FPool := TCancelWorkerPool.Create(0);
  AssertEquals('a zero size still creates one worker', 1, FPool.WorkerCount);
end;

initialization
  RegisterTest(TSeamShapeTest);
  RegisterTest(TBlockingWaiterTest);
  RegisterTest(TCancelWorkerPoolTest);

end.
