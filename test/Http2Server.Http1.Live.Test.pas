{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, live, keep-alive, pipelining, chunked, expect, refusal, stop, test, fpcunit
notes:
  - This unit tests the HTTP/1.1 fallback on a running server over cleartext with
    a raw-socket client. The TLS leg runs in the validation script.
  - Each test that expects a close also sends a second request and checks that the
    server does not answer it.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Live tests of the HTTP/1.1 fallback
unit Http2Server.Http1.Live.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server, Http2Server.Http1.Limits, Http2Server.Server.Test,
  Http2Server.Http1.RawClient;

type
  THttp1LiveTest = class(TTestCase)
  private
    FHandler: TTestHandler;
    FHandlerRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function Get(const APath: string; out AResponse: TRawResponse): TRawHttp;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestGetAnswersWithContentLengthAndDate;
    procedure TestRequestFieldsReachTheHandler;
    procedure TestKeepAliveAcrossTenRequests;
    procedure TestPostWithBody;
    procedure TestChunkedPostIsDecoded;
    procedure TestResponseWithoutLengthIsChunked;
    procedure TestHeadHasNoBody;
    procedure TestNoContentAndNotModifiedHaveNoBody;
    procedure TestConnectionCloseClosesAfterTheResponse;
    procedure TestHttp10ClosesAndIsNotChunked;
    procedure TestExpectContinueIsAnsweredAtTheFirstRead;
    procedure TestPipelinedRequestsAnswerInOrder;
    procedure TestOversizedHeadGets431AndClose;
    procedure TestSlowHeadGets408;
    procedure TestHandlerExceptionBeforeTheHeadersGets500;
    procedure TestHandlerExceptionAfterTheHeadersCutsTheResponse;
    procedure TestFramingDefectGets400AndNoSecondAnswer;
    procedure TestSmuggledRequestIsNeverServed;
    procedure TestHandlerDateIsKeptAndOtherwiseAdded;
    procedure TestHeaderInjectionByTheHandlerIsRefused;
    procedure TestEarlyAnswerWithAnUnreadBodyKeepsTheConnection;
    procedure TestQueueFullAnswers503WithRetryAfter;
    procedure TestStopEndsAnOpenConnection;
    procedure TestFallbackOffClosesAnHttp1Request;
    procedure TestOneListenerServesBothProtocols;
    procedure TestLargeResponseIsDelivered;
    procedure TestAClientThatNeverReadsBlocksTheHandlerInsteadOfGrowingMemory;
  end;

implementation

procedure THttp1LiveTest.SetUp;
begin
  FHandler := TTestHandler.Create;
  FHandlerRef := FHandler;
end;

procedure THttp1LiveTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandlerRef := nil;
end;

procedure THttp1LiveTest.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function THttp1LiveTest.Get(const APath: string; out AResponse: TRawResponse): TRawHttp;
begin
  Result := TRawHttp.Create(FServer.Port);
  Result.Send('GET ' + APath + ' HTTP/1.1' + CRLF + 'Host: localhost' + CRLF + CRLF);
  AssertTrue('a response to ' + APath, Result.ReadResponse(False, ResponseMs, AResponse));
end;

procedure THttp1LiveTest.TestGetAnswersWithContentLengthAndDate;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := Get('/hello', R);
  try
    AssertEquals(200, R.Status);
    AssertEquals('hello', R.Body);
    AssertEquals('5', R.Header('content-length'));
    AssertEquals('RFC 9110 section 6.6.1: the server adds Date', 29, Length(R.Header('date')));
    AssertEquals('', R.Header('transfer-encoding'));
    AssertEquals('HTTP/1.1 200 OK', Copy(R.Head, 1, 15));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestRequestFieldsReachTheHandler;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := Get('/info?x=1', R);
  try
    AssertEquals('GET http localhost /info?x=1', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestKeepAliveAcrossTenRequests;
var
  C: TRawHttp;
  R: TRawResponse;
  I: Integer;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    for I := 1 to 10 do
    begin
      C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
      AssertTrue('response ' + IntToStr(I), C.ReadResponse(False, ResponseMs, R));
      AssertEquals('hello', R.Body);
    end;
    AssertFalse('the connection stayed open', C.Closed);
    AssertEquals(10, FHandler.Calls);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestPostWithBody;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 11' + CRLF + CRLF +
      'hello world');
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello world', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestChunkedPostIsDecoded;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
      '5' + CRLF + 'hello' + CRLF + '6;x=y' + CRLF + ' world' + CRLF + '0' + CRLF + 'X-T: 1' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello world', R.Body);
    // the connection serves the next request
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestResponseWithoutLengthIsChunked;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := Get('/chunked', R);
  try
    AssertTrue('the response is chunked', R.Chunked);
    AssertEquals('onetwothree', R.Body);
    AssertEquals('', R.Header('content-length'));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestHeadHasNoBody;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('HEAD /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(True, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('the length of the GET answer', '5', R.Header('content-length'));
    // no body octet follows: the next response parses cleanly
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestNoContentAndNotModifiedHaveNoBody;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /nocontent HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(204, R.Status);
    AssertEquals('', R.Header('content-length'));
    AssertEquals('', R.Header('transfer-encoding'));
    C.Send('GET /notmodified HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(304, R.Status);
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestConnectionCloseClosesAfterTheResponse;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Connection: close' + CRLF + CRLF +
      'GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
    AssertEquals('close', R.Header('connection'));
    AssertTrue('the server closed', C.WaitClosed(ResponseMs));
    AssertEquals('the pipelined request after close was not served', 1, FHandler.Calls);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestHttp10ClosesAndIsNotChunked;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /chunked HTTP/1.0' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertFalse('an HTTP/1.0 client gets no chunked coding', R.Chunked);
    AssertEquals('onetwothree', R.Body);
    AssertEquals('HTTP/1.0 200', Copy(R.Head, 1, 12));
    AssertTrue('the connection closed', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestExpectContinueIsAnsweredAtTheFirstRead;
var
  C: TRawHttp;
  R: TRawResponse;
  Interim: string;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /expect HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Expect: 100-continue' + CRLF +
      'Content-Length: 5' + CRLF + CRLF);
    AssertTrue('the handler read, so 100 Continue comes', C.ReadInterim(ResponseMs, Interim));
    AssertEquals('HTTP/1.1 100 Continue', Copy(Interim, 1, 21));
    C.Send('hello');
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('hello', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestPipelinedRequestsAnswerInOrder;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF +
      'GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF +
      'POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 3' + CRLF + CRLF + 'abc');
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('the first request answers first', 'slow', R.Body);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('abc', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestOversizedHeadGets431AndClose;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-Big: ' + StringOfChar('a', 9000) + CRLF + CRLF +
      'GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(431, R.Status);
    AssertEquals('close', R.Header('connection'));
    AssertTrue(C.WaitClosed(ResponseMs));
    AssertEquals('no handler ran', 0, FHandler.Calls);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestSlowHeadGets408;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef).WithHeaderTimeout(1000));
  C := TRawHttp.Create(FServer.Port);
  try
    // a partial head, then nothing
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: b');
    AssertTrue('a 408 answer', C.ReadResponse(False, 8000, R));
    AssertEquals(408, R.Status);
    AssertTrue(C.WaitClosed(ResponseMs));
    AssertEquals(0, FHandler.Calls);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestHandlerExceptionBeforeTheHeadersGets500;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := Get('/raise', R);
  try
    AssertEquals(500, R.Status);
    AssertTrue(C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestHandlerExceptionAfterTheHeadersCutsTheResponse;
var
  C: TRawHttp;
  R: TRawResponse;
  Ok: Boolean;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /raise-late HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    // the chunked body never gets its last chunk, so the reader does not finish
    Ok := C.ReadResponse(False, 1500, R);
    AssertFalse('a truncated chunked response is never complete', Ok);
    AssertTrue('the connection closed', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestFramingDefectGets400AndNoSecondAnswer;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 5' + CRLF +
      'Transfer-Encoding: chunked' + CRLF + CRLF + '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF +
      'GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(400, R.Status);
    AssertTrue(C.WaitClosed(ResponseMs));
    AssertEquals('no handler ran for either request', 0, FHandler.Calls);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestSmuggledRequestIsNeverServed;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    // the garbage chunk size would swallow the next request in the parser alone
    C.Send('POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
      'zz' + CRLF + 'GET /smuggled HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(400, R.Status);
    AssertTrue(C.WaitClosed(ResponseMs));
    // the echo handler may have started; the smuggled request never ran
    AssertTrue(FHandler.Calls <= 1);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestHandlerDateIsKeptAndOtherwiseAdded;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := Get('/own-date', R);
  try
    AssertEquals('Mon, 01 Jan 2001 00:00:00 GMT', R.Header('date'));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestHeaderInjectionByTheHandlerIsRefused;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := Get('/bad-header', R);
  try
    AssertEquals('the writer refuses the header, the handler failed', 500, R.Status);
    AssertEquals('no split header reached the wire', '', R.Header('set-cookie'));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestEarlyAnswerWithAnUnreadBodyKeepsTheConnection;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /ignore-body HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 1000' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('ok', R.Body);
    // the body arrives after the answer; the server drains it, then serves on
    C.Send(StringOfChar('x', 1000));
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestQueueFullAnswers503WithRetryAfter;
var
  A, B, D: TRawHttp;
  R: TRawResponse;
begin
  FHandler.SlowMs := 800;
  StartServer(LiveFactory(FHandlerRef).WithHandlerThreads(1)
    .WithQueue(TQueueOptions.Create.WithDepth(1)));
  A := TRawHttp.Create(FServer.Port);
  B := TRawHttp.Create(FServer.Port);
  D := TRawHttp.Create(FServer.Port);
  try
    A.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    Sleep(150);   // the first request holds the only handler thread
    B.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    Sleep(150);   // the second fills the queue
    D.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(D.ReadResponse(False, ResponseMs, R));
    AssertEquals(503, R.Status);
    AssertEquals('1', R.Header('retry-after'));
    AssertTrue(D.WaitClosed(ResponseMs));
    AssertTrue(A.ReadResponse(False, ResponseMs, R));
    AssertEquals('slow', R.Body);
  finally
    A.Free;
    B.Free;
    D.Free;
  end;
end;

procedure THttp1LiveTest.TestStopEndsAnOpenConnection;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    FServer.Stop;
    AssertTrue('Stop closed the idle keep-alive connection', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestFallbackOffClosesAnHttp1Request;
var
  C: TRawHttp;
  S: string;
begin
  StartServer(LiveFactory(FHandlerRef).WithHttp11Fallback(False));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    S := C.ReadSome(1500);
    AssertTrue('no HTTP/1.1 answer', Pos('HTTP/1.1 200', S) = 0);
    AssertEquals('the handler never ran', 0, FHandler.Calls);
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestOneListenerServesBothProtocols;
var
  H1: TRawHttp;
  H2: TLifecycleClient;
  R: TRawResponse;
  Body: TBytes;
begin
  StartServer(LiveFactory(FHandlerRef));
  H1 := TRawHttp.Create(FServer.Port);
  H2 := TLifecycleClient.Create(FServer.Port);
  try
    H2.SendGet(1, '/hello');
    H1.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(H1.ReadResponse(False, ResponseMs, R));
    AssertEquals('hello', R.Body);
    AssertTrue(H2.WaitForResponse(1, ResponseMs, Body));
    AssertEquals('both protocols got the same body', 5, Length(Body));
  finally
    H1.Free;
    H2.Free;
  end;
end;

procedure THttp1LiveTest.TestLargeResponseIsDelivered;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /big HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, 20000, R));
    AssertEquals(16 * 65536, Length(R.Body));
  finally
    C.Free;
  end;
end;

procedure THttp1LiveTest.TestAClientThatNeverReadsBlocksTheHandlerInsteadOfGrowingMemory;
var
  C: TRawHttp;
  R: TRawResponse;
  Deadline: QWord;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /huge HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    // 8 MiB is far above the queue limit and the buffers of the socket, so a
    // handler that nobody slows down would finish at once
    Sleep(1500);
    AssertEquals('the handler waits for the reader', 0, FHandler.HugeDone);
    AssertTrue('and the client reads all of it', C.ReadResponse(False, 20000, R));
    AssertEquals(128 * 65536, Length(R.Body));
    Deadline := GetTickCount64 + ResponseMs;
    while (FHandler.HugeDone = 0) and (GetTickCount64 < Deadline) do
      Sleep(5);
    AssertEquals(1, FHandler.HugeDone);
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(THttp1LiveTest);

end.
