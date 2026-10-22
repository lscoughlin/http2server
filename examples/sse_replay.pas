{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, http1, example, sse, server-sent events, last-event-id, replay
notes:
  - This example serves the path /events on port 8085. The stream carries the events
    1 to 1000, each with its number as the event ID and as the data. A client that
    reconnects with Last-Event-ID n receives the events from n plus 1.
  - The handler sends the events from its own thread and ends the stream after the
    last one. A full queue makes the handler wait a little and try again.
  - The example serves HTTP/1.1 and HTTP/2 clients. The commands curl -N
    http://127.0.0.1:8085/events and the same with --http2-prior-knowledge read the stream.
  - The path /hold opens a stream that sends no event and stays open. The limit of detached
    streams is 30000, so a load run can hold many of them.
  - The optional arguments are the host and the port. The port 0 picks a free port.
---
}
/// A replayable event stream of 1000 numbered events
program sse_replay;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  mormot.core.base,
  Http2Server;

const
  LastEvent = 1000;

type
  TReplayHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure TReplayHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Stream: ISseStream;
  E: TSseEvent;
  N: Integer;
  R: TSendResult;
begin
  if ARequest.Path = '/hold' then
  begin
    StartSse(ARequest, AResponse);
    Exit;
  end;
  if ARequest.Path <> '/events' then
  begin
    AResponse.SendHeaders(404, nil, True);
    Exit;
  end;
  Stream := StartSse(ARequest, AResponse);
  N := StrToIntDef(string(Stream.LastEventId), 0) + 1;
  while (N <= LastEvent) and Stream.IsOpen do
  begin
    E := TSseEvent.Text(UTF8String(IntToStr(N)));
    E.Id := UTF8String(IntToStr(N));
    R := Stream.Send(E);
    if R = srFull then
      Sleep(2)
    else
      Inc(N);
    if R = srClosed then
      Break;
  end;
  Stream.Close;
end;

var
  Server: IHttp2Server;
  Line, Host: string;
  Port: Integer;
begin
  Host := '127.0.0.1';
  if ParamCount >= 1 then
    Host := ParamStr(1);
  Port := 8085;
  if ParamCount >= 2 then
    Port := StrToIntDef(ParamStr(2), 8085);
  Server := THttp2ServerFactory.Create
    .WithHost(Host)
    .WithPort(Port)
    .WithClearTextAllowed(True)
    .WithMaxDetachedStreams(30000)
    .WithHandler(TReplayHandler.Create)
    .Build;
  Server.Start;
  WriteLn('SSE replay on http://', Host, ':', Server.Port, '/events ; press Enter to stop');
  Flush(Output);
  ReadLn(Line);
  Server.Stop;
end.
