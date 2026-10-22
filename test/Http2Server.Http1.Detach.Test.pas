{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, detach, chunked channel, server-sent events, keep-alive, stop, test, fpcunit
notes:
  - This unit tests the detached HTTP/1.1 response and the server-sent events
    that run on it, on a running server with a raw-socket client.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Live tests of detached HTTP/1.1 responses and server-sent events
unit Http2Server.Http1.Detach.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2Server, Http2Server.Duplex, Http2Server.Sse.Encoder, Http2Server.Sse,
  Http2Server.Http1.RawClient;

type
  /// sends from another thread while the handler activates the channel
  TRaceSender = class(TThread)
  public
    Channel: IDuplexChannel;
    Go: PRTLEvent;
    procedure Execute; override;
  end;

  /// opens an event stream and keeps it, and keeps a plain detached channel
  TStreamHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FLock: TCriticalSection;
    FStream: ISseStream;
    FChannel: IDuplexChannel;
    FLastEventId: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    function Stream: ISseStream;
    function Channel: IDuplexChannel;
    function LastEventId: string;
    procedure Release;
  end;

  THttp1DetachTest = class(TTestCase)
  private
    FHandler: TStreamHandler;
    FHandlerRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function WaitStream: ISseStream;
    function WaitChannel: IDuplexChannel;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEventsArriveAsChunks;
    procedure TestKeepAliveCommentArrives;
    procedure TestGracefulCloseSendsTheLastChunkAndKeepsTheConnection;
    procedure TestPeerCloseEndsTheStream;
    procedure TestStopEndsTheStream;
    procedure TestLastEventIdReachesTheHandler;
    procedure TestHttp10GetsNoChunkFraming;
    procedure TestPendingChannelHoldsBytesUntilActivate;
    procedure TestCompleteSendsAWholeResponse;
    procedure TestTheDetachLimitRefusesTheNextDetach;
    procedure TestAbortCutsTheConnection;
    procedure TestSendDuringActivateNeverOvertakesTheHead;
  end;

implementation

{ TRaceSender }

procedure TRaceSender.Execute;
var
  I: Integer;
begin
  RTLEventWaitFor(Go);
  // send at once, and again as soon as the channel is no longer pending: a channel
  // that turns active before its head is out would let these bytes overtake it
  for I := 1 to 250 do
    Channel.Send(TBytes.Create(Ord('r')));
  while Channel.State = csPending do
    ;
  for I := 251 to 500 do
    Channel.Send(TBytes.Create(Ord('r')));
end;

{ TStreamHandler }

constructor TStreamHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TStreamHandler.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TStreamHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  S: ISseStream;
  C: IDuplexChannel;
  H: THeaderBlock;
  Sender: TRaceSender;
begin
  if ARequest.Path = '/channel' then
  begin
    C := AResponse.Detach;
    SetLength(H, 1);
    H[0].Name := 'content-type';
    H[0].Value := 'application/octet-stream';
    // bytes sent while the channel is pending wait for Activate
    C.Send(TBytes.Create(Ord('a'), Ord('b')));
    C.Activate(200, H);
    FLock.Acquire;
    try
      FChannel := C;
    finally
      FLock.Release;
    end;
    Exit;
  end;
  if ARequest.Path = '/race' then
  begin
    C := AResponse.Detach;
    Sender := TRaceSender.Create(True);
    Sender.Channel := C;
    Sender.Go := RTLEventCreate;
    Sender.Start;
    // the sender starts to send as Activate begins
    RTLEventSetEvent(Sender.Go);
    SetLength(H, 1);
    H[0].Name := 'content-type';
    H[0].Value := 'application/octet-stream';
    C.Activate(200, H);
    Sender.WaitFor;
    RTLEventDestroy(Sender.Go);
    Sender.Free;
    C.Close(ccGraceful);
    Exit;
  end;
  if ARequest.Path = '/complete' then
  begin
    C := AResponse.Detach;
    C.Complete(201, nil, TBytes.Create(Ord('o'), Ord('k')));
    Exit;
  end;
  S := StartSse(ARequest, AResponse);
  FLock.Acquire;
  try
    FStream := S;
    FLastEventId := string(S.LastEventId);
  finally
    FLock.Release;
  end;
end;

function TStreamHandler.Stream: ISseStream;
begin
  FLock.Acquire;
  try
    Result := FStream;
  finally
    FLock.Release;
  end;
end;

function TStreamHandler.Channel: IDuplexChannel;
begin
  FLock.Acquire;
  try
    Result := FChannel;
  finally
    FLock.Release;
  end;
end;

function TStreamHandler.LastEventId: string;
begin
  FLock.Acquire;
  try
    Result := FLastEventId;
  finally
    FLock.Release;
  end;
end;

procedure TStreamHandler.Release;
begin
  FLock.Acquire;
  try
    FStream := nil;
    FChannel := nil;
  finally
    FLock.Release;
  end;
end;

{ THttp1DetachTest }

procedure THttp1DetachTest.SetUp;
begin
  FHandler := TStreamHandler.Create;
  FHandlerRef := FHandler;
end;

procedure THttp1DetachTest.TearDown;
begin
  FHandler.Release;
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandlerRef := nil;
end;

procedure THttp1DetachTest.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function THttp1DetachTest.WaitStream: ISseStream;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ResponseMs;
  while (FHandler.Stream = nil) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := FHandler.Stream;
  AssertTrue('the handler opened the stream', Result <> nil);
end;

function THttp1DetachTest.WaitChannel: IDuplexChannel;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ResponseMs;
  while (FHandler.Channel = nil) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := FHandler.Channel;
  AssertTrue('the handler detached the channel', Result <> nil);
end;

procedure THttp1DetachTest.TestEventsArriveAsChunks;
var
  C: TRawHttp;
  R: TRawResponse;
  Data: string;
  Last: Boolean;
  E: TSseEvent;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Accept: text/event-stream' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('text/event-stream', R.Header('content-type'));
    AssertEquals('no-store', R.Header('cache-control'));
    AssertTrue('the body is chunked', R.Chunked);
    AssertEquals('', R.Header('content-length'));
    E := TSseEvent.Text('hello');
    E.Id := '1';
    AssertTrue(WaitStream.Send(E) = srQueued);
    AssertTrue(FHandler.Stream.Send(TSseEvent.Text('second')) = srQueued);
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertEquals('one event is one chunk', 'id: 1'#10'data: hello'#10#10, Data);
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertEquals('data: second'#10#10, Data);
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestKeepAliveCommentArrives;
var
  C: TRawHttp;
  R: TRawResponse;
  Data: string;
  Last: Boolean;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(50));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertEquals('an idle stream gets the keep-alive comment', ': keep-alive'#10#10, Data);
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestGracefulCloseSendsTheLastChunkAndKeepsTheConnection;
var
  C: TRawHttp;
  R: TRawResponse;
  Data: string;
  Last: Boolean;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    WaitStream.Send(TSseEvent.Text('x'));
    FHandler.Stream.Close;
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertFalse(Last);
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertTrue('Close sent the last chunk', Last);
    FHandler.Release;
    // the request allowed keep-alive, so the connection serves the next request
    C.Send('GET /complete HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(201, R.Status);
    AssertEquals('ok', R.Body);
    AssertFalse(C.Closed);
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestPeerCloseEndsTheStream;
var
  C: TRawHttp;
  R: TRawResponse;
  S: ISseStream;
  Deadline: QWord;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0));
  C := TRawHttp.Create(FServer.Port);
  C.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
  AssertTrue(C.ReadHead(ResponseMs, R));
  S := WaitStream;
  AssertTrue(S.IsOpen);
  C.Free;
  Deadline := GetTickCount64 + ResponseMs;
  while S.IsOpen and (GetTickCount64 < Deadline) do
  begin
    S.Send(TSseEvent.Text('x'));
    Sleep(20);
  end;
  AssertFalse('a closed socket ends the stream', S.IsOpen);
  AssertTrue(S.Send(TSseEvent.Text('late')) = srClosed);
end;

procedure THttp1DetachTest.TestStopEndsTheStream;
var
  C: TRawHttp;
  R: TRawResponse;
  Data: string;
  Last: Boolean;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    WaitStream;
    FServer.Stop;
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertTrue('Stop closes the channel gracefully: the last chunk', Last);
    AssertFalse(FHandler.Stream.IsOpen);
    AssertTrue(C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestLastEventIdReachesTheHandler;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Last-Event-ID: 42' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    WaitStream;
    AssertEquals('42', FHandler.LastEventId);
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestHttp10GetsNoChunkFraming;
var
  C: TRawHttp;
  R: TRawResponse;
  S: string;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /events HTTP/1.0' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    AssertFalse('no chunked coding for HTTP/1.0', R.Chunked);
    WaitStream.Send(TSseEvent.Text('x'));
    S := C.ReadSome(500);
    AssertEquals('the event goes out as it is', 'data: x'#10#10, S);
    FHandler.Stream.Close;
    AssertTrue('the end of the connection ends the body', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestPendingChannelHoldsBytesUntilActivate;
var
  C: TRawHttp;
  R: TRawResponse;
  Data: string;
  Last: Boolean;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /channel HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    AssertEquals('the head comes before any body octet', 200, R.Status);
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertEquals('ab', Data);
    WaitChannel.Send(TBytes.Create(Ord('c')));
    AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
    AssertEquals('c', Data);
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestCompleteSendsAWholeResponse;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /complete HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(201, R.Status);
    AssertEquals('ok', R.Body);
    AssertEquals('2', R.Header('content-length'));
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestTheDetachLimitRefusesTheNextDetach;
var
  A, B: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef).WithSseKeepAlive(0).WithMaxDetachedStreams(1));
  A := TRawHttp.Create(FServer.Port);
  B := TRawHttp.Create(FServer.Port);
  try
    A.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(A.ReadHead(ResponseMs, R));
    WaitStream;
    AssertEquals(1, FServer.Stats.DetachedStreams);
    B.Send('GET /events HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('the refused detach ends in an error answer', B.ReadResponse(False, ResponseMs, R));
    AssertEquals(500, R.Status);
    AssertEquals(1, FServer.Stats.DetachedStreams);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure THttp1DetachTest.TestAbortCutsTheConnection;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /channel HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadHead(ResponseMs, R));
    WaitChannel.Close(ccAbort);
    AssertTrue('an abort closes the connection', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1DetachTest.TestSendDuringActivateNeverOvertakesTheHead;
var
  I: Integer;
  C: TRawHttp;
  R: TRawResponse;
  Total: Integer;
  Data: string;
  Last: Boolean;
begin
  StartServer(LiveFactory(FHandlerRef));
  for I := 1 to 20 do
  begin
    C := TRawHttp.Create(FServer.Port);
    try
      C.Send('GET /race HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
      // the first octets on the wire are the status line, never a chunk
      AssertTrue('the head comes first in round ' + IntToStr(I), C.ReadHead(ResponseMs, R));
      AssertEquals(200, R.Status);
      Total := 0;
      repeat
        AssertTrue(C.ReadChunk(ResponseMs, Data, Last));
        Inc(Total, Length(Data));
      until Last;
      AssertEquals('no byte was lost or doubled in round ' + IntToStr(I), 500, Total);
    finally
      C.Free;
    end;
  end;
end;

initialization
  RegisterTest(THttp1DetachTest);

end.
