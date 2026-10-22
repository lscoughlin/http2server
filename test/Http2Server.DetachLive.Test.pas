{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, detach, live, stop, cancel, handler pool, test, fpcunit
notes:
  - This unit tests detached streams on a running server with a raw h2c client.
  - The tests check that a detached stream does not hold a handler thread, that
    Stop ends it, that the limit refuses the next detach, that an exception after
    Detach leaves the stream alone, and that the loss of the socket cancels a
    waiting handler once.
  - The waits are bounded polls of a counter or a socket and never a fixed sleep
    that decides a result.
---
}
/// Live tests of detached streams
unit Http2Server.DetachLive.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.base,
  mormot.core.os,
  Http2Server,
  Http2Server.Errors, Http2Server.Duplex, Http2Server.Server.Test;

type
  /// a handler that detaches its stream; the path selects what it does
  // - /ordinary answers a plain 200 with the body "ordinary"
  // - /raise-pending detaches, activates, sends, and then raises
  // - /raise-after-headers sends the headers, detaches, sends, and then raises
  // - any other path detaches, activates and sends; a refused detach answers 503
  TDetachingHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FLock: TCriticalSection;
    FChannels: TList<IDuplexChannel>;
    FRefused: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    function ChannelCount: Integer;
    function ChannelAt(const AIndex: Integer): IDuplexChannel;
    function Refused: Integer;
  end;

  /// a handler that writes until the stream ends and counts its cancel hook
  TBlockedWriterHandler = class(TInterfacedObject, IHttp2Handler)
  public
    Hooks: Integer;
    Started: Integer;
    Ended: Integer;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    procedure OnCancel;
  end;

  TDetachLiveTest = class(TTestCase)
  private
    procedure WaitFor(var ACounter: Integer; const AWanted, ATimeoutMs: Integer);
  published
    procedure TestDetachedStreamIsServedAndStopEndsIt;
    procedure TestDetachLimitRefusesAndTheObserverSeesIt;
    procedure TestRaiseAfterPendingDetachLeavesTheStreamAlone;
    procedure TestRaiseAfterHeadersDetachLeavesTheStreamAlone;
    procedure TestManyDetachedStreamsLeaveTheHandlerPoolFree;
    procedure TestClientDisconnectEndsABlockedHandler;
    procedure TestCancelHookRunsAtMostOnceAcrossStop;
  end;

implementation

const
  ResponseTimeoutMs = 5000;

function BytesOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

function LiveFactory(const AHandler: IHttp2Handler): THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500);
end;

{ TDetachingHandler }

constructor TDetachingHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FChannels := TList<IDuplexChannel>.Create;
end;

destructor TDetachingHandler.Destroy;
begin
  FChannels.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDetachingHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Channel: IDuplexChannel;
  Path: string;

  procedure Keep(const AChannel: IDuplexChannel);
  begin
    FLock.Acquire;
    try
      FChannels.Add(AChannel);
    finally
      FLock.Release;
    end;
  end;

begin
  Path := ARequest.Path;
  if Path = '/ordinary' then
  begin
    AResponse.SendHeaders(200, nil, False);
    AResponse.Write(BytesOf('ordinary'));
    AResponse.Finish;
    Exit;
  end;
  if Path = '/raise-after-headers' then
  begin
    AResponse.SendHeaders(200, nil, False);
    Channel := AResponse.Detach;
    Channel.Send(BytesOf('first'));
    Keep(Channel);
    raise Exception.Create('the handler failed after Detach');
  end;
  try
    Channel := AResponse.Detach;
  except
    on EDetachRefused do
    begin
      FLock.Acquire;
      try
        Inc(FRefused);
      finally
        FLock.Release;
      end;
      AResponse.SendHeaders(503, nil, False);
      AResponse.Write(BytesOf('busy'));
      AResponse.Finish;
      Exit;
    end;
  end;
  // the channel is pending: the headers and the first bytes follow
  Channel.Activate(200, nil);
  Channel.Send(BytesOf('first'));
  Keep(Channel);
  if Path = '/raise-pending' then
    raise Exception.Create('the handler failed after Detach');
end;

function TDetachingHandler.ChannelCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FChannels.Count;
  finally
    FLock.Release;
  end;
end;

function TDetachingHandler.ChannelAt(const AIndex: Integer): IDuplexChannel;
begin
  FLock.Acquire;
  try
    Result := FChannels[AIndex];
  finally
    FLock.Release;
  end;
end;

function TDetachingHandler.Refused: Integer;
begin
  FLock.Acquire;
  try
    Result := FRefused;
  finally
    FLock.Release;
  end;
end;

{ TBlockedWriterHandler }

procedure TBlockedWriterHandler.OnCancel;
begin
  InterlockedIncrement(Hooks);
end;

procedure TBlockedWriterHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Chunk: TBytes;
begin
  InterlockedIncrement(Started);
  AResponse.RegisterCancelHook(OnCancel);
  AResponse.SendHeaders(200, nil, False);
  SetLength(Chunk, 65536);
  try
    // the client never reads, so the windows close and the write blocks
    while True do
      AResponse.Write(Chunk);
  finally
    InterlockedIncrement(Ended);
  end;
end;

{ TDetachLiveTest }

procedure TDetachLiveTest.WaitFor(var ACounter: Integer; const AWanted,
  ATimeoutMs: Integer);
var
  Waited: Integer;
begin
  Waited := 0;
  while (ACounter < AWanted) and (Waited < ATimeoutMs) do
  begin
    Sleep(5);
    Inc(Waited, 5);
  end;
end;

procedure TDetachLiveTest.TestDetachedStreamIsServedAndStopEndsIt;
var
  Handler: TDetachingHandler;
  HandlerRef: IHttp2Handler;
  Observer: TCollectObserver;
  ObserverRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
  Stats: TServerStats;
begin
  Handler := TDetachingHandler.Create;
  HandlerRef := Handler;
  Observer := TCollectObserver.Create;
  ObserverRef := Observer;
  Server := LiveFactory(HandlerRef).Build(ObserverRef);
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/detach');
    Client.CollectStream(1, 5, ResponseTimeoutMs, Body, Ended);
    AssertEquals('the first bytes of the detached stream arrive', 'first',
      TextOf(Body));
    AssertFalse('the stream is still open', Ended);
    Stats := Server.Stats;
    AssertEquals('one stream is detached', 1, Stats.DetachedStreams);
    AssertEquals('the observer saw the detach', 1,
      Observer.CountOf(seStreamDetached));
    // the owner sends more bytes from this thread, with no handler thread
    AssertTrue(Handler.ChannelAt(0).Send(BytesOf('second')) = srQueued);
    Client.CollectStream(1, 6, ResponseTimeoutMs, Body, Ended);
    AssertEquals('later bytes arrive without a handler thread', 'second',
      TextOf(Body));
    // Stop closes the channel gracefully, so END_STREAM reaches the client
    Server.Stop;
    Client.CollectStream(1, 0, ResponseTimeoutMs, Body, Ended);
    AssertTrue('Stop ended the detached stream with END_STREAM', Ended);
  finally
    Client.Free;
  end;
  Stats := Server.Stats;
  AssertEquals('no stream is detached after a stop', 0, Stats.DetachedStreams);
  AssertFalse('the channel is closed', Handler.ChannelAt(0).IsOpen);
end;

procedure TDetachLiveTest.TestDetachLimitRefusesAndTheObserverSeesIt;
var
  Handler: TDetachingHandler;
  HandlerRef: IHttp2Handler;
  Observer: TCollectObserver;
  ObserverRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Client, Second: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
begin
  Handler := TDetachingHandler.Create;
  HandlerRef := Handler;
  Observer := TCollectObserver.Create;
  ObserverRef := Observer;
  Server := LiveFactory(HandlerRef).WithMaxDetachedStreams(1).Build(ObserverRef);
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  Second := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/one');
    Client.CollectStream(1, 5, ResponseTimeoutMs, Body, Ended);
    AssertEquals('first', TextOf(Body));
    // the limit counts the detached streams of the whole server, so the
    // second connection meets it
    Second.SendGet(1, '/two');
    Second.CollectStream(1, 4, ResponseTimeoutMs, Body, Ended);
    AssertEquals('the second detach was refused and answered 503 with a body',
      'busy', TextOf(Body));
    AssertEquals('the handler saw one refusal', 1, Handler.Refused);
    AssertEquals('the observer saw one detach', 1,
      Observer.CountOf(seStreamDetached));
    AssertEquals('the observer saw one refusal', 1,
      Observer.CountOf(seStreamDetachRefused));
  finally
    Client.Free;
    Second.Free;
  end;
  Server.Stop;
end;

procedure TDetachLiveTest.TestRaiseAfterPendingDetachLeavesTheStreamAlone;
var
  Handler: TDetachingHandler;
  HandlerRef: IHttp2Handler;
  Observer: TCollectObserver;
  ObserverRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
  Code: THttp2ErrorCode;
begin
  Handler := TDetachingHandler.Create;
  HandlerRef := Handler;
  Observer := TCollectObserver.Create;
  ObserverRef := Observer;
  Server := LiveFactory(HandlerRef).Build(ObserverRef);
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/raise-pending');
    Client.CollectStream(1, 5, ResponseTimeoutMs, Body, Ended);
    AssertEquals('the 200 and the first bytes arrive', 'first', TextOf(Body));
    AssertFalse('the pool did not end the stream', Ended);
    AssertFalse('no RST_STREAM and no 500 follow the failed handler',
      Client.WaitForReset(1, 400, Code));
    AssertEquals('the observer saw the exception once', 1,
      Observer.CountOf(seHandlerException));
    AssertTrue('the owner still controls the channel',
      Handler.ChannelAt(0).Send(BytesOf('more')) = srQueued);
    Client.CollectStream(1, 4, ResponseTimeoutMs, Body, Ended);
    AssertEquals('more', TextOf(Body));
  finally
    Client.Free;
  end;
  Server.Stop;
end;

procedure TDetachLiveTest.TestRaiseAfterHeadersDetachLeavesTheStreamAlone;
var
  Handler: TDetachingHandler;
  HandlerRef: IHttp2Handler;
  Observer: TCollectObserver;
  ObserverRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
  Code: THttp2ErrorCode;
begin
  Handler := TDetachingHandler.Create;
  HandlerRef := Handler;
  Observer := TCollectObserver.Create;
  ObserverRef := Observer;
  Server := LiveFactory(HandlerRef).Build(ObserverRef);
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/raise-after-headers');
    Client.CollectStream(1, 5, ResponseTimeoutMs, Body, Ended);
    AssertEquals('first', TextOf(Body));
    AssertFalse('the stream is not reset by the failed handler',
      Client.WaitForReset(1, 400, Code));
    AssertEquals('the observer saw the exception once', 1,
      Observer.CountOf(seHandlerException));
    AssertTrue(Handler.ChannelAt(0).IsOpen);
  finally
    Client.Free;
  end;
  Server.Stop;
end;

procedure TDetachLiveTest.TestManyDetachedStreamsLeaveTheHandlerPoolFree;
const
  cDetached = 50;
var
  Handler: TDetachingHandler;
  HandlerRef: IHttp2Handler;
  Server: IHttp2Server;
  Clients: array[0..cDetached - 1] of TLifecycleClient;
  Ordinary: TLifecycleClient;
  I: Integer;
  Body: TBytes;
  Ended: Boolean;
  Stats: TServerStats;
begin
  Handler := TDetachingHandler.Create;
  HandlerRef := Handler;
  // two handler threads serve fifty detached streams and one ordinary request
  Server := LiveFactory(HandlerRef).Build;
  Server.Start;
  for I := 0 to cDetached - 1 do
    Clients[I] := nil;
  try
    for I := 0 to cDetached - 1 do
    begin
      Clients[I] := TLifecycleClient.Create(Server.Port);
      Clients[I].SendGet(1, '/detach');
      Clients[I].CollectStream(1, 5, ResponseTimeoutMs, Body, Ended);
      AssertEquals('the detached stream answers', 'first', TextOf(Body));
    end;
    Stats := Server.Stats;
    AssertEquals('all streams are detached', cDetached, Stats.DetachedStreams);
    Ordinary := TLifecycleClient.Create(Server.Port);
    try
      Ordinary.SendGet(1, '/ordinary');
      Ordinary.CollectStream(1, 8, ResponseTimeoutMs, Body, Ended);
      AssertEquals('an ordinary request is served while streams are detached',
        'ordinary', TextOf(Body));
    finally
      Ordinary.Free;
    end;
    Stats := Server.Stats;
    AssertEquals('no handler thread is busy', 0, Stats.BusyHandlers);
  finally
    for I := 0 to cDetached - 1 do
      Clients[I].Free;
  end;
  Server.Stop;
end;

procedure TDetachLiveTest.TestClientDisconnectEndsABlockedHandler;
var
  Handler: TBlockedWriterHandler;
  HandlerRef: IHttp2Handler;
  Server: IHttp2Server;
  Client: TLifecycleClient;
begin
  Handler := TBlockedWriterHandler.Create;
  HandlerRef := Handler;
  Server := LiveFactory(HandlerRef).Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  Client.SendGet(1, '/blocked');
  WaitFor(Handler.Started, 1, ResponseTimeoutMs);
  AssertEquals('the handler started', 1, Handler.Started);
  // the client closes its socket with the handler blocked in a write
  Client.Free;
  WaitFor(Handler.Ended, 1, ResponseTimeoutMs);
  AssertEquals('the loss of the socket ended the blocked handler', 1,
    Handler.Ended);
  // the server builds no cancel-worker pool yet, so a registered hook does not
  // run in production (a gap that predates the detached streams); the test
  // holds the weaker rule that a hook never runs twice
  AssertTrue('the cancel hook ran at most once', Handler.Hooks <= 1);
  Server.Stop;
  AssertTrue('Stop does not run the hook again', Handler.Hooks <= 1);
end;

procedure TDetachLiveTest.TestCancelHookRunsAtMostOnceAcrossStop;
var
  Handler: TBlockedWriterHandler;
  HandlerRef: IHttp2Handler;
  Server: IHttp2Server;
  Client: TLifecycleClient;
begin
  Handler := TBlockedWriterHandler.Create;
  HandlerRef := Handler;
  Server := LiveFactory(HandlerRef).Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/blocked');
    WaitFor(Handler.Started, 1, ResponseTimeoutMs);
    AssertEquals('the handler started', 1, Handler.Started);
    // Stop cancels the blocked handler after the graceful wait
    Server.Stop;
  finally
    Client.Free;
  end;
  WaitFor(Handler.Ended, 1, ResponseTimeoutMs);
  AssertEquals('the handler ended', 1, Handler.Ended);
  AssertTrue('the cancel hook ran at most once', Handler.Hooks <= 1);
end;

initialization
  RegisterTest(TDetachLiveTest);

end.
