{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, sse, server-sent events, fan-out
notes:
  - This example serves any number of event streams on port 8083. One producer
    thread sends the same event to every open stream once a second.
  - The handler opens the stream and returns at once. The stream costs no
    handler thread.
  - A client can read the stream with the command curl --http2-prior-knowledge -N
    http://127.0.0.1:8083/feed.
---
}
/// Several event streams, one producer
program sse_fanout;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  mormot.core.base,
  Http2Server;

type
  /// the streams that the timer thread feeds
  TClockHub = class
  private
    FLock: TCriticalSection;
    FStreams: TList<ISseStream>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AStream: ISseStream);
    /// send AText to every open stream and forget the closed ones
    procedure Broadcast(const AText: string);
  end;

  THubThread = class(TThread)
  private
    FHub: TClockHub;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHub: TClockHub);
  end;

  TClockHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FHub: TClockHub;
  public
    constructor Create(const AHub: TClockHub);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

constructor TClockHub.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStreams := TList<ISseStream>.Create;
end;

destructor TClockHub.Destroy;
begin
  FStreams.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TClockHub.Add(const AStream: ISseStream);
begin
  FLock.Acquire;
  try
    FStreams.Add(AStream);
  finally
    FLock.Release;
  end;
end;

procedure TClockHub.Broadcast(const AText: string);
var
  I: Integer;
  E: TSseEvent;
begin
  E := TSseEvent.Text(UTF8String(AText));
  E.Event := 'tick';
  FLock.Acquire;
  try
    for I := FStreams.Count - 1 downto 0 do
    begin
      // a full stream drops this tick; a closed stream leaves the list
      if FStreams[I].Send(E) = srClosed then
        FStreams.Delete(I);
    end;
  finally
    FLock.Release;
  end;
end;

constructor THubThread.Create(const AHub: TClockHub);
begin
  FHub := AHub;
  inherited Create(False);
end;

procedure THubThread.Execute;
begin
  while not Terminated do
  begin
    Sleep(1000);
    FHub.Broadcast(FormatDateTime('hh:nn:ss', Now));
  end;
end;

constructor TClockHandler.Create(const AHub: TClockHub);
begin
  inherited Create;
  FHub := AHub;
end;

procedure TClockHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Stream: ISseStream;
begin
  // the handler returns at once; the hub thread owns the stream from now on
  Stream := StartSse(ARequest, AResponse);
  FHub.Add(Stream);
end;

var
  Hub: TClockHub;
  Ticker: THubThread;
  Server: IHttp2Server;
  Line: string;
begin
  Hub := TClockHub.Create;
  Ticker := THubThread.Create(Hub);
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(8083)
    .WithClearTextAllowed(True)
    .WithHandler(TClockHandler.Create(Hub))
    .Build;
  Server.Start;
  WriteLn('event stream on http://127.0.0.1:', Server.Port, '/feed; press Enter to stop');
  ReadLn(Line);
  Ticker.Terminate;
  Ticker.WaitFor;
  Ticker.Free;
  Server.Stop;
  Hub.Free;
end.
