{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, locks, goaway, waker, output cap, write timeout, test
notes:
  - This unit holds the tests of story 28 of the hardening plan. The findings
    are H2-7 (GracefulGoAway writes the output queue without the connection
    lock), H2-8 (the write waker runs under the connection lock), H2-11 (a
    handler write waits for ever on a peer that does not read) and H2-12 (some
    reset frames are not charged, and the output queue has no cap).
  - The lock tests park one thread inside the core and look at what a second
    thread can do. They use a bounded wait to see that a call stays blocked.
---
}
/// Tests of the connection lock, the output cap and the write timeout
unit Http2Server.H2Locks.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.os,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.Seam, Http2Server.Output, Http2Server.Stream,
  Http2Server.StreamHost, Http2Server.Connection, Http2Server.H2Peer;

type
  /// the method a helper thread runs
  TCallProc = procedure of object;

  /// a thread that runs one method
  TCallThread = class(TThread)
  private
    FProc: TCallProc;
  protected
    procedure Execute; override;
  public
    Finished_: TEvent;
    constructor Create(const AProc: TCallProc);
    destructor Destroy; override;
  end;

  /// a waker that tries to take the connection lock from another thread
  // - if the caller of Signal holds that lock, the probe thread cannot finish
  TLockProbeWaker = class(TInterfacedObject, IWriteWaker)
  private
    FCore: TServerConnectionCore;
    FThread: TCallThread;
    procedure Probe;
  public
    Signals: Integer;
    LockHeld: Boolean;
    constructor Create(const ACore: TServerConnectionCore);
    procedure Signal;
    /// wait for the probe thread and free it
    procedure Join;
  end;

  TH2LocksTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Start(const AOptions: TPeerOptions);
    procedure FeedGet;
    procedure CallGoAway;
  protected
    procedure TearDown; override;
  published
    procedure TestGracefulGoAwayWaitsForTheConnectionLock;
    procedure TestWakerRunsAfterTheLockIsReleased;
    procedure TestOutputQueueCapAbortsTheConnection;
    procedure TestPriorityResetsAreChargedToTheLimiter;
    procedure TestWindowUpdateOverflowResetsOnceAndClosesTheStream;
    procedure TestHandlerWriteToAPeerThatDoesNotReadTimesOut;
  end;

implementation

type
  /// a stream host that records nothing
  TNullHost = class(TInterfacedObject, IStreamHost)
  public
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    procedure OutputPending(const AStreamId: LongWord);
  end;

procedure TNullHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
end;

procedure TNullHost.OutputPending(const AStreamId: LongWord);
begin
end;

{ TCallThread }

constructor TCallThread.Create(const AProc: TCallProc);
begin
  Finished_ := TEvent.Create(nil, True, False, '');
  FProc := AProc;
  inherited Create(False);
end;

destructor TCallThread.Destroy;
begin
  Finished_.Free;
  inherited Destroy;
end;

procedure TCallThread.Execute;
begin
  try
    FProc();
  finally
    Finished_.SetEvent;
  end;
end;

{ TLockProbeWaker }

constructor TLockProbeWaker.Create(const ACore: TServerConnectionCore);
begin
  inherited Create;
  FCore := ACore;
end;

procedure TLockProbeWaker.Probe;
begin
  FCore.HasOutput;   // takes the connection lock
end;

procedure TLockProbeWaker.Signal;
var
  Thread: TCallThread;
begin
  Inc(Signals);
  Thread := TCallThread.Create(Probe);
  if Thread.Finished_.WaitFor(400) <> wrSignaled then
    LockHeld := True;
  // the probe ends only after the caller released the lock, so the test joins
  // it later and not here
  FThread := Thread;
end;

procedure TLockProbeWaker.Join;
begin
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

{ TH2LocksTest }

procedure TH2LocksTest.TearDown;
begin
  FreeAndNil(FPeer);
end;

procedure TH2LocksTest.Start(const AOptions: TPeerOptions);
begin
  FPeer := TH2Peer.Create(AOptions);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

procedure TH2LocksTest.FeedGet;
begin
  FPeer.SendGet(1);
end;

procedure TH2LocksTest.CallGoAway;
begin
  FPeer.Core.GracefulGoAway(0, ecNoError);
end;

procedure TH2LocksTest.TestGracefulGoAwayWaitsForTheConnectionLock;
var
  Entered, Hold: TEvent;
  Feeder, Goer: TCallThread;
  Blocked: Boolean;
begin
  Start(TPeerOptions.Default);
  Entered := TEvent.Create(nil, True, False, '');
  Hold := TEvent.Create(nil, True, False, '');
  try
    FPeer.Events.ParkRequestReady(Entered, Hold);
    // the feeding thread holds the connection lock inside RequestReady
    Feeder := TCallThread.Create(FeedGet);
    try
      AssertTrue('the feeder is inside the core', Entered.WaitFor(2000) = wrSignaled);
      Goer := TCallThread.Create(CallGoAway);
      try
        // H2-7: the call needs the lock, so it cannot finish while the feeder holds it
        Blocked := Goer.Finished_.WaitFor(400) <> wrSignaled;
        Hold.SetEvent;
        AssertTrue('GracefulGoAway waited for the connection lock', Blocked);
        Goer.WaitFor;
      finally
        Goer.Free;
      end;
      Feeder.WaitFor;
    finally
      Feeder.Free;
    end;
  finally
    Hold.Free;
    Entered.Free;
  end;
  FPeer.Pump;
  AssertEquals('one GOAWAY frame', 1, FPeer.CountOf(ftGoAway));
  AssertEquals('the output stays intact', 0, FPeer.Violations.Count);
end;

procedure TH2LocksTest.TestWakerRunsAfterTheLockIsReleased;
var
  Waker: TLockProbeWaker;
  WakerRef: IWriteWaker;
begin
  Start(TPeerOptions.Default);
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  Waker := TLockProbeWaker.Create(FPeer.Core);
  WakerRef := Waker;
  FPeer.Core.SetWriteWaker(WakerRef);
  // a refusal from a handler thread queues an RST_STREAM and wakes the writer
  FPeer.Core.StreamById(1).Refuse(ecRefusedStream);
  Waker.Join;
  AssertEquals('the waker ran', 1, Waker.Signals);
  AssertFalse('H2-8: the waker ran with the connection lock held', Waker.LockHeld);
  FPeer.Core.SetWriteWaker(nil);
end;

procedure TH2LocksTest.TestOutputQueueCapAbortsTheConnection;
var
  Options: TPeerOptions;
  I: Integer;
  Code: THttp2ErrorCode;
begin
  Options := TPeerOptions.Default;
  Options.Core.MaxOutputBytes := 1000;
  Start(Options);
  // a peer that sends and never reads: every PING queues a 17 octet answer
  for I := 1 to 100 do
    FPeer.SendPing;
  AssertTrue('the core aborts the connection above the cap', FPeer.Core.Aborted);
  FPeer.Pump;
  AssertTrue('the GOAWAY says why', FPeer.GoAwayCode(Code));
  AssertTrue(Code = ecEnhanceYourCalm);
end;

procedure TH2LocksTest.TestPriorityResetsAreChargedToTheLimiter;
var
  Options: TPeerOptions;
  I: Integer;
  Code: THttp2ErrorCode;
begin
  Options := TPeerOptions.Default;
  Options.BucketCapacity := 5;
  Start(Options);
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  // each PRIORITY frame that names its own stream makes the server send an RST_STREAM
  for I := 1 to 10 do
    FPeer.SendPriority(1, 1);
  FPeer.Pump;
  AssertTrue('the reset flood trips the limiter', FPeer.GoAwayCode(Code));
  AssertTrue(Code = ecEnhanceYourCalm);
end;

procedure TH2LocksTest.TestWindowUpdateOverflowResetsOnceAndClosesTheStream;
var
  I: Integer;
begin
  Start(TPeerOptions.Default);
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  for I := 1 to 10 do
    FPeer.SendWindowUpdate(1, 2147483647);
  FPeer.Pump;
  AssertEquals('one reset, because the stream is closed after the first', 1,
    FPeer.CountOnStream(ftRstStream, 1));
  AssertEquals('the stream left the table', 0, FPeer.Core.OpenStreams);
end;

procedure TH2LocksTest.TestHandlerWriteToAPeerThatDoesNotReadTimesOut;
var
  Lock: TCriticalSection;
  Host: IStreamHost;
  Stream: TServerStream;
  Chunk: TBytes;
  Started: QWord;
  Raised: Boolean;
begin
  Lock := TCriticalSection.Create;
  Host := TNullHost.Create;
  Stream := TServerStream.Create(1, Lock, Host, 100, 10);
  try
    Stream.WriteTimeoutMs := 150;
    SetLength(Chunk, 10);
    Stream.Write(Chunk);       // fills the buffer; nothing drains it
    Started := GetTickCount64;
    Raised := False;
    try
      Stream.Write(Chunk);     // waits for room that never comes
    except
      on E: EHttpTimeout do
        Raised := True;
    end;
    AssertTrue('H2-11: the blocked write ends with a timeout', Raised);
    AssertTrue('the wait took about the write timeout',
      GetTickCount64 - Started < 3000);
  finally
    Stream.ReleaseRef;
    Lock.Free;
  end;
end;

initialization
  RegisterTest(TH2LocksTest);
end.
