{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, seam, handler, cancellation, streams
notes:
  - This unit holds the interfaces between the IO side and the handler side.
  - A handler runs on a handler-pool thread and is synchronous code.
  - Every wait of the handler side passes through IStreamWaiter.
  - A handler sees bytes only; no method takes a string as a byte container.
---
}
/// The seam between the IO side and the handler side of the HTTP/2 server
// - the IO side owns the socket, the connection lock and the HPACK codecs.
//   It calls the stream buffer methods of TServerStream under the connection
//   lock.
// - the handler side owns one handler-pool thread per request.  It calls the
//   methods of IServerRequest and IServerResponse, which hold the connection
//   lock only for the length of one buffer operation and never across a wait.
// - IStreamWaiter is the only wait interface of the seam.  A later release
//   can replace TBlockingWaiter with a coroutine implementation without a
//   change to the handler contract.
// - a cancellation raises EStreamCancelled inside the handler's own thread.
//   The IO side never raises an exception inside another thread.
unit Http2Server.Seam;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Errors, Http2Server.Hpack;

type
  /// the outcome of one IStreamWaiter.Wait call
  TWaitResult = (
    /// the wait ended because Signal or Cancel ran
    wrSignalled,
    /// the wait ended because the timeout expired
    wrTimeout,
    /// the wait ended because the stream was cancelled
    wrCancelled);

  /// The one wait interface of the seam.
  ///
  /// A handler blocks on Wait.  The IO side calls Signal when new data or new
  /// send credit arrives, and Cancel when the stream ends early.  Every later
  /// call of a stream after a cancellation raises EStreamCancelled.
  IStreamWaiter = interface
    ['{7E1F0C11-0001-4A11-9C72-000000000501}']
    /// block until ATimeoutMs has passed, or the waiter is signalled, or the
    /// stream is cancelled
    function Wait(const ATimeoutMs: Integer): TWaitResult;
    /// wake a blocked Wait; the caller holds the connection lock
    procedure Signal;
    /// set the cancel flag, wake a blocked Wait and queue the cancel hooks
    procedure Cancel;
    /// true once Cancel has run
    function IsCancelled: Boolean;
  end;

  /// A cancel hook of one stream.
  ///
  /// The hook runs at most once, on a cancel-worker thread.  It never runs on
  /// the thread that called Cancel.  A long block inside the hook delays the
  /// other hooks of the same pool; the pool is sized so that one blocked hook
  /// does not stop the release of a different stream.
  TCancelHook = procedure of object;

  /// A pulled response body.
  ///
  /// The server calls NextChunk until it answers False.  A False answer sends
  /// the END_STREAM flag on the last DATA frame.
  IBodyWriter = interface
    ['{7E1F0C11-0002-4A11-9C72-000000000502}']
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

  /// The request as one handler sees it.
  ///
  /// The request is byte-oriented.  No method converts a text encoding and no
  /// method takes a string as a byte container.
  IServerRequest = interface
    ['{7E1F0C11-0003-4A11-9C72-000000000503}']
    /// ':method'
    function Method: string;
    /// ':scheme'
    function Scheme: string;
    /// ':authority'
    function Authority: string;
    /// ':path'
    function Path: string;
    /// the decoded header list of the request, without the pseudo-headers
    function Headers: THeaderBlock;
    /// block until bytes arrive, the body ends, the timeout expires, or the
    /// stream is cancelled
    // - a return of 0 means the body has ended
    // - a cancelled stream raises EStreamCancelled in the handler's thread
    function Read(var ABuffer; const ACount: Integer): Integer;
    /// answer with the next buffered chunk; False means the body has ended
    // - the server sends WINDOW_UPDATE for the stream only when the handler
    //   reads, which bounds the memory of a queued or slow request
    function ReadChunk(out AChunk: TBytes): Boolean;
    /// true once the request body has ended
    function BodyIsComplete: Boolean;
    /// true once the peer, or the connection, has cancelled the stream
    function IsCancelled: Boolean;
    /// the stream id of the request
    function StreamId: LongWord;
  end;

  /// The response as one handler writes it.
  ///
  /// The handler gives up the header list when it calls SendHeaders.  The IO
  /// thread encodes the list into HPACK under the connection lock and emits
  /// it as one contiguous HEADERS and CONTINUATION run.
  IServerResponse = interface
    ['{7E1F0C11-0004-4A11-9C72-000000000504}']
    /// send the response headers
    procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
      const AEndStream: Boolean = False);
    /// send bytes; the call blocks while the outbound buffer or the
    /// flow-control window is full
    procedure Write(const AData: TBytes); overload;
    /// send ACount bytes from ABuffer; same blocking rule as the other Write
    procedure Write(const ABuffer; const ACount: Integer); overload;
    /// send the response body from a pull writer until it answers False
    procedure SetBodyWriter(const AWriter: IBodyWriter);
    /// end the response; sends END_STREAM on an empty DATA frame when the
    /// last data frame did not carry the flag
    procedure Finish;
    /// register the hook that a cancellation runs, at most once, on a
    /// cancel-worker thread
    // - a handler that blocks inside a database call without a cancel hook
    //   runs on to completion; the hook is the only way to interrupt it
    procedure RegisterCancelHook(const AHook: TCancelHook);
    /// true once the peer, or the connection, has cancelled the stream
    function IsCancelled: Boolean;
    /// the stream id of the response
    function StreamId: LongWord;
  end;

  /// The handler contract.
  ///
  /// A handler runs on a handler-pool thread.  It is synchronous code: it
  /// reads the request, writes the response and returns.  No coroutine and no
  /// continuation is part of this contract.
  IHttp2Handler = interface
    ['{7E1F0C11-0005-4A11-9C72-000000000505}']
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

/// mark the calling thread as running IO-side code
// - the IO callbacks of the async unit enter this mark before they touch the
//   connection core, so a handler that an IO thread runs fails at once
procedure Http2IoThreadEnter;

/// clear the IO-side mark of the calling thread
procedure Http2IoThreadLeave;

/// TRUE while the calling thread runs IO-side code
function Http2IsIoThread: Boolean;

/// raise when the calling thread runs IO-side code
// - handler code calls this at entry.  A handler on an IO thread would hold
//   the connection lock and would stall the whole pool, so the rule is a hard
//   check and it raises in every build
procedure Http2AssertHandlerThread(const AWhere: string);

implementation

threadvar
  /// how many IO-side calls the current thread holds; zero on a handler thread
  IoDepth: Integer;

procedure Http2IoThreadEnter;
begin
  Inc(IoDepth);
end;

procedure Http2IoThreadLeave;
begin
  if IoDepth > 0 then
    Dec(IoDepth);
end;

function Http2IsIoThread: Boolean;
begin
  result := IoDepth > 0;
end;

procedure Http2AssertHandlerThread(const AWhere: string);
begin
  if IoDepth > 0 then
    raise EHttpError.Create('handler code ran on an IO thread at ' + AWhere);
end;

end.
