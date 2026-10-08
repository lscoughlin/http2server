{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, slow handler, queue refusal
notes:
  - This example runs a handler that sleeps, on a small handler pool.
  - A burst of requests then fills the queue, and the server refuses the
    surplus with the configured refusal mode.  The observer counts them.
  - The example shows the admission queue as the answer to a request flood.
---
}
/// A server with a slow handler and a small queue
// - the program shows the queue refusal of the admission pool
program slow_handler;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  mormot.core.base,
  Http2Server;

const
  /// how long one handler call blocks
  HandlerMs = 500;
  /// how many handler threads run
  HandlerThreads = 2;

/// the raw bytes of a text literal, in the default code page
function BytesOf(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

type
  /// the handler that sleeps before it answers
  TSlowHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the observer that reports the counters
  TCountingObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FRefused: Integer;
    FTimedOut: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    property Refused: Integer read FRefused;
    property TimedOut: Integer read FTimedOut;
  end;

procedure TSlowHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Text: TBytes;
begin
  Sleep(HandlerMs);
  Text := BytesOf('a slow answer for ' + ARequest.Path + sLineBreak);
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Text);
  AResponse.Finish;
end;

constructor TCountingObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TCountingObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TCountingObserver.OnEvent(const AEvent: TServerEvent);
begin
  // the observer runs on the thread that raised the event
  case AEvent.Kind of
    seQueueFull:
      begin
        FLock.Acquire;
        try
          Inc(FRefused);
        finally
          FLock.Release;
        end;
      end;
    seRequestTimedOut:
      begin
        FLock.Acquire;
        try
          Inc(FTimedOut);
        finally
          FLock.Release;
        end;
      end;
  end;
end;

var
  Observer: TCountingObserver;
  Server: IHttp2Server;
  Stats: TServerStats;
  Line: string;
begin
  Observer := TCountingObserver.Create;
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(8080)
    .WithClearTextAllowed(True)
    .WithHandler(TSlowHandler.Create)
    .WithHandlerThreads(HandlerThreads)
    .WithQueue(TQueueOptions.Create.WithDepth(4).WithMaxWaitMs(2000))
    .Build(Observer);
  Server.Start;
  Writeln('the server listens on port ', Server.Port, ' (h2c)');
  Writeln('one handler call takes ', HandlerMs, ' ms on ',
    HandlerThreads, ' handler threads');
  Writeln('press Enter to stop');
  Readln(Line);
  Stats := Server.Stats;
  Writeln('refused in the queue: ', Stats.RefusedTotal);
  Writeln('timed out in the queue: ', Stats.TimedOutTotal);
  Server.Stop;
end.
