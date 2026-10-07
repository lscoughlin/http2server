{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, observer, events, statistics
notes:
  - This unit holds the observer contract and the statistics record of the
    server.
  - An observer runs on the thread that raised the event, so a slow observer
    slows that thread.  The default observer does nothing.
  - The counters are truthful: every total counts a real event and no number
    is guessed.
---
}
/// Server observation
// - The server raises one event per state change that a caller acts on.  The
//   observer receives the event on the thread that raised it, which is an IO
//   thread, a handler-pool thread, or the caller of Start and Stop.
// - The default observer, TNullServerObserver, does nothing, so the server
//   carries no cost when no observer is set.
unit Http2Server.Observer;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Errors, Http2Server.Limits;

type
  /// one state change of the server
  TServerEventKind = (
    /// a connection arrived and the socket is accepted
    seConnectionAccepted,
    /// a connection ended
    seConnectionClosed,
    /// a request header block ended and the request is complete
    seStreamOpened,
    /// a stream was refused, because the queue was full or the stream limit
    /// was reached
    seStreamRefused,
    /// the peer reset a stream, or the server reset it
    seStreamReset,
    /// a handler finished its stream
    seStreamCompleted,
    /// an offer to the request queue was refused, because the queue was full
    seQueueFull,
    /// a queued request passed its wait limit and never reached a handler
    seRequestTimedOut,
    /// a token bucket tripped
    seBucketTripped,
    /// the core sent a GOAWAY frame
    seGoAwaySent,
    /// a handler raised an exception
    seHandlerException);

  /// one event of the server
  TServerEvent = record
    /// what changed
    Kind: TServerEventKind;
    /// the stream the event belongs to, or 0 for a connection event
    StreamId: LongWord;
    /// the bucket kind, for seBucketTripped
    LimitKind: TLimitKind;
    /// the protocol error code, for seGoAwaySent and seStreamReset
    ErrorCode: THttp2ErrorCode;
    /// a short human-readable detail; the observer never parses it
    Detail: string;
  end;

  /// the receiver of server events
  ///
  /// OnEvent runs on the thread that raised the event.  A slow OnEvent slows
  /// that thread, and on an IO thread it can also delay the wake-up of a
  /// connection.  An observer that blocks belongs on its own queue.
  IHttp2ServerObserver = interface
    ['{7E1F0C11-0007-4A11-9C72-000000000507}']
    procedure OnEvent(const AEvent: TServerEvent);
  end;

  /// the observer that does nothing
  TNullServerObserver = class(TInterfacedObject, IHttp2ServerObserver)
  public
    procedure OnEvent(const AEvent: TServerEvent);
  end;

  /// the live counters of the server
  ///
  /// The gauges count what the server holds now.  The totals count every
  /// event since the server was built and never decrease.
  TServerStats = record
    /// handlers that run now
    BusyHandlers: Integer;
    /// requests that wait in the queue now
    QueueLength: Integer;
    /// connections that are open now
    OpenConnections: Integer;
    /// streams that are open now
    OpenStreams: Integer;
    /// requests refused because the queue was full
    RefusedTotal: Int64;
    /// queued requests that passed their wait limit
    TimedOutTotal: Int64;
    /// streams the peer or the server reset
    ResetTotal: Int64;
    /// bucket trips
    TrippedTotal: Int64;
  end;

implementation

{ TNullServerObserver }

procedure TNullServerObserver.OnEvent(const AEvent: TServerEvent);
begin
  // the default observer discards every event
end;

end.
