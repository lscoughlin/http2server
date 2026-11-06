{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, flush, headers, flow control
notes:
  - This unit holds the flush helpers of the connection core.
  - The helpers take their state as parameters and queue frames through a
    callback, so the core keeps its locks and its queue.
---
}
/// The flush helpers of the connection core
// - FlushPendingHeaders encodes every pending response head and queues the
//   HEADERS runs
// - FlushStreamCredits and FlushConnectionCredit refill the windows that the
//   peer spent
// - FlushDrainedOutput moves the bytes of the drain into the output queue
// - the caller holds the connection lock for every call
unit Http2Server.Connection.Flush;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Generics.Collections,
  Http2Server.Frames, Http2Server.Hpack, Http2Server.FlowControl,
  Http2Server.Stream, Http2Server.HpackConnection, Http2Server.Output;

type
  /// the frame queue of the core, as a callback
  TQueueFrameProc = procedure(const AFrame: TFrame) of object;
  /// the byte queue of the core, as a callback
  TQueueBytesProc = procedure(const AData: TBytes) of object;

/// queue the HEADERS run of one encoded header block
procedure EmitHeaderRun(AHpack: THpackConnection;
  const AQueue: TQueueFrameProc; const AStreamId: LongWord;
  const AHeaderBlock: TBytes);

/// encode every pending response head and queue its frames
procedure FlushPendingHeaders(AStreams: TObjectList<TServerStream>;
  AHpack: THpackConnection; const AQueue: TQueueFrameProc);

/// refill every stream window whose consumed credit passed the threshold
procedure FlushStreamCredits(AStreams: TObjectList<TServerStream>;
  ARecv: TFlowControl; const AThreshold: LongWord;
  const AQueue: TQueueFrameProc);

/// refill the connection window from the pending credit
procedure FlushConnectionCredit(ARecv: TFlowControl;
  const AThreshold: LongWord; var APending: LongWord;
  const AQueue: TQueueFrameProc);

/// move the bytes the drain produced into the connection output queue
procedure FlushDrainedOutput(AOut: TOutputDrain;
  const AQueueBytes: TQueueBytesProc);

implementation

procedure EmitHeaderRun(AHpack: THpackConnection;
  const AQueue: TQueueFrameProc; const AStreamId: LongWord;
  const AHeaderBlock: TBytes);
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  // the HPACK unit frames the header block, because the wire order of the
  // HEADERS frame and its CONTINUATION frames follows the encoder state
  Frames := AHpack.BuildHeaderRun(AStreamId, AHeaderBlock);
  for I := 0 to Length(Frames) - 1 do
    AQueue(Frames[I]);
end;

procedure FlushPendingHeaders(AStreams: TObjectList<TServerStream>;
  AHpack: THpackConnection; const AQueue: TQueueFrameProc);
var
  I: Integer;
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
  Encoded: TBytes;
begin
  for I := 0 to AStreams.Count - 1 do
  begin
    Stream := AStreams[I];
    if not Stream.HasPendingHeaders then
      Continue;
    if not Stream.TakePendingHeaders(Status, Headers, EndStream) then
      Continue;
    Encoded := AHpack.EncodeResponse(Status, Headers);
    EmitHeaderRun(AHpack, AQueue, Stream.StreamId, Encoded);
    if EndStream then
    begin
      AQueue(BuildDataFrame(Stream.StreamId, nil, True));
      Stream.MarkLocalEnded;
    end;
  end;
end;

procedure FlushStreamCredits(AStreams: TObjectList<TServerStream>;
  ARecv: TFlowControl; const AThreshold: LongWord;
  const AQueue: TQueueFrameProc);
var
  I: Integer;
  Stream: TServerStream;
  Credit: LongWord;
begin
  // the handler thread adds to ConsumedSinceUpdate under the stream lock; the
  // IO thread reads it here, so the two threads share no container
  for I := 0 to AStreams.Count - 1 do
  begin
    Stream := AStreams[I];
    Credit := Stream.ConsumedSinceUpdate;
    if Credit < AThreshold then
      Continue;
    Stream.ClearConsumed;
    AQueue(BuildWindowUpdateFrame(Stream.StreamId, Credit));
    ARecv.ApplyStreamUpdate(Stream.StreamId, Credit);
  end;
end;

procedure FlushConnectionCredit(ARecv: TFlowControl;
  const AThreshold: LongWord; var APending: LongWord;
  const AQueue: TQueueFrameProc);
begin
  if APending < AThreshold then
  begin
    // an empty window stalls every stream, so it is refilled at once
    if (APending > 0) and (ARecv.Connection.Size <= 0) then
    begin
      AQueue(BuildWindowUpdateFrame(0, APending));
      ARecv.ApplyConnectionUpdate(APending);
      APending := 0;
    end;
    Exit;
  end;
  AQueue(BuildWindowUpdateFrame(0, APending));
  ARecv.ApplyConnectionUpdate(APending);
  APending := 0;
end;

procedure FlushDrainedOutput(AOut: TOutputDrain;
  const AQueueBytes: TQueueBytesProc);
var
  Data: TBytes;
begin
  if AOut.TakeOutput(Data) then
    AQueueBytes(Data);
end;

end.
