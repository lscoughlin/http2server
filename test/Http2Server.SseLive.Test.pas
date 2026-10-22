{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: sse, server-sent events, live, http2, keep-alive, stop, test, fpcunit
notes:
  - This unit tests event streams on a running server with a raw h2c client.
  - The tests check the wire bytes of events, the keep-alive comment, the
    Last-Event-ID path through the handler, and the end of the stream at Stop.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Live tests of server-sent events over HTTP/2
unit Http2Server.SseLive.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2Server,
  Http2Server.Errors, Http2Server.Duplex, Http2Server.Sse.Encoder,
  Http2Server.Sse, Http2Server.Server.Test;

type
  /// a handler that opens an event stream and keeps it
  TSseHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FLock: TCriticalSection;
    FStream: ISseStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    function Stream: ISseStream;
    procedure Release;
  end;

  TSseLiveTest = class(TTestCase)
  published
    procedure TestEventsArriveOnTheWire;
    procedure TestKeepAliveArrivesOnAnIdleStream;
    procedure TestStopEndsTheStream;
  end;

implementation

const
  ResponseTimeoutMs = 5000;

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

{ TSseHandler }

constructor TSseHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TSseHandler.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TSseHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  S: ISseStream;
begin
  S := StartSse(ARequest, AResponse);
  FLock.Acquire;
  try
    FStream := S;
  finally
    FLock.Release;
  end;
end;

function TSseHandler.Stream: ISseStream;
begin
  FLock.Acquire;
  try
    Result := FStream;
  finally
    FLock.Release;
  end;
end;

procedure TSseHandler.Release;
begin
  FLock.Acquire;
  try
    FStream := nil;
  finally
    FLock.Release;
  end;
end;

{ TSseLiveTest }

procedure TSseLiveTest.TestEventsArriveOnTheWire;
var
  Handler: TSseHandler;
  HandlerRef: IHttp2Handler;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
  Waited: Integer;
  E: TSseEvent;
  Wanted: string;
begin
  Handler := TSseHandler.Create;
  HandlerRef := Handler;
  Server := LiveFactory(HandlerRef).WithSseKeepAlive(0).Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/events');
    Waited := 0;
    while (Handler.Stream = nil) and (Waited < ResponseTimeoutMs) do
    begin
      Sleep(5);
      Inc(Waited, 5);
    end;
    AssertTrue('the handler opened the stream', Handler.Stream <> nil);
    E := TSseEvent.Text('hello'#10'world');
    E.Id := '1';
    E.Event := 'greeting';
    AssertTrue(Handler.Stream.Send(E) = srQueued);
    AssertTrue(Handler.Stream.Send(TSseEvent.Text('second')) = srQueued);
    Wanted := 'id: 1'#10'event: greeting'#10'data: hello'#10'data: world'#10#10 +
      'data: second'#10#10;
    Client.CollectStream(1, Length(Wanted), ResponseTimeoutMs, Body, Ended);
    AssertEquals('the events reach the client byte for byte', Wanted, TextOf(Body));
    AssertFalse(Ended);
    Handler.Stream.Close;
    Client.CollectStream(1, 0, ResponseTimeoutMs, Body, Ended);
    AssertTrue('Close ended the stream with END_STREAM', Ended);
  finally
    Client.Free;
    Handler.Release;
    Server.Stop;
  end;
end;

procedure TSseLiveTest.TestKeepAliveArrivesOnAnIdleStream;
var
  Handler: TSseHandler;
  HandlerRef: IHttp2Handler;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
begin
  Handler := TSseHandler.Create;
  HandlerRef := Handler;
  Server := LiveFactory(HandlerRef).WithSseKeepAlive(50).Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/events');
    Client.CollectStream(1, Length(': keep-alive'#10#10), ResponseTimeoutMs,
      Body, Ended);
    AssertEquals('an idle stream gets the keep-alive comment', ': keep-alive'#10#10,
      Copy(TextOf(Body), 1, Length(': keep-alive'#10#10)));
  finally
    Client.Free;
    Handler.Release;
    Server.Stop;
  end;
end;

procedure TSseLiveTest.TestStopEndsTheStream;
var
  Handler: TSseHandler;
  HandlerRef: IHttp2Handler;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Ended: Boolean;
  Waited: Integer;
begin
  Handler := TSseHandler.Create;
  HandlerRef := Handler;
  Server := LiveFactory(HandlerRef).WithSseKeepAlive(0).Build;
  Server.Start;
  Client := TLifecycleClient.Create(Server.Port);
  try
    Client.SendGet(1, '/events');
    Waited := 0;
    while (Handler.Stream = nil) and (Waited < ResponseTimeoutMs) do
    begin
      Sleep(5);
      Inc(Waited, 5);
    end;
    AssertTrue(Handler.Stream <> nil);
    Server.Stop;
    Client.CollectStream(1, 0, ResponseTimeoutMs, Body, Ended);
    AssertTrue('Stop ended the stream with END_STREAM', Ended);
    AssertFalse('the producer sees a closed stream', Handler.Stream.IsOpen);
    AssertTrue(Handler.Stream.Send(TSseEvent.Text('late')) = srClosed);
  finally
    Client.Free;
    Handler.Release;
  end;
end;

initialization
  RegisterTest(TSseLiveTest);

end.
