{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: handler pool, job, admission, http1
notes:
  - A job is one request that waits in the bounded queue of the handler pool and
    is not an HTTP/2 stream. The HTTP/1.1 request is a job. The job shares the
    depth, the wait limit and the handler threads with the HTTP/2 streams.
---
}
/// The unit of work that the handler pool runs besides an HTTP/2 stream
unit Http2Server.HandlerJob;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  Http2Server.Seam, Http2Server.Duplex;

type
  /// why the pool did not run a job
  THandlerJobRefusal = (
    /// the queue was full
    jrQueueFull,
    /// the job waited past the wait limit
    jrTimedOut,
    /// the pool stopped
    jrStopped);

  /// one request for the handler pool
  IHandlerJob = interface
    ['{7E1F0C11-0091-4A11-9C72-000000000C01}']
    /// run the handler on the calling handler-pool thread
    procedure Run(const AHandler: IHttp2Handler; const ARegistry: IChannelRegistry);
    /// the pool did not run the job; the job answers the peer
    procedure Refuse(const AReason: THandlerJobRefusal);
    /// the connection or the server ended; a waiting handler wakes
    procedure Cancel;
    function IsCancelled: Boolean;
  end;

implementation

end.
