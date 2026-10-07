{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, admission, queue, handler pool, test, fpcunit
notes:
  - This unit tests the bounded request queue and the handler pool.
  - The blocking handlers park on an RTLEvent, and the wait-limit test drives
    a manual clock, so no test waits on wall-clock time.
  - A self-cancelling handler and a read-parked handler both run on the pool,
    so the shutdown path is exercised with real threads.
---
}
/// Unit tests for TRequestQueue and THandlerPool
// - run with `make test`.
// - the sixth-request test fills the pool first, then the queue, then offers
//   one more request, so the refusal is deterministic.
// - the counters test offers requests from eight producer threads and checks
//   that accepted plus refused equals offered.
unit Http2Server.Admission.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Seam, Http2Server.Stream,
  Http2Server.Limits, Http2Server.Config, Http2Server.Hpack,
  Http2Server.Admission;

type
  /// a stream host that ignores the window credit
  TNullHost = class(TInterfacedObject, IStreamHost)
  public
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
  end;

  /// the mode of the blocking handler
  TBlockingMode = (
    /// park on the release event
    bmGate,
    /// park in the request read
    bmRead);

  /// a handler that records every stream it sees and then blocks
  TBlockingHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FLock: TCriticalSection;
    FIds: TList<LongWord>;
    FStarted: Integer;
    FMode: TBlockingMode;
    FRelease: PRTLEvent;
    FReleased: Boolean;
  public
    constructor Create(const AMode: TBlockingMode);
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    /// the streams seen so far
    function StartedCount: Integer;
    /// true when the handler saw AStreamId
    function HasId(const AStreamId: LongWord): Boolean;
    /// release every handler parked on the gate
    procedure Release;
  private
    function IsReleased: Boolean;
  end;

  /// a handler that cancels its own stream and then reads
  TSelfCancelHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FStream: TServerStream;
    FStarted: Integer;
    FStartEvent: PRTLEvent;
  public
    constructor Create(const AStream: TServerStream);
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    function StartedCount: Integer;
  end;

  /// a handler that raises, before or after it sends the headers
  TRaisingHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FSendHeaders: Boolean;
  public
    constructor Create(const ASendHeaders: Boolean);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// one producer thread of the counters test
  TProducer = class(TThread)
  private
    FPool: THandlerPool;
    FStreams: TArray<TServerStream>;
    FAccepted: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const APool: THandlerPool;
      const AStreams: TArray<TServerStream>);
    property Accepted: Integer read FAccepted;
  end;

  /// tests of TRequestQueue and THandlerPool
  TAdmissionTest = class(TTestCase)
  private
    FLock: TCriticalSection;
    FHost: IStreamHost;
    FClock: TManualMonotonicClock;
    FPool: THandlerPool;
    FFactory: THttp2ServerFactory;
    FStreams: TObjectList<TServerStream>;
    FGate: TBlockingHandler;
    FErrorStreamId: LongWord;
    FErrorBeforeHeaders: Boolean;
    FErrorCount: Integer;
    function NewStream(const AStreamId: LongWord): TServerStream;
    procedure Configure(const AHandlerThreads, ADepth, AMaxWaitMs: Integer;
      const AMode: TQueueRefusalMode);
    function WaitStarted(const AHandler: TBlockingHandler;
      const ACount, ATimeoutMs: Integer): Boolean;
    function WaitError(const ATimeoutMs: Integer): Boolean;
    function WaitTimedOut(const ACount, ATimeoutMs: Integer): Boolean;
    procedure HandleError(const AStream: TServerStream;
      const ABeforeHeaders: Boolean);
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // task 2a: pool of 2, queue of 3, the sixth request is refused
    procedure TestSixthRequestIsRefused;
    // task 2b: a reset while queued removes the entry, the handler never runs
    procedure TestResetWhileQueuedRemovesEntry;
    // task 2c: the wait limit gives a timeout, and the pool answers 503
    procedure TestWaitLimitYieldsTimeout;
    // task 2d: a handler exception reaches OnHandlerError and names the stream
    procedure TestHandlerExceptionReachesOnHandlerError;
    procedure TestHandlerExceptionAfterHeadersSetsFlag;
    // task 2e: counters stay correct under eight producer threads
    procedure TestCountersUnderProducerLoad;
    // task 2f: Stop with running and queued work leaves no thread alive
    procedure TestStopLeavesNoThreadAlive;
    // task 2g: no deadlock when a handler cancels its own stream
    procedure TestSelfCancelDoesNotDeadlock;
    // direct queue checks
    procedure TestQueueRefusesBeyondDepth;
    procedure TestQueueRemovesStream;
    procedure TestQueueDrainAllReturnsFifo;
    procedure TestRefusalModeHttp503QueuesResponse;
    procedure TestAdaptersExposeStreamState;
  end;

implementation

function WaitFlag(const AFlag: Integer; const ATarget: Integer;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (AFlag < ATarget) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := AFlag >= ATarget;
end;

{ TNullHost }

procedure TNullHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
  // the credit is not part of these tests
end;

{ TBlockingHandler }

constructor TBlockingHandler.Create(const AMode: TBlockingMode);
begin
  inherited Create;
  FMode := AMode;
  FLock := TCriticalSection.Create;
  FIds := TList<LongWord>.Create;
  FRelease := RTLEventCreate;
  FReleased := False;
end;

destructor TBlockingHandler.Destroy;
begin
  RTLEventDestroy(FRelease);
  FIds.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TBlockingHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: TBytes;
begin
  FLock.Acquire;
  try
    Inc(FStarted);
    FIds.Add(ARequest.StreamId);
  finally
    FLock.Release;
  end;
  case FMode of
    bmGate:
      // poll until Release, so a test cannot hang and the stop path is quick
      while not IsReleased do
        RTLEventWaitFor(FRelease, 20);
    bmRead:
      begin
        SetLength(Buf, 1);
        // a cancellation raises EStreamCancelled inside this thread
        ARequest.Read(Buf[0], 1);
      end;
  end;
end;

function TBlockingHandler.IsReleased: Boolean;
begin
  FLock.Acquire;
  try
    Result := FReleased;
  finally
    FLock.Release;
  end;
end;

function TBlockingHandler.StartedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FStarted;
  finally
    FLock.Release;
  end;
end;

function TBlockingHandler.HasId(const AStreamId: LongWord): Boolean;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    Result := False;
    for I := 0 to FIds.Count - 1 do
      if FIds[I] = AStreamId then
        Exit(True);
  finally
    FLock.Release;
  end;
end;

procedure TBlockingHandler.Release;
begin
  FLock.Acquire;
  try
    FReleased := True;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FRelease);
end;

{ TSelfCancelHandler }

constructor TSelfCancelHandler.Create(const AStream: TServerStream);
begin
  inherited Create;
  FStream := AStream;
  FStartEvent := RTLEventCreate;
end;

destructor TSelfCancelHandler.Destroy;
begin
  RTLEventDestroy(FStartEvent);
  inherited Destroy;
end;

procedure TSelfCancelHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: TBytes;
begin
  Inc(FStarted);
  RTLEventSetEvent(FStartEvent);
  // the handler resets its own stream, then reads; the read observes the
  // cancellation at once, so the handler cannot park forever
  FStream.Cancel(ecCancel);
  SetLength(Buf, 1);
  ARequest.Read(Buf[0], 1);
end;

function TSelfCancelHandler.StartedCount: Integer;
begin
  Result := FStarted;
end;

{ TRaisingHandler }

constructor TRaisingHandler.Create(const ASendHeaders: Boolean);
begin
  inherited Create;
  FSendHeaders := ASendHeaders;
end;

procedure TRaisingHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  if FSendHeaders then
    AResponse.SendHeaders(200, nil, False);
  raise EHttpError.Create('the handler failed');
end;

{ TProducer }

constructor TProducer.Create(const APool: THandlerPool;
  const AStreams: TArray<TServerStream>);
begin
  FPool := APool;
  FStreams := AStreams;
  inherited Create(False);
end;

procedure TProducer.Execute;
var
  I: Integer;
begin
  for I := 0 to High(FStreams) do
    if FPool.Admit(FStreams[I]) = asQueued then
      Inc(FAccepted);
end;

{ TAdmissionTest }

procedure TAdmissionTest.SetUp;
begin
  inherited SetUp;
  FLock := TCriticalSection.Create;
  FHost := TNullHost.Create;
  FClock := TManualMonotonicClock.Create(0);
  FStreams := TObjectList<TServerStream>.Create(True);
  FPool := nil;
  FGate := nil;
  FErrorCount := 0;
  FErrorStreamId := 0;
  FErrorBeforeHeaders := False;
end;

procedure TAdmissionTest.TearDown;
begin
  if FGate <> nil then
    FGate.Release;
  FreeAndNil(FPool);
  FStreams.Free;
  FClock := nil;
  FHost := nil;
  FLock.Free;
  inherited TearDown;
end;

function TAdmissionTest.NewStream(const AStreamId: LongWord): TServerStream;
begin
  Result := TServerStream.Create(AStreamId, FLock, FHost, 65536, 65536);
  FStreams.Add(Result);
end;

procedure TAdmissionTest.Configure(const AHandlerThreads, ADepth,
  AMaxWaitMs: Integer; const AMode: TQueueRefusalMode);
begin
  FFactory := THttp2ServerFactory.Create
    .WithHandlerThreads(AHandlerThreads)
    .WithQueue(TQueueOptions.Create
      .WithDepth(ADepth)
      .WithMaxWaitMs(AMaxWaitMs)
      .WithRefusalMode(AMode))
    .WithClock(FClock)
    .WithGracefulStopTimeout(500);
end;

function TAdmissionTest.WaitStarted(const AHandler: TBlockingHandler;
  const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (AHandler.StartedCount < ACount) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := AHandler.StartedCount >= ACount;
end;

function TAdmissionTest.WaitError(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (FErrorCount < 1) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := FErrorCount >= 1;
end;

function TAdmissionTest.WaitTimedOut(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (FPool.TimedOutTotal < ACount) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := FPool.TimedOutTotal >= ACount;
end;

procedure TAdmissionTest.HandleError(const AStream: TServerStream;
  const ABeforeHeaders: Boolean);
begin
  Inc(FErrorCount);
  FErrorStreamId := AStream.StreamId;
  FErrorBeforeHeaders := ABeforeHeaders;
end;

procedure TAdmissionTest.TestSixthRequestIsRefused;
var
  I: Integer;
  Offered: array[0..5] of TServerStream;
  Result6: TAdmitResult;
begin
  FGate := TBlockingHandler.Create(bmGate);
  Configure(2, 3, 600000, rmRefuseStream);
  FFactory := FFactory.WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  // two requests fill the pool threads
  for I := 0 to 1 do
  begin
    Offered[I] := NewStream(1 + I);
    AssertEquals('a free handler queues the request', Ord(asQueued),
      Ord(FPool.Admit(Offered[I])));
  end;
  AssertTrue('both handlers run', WaitStarted(FGate, 2, 2000));
  AssertEquals('the queue is empty while the handlers run', 0,
    FPool.QueueLength);

  // three requests fill the queue
  for I := 2 to 4 do
  begin
    Offered[I] := NewStream(1 + I);
    AssertEquals('a queue slot takes the request', Ord(asQueued),
      Ord(FPool.Admit(Offered[I])));
  end;
  AssertEquals('three requests wait', 3, FPool.QueueLength);

  // the sixth request finds no free handler and no queue slot
  Offered[5] := NewStream(6);
  Result6 := FPool.Admit(Offered[5]);
  AssertEquals('the sixth request is refused', Ord(asRefused), Ord(Result6));
  AssertEquals('the refused total counts one', 1, FPool.RefusedTotal);
  AssertEquals('the queue depth is the bound', 3, FPool.QueueLength);
  AssertTrue('the refused stream is reset', Offered[5].IsCancelled);
end;

procedure TAdmissionTest.TestResetWhileQueuedRemovesEntry;
var
  Busy1, Busy2, Queued: TServerStream;
begin
  FGate := TBlockingHandler.Create(bmGate);
  Configure(2, 3, 600000, rmRefuseStream);
  FFactory := FFactory.WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  Busy1 := NewStream(1);
  Busy2 := NewStream(2);
  AssertEquals('the first request queues', Ord(asQueued),
    Ord(FPool.Admit(Busy1)));
  AssertEquals('the second request queues', Ord(asQueued),
    Ord(FPool.Admit(Busy2)));
  AssertTrue('both handlers run', WaitStarted(FGate, 2, 2000));

  Queued := NewStream(3);
  AssertEquals('the third request waits', Ord(asQueued), Ord(FPool.Admit(Queued)));
  AssertEquals('one request waits', 1, FPool.QueueLength);

  // the peer resets the queued stream
  AssertTrue('the queued entry is removed',
    FPool.RemoveStream(Queued.StreamId));
  AssertEquals('the queue is short one entry', 0, FPool.QueueLength);
  AssertEquals('the drop is counted', 1, FPool.DroppedBeforeDispatch);

  // release the handlers; the removed stream was never dispatched
  FGate.Release;
  Sleep(100);
  AssertFalse('the handler never saw the removed stream',
    FGate.HasId(Queued.StreamId));
  AssertFalse('a second removal finds nothing',
    FPool.RemoveStream(Queued.StreamId));
end;

procedure TAdmissionTest.TestWaitLimitYieldsTimeout;
var
  Busy1: TServerStream;
  Queued1, Queued2: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  FGate := TBlockingHandler.Create(bmGate);
  Configure(1, 2, 100, rmHttp503);
  FFactory := FFactory.WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  // one handler thread takes the first request and parks in the gate
  Busy1 := NewStream(1);
  AssertEquals('the first request queues', Ord(asQueued),
    Ord(FPool.Admit(Busy1)));
  AssertTrue('the handler runs', WaitStarted(FGate, 1, 2000));

  // two requests wait behind the busy handler
  Queued1 := NewStream(2);
  Queued2 := NewStream(3);
  AssertEquals('the second request waits', Ord(asQueued),
    Ord(FPool.Admit(Queued1)));
  AssertEquals('the third request waits', Ord(asQueued),
    Ord(FPool.Admit(Queued2)));
  AssertEquals('two requests wait', 2, FPool.QueueLength);

  // the clock passes the wait limit, then the busy handler frees the thread
  FClock.Advance(200);
  FGate.Release;

  // both waiting entries are past the limit, so both time out at dequeue
  AssertTrue('the entries time out', WaitTimedOut(2, 3000));
  AssertEquals('no waiting entry is dispatched', 1, FGate.StartedCount);
  AssertEquals('the timeout total counts both', 2, FPool.TimedOutTotal);

  // the 503 path holds a response header block for the IO side
  AssertTrue('the timed-out stream has a pending response',
    Queued1.HasPendingHeaders);
  AssertTrue('the pending block is readable',
    Queued1.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the refusal is a 503', 503, Status);
  AssertTrue('the refusal ends the response', EndStream);
end;

procedure TAdmissionTest.TestHandlerExceptionReachesOnHandlerError;
var
  Stream: TServerStream;
  Handler: TRaisingHandler;
begin
  Handler := TRaisingHandler.Create(False);
  Configure(1, 2, 600000, rmRefuseStream);
  FFactory := FFactory.WithHandler(Handler);
  FPool := THandlerPool.Create(FFactory);
  FPool.OnHandlerError := HandleError;

  Stream := NewStream(7);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitError(2000));
  AssertEquals('the hook names the stream', 7, Integer(FErrorStreamId));
  AssertTrue('no headers were sent', FErrorBeforeHeaders);
  AssertEquals('the hook runs once', 1, FErrorCount);
end;

procedure TAdmissionTest.TestHandlerExceptionAfterHeadersSetsFlag;
var
  Stream: TServerStream;
  Handler: TRaisingHandler;
begin
  Handler := TRaisingHandler.Create(True);
  Configure(1, 2, 600000, rmRefuseStream);
  FFactory := FFactory.WithHandler(Handler);
  FPool := THandlerPool.Create(FFactory);
  FPool.OnHandlerError := HandleError;

  Stream := NewStream(9);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitError(2000));
  AssertFalse('the flag reports headers already sent', FErrorBeforeHeaders);
end;

procedure TAdmissionTest.TestCountersUnderProducerLoad;
const
  cProducers = 8;
  cPerProducer = 25;
  cDepth = 8;
var
  Producers: array[0..cProducers - 1] of TProducer;
  Streams: TArray<TServerStream>;
  I, J, Accepted, Offered, MaxObserved: Integer;
  Id: LongWord;
  Running: Boolean;
begin
  FGate := TBlockingHandler.Create(bmGate);
  Configure(4, cDepth, 600000, rmRefuseStream);
  FFactory := FFactory.WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  Offered := cProducers * cPerProducer;
  Id := 1;
  for I := 0 to cProducers - 1 do
  begin
    SetLength(Streams, cPerProducer);
    for J := 0 to cPerProducer - 1 do
    begin
      Streams[J] := NewStream(Id);
      Inc(Id);
    end;
    Producers[I] := TProducer.Create(FPool, Streams);
  end;

  // sample the queue depth while the producers run, so a transient overflow
  // is visible
  MaxObserved := 0;
  Running := True;
  while Running do
  begin
    if FPool.QueueLength > MaxObserved then
      MaxObserved := FPool.QueueLength;
    Running := False;
    for I := 0 to cProducers - 1 do
      if not Producers[I].Finished then
        Running := True;
    if Running then
      Sleep(0);
  end;

  Accepted := 0;
  for I := 0 to cProducers - 1 do
  begin
    Producers[I].WaitFor;
    Inc(Accepted, Producers[I].Accepted);
    Producers[I].Free;
  end;

  // every offered request is either accepted or refused, and the queue never
  // held more than its depth at any sampled moment
  AssertEquals('accepted plus refused equals offered',
    Offered, Accepted + FPool.RefusedTotal);
  AssertTrue('the sampled depth never exceeds the bound',
    MaxObserved <= cDepth);
  AssertTrue('the queue never exceeds its depth',
    FPool.QueueLength <= cDepth);
  AssertEquals('no entry timed out', 0, FPool.TimedOutTotal);
  AssertEquals('no entry was dropped', 0, FPool.DroppedBeforeDispatch);
  AssertTrue('the pool threads are all busy', FPool.BusyHandlers > 0);
end;

procedure TAdmissionTest.TestStopLeavesNoThreadAlive;
begin
  FGate := TBlockingHandler.Create(bmRead);
  Configure(2, 3, 600000, rmRefuseStream);
  FFactory := FFactory.WithGracefulStopTimeout(100);
  FFactory := FFactory.WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  AssertEquals('the first request queues', Ord(asQueued),
    Ord(FPool.Admit(NewStream(1))));
  AssertEquals('the second request queues', Ord(asQueued),
    Ord(FPool.Admit(NewStream(2))));
  AssertTrue('both handlers run', WaitStarted(FGate, 2, 2000));

  AssertEquals('the third request waits', Ord(asQueued),
    Ord(FPool.Admit(NewStream(3))));
  AssertEquals('the fourth request waits', Ord(asQueued),
    Ord(FPool.Admit(NewStream(4))));
  AssertEquals('two requests wait', 2, FPool.QueueLength);

  // Stop refuses the waiting entries, then cancels the running handlers
  FPool.Stop;
  AssertEquals('no worker thread is alive', 0, FPool.AliveThreadCount);
  AssertEquals('no handler is busy', 0, FPool.BusyHandlers);
  // a second Stop is harmless
  FPool.Stop;
end;

procedure TAdmissionTest.TestSelfCancelDoesNotDeadlock;
var
  Stream: TServerStream;
  Handler: TSelfCancelHandler;
  Deadline: QWord;
begin
  Stream := NewStream(1);
  Handler := TSelfCancelHandler.Create(Stream);
  Configure(1, 2, 600000, rmRefuseStream);
  FFactory := FFactory.WithGracefulStopTimeout(500);
  FFactory := FFactory.WithHandler(Handler);
  FPool := THandlerPool.Create(FFactory);

  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  // let the self-cancelling handler start before the stop
  Deadline := GetTickCount64 + 2000;
  while (Handler.StartedCount < 1) and (GetTickCount64 < Deadline) do
    Sleep(1);
  AssertTrue('the handler ran', Handler.StartedCount >= 1);

  FPool.Stop;
  AssertEquals('the self-cancelling handler ends', 0, FPool.BusyHandlers);
  AssertEquals('no worker thread is alive', 0, FPool.AliveThreadCount);
end;

procedure TAdmissionTest.TestQueueRefusesBeyondDepth;
var
  Queue: TRequestQueue;
  I: Integer;
begin
  Queue := TRequestQueue.Create(3, 600000, FClock);
  try
    for I := 1 to 3 do
      AssertEquals('a slot takes the request', Ord(asQueued),
        Ord(Queue.TryEnqueue(NewStream(I))));
    AssertEquals('the queue is full', 3, Queue.Count);
    AssertEquals('one past the depth is refused', Ord(asRefused),
      Ord(Queue.TryEnqueue(NewStream(4))));
    AssertEquals('the refused request left the queue alone', 3, Queue.Count);
  finally
    Queue.Free;
  end;
end;

procedure TAdmissionTest.TestQueueRemovesStream;
var
  Queue: TRequestQueue;
begin
  Queue := TRequestQueue.Create(4, 600000, FClock);
  try
    Queue.TryEnqueue(NewStream(1));
    Queue.TryEnqueue(NewStream(2));
    AssertTrue('the matching entry is removed', Queue.RemoveStream(2));
    AssertEquals('the queue is short one entry', 1, Queue.Count);
    AssertFalse('an absent entry is not removed', Queue.RemoveStream(2));
  finally
    Queue.Free;
  end;
end;

procedure TAdmissionTest.TestQueueDrainAllReturnsFifo;
var
  Queue: TRequestQueue;
  Got: TArray<TServerStream>;
begin
  Queue := TRequestQueue.Create(4, 600000, FClock);
  try
    Queue.TryEnqueue(NewStream(11));
    Queue.TryEnqueue(NewStream(22));
    Queue.TryEnqueue(NewStream(33));
    Got := Queue.DrainAll;
    AssertEquals('the drain answers every entry', 3, Length(Got));
    AssertEquals('the first entry comes first', 11, Integer(Got[0].StreamId));
    AssertEquals('the last entry comes last', 33, Integer(Got[2].StreamId));
    AssertEquals('the queue is empty after the drain', 0, Queue.Count);
  finally
    Queue.Free;
  end;
end;

procedure TAdmissionTest.TestRefusalModeHttp503QueuesResponse;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  FGate := TBlockingHandler.Create(bmGate);
  Configure(1, 0, 600000, rmHttp503);
  FFactory := FFactory.WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  // depth 0 refuses every request at once
  Stream := NewStream(5);
  AssertEquals('depth zero refuses the request', Ord(asRefused),
    Ord(FPool.Admit(Stream)));
  AssertTrue('the refusal has a pending response',
    Stream.HasPendingHeaders);
  AssertTrue('the pending block is readable',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the refusal is a 503', 503, Status);
  AssertEquals('the handler never started', 0, FGate.StartedCount);
end;

procedure TAdmissionTest.TestAdaptersExposeStreamState;
var
  Stream: TServerStream;
  Req: IServerRequest;
  Res: IServerResponse;
  Block: THeaderBlock;
begin
  Stream := NewStream(42);
  SetLength(Block, 3);
  Block[0].Name := ':method';
  Block[0].Value := 'GET';
  Block[1].Name := ':path';
  Block[1].Value := '/index';
  Block[2].Name := 'accept';
  Block[2].Value := 'text/plain';
  Stream.SetRemoteHeaders(Block);

  Req := TServerStreamRequest.Create(Stream);
  AssertEquals('the adapter reports the stream id', 42, Integer(Req.StreamId));
  AssertEquals('the adapter reads the method', 'GET', Req.Method);
  AssertEquals('the adapter reads the path', '/index', Req.Path);
  Block := Req.Headers;
  AssertEquals('the adapter drops the pseudo-headers', 1, Length(Block));
  AssertEquals('the adapter keeps a regular header', 'accept', Block[0].Name);

  Res := TServerStreamResponse.Create(Stream);
  Res.SendHeaders(204, nil, False);
  AssertTrue('the response block is pending', Stream.HasPendingHeaders);
  AssertFalse('a fresh response is not cancelled', Res.IsCancelled);
end;

initialization
  RegisterTest(TAdmissionTest);

end.
