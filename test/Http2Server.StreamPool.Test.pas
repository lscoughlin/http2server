{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream pool, test, fairness, timers, fpcunit
notes:
  - This unit tests the streaming pool.
  - Most tests use a pool of size 0 and a manual clock, so the test thread runs
    each task by hand and the order is exact. No test sleeps to decide an order.
  - The thread tests wait with a bounded poll for a counter, never for a fixed
    time, and they fail with a message when the bound passes.
---
}
/// Unit tests for the streaming pool
unit Http2Server.StreamPool.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Generics.Collections, fpcunit, testregistry,
  Http2Server.Limits, Http2Server.Seam, Http2Server.Duplex, Http2Server.StreamPool;

type
  /// one named task that writes its name into a shared log
  TNamedTask = class
  public
    Name: string;
    Log: TStrings;
    /// a task that another task posts when this one runs
    Follow: TNamedTask;
    FollowSource: IStreamSource;
    constructor Create(const AName: string; const ALog: TStrings);
    procedure Run;
    procedure RunAndRaise;
  end;

  /// tests of TStreamPool with a pool of size 0 and a manual clock
  TStreamPoolOrderTest = class(TTestCase)
  private
    FClock: TManualMonotonicClock;
    FClockRef: IMonotonicClock;
    FPool: TStreamPool;
    FLog: TStringList;
    FTasks: TObjectList<TNamedTask>;
    FErrors: Integer;
    FSawStreamThread: Boolean;
    FStopRaised: Boolean;
    function T(const AName: string): TStreamTask;
    function Joined: string;
    procedure CountError(const AError: Exception);
    procedure RecordThreadMark;
    procedure TryStopFromTask;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestTasksOfOneSourceRunInOrder;
    procedure TestSourcesTakeTurns;
    procedure TestFollowUpPostQueuesBehind;
    procedure TestTimerWaitsForTheClock;
    procedure TestTimersFireInDeadlineOrder;
    procedure TestTimerQueuesBehindWaitingTasks;
    procedure TestCloseDropsTasksAndTimers;
    procedure TestStopRefusesPosts;
    procedure TestSourceSurvivesPoolDestroy;
    procedure TestTaskErrorDoesNotStopTheNextTask;
    procedure TestTaskRunsWithTheStreamThreadMark;
    procedure TestStopFromATaskRaises;
    procedure TestStatsCountTasksAndTimers;
  end;

  /// tests of TStreamPool with real threads
  TStreamPoolThreadTest = class(TTestCase)
  private
    FStarted: Integer;
    FInside: Integer;
    FMaxInside: Integer;
    FDone: Integer;
    FOrder: array of Integer;
    FNext: Integer;
    FOutOfOrder: Boolean;
    procedure Barrier;
    procedure Sequenced;
    procedure TimerHit;
    procedure WaitFor(var ACounter: Integer; const AWanted: Integer;
      const ATimeoutMs: Integer);
  published
    procedure TestSourcesRunInParallelOnSeveralThreads;
    procedure TestOneSourceNeverRunsTwoTasksAtOnce;
    procedure TestTimerFiresOnAPoolThread;
    procedure TestStopIsIdempotent;
  end;

implementation

{ TNamedTask }

constructor TNamedTask.Create(const AName: string; const ALog: TStrings);
begin
  inherited Create;
  Name := AName;
  Log := ALog;
end;

procedure TNamedTask.Run;
begin
  Log.Add(Name);
  if Follow <> nil then
    FollowSource.Post(Follow.Run);
end;

procedure TNamedTask.RunAndRaise;
begin
  Log.Add(Name);
  raise Exception.Create('task ' + Name + ' failed');
end;

{ TStreamPoolOrderTest }

procedure TStreamPoolOrderTest.SetUp;
begin
  FClock := TManualMonotonicClock.Create(1000);
  FClockRef := FClock;
  FPool := TStreamPool.Create(0, FClockRef);
  FLog := TStringList.Create;
  FTasks := TObjectList<TNamedTask>.Create(True);
  FErrors := 0;
  FSawStreamThread := False;
  FStopRaised := False;
end;

procedure TStreamPoolOrderTest.TearDown;
begin
  FPool.Free;
  FTasks.Free;
  FLog.Free;
  FClockRef := nil;
end;

function TStreamPoolOrderTest.T(const AName: string): TStreamTask;
var
  Task: TNamedTask;
begin
  Task := TNamedTask.Create(AName, FLog);
  FTasks.Add(Task);
  Result := Task.Run;
end;

function TStreamPoolOrderTest.Joined: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FLog.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + FLog[I];
  end;
end;

procedure TStreamPoolOrderTest.CountError(const AError: Exception);
begin
  Inc(FErrors);
end;

procedure TStreamPoolOrderTest.RecordThreadMark;
begin
  FSawStreamThread := Http2IsStreamThread;
  Http2AssertStreamThread('the test task');
end;

procedure TStreamPoolOrderTest.TryStopFromTask;
begin
  try
    FPool.Stop;
  except
    on EInvalidOperation do
      FStopRaised := True;
  end;
end;

procedure TStreamPoolOrderTest.TestTasksOfOneSourceRunInOrder;
var
  A: IStreamSource;
begin
  A := FPool.NewSource;
  AssertTrue(A.Post(T('a1')));
  AssertTrue(A.Post(T('a2')));
  AssertTrue(A.Post(T('a3')));
  AssertEquals(3, A.PendingTasks);
  while FPool.RunOne do
    ;
  AssertEquals('a1 a2 a3', Joined);
  AssertEquals(0, A.PendingTasks);
  AssertFalse('nothing is left', FPool.RunOne);
end;

procedure TStreamPoolOrderTest.TestSourcesTakeTurns;
var
  A, B: IStreamSource;
begin
  A := FPool.NewSource;
  B := FPool.NewSource;
  A.Post(T('a1'));
  A.Post(T('a2'));
  A.Post(T('a3'));
  B.Post(T('b1'));
  B.Post(T('b2'));
  while FPool.RunOne do
    ;
  // one task per turn: a long queue of one source does not starve the other
  AssertEquals('a1 b1 a2 b2 a3', Joined);
end;

procedure TStreamPoolOrderTest.TestFollowUpPostQueuesBehind;
var
  A, B: IStreamSource;
  First, Second: TNamedTask;
begin
  A := FPool.NewSource;
  B := FPool.NewSource;
  First := TNamedTask.Create('a1', FLog);
  Second := TNamedTask.Create('a2', FLog);
  FTasks.Add(First);
  FTasks.Add(Second);
  First.Follow := Second;
  First.FollowSource := A;
  A.Post(First.Run);
  B.Post(T('b1'));
  while FPool.RunOne do
    ;
  // a2 was posted by a1 while A ran: it waits behind b1, and it never overlaps a1
  AssertEquals('a1 b1 a2', Joined);
  First.FollowSource := nil;
end;

procedure TStreamPoolOrderTest.TestTimerWaitsForTheClock;
var
  A: IStreamSource;
begin
  A := FPool.NewSource;
  AssertTrue(A.PostAfter(100, T('late')));
  AssertFalse('before the deadline', FPool.RunOne);
  FClock.Advance(99);
  AssertFalse('one millisecond early', FPool.RunOne);
  FClock.Advance(1);
  AssertTrue('at the deadline', FPool.RunOne);
  AssertEquals('late', Joined);
end;

procedure TStreamPoolOrderTest.TestTimersFireInDeadlineOrder;
var
  A, B: IStreamSource;
begin
  A := FPool.NewSource;
  B := FPool.NewSource;
  A.PostAfter(50, T('x'));
  A.PostAfter(10, T('y'));
  B.PostAfter(10, T('z'));
  FClock.Advance(60);
  while FPool.RunOne do
    ;
  // y and z share a deadline and keep the order of posting; x is last
  AssertEquals('y z x', Joined);
end;

procedure TStreamPoolOrderTest.TestTimerQueuesBehindWaitingTasks;
var
  A: IStreamSource;
begin
  A := FPool.NewSource;
  A.PostAfter(10, T('timer'));
  A.Post(T('p1'));
  A.Post(T('p2'));
  FClock.Advance(10);
  while FPool.RunOne do
    ;
  AssertEquals('p1 p2 timer', Joined);
end;

procedure TStreamPoolOrderTest.TestCloseDropsTasksAndTimers;
var
  A: IStreamSource;
begin
  A := FPool.NewSource;
  A.Post(T('a1'));
  A.PostAfter(5, T('a2'));
  A.Close;
  AssertTrue(A.IsClosed);
  AssertFalse('a closed source refuses a post', A.Post(T('a3')));
  AssertFalse('a closed source refuses a timer', A.PostAfter(1, T('a4')));
  FClock.Advance(100);
  AssertFalse('nothing runs', FPool.RunOne);
  AssertEquals('', Joined);
  AssertEquals(0, A.PendingTasks);
end;

procedure TStreamPoolOrderTest.TestStopRefusesPosts;
var
  A: IStreamSource;
begin
  A := FPool.NewSource;
  A.Post(T('a1'));
  FPool.Stop;
  AssertTrue(FPool.IsStopped);
  AssertTrue(A.IsClosed);
  AssertFalse(A.Post(T('a2')));
  AssertFalse(FPool.RunOne);
  AssertEquals('', Joined);
  FPool.Stop;   // a second call does nothing
end;

procedure TStreamPoolOrderTest.TestSourceSurvivesPoolDestroy;
var
  Pool: TStreamPool;
  A: IStreamSource;
begin
  Pool := TStreamPool.Create(0, FClockRef);
  A := Pool.NewSource;
  Pool.Free;
  // the source keeps the shared state alive, so these calls are safe
  AssertTrue(A.IsClosed);
  AssertFalse(A.Post(T('late')));
  AssertEquals(0, A.PendingTasks);
end;

procedure TStreamPoolOrderTest.TestTaskErrorDoesNotStopTheNextTask;
var
  A: IStreamSource;
  Bad: TNamedTask;
begin
  FPool.OnTaskError := CountError;
  Bad := TNamedTask.Create('bad', FLog);
  FTasks.Add(Bad);
  A := FPool.NewSource;
  A.Post(Bad.RunAndRaise);
  A.Post(T('after'));
  while FPool.RunOne do
    ;
  AssertEquals('bad after', Joined);
  AssertEquals(1, FErrors);
  AssertEquals(1, Integer(FPool.Stats.TaskErrors));
end;

procedure TStreamPoolOrderTest.TestTaskRunsWithTheStreamThreadMark;
var
  A: IStreamSource;
begin
  AssertFalse('the test thread has no mark', Http2IsStreamThread);
  A := FPool.NewSource;
  A.Post(RecordThreadMark);
  FPool.OnTaskError := CountError;
  AssertTrue(FPool.RunOne);
  AssertTrue('the mark was set inside the task', FSawStreamThread);
  AssertEquals('Http2AssertStreamThread passed inside', 0, FErrors);
  AssertFalse('the mark is cleared after the task', Http2IsStreamThread);
  try
    Http2AssertStreamThread('outside');
    Fail('the check must raise outside a task');
  except
    on EHttpErrorLike: Exception do
      ;
  end;
end;

procedure TStreamPoolOrderTest.TestStopFromATaskRaises;
var
  A: IStreamSource;
begin
  A := FPool.NewSource;
  A.Post(TryStopFromTask);
  AssertTrue(FPool.RunOne);
  AssertTrue('a task cannot stop its own pool', FStopRaised);
  AssertFalse('the pool still runs', FPool.IsStopped);
end;

procedure TStreamPoolOrderTest.TestStatsCountTasksAndTimers;
var
  A: IStreamSource;
  S: TStreamPoolStats;
begin
  A := FPool.NewSource;
  A.Post(T('a1'));
  A.PostAfter(5, T('a2'));
  S := FPool.Stats;
  AssertEquals(1, S.ReadySources);
  AssertEquals(1, S.PendingTimers);
  FClock.Advance(5);
  while FPool.RunOne do
    ;
  S := FPool.Stats;
  AssertEquals(2, Integer(S.TasksRun));
  AssertEquals(1, Integer(S.TimersFired));
  AssertEquals(0, S.ReadySources);
  AssertEquals(0, S.PendingTimers);
end;

{ TStreamPoolThreadTest }

procedure TStreamPoolThreadTest.WaitFor(var ACounter: Integer;
  const AWanted, ATimeoutMs: Integer);
var
  Waited: Integer;
begin
  Waited := 0;
  while (ACounter < AWanted) and (Waited < ATimeoutMs) do
  begin
    Sleep(1);
    Inc(Waited);
  end;
end;

procedure TStreamPoolThreadTest.Barrier;
begin
  InterlockedIncrement(FStarted);
  // every task waits until all four have started, so the test passes only if
  // four tasks run at the same time
  WaitFor(FStarted, 4, 5000);
  InterlockedIncrement(FDone);
end;

procedure TStreamPoolThreadTest.Sequenced;
var
  Inside, Mine: Integer;
begin
  Inside := InterlockedIncrement(FInside);
  if Inside > FMaxInside then
    FMaxInside := Inside;
  Mine := InterlockedIncrement(FNext) - 1;
  // the tasks of one source run in the order of posting, never at once
  if Mine <> FDone then
    FOutOfOrder := True;
  InterlockedDecrement(FInside);
  InterlockedIncrement(FDone);
end;

procedure TStreamPoolThreadTest.TimerHit;
begin
  InterlockedIncrement(FDone);
end;

procedure TStreamPoolThreadTest.TestSourcesRunInParallelOnSeveralThreads;
var
  Pool: TStreamPool;
  S: array[0..3] of IStreamSource;
  I: Integer;
begin
  FStarted := 0;
  FDone := 0;
  Pool := TStreamPool.Create(4);
  try
    for I := 0 to 3 do
    begin
      S[I] := Pool.NewSource;
      S[I].Post(Barrier);
    end;
    WaitFor(FDone, 4, 8000);
    AssertEquals('four tasks ran at the same time', 4, FDone);
  finally
    Pool.Free;
  end;
end;

procedure TStreamPoolThreadTest.TestOneSourceNeverRunsTwoTasksAtOnce;
var
  Pool: TStreamPool;
  A: IStreamSource;
  I: Integer;
begin
  FInside := 0;
  FMaxInside := 0;
  FDone := 0;
  FNext := 0;
  FOutOfOrder := False;
  Pool := TStreamPool.Create(4);
  try
    A := Pool.NewSource;
    for I := 1 to 300 do
      A.Post(Sequenced);
    WaitFor(FDone, 300, 8000);
    AssertEquals('every task ran', 300, FDone);
    AssertEquals('never two tasks of one source at once', 1, FMaxInside);
    AssertFalse('tasks kept the order of posting', FOutOfOrder);
  finally
    Pool.Free;
  end;
end;

procedure TStreamPoolThreadTest.TestTimerFiresOnAPoolThread;
var
  Pool: TStreamPool;
  A: IStreamSource;
begin
  FDone := 0;
  Pool := TStreamPool.Create(1);
  try
    A := Pool.NewSource;
    A.PostAfter(30, TimerHit);
    WaitFor(FDone, 1, 5000);
    AssertEquals('the timer fired', 1, FDone);
  finally
    Pool.Free;
  end;
end;

procedure TStreamPoolThreadTest.TestStopIsIdempotent;
var
  Pool: TStreamPool;
begin
  Pool := TStreamPool.Create(3);
  try
    Pool.Stop;
    Pool.Stop;
    AssertTrue(Pool.IsStopped);
  finally
    Pool.Free;
  end;
end;

initialization
  RegisterTest(TStreamPoolOrderTest);
  RegisterTest(TStreamPoolThreadTest);

end.
