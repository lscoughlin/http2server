{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, output, drain, round robin
notes:
  - This unit drains the outbound buffers of every stream to the socket.
  - A handler writes into a bounded buffer; this unit turns that buffer into
    DATA frames that obey the stream window, the connection window and the
    peer frame size.
  - The drain never runs on a handler thread, and the header encoder stays
    with the connection core, so one encoder serves one connection.
---
}
/// HTTP/2 outbound drain
// - Drain takes exactly one turn. A turn gives every stream with bytes an
//   equal share of the connection window, in a rotating order, so ten equal
//   streams finish within one turn of each other.
// - The caller holds the connection lock for the whole of every call, so the
//   flow-control windows and the frame queue have one owner.
unit Http2Server.Output;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Frames, Http2Server.FlowControl,
  Http2Server.Stream;

type
  /// wakes the IO thread when the connection gains output
  // - the handler side calls NotifyWrite once per transition from "no
  //   output" to "output", so the IO thread is never woken for a write that
  //   adds nothing; taking the bytes clears the mark for the next write
  IWriteWaker = interface
    ['{7E1F0C11-0032-4A11-9C72-000000000701}']
    procedure Signal;
  end;

  /// the values the drain needs from the connection
  TOutputDrainOptions = record
    /// the largest frame this server will send
    MaxFrameSize: LongWord;
    /// the share of the connection window one stream may take in one turn
    // - zero lets every active stream take its equal share of the window
    BytesPerTurn: LongWord;
  end;

  /// the drain loop of one connection
  TOutputDrain = class
  private
    FOptions: TOutputDrainOptions;
    FFlow: TFlowControl;
    FWaker: IWriteWaker;
    FPeerMaxFrameSize: LongWord;
    FRrCursor: Integer;
    FQueued: TBytes;
    FQueuedCount: Integer;
    FWakePending: Boolean;

    function PeerFrameSize: LongWord;
    procedure QueueBytes(const AData: TBytes);
    procedure QueueFrame(const AFrame: TFrame);
    function ActiveCount(const AStreams: TObjectList<TServerStream>): Integer;
    procedure DrainStream(const AStream: TServerStream;
      const AShare: Int64);
    procedure DataTurn(const AStreams: TObjectList<TServerStream>);
  public
    constructor Create(const AOptions: TOutputDrainOptions;
      const AFlow: TFlowControl; const AWaker: IWriteWaker);
    destructor Destroy; override;

    /// note that a handler wrote bytes, and wake the IO thread if it sleeps
    procedure NotifyWrite;
    /// take one turn over the streams, then queue the frames it produced
    procedure Drain(const AStreams: TObjectList<TServerStream>);
    /// copy and clear the frames this unit has queued
    function TakeOutput(out AData: TBytes): Boolean;
    /// true while a byte still waits for a turn
    function HasWork: Boolean;
    /// apply a peer SETTINGS_MAX_FRAME_SIZE value
    procedure ApplyPeerFrameSize(const AValue: LongWord);
    /// the frame size the drain will obey, after both limits are compared
    function EffectiveFrameSize: LongWord;
  end;

implementation

{ TOutputDrain }

constructor TOutputDrain.Create(const AOptions: TOutputDrainOptions;
  const AFlow: TFlowControl; const AWaker: IWriteWaker);
begin
  inherited Create;
  FOptions := AOptions;
  FFlow := AFlow;
  FWaker := AWaker;
  FPeerMaxFrameSize := DefaultMaxFrameSize;
end;

destructor TOutputDrain.Destroy;
begin
  inherited Destroy;
end;

function TOutputDrain.PeerFrameSize: LongWord;
begin
  Result := FPeerMaxFrameSize;
  if Result > FOptions.MaxFrameSize then
    Result := FOptions.MaxFrameSize;
end;

function TOutputDrain.EffectiveFrameSize: LongWord;
begin
  Result := PeerFrameSize;
end;

procedure TOutputDrain.ApplyPeerFrameSize(const AValue: LongWord);
begin
  FPeerMaxFrameSize := AValue;
end;

procedure TOutputDrain.QueueBytes(const AData: TBytes);
begin
  if Length(AData) = 0 then
    Exit;
  if FQueuedCount + Length(AData) > Length(FQueued) then
    SetLength(FQueued, FQueuedCount + Length(AData));
  Move(AData[0], FQueued[FQueuedCount], Length(AData));
  Inc(FQueuedCount, Length(AData));
end;

procedure TOutputDrain.QueueFrame(const AFrame: TFrame);
var
  Header: TBytes;
begin
  SetLength(Header, FrameHeaderSize);
  AFrame.Header.WriteTo(Header);
  QueueBytes(Header);
  QueueBytes(AFrame.Payload);
end;

procedure TOutputDrain.NotifyWrite;
begin
  if FWakePending then
    Exit;
  FWakePending := True;
  if FWaker <> nil then
    FWaker.Signal;
end;

function TOutputDrain.TakeOutput(out AData: TBytes): Boolean;
begin
  AData := nil;
  Result := FQueuedCount > 0;
  if not Result then
    Exit;
  SetLength(AData, FQueuedCount);
  Move(FQueued[0], AData[0], FQueuedCount);
  FQueuedCount := 0;
  // the IO thread holds the bytes now, so the next write may wake it again
  FWakePending := False;
end;

function TOutputDrain.HasWork: Boolean;
begin
  Result := FQueuedCount > 0;
end;

function TOutputDrain.ActiveCount(
  const AStreams: TObjectList<TServerStream>): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to AStreams.Count - 1 do
    if AStreams[I].OutboundCount > 0 then
      Inc(Result);
end;

procedure TOutputDrain.DrainStream(const AStream: TServerStream;
  const AShare: Int64);
var
  Budget, StreamRoom: Int64;
  Take: Integer;
  Chunk: TBytes;
  CanEnd: Boolean;
  W: TWindow;
begin
  if AStream.OutboundCount = 0 then
  begin
    if AStream.WantsFinish then
    begin
      QueueFrame(BuildDataFrame(AStream.StreamId, nil, True));
      AStream.ClearFinish;
      AStream.MarkLocalEnded;
    end;
    Exit;
  end;
  // the turn budget is the share for this stream; the peer frame size caps
  // each frame inside that budget. A caller must pass a positive share.
  if AShare <= 0 then
    Exit;
  // the stream window bounds this stream on its own, so a slow reader
  // holds back only its own response
  StreamRoom := 0;
  if FFlow.TryGetStream(AStream.StreamId, W) then
    StreamRoom := W.Size;
  if StreamRoom <= 0 then
    Exit;
  Budget := AShare;
  if StreamRoom < Budget then
    Budget := StreamRoom;
  while Budget > 0 do
  begin
    Take := Integer(PeerFrameSize);
    if Int64(Take) > Budget then
      Take := Integer(Budget);
    if not AStream.TakeOutbound(Chunk, Take) then
      Break;
    if not FFlow.TryConsume(AStream.StreamId, LongWord(Length(Chunk))) then
      Break;
    CanEnd := AStream.WantsFinish and (AStream.OutboundCount = 0);
    QueueFrame(BuildDataFrame(AStream.StreamId, Chunk, CanEnd));
    if CanEnd then
    begin
      AStream.ClearFinish;
      AStream.MarkLocalEnded;
    end;
    Dec(Budget, Length(Chunk));
  end;
end;

procedure TOutputDrain.DataTurn(const AStreams: TObjectList<TServerStream>);
var
  Active, I, Index: Integer;
  Share: Int64;
  Stream: TServerStream;
begin
  if AStreams.Count = 0 then
    Exit;
  Active := ActiveCount(AStreams);
  // a stream that only asked to finish carries no data, so it needs no share
  // of the connection window.  The turn still visits it, because an empty
  // DATA frame with END_STREAM is the whole of its remaining output.
  Share := 0;
  if (Active > 0) and (FFlow.Connection.Size > 0) then
  begin
    // every active stream gets an equal share of what the connection window
    // currently holds, so a stream cannot starve the others
    Share := FFlow.Connection.Size div Active;
    if FOptions.BytesPerTurn > 0 then
      if Int64(FOptions.BytesPerTurn) < Share then
        Share := FOptions.BytesPerTurn;
    if Share <= 0 then
      Share := 1;
  end;
  for I := 0 to AStreams.Count - 1 do
  begin
    Index := (FRrCursor + I) mod AStreams.Count;
    Stream := AStreams[Index];
    if (Stream.OutboundCount = 0) and not Stream.WantsFinish then
      Continue;
    if Stream.OutboundCount = 0 then
      DrainStream(Stream, 0)   // the finish branch needs no share
    else if Share > 0 then
      DrainStream(Stream, Share);
  end;
  // the next turn starts one stream further on
  FRrCursor := (FRrCursor + 1) mod AStreams.Count;
end;

procedure TOutputDrain.Drain(const AStreams: TObjectList<TServerStream>);
begin
  DataTurn(AStreams);
end;

end.
