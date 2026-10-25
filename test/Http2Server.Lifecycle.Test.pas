{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: stop, drain, observer, start failure, lifecycle
notes:
  - These tests hold the stop and start rules of the server on a live socket.
  - A stop refuses new connections, closes idle HTTP/1.1 connections, lets a
    running request finish, and ends within one deadline.
  - An observer that raises must not shrink the handler pool.
  - A start that fails leaves nothing bound.
---
}
unit Http2Server.Lifecycle.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server, Http2Server.Errors, Http2Server.Http1.RawClient,
  Http2Server.WsHardening.Test;

type
  /// an observer that raises on every event
  TRaisingObserver = class(TInterfacedObject, IHttp2ServerObserver)
  public
    procedure OnEvent(const AEvent: TServerEvent);
  end;

  TLifecycleTest = class(TTestCase)
  private
    FHandler: TTestHandler;
    FHandlerRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure DoStop;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestIdleStopIsQuick;
    procedure TestStopClosesAnIdleKeepAliveConnection;
    procedure TestStopWaitsForARunningRequestAndSaysClose;
    procedure TestNewConnectionIsRefusedWhileStopping;
    procedure TestStopCancelsPastTheGracefulTimeout;
    procedure TestObserverThatRaisesDoesNotShrinkThePool;
    procedure TestFailedStartLeavesNothingBound;
  end;

implementation

procedure TRaisingObserver.OnEvent(const AEvent: TServerEvent);
begin
  raise Exception.Create('the observer fails');
end;

procedure TLifecycleTest.SetUp;
begin
  FHandler := TTestHandler.Create;
  FHandlerRef := FHandler;
end;

procedure TLifecycleTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandlerRef := nil;
end;

procedure TLifecycleTest.DoStop;
begin
  FServer.Stop;
end;

procedure TLifecycleTest.TestIdleStopIsQuick;
var
  Started: QWord;
begin
  FServer := LiveFactory(FHandlerRef).Build;
  FServer.Start;
  Started := GetTickCount64;
  FServer.Stop;
  AssertTrue('SRV-1: an idle stop ends well before the graceful timeout',
    GetTickCount64 - Started < 250);
end;

procedure TLifecycleTest.TestStopClosesAnIdleKeepAliveConnection;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  FServer := LiveFactory(FHandlerRef).Build;
  FServer.Start;
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertFalse('the connection is kept', R.Closed);
    FServer.Stop;
    AssertTrue('SRV-1: the idle connection closes', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure TLifecycleTest.TestStopWaitsForARunningRequestAndSaysClose;
var
  C: TRawHttp;
  R: TRawResponse;
  Stopper: TProcThread;
  Deadline: QWord;
begin
  FHandler.SlowMs := 300;
  FServer := LiveFactory(FHandlerRef).WithGracefulStopTimeout(3000).Build;
  FServer.Start;
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    Deadline := GetTickCount64 + ResponseMs;
    while (FHandler.Calls = 0) and (GetTickCount64 < Deadline) do
      Sleep(5);
    Stopper := TProcThread.Create(DoStop);
    try
      AssertTrue('the running request is answered', C.ReadResponse(False, ResponseMs, R));
      AssertEquals('slow', R.Body);
      AssertEquals('SRV-1: the answer says close', 'close', LowerCase(R.Header('connection')));
      AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
      Stopper.Done.WaitFor(ResponseMs);
    finally
      Stopper.WaitFor;
      Stopper.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TLifecycleTest.TestNewConnectionIsRefusedWhileStopping;
var
  C, Late: TRawHttp;
  R: TRawResponse;
  Stopper: TProcThread;
  Deadline: QWord;
  Served: Boolean;
begin
  FHandler.SlowMs := 800;
  FServer := LiveFactory(FHandlerRef).WithGracefulStopTimeout(3000).Build;
  FServer.Start;
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    Deadline := GetTickCount64 + ResponseMs;
    while (FHandler.Calls = 0) and (GetTickCount64 < Deadline) do
      Sleep(5);
    Stopper := TProcThread.Create(DoStop);
    try
      Sleep(150);
      Served := False;
      try
        Late := TRawHttp.Create(FServer.Port);
        try
          Late.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
          Served := Late.ReadResponse(False, 1500, R) and (R.Status = 200);
        finally
          Late.Free;
        end;
      except
        // a refused connect is a good answer too
        Served := False;
      end;
      AssertFalse('SRV-1: a connection that arrives during the stop is not served', Served);
      AssertTrue(C.ReadResponse(False, ResponseMs, R));
    finally
      Stopper.WaitFor;
      Stopper.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TLifecycleTest.TestStopCancelsPastTheGracefulTimeout;
var
  C: TRawHttp;
  Started, Deadline: QWord;
begin
  FHandler.SlowMs := 4000;
  FServer := LiveFactory(FHandlerRef).WithGracefulStopTimeout(300).Build;
  FServer.Start;
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    Deadline := GetTickCount64 + ResponseMs;
    while (FHandler.Calls = 0) and (GetTickCount64 < Deadline) do
      Sleep(5);
    Started := GetTickCount64;
    FServer.Stop;
    AssertTrue('SRV-4: the stop ends within one deadline and a margin',
      GetTickCount64 - Started < 2500);
  finally
    C.Free;
  end;
end;

procedure TLifecycleTest.TestObserverThatRaisesDoesNotShrinkThePool;
var
  I: Integer;
  C: TRawHttp;
  R: TRawResponse;
  Observer: IHttp2ServerObserver;
begin
  Observer := TRaisingObserver.Create;
  FServer := LiveFactory(FHandlerRef).Build(Observer);
  FServer.Start;
  for I := 1 to 8 do
  begin
    C := TRawHttp.Create(FServer.Port);
    try
      C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Connection: close' + CRLF + CRLF);
      AssertTrue('SRV-3: request ' + IntToStr(I) + ' is answered',
        C.ReadResponse(False, ResponseMs, R));
      AssertEquals(200, R.Status);
    finally
      C.Free;
    end;
  end;
end;

procedure TLifecycleTest.TestFailedStartLeavesNothingBound;
var
  Tls: TTlsServerOptions;
  Failed: Boolean;
  Server: IHttp2Server;
begin
  Tls := TTlsServerOptions.Create
    .WithCertificateFile('/nonexistent/cert.pem')
    .WithKeyFile('/nonexistent/key.pem');
  Server := LiveFactory(FHandlerRef).WithTls(Tls).Build;
  Failed := False;
  try
    Server.Start;
  except
    Failed := True;
  end;
  AssertTrue('Start raises', Failed);
  AssertFalse('SRV-6: the server is not running', Server.IsRunning);
  Failed := False;
  try
    Server.Start;
  except
    Failed := True;
  end;
  AssertTrue('a second Start raises again', Failed);
  Server.Stop;
end;

initialization
  RegisterTest(TLifecycleTest);

end.
