{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, counters, connections, resets, bucket trips, handshakes
notes:
  - This unit holds the counters of the async server. An IO thread, a handler
    thread or a cancel worker bumps a counter, and the stats call reads it.
  - A counter moves with an atomic operation, so no lock is needed and no call
    into another unit runs under one.
---
}
/// The counters of the async server
unit Http2Server.Async.Counters;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// the counters that the stats of the server report
  TServerCounters = class
  private
    FConnections: Integer;
    FResets: Int64;
    FTrips: Int64;
    FTlsFailed: Int64;
  public
    /// count one accepted connection
    procedure ConnectionOpened;
    /// count one closed connection; the count never goes below zero
    procedure ConnectionClosed;
    /// count one stream reset, on the thread that saw it
    procedure StreamResetted;
    /// count one bucket trip, on the thread that saw it
    procedure BucketTripped;
    /// count one failed TLS handshake
    procedure TlsFailed;
    /// the connections that are open now
    property Connections: Integer read FConnections;
    /// streams the peer or the server reset since the build
    property Resets: Int64 read FResets;
    /// bucket trips since the build
    property Trips: Int64 read FTrips;
    /// TLS handshakes that failed while a client certificate mode was on
    property TlsFailedTotal: Int64 read FTlsFailed;
  end;

implementation

procedure TServerCounters.ConnectionOpened;
begin
  InterlockedIncrement(FConnections);
end;

procedure TServerCounters.ConnectionClosed;
var
  Seen: Integer;
begin
  // a close without an open must not push the count below zero
  repeat
    Seen := FConnections;
    if Seen <= 0 then
      exit;
  until InterlockedCompareExchange(FConnections, Seen - 1, Seen) = Seen;
end;

procedure TServerCounters.StreamResetted;
begin
  InterlockedIncrement64(FResets);
end;

procedure TServerCounters.BucketTripped;
begin
  InterlockedIncrement64(FTrips);
end;

procedure TServerCounters.TlsFailed;
begin
  InterlockedIncrement64(FTlsFailed);
end;

end.
