{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, environment, counters, observer, watchdog, init timeout
notes:
  - The environment is what a session needs from the server. It holds the options, the
    clock, the session counters, the report to the observer and the watchdog of the
    time limit of Init.
  - The watchdog is one thread for the whole server and not one for each session.
    Init may block every thread of the streaming pool, so a timer on the pool could
    not fire. The watchdog starts when the first session waits for Init, and it ends
    with the environment.
---
}
/// The server-side environment of the WebSocket sessions
unit Http2Server.Ws.Environment;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Limits, Http2Server.Observer,
  Http2Server.Ws.Options, Http2Server.Ws.Types;

type
  /// a report to the observer of the server
  TWsReportProc = procedure(const AEvent: TServerEvent) of object;

  TWsEnvironment = class;

  /// the watchdog thread of the time limit of Init
  TWsWatchdog = class(TThread)
  private
    FOwner: TWsEnvironment;
  protected
    procedure Execute; override;
  public
    constructor Create(const AOwner: TWsEnvironment);
  end;

  TWsEnvironment = class(TInterfacedObject, IWsEnvironment)
  private
    type
      TWatch = record
        Session: IWsInitWatch;
        DeadlineMs: QWord;
      end;
  private
    FOptions: TWsOptions;
    FClock: IMonotonicClock;
    FReport: TWsReportProc;
    FLock: TCriticalSection;
    FWake: PRTLEvent;
    FNextId: Int64;
    FOpen: Integer;
    FCounts: array[TWsCounter] of Int64;
    FWatches: TList<TWatch>;
    FDog: TWsWatchdog;
    FStopping: Boolean;
    procedure Sweep;
  public
    constructor Create(const AOptions: TWsOptions; const AClock: IMonotonicClock;
      const AReport: TWsReportProc);
    destructor Destroy; override;
    /// stop the watchdog; the sessions keep running
    procedure Stop;
    /// copy the counters into AStats
    procedure FillStats(var AStats: TServerStats);

    // IWsEnvironment
    function Options: TWsOptions;
    function Clock: IMonotonicClock;
    function NextId: Int64;
    procedure Report(const AKind: TServerEventKind; const ACode: Integer;
      const ADetail: string);
    procedure SessionOpened;
    procedure SessionClosed;
    procedure Count(const AWhat: TWsCounter; const AValue: Int64);
    procedure WatchInit(const ASession: IWsInitWatch; const ADeadlineMs: QWord);
    procedure UnwatchInit(const ASession: IWsInitWatch);
  end;

implementation

{ TWsWatchdog }

constructor TWsWatchdog.Create(const AOwner: TWsEnvironment);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TWsWatchdog.Execute;
begin
  while not Terminated do
  begin
    FOwner.Sweep;
    RTLEventWaitFor(FOwner.FWake, 50);
  end;
end;

{ TWsEnvironment }

constructor TWsEnvironment.Create(const AOptions: TWsOptions;
  const AClock: IMonotonicClock; const AReport: TWsReportProc);
begin
  inherited Create;
  FOptions := AOptions;
  FClock := AClock;
  FReport := AReport;
  FLock := TCriticalSection.Create;
  FWake := RTLEventCreate;
  FWatches := TList<TWatch>.Create;
end;

destructor TWsEnvironment.Destroy;
begin
  Stop;
  FWatches.Free;
  RTLEventDestroy(FWake);
  FLock.Free;
  inherited Destroy;
end;

procedure TWsEnvironment.Stop;
var
  Dog: TWsWatchdog;
begin
  FLock.Acquire;
  try
    FStopping := True;
    Dog := FDog;
    FDog := nil;
  finally
    FLock.Release;
  end;
  if Dog <> nil then
  begin
    Dog.Terminate;
    RTLEventSetEvent(FWake);
    Dog.WaitFor;
    Dog.Free;
  end;
end;

procedure TWsEnvironment.Sweep;
var
  Due: TArray<IWsInitWatch>;
  I, N: Integer;
  Now_: QWord;
begin
  Due := nil;
  N := 0;
  Now_ := GetTickCount64;
  FLock.Acquire;
  try
    for I := FWatches.Count - 1 downto 0 do
      if FWatches[I].DeadlineMs <= Now_ then
      begin
        SetLength(Due, N + 1);
        Due[N] := FWatches[I].Session;
        Inc(N);
        FWatches.Delete(I);
      end;
  finally
    FLock.Release;
  end;
  // a session answers the upgrade outside the lock
  for I := 0 to N - 1 do
    try
      Due[I].InitTimedOut;
    except
      ;   // the watchdog survives a session that fails
    end;
end;

function TWsEnvironment.Options: TWsOptions;
begin
  Result := FOptions;
end;

function TWsEnvironment.Clock: IMonotonicClock;
begin
  Result := FClock;
end;

function TWsEnvironment.NextId: Int64;
begin
  FLock.Acquire;
  try
    Inc(FNextId);
    Result := FNextId;
  finally
    FLock.Release;
  end;
end;

procedure TWsEnvironment.Report(const AKind: TServerEventKind; const ACode: Integer;
  const ADetail: string);
var
  E: TServerEvent;
begin
  if not Assigned(FReport) then
    Exit;
  E := Default(TServerEvent);
  E.Kind := AKind;
  E.Detail := ADetail;
  E.WsCode := ACode;
  FReport(E);
end;

procedure TWsEnvironment.SessionOpened;
begin
  FLock.Acquire;
  try
    Inc(FOpen);
  finally
    FLock.Release;
  end;
end;

procedure TWsEnvironment.SessionClosed;
begin
  FLock.Acquire;
  try
    if FOpen > 0 then
      Dec(FOpen);
  finally
    FLock.Release;
  end;
end;

procedure TWsEnvironment.Count(const AWhat: TWsCounter; const AValue: Int64);
begin
  FLock.Acquire;
  try
    Inc(FCounts[AWhat], AValue);
  finally
    FLock.Release;
  end;
end;

procedure TWsEnvironment.FillStats(var AStats: TServerStats);
begin
  FLock.Acquire;
  try
    AStats.WsSessions := FOpen;
    AStats.WsMessagesIn := FCounts[wcMessagesIn];
    AStats.WsMessagesOut := FCounts[wcMessagesOut];
    AStats.WsBytesIn := FCounts[wcBytesIn];
    AStats.WsBytesOut := FCounts[wcBytesOut];
    AStats.WsProtocolErrors := FCounts[wcProtocolErrors];
    AStats.WsPingTimeouts := FCounts[wcPingTimeouts];
  finally
    FLock.Release;
  end;
end;

procedure TWsEnvironment.WatchInit(const ASession: IWsInitWatch; const ADeadlineMs: QWord);
var
  W: TWatch;
begin
  FLock.Acquire;
  try
    if FStopping then
      Exit;
    W.Session := ASession;
    W.DeadlineMs := ADeadlineMs;
    FWatches.Add(W);
    if FDog = nil then
      FDog := TWsWatchdog.Create(Self);
  finally
    FLock.Release;
  end;
end;

procedure TWsEnvironment.UnwatchInit(const ASession: IWsInitWatch);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := FWatches.Count - 1 downto 0 do
      if FWatches[I].Session = ASession then
        FWatches.Delete(I);
  finally
    FLock.Release;
  end;
end;

end.
