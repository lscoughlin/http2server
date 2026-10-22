{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, streaming pool, fairness, ordering, parallelism, stop, test, fpcunit
notes:
  - This unit tests the sessions on the streaming pool. Many sessions share a pool of
    one thread, the tasks of one session keep wire order, sessions take turns, a pool
    of four threads runs four sessions at once and never two tasks of one session at
    once, and Stop delivers Closed to every session.
  - The channels are fake, so the tests need no socket and measure the pool and the
    session queue only.
---
}
/// Pool tests of the WebSocket sessions
unit Http2Server.Ws.Pool.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.Limits, Http2Server.Sse.Test, Http2Server.Ws.Options,
  Http2Server.Ws.Types, Http2Server.Ws.Frames, Http2Server.Ws.Session,
  Http2Server.Ws.TestKit;

type
  /// a handler that counts and measures; one handler serves one session
  TCountingHandler = class(TInterfacedObject, IWsHandler)
  private
    FLock: TCriticalSection;
    FInside: Integer;
  public
    Order: TStringList;
    MaxInside: Integer;
    Messages: Integer;
    ClosedCalls: Integer;
    SleepMs: Integer;
    GlobalLog: TStringList;
    GlobalLock: TCriticalSection;
    Tag: string;
    /// when set, the first Message call waits on it
    Gate: PRTLEvent;
    constructor Create;
    destructor Destroy; override;
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
    function Count: Integer;
    function ClosedCount: Integer;
  end;

  TWsPoolTest = class(TTestCase)
  private
    FRig: TWsRig;
    FHandlers: TList<TCountingHandler>;
    FRefs: TList<IWsHandler>;
    FChannels: TList<TFakeWsChannel>;
    FChannelRefs: TList<IDuplexChannel>;
    FSessions: TList<IWsSession>;
    FRequests: TList<IServerRequest>;
    procedure Open(const AOptions: TWsOptions; const APoolSize, ACount: Integer;
      const ASleepMs: Integer = 0);
    function WaitAll(const AMessages: Integer; const ATimeoutMs: Integer): Boolean;
    function AllActivated: Boolean;
    function AllDelivered: Boolean;
    function AllADelivered: Boolean;
    function Quick: TWsOptions;
  protected
    procedure TearDown; override;
  published
    procedure TestThousandsOfIdleSessionsShareOnePoolThread;
    procedure TestTasksOfOneSessionKeepWireOrder;
    procedure TestSessionsTakeTurns;
    procedure TestFourThreadsRunSessionsInParallelNeverTwoTasksOfOne;
    procedure TestABlockingCallbackDelaysOtherSessions;
    procedure TestStopDeliversClosedToEverySession;
  end;

implementation

var
  GWantedMessages: Integer;

{ TCountingHandler }

constructor TCountingHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  Order := TStringList.Create;
end;

destructor TCountingHandler.Destroy;
begin
  Order.Free;
  FLock.Free;
  inherited Destroy;
end;

function TCountingHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TCountingHandler.Message(const ASession: IWsSession; const AData: TBytes;
  const AText: Boolean);
begin
  if Gate <> nil then
  begin
    RTLEventWaitFor(Gate);
    Gate := nil;
  end;
  FLock.Acquire;
  try
    Inc(FInside);
    if FInside > MaxInside then
      MaxInside := FInside;
    Inc(Messages);
    Order.Add(TextOf(AData));
  finally
    FLock.Release;
  end;
  if GlobalLog <> nil then
  begin
    GlobalLock.Acquire;
    try
      GlobalLog.Add(Tag);
    finally
      GlobalLock.Release;
    end;
  end;
  if SleepMs > 0 then
    Sleep(SleepMs);
  FLock.Acquire;
  try
    Dec(FInside);
  finally
    FLock.Release;
  end;
end;

procedure TCountingHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TCountingHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  FLock.Acquire;
  try
    Inc(ClosedCalls);
  finally
    FLock.Release;
  end;
end;

procedure TCountingHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

function TCountingHandler.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := Messages;
  finally
    FLock.Release;
  end;
end;

function TCountingHandler.ClosedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := ClosedCalls;
  finally
    FLock.Release;
  end;
end;

{ TWsPoolTest }

function TWsPoolTest.Quick: TWsOptions;
begin
  Result := TWsOptions.Create
    .WithPingIntervalMs(0)
    .WithCloseTimeoutMs(300)
    .WithQueuedMessages(100000)
    .WithMessageBucket(TTokenBucketOptions.Create.WithCapacity(100000000).WithRefillPerSecond(100000000));
end;

procedure TWsPoolTest.Open(const AOptions: TWsOptions; const APoolSize, ACount: Integer;
  const ASleepMs: Integer);
var
  I: Integer;
  H: TCountingHandler;
  Ch: TFakeWsChannel;
  Req: TFakeRequest;
begin
  FRig := TWsRig.Create(AOptions, APoolSize);
  FHandlers := TList<TCountingHandler>.Create;
  FRefs := TList<IWsHandler>.Create;
  FChannels := TList<TFakeWsChannel>.Create;
  FChannelRefs := TList<IDuplexChannel>.Create;
  FSessions := TList<IWsSession>.Create;
  FRequests := TList<IServerRequest>.Create;
  for I := 0 to ACount - 1 do
  begin
    H := TCountingHandler.Create;
    H.SleepMs := ASleepMs;
    H.Tag := IntToStr(I);
    FHandlers.Add(H);
    FRefs.Add(H);
    Ch := FRig.NewChannel;
    FChannels.Add(Ch);
    FChannelRefs.Add(Ch);
    Req := TFakeRequest.Create;
    FRequests.Add(Req);
    FSessions.Add(WsStartSession(Ch, Req, H, TFakeHandshake.Create, nil));
  end;
end;

procedure TWsPoolTest.TearDown;
var
  I: Integer;
begin
  if FRig <> nil then
  begin
    FRig.Registry.CloseAll(ccGraceful);
    FRig.Registry.CloseAll(ccAbort);
  end;
  if FChannels <> nil then
    for I := 0 to FChannels.Count - 1 do
      FChannels[I].Sink := nil;
  FSessions.Free;
  FSessions := nil;
  FreeAndNil(FRig);
  FChannelRefs.Free;
  FChannels.Free;
  FRefs.Free;
  FHandlers.Free;
  FRequests.Free;
  inherited TearDown;
end;

function TWsPoolTest.AllActivated: Boolean;
var
  I: Integer;
begin
  for I := 0 to FChannels.Count - 1 do
    if not FChannels[I].Activated then
      Exit(False);
  Result := True;
end;

function TWsPoolTest.AllDelivered: Boolean;
var
  I: Integer;
begin
  for I := 0 to FHandlers.Count - 1 do
    if FHandlers[I].Count < GWantedMessages then
      Exit(False);
  Result := True;
end;

function TWsPoolTest.AllADelivered: Boolean;
begin
  Result := (FHandlers[0].Count >= GWantedMessages) and (FHandlers[1].Count >= 1);
end;

function TWsPoolTest.WaitAll(const AMessages: Integer; const ATimeoutMs: Integer): Boolean;
begin
  GWantedMessages := AMessages;
  Result := WaitUntil(AllDelivered, ATimeoutMs);
end;

procedure TWsPoolTest.TestThousandsOfIdleSessionsShareOnePoolThread;
begin
  Open(Quick, 1, 5000);
  AssertTrue('all 5,000 sessions opened', WaitUntil(AllActivated, 60000));
  AssertEquals('one pool thread serves them all', 1, FRig.Pool.Stats.Threads);
  AssertEquals(5000, FRig.Registry.Count);
end;

procedure TWsPoolTest.TestTasksOfOneSessionKeepWireOrder;
var
  I, J: Integer;
begin
  Open(Quick, 2, 50);
  AssertTrue(WaitUntil(AllActivated, 20000));
  for J := 1 to 40 do
    for I := 0 to FChannels.Count - 1 do
      FChannels[I].Deliver(ClientText(IntToStr(J)));
  AssertTrue('every message arrived', WaitAll(40, 30000));
  for I := 0 to FHandlers.Count - 1 do
    for J := 0 to 39 do
      AssertEquals('session ' + IntToStr(I) + ' message ' + IntToStr(J), IntToStr(J + 1),
        FHandlers[I].Order[J]);
end;

procedure TWsPoolTest.TestSessionsTakeTurns;
var
  Log: TStringList;
  Lock: TCriticalSection;
  I, FirstB: Integer;
  Gate: PRTLEvent;
begin
  Open(Quick, 1, 2);
  Log := TStringList.Create;
  Lock := TCriticalSection.Create;
  try
    FHandlers[0].GlobalLog := Log;
    FHandlers[0].GlobalLock := Lock;
    FHandlers[1].GlobalLog := Log;
    FHandlers[1].GlobalLock := Lock;
    AssertTrue(WaitUntil(AllActivated, 10000));
    // the first message of session 0 holds the only pool thread while 3,000 more
    // queue for session 0 and one for session 1
    Gate := RTLEventCreate;
    FHandlers[0].Gate := Gate;
    FChannels[0].Deliver(ClientText('a'));
    Sleep(100);
    for I := 1 to 3000 do
      FChannels[0].Deliver(ClientText('a'));
    FChannels[1].Deliver(ClientText('b'));
    RTLEventSetEvent(Gate);
    GWantedMessages := 3001;
    // every message of session 0 must be through before the log and the lock go
    AssertTrue(WaitUntil(AllADelivered, 30000));
    RTLEventDestroy(Gate);
    Lock.Acquire;
    try
      FirstB := Log.IndexOf('1');
    finally
      Lock.Release;
    end;
    AssertTrue('the second session ran before the first finished its 3,000: position ' +
      IntToStr(FirstB), (FirstB >= 0) and (FirstB < 20));
  finally
    FHandlers[0].GlobalLog := nil;
    FHandlers[1].GlobalLog := nil;
    Log.Free;
    Lock.Free;
  end;
end;

procedure TWsPoolTest.TestFourThreadsRunSessionsInParallelNeverTwoTasksOfOne;
var
  I, J: Integer;
begin
  Open(Quick, 4, 4, 15);
  AssertTrue(WaitUntil(AllActivated, 10000));
  for J := 1 to 10 do
    for I := 0 to 3 do
      FChannels[I].Deliver(ClientText(IntToStr(J)));
  AssertTrue(WaitAll(10, 30000));
  for I := 0 to 3 do
    AssertEquals('never two tasks of session ' + IntToStr(I) + ' at once', 1, FHandlers[I].MaxInside);
  AssertEquals(4, FRig.Pool.Stats.Threads);
end;

procedure TWsPoolTest.TestABlockingCallbackDelaysOtherSessions;
var
  Waited: Integer;
begin
  Open(Quick, 1, 2);
  AssertTrue(WaitUntil(AllActivated, 10000));
  // session 0 blocks the only pool thread for 400 ms
  FHandlers[0].SleepMs := 400;
  FChannels[0].Deliver(ClientText('slow'));
  Sleep(50);
  FChannels[1].Deliver(ClientText('fast'));
  Waited := 0;
  while (FHandlers[1].Count = 0) and (Waited < 200) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  AssertEquals('with one pool thread the blocking callback delays the other session', 0,
    FHandlers[1].Count);
  GWantedMessages := 1;
  AssertTrue('and the other session runs once the callback returns', WaitUntil(AllDelivered, 5000));
end;

procedure TWsPoolTest.TestStopDeliversClosedToEverySession;
var
  I: Integer;
  Done: Integer;
begin
  Open(Quick.WithCloseTimeoutMs(100), 1, 200);
  AssertTrue(WaitUntil(AllActivated, 20000));
  FRig.Registry.CloseAll(ccGraceful);
  FRig.Registry.CloseAll(ccAbort);
  Done := 0;
  for I := 0 to FHandlers.Count - 1 do
    if FHandlers[I].ClosedCount = 1 then
      Inc(Done);
  AssertEquals('every session heard Closed exactly once', 200, Done);
end;

initialization
  RegisterTest(TWsPoolTest);

end.
