{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, state machine, frames, flow control, hpack
notes:
  - This unit holds the frame handling of the server connection state machine.
  - The base class, with the fields, the output queue and the stream table, is
    in Http2Server.Connection.Core. This unit re-exports its public types, so a
    caller that uses this unit sees the same names as before the split.
  - The unit compiles without the mORMot units, because it touches no socket
    and no TLS. The caller holds the connection lock for every call.
---
}
/// HTTP/2 server connection core
// - Feed takes bytes from the socket and TakeOutput gives bytes for the socket.
// - The core holds no lock of its own: the caller holds the connection lock for
//   the whole of every call, so one thread uses the HPACK encoder and decoder.
// - The options record carries every limit. The core holds no limit literal.
unit Http2Server.Connection;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.FlowControl, Http2Server.Limits, Http2Server.Seam,
  Http2Server.Stream, Http2Server.Headers, Http2Server.Output,
  Http2Server.HpackConnection, Http2Server.RequestValidation,
  Http2Server.Connection.Core;

type
  /// the per-connection values the core needs (see Http2Server.Connection.Core)
  TConnectionCoreOptions = Http2Server.Connection.Core.TConnectionCoreOptions;
  /// the events the core raises (see Http2Server.Connection.Core)
  IConnectionEvents = Http2Server.Connection.Core.IConnectionEvents;
  /// the stream host adapter of one core (see Http2Server.Connection.Core)
  TCoreStreamHost = Http2Server.Connection.Core.TCoreStreamHost;

  /// the server connection state machine
  // - the fields, the output queue and the stream table are in the base class
  TServerConnectionCore = class(TConnectionCoreBase)
  private
    procedure ProcessFrame(const AFrame: TFrame);
    procedure ProcessPriority(const AFrame: TFrame);
    procedure ProcessHeaders(const AFrame: TFrame);
    procedure ProcessContinuation(const AFrame: TFrame);
    procedure CompleteHeaderBlock;
    function ValidateRequestBlock(const AStream: TServerStream;
      const AIsTrailer: Boolean): Boolean;
    procedure ProcessData(const AFrame: TFrame);
    procedure ProcessSettings(const AFrame: TFrame);
    procedure ProcessRstStream(const AFrame: TFrame);
    procedure ProcessPing(const AFrame: TFrame);
    procedure ProcessGoAway(const AFrame: TFrame);
    procedure ProcessWindowUpdate(const AFrame: TFrame);
  public
    /// consume bytes from the socket; a partial frame stays buffered
    procedure Feed(const AData: TBytes);
  end;

implementation

/// true when the block holds the :protocol pseudo-header of an extended CONNECT
function HasProtocolPseudo(const ABlock: THeaderBlock): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ABlock) do
    if ABlock[I].Name = ':protocol' then
      Exit(True);
  Result := False;
end;

procedure TServerConnectionCore.Feed(const AData: TBytes);
var
  Offset, Total, FrameLen, Need: Integer;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  LockConn;
  try
  if Length(AData) > 0 then
  begin
    if FInputCount + Length(AData) > Length(FInput) then
      SetLength(FInput, FInputCount + Length(AData));
    Move(AData[0], FInput[FInputCount], Length(AData));
    Inc(FInputCount, Length(AData));
  end;

  // the client connection preface precedes every frame and arrives in pieces
  if FPrefaceCount < ClientPrefaceSize then
  begin
    Need := ClientPrefaceSize - FPrefaceCount;
    if FInputCount < Need then
      Need := FInputCount;
    if Need > 0 then
    begin
      if FPrefaceCount + Need > Length(FPreface) then
        SetLength(FPreface, FPrefaceCount + Need);
      Move(FInput[0], FPreface[FPrefaceCount], Need);
      Inc(FPrefaceCount, Need);
      Move(FInput[Need], FInput[0], FInputCount - Need);
      Dec(FInputCount, Need);
    end;
    if FPrefaceCount < ClientPrefaceSize then
      Exit;
    if not CheckClientPreface(FPreface) then
    begin
      FailConnection('the client connection preface does not match',
        ecProtocolError);
      Exit;
    end;
    // the server SETTINGS frame is the first frame of the connection
    QueueFrame(BuildServerSettings(FSettings));
  end;

  Offset := 0;
  Total := FInputCount;
  while Offset + FrameHeaderSize <= Total do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(FInput[Offset], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    // RFC 9113 section 4.2: a frame larger than the advertised maximum is a
    // connection error, and its payload is never buffered
    if Header.Length > FSettings.MaxFrameSize then
    begin
      FailConnection('the frame is larger than the server accepts',
        ecFrameSizeError);
      Break;
    end;
    FrameLen := FrameHeaderSize + Integer(Header.Length);
    if Offset + FrameLen > Total then
      Break;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(FInput[Offset + FrameHeaderSize], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    try
      ProcessFrame(Frame);
    except
      on E: EHttpError do
      begin
        // a parser raises with the protocol code that the fault requires, so
        // the code travels unchanged unless the parser left it unset
        if E.ErrorCode = ecInternalError then
          FailConnection(E.Message, ecProtocolError)
        else
          FailConnection(E.Message, E.ErrorCode);
      end;
    end;
    Inc(Offset, FrameLen);
    // A connection error or a trip ends the read loop, because no later frame
    // of the buffer changes the outcome.  A GOAWAY from the peer is not such
    // an end: RFC 9113 section 6.8 lets the peer keep the connection in use
    // until the last stream ends, so the frames after it are still read.
    if FClosing and FGoAwaySent and not FPeerGoAway then
      Break;
  end;
  if Offset > 0 then
  begin
    Move(FInput[Offset], FInput[0], Total - Offset);
    Dec(FInputCount, Offset);
    if FInputCount = 0 then
      FInput := nil;
  end;

  FlushLocked;
  finally
    UnlockConn;
  end;
end;

procedure TServerConnectionCore.ProcessFrame(const AFrame: TFrame);
begin
  // RFC 9113 section 4.3: a header block runs to the end of the CONTINUATION
  // run on its stream, so no other frame may stand between them
  if FHpack.InBlock and (AFrame.Header.FrameType <> ftContinuation) then
  begin
    FailConnection('a frame interrupted a header block', ecProtocolError);
    Exit;
  end;
  case AFrame.Header.FrameType of
    ftData: ProcessData(AFrame);
    ftHeaders: ProcessHeaders(AFrame);
    ftPriority: ProcessPriority(AFrame);
    ftRstStream: ProcessRstStream(AFrame);
    ftSettings: ProcessSettings(AFrame);
    ftPushPromise:
      // RFC 9113 section 8.2: a server never receives PUSH_PROMISE
      FailConnection('a server refuses a PUSH_PROMISE frame', ecProtocolError);
    ftPing: ProcessPing(AFrame);
    ftGoAway: ProcessGoAway(AFrame);
    ftWindowUpdate: ProcessWindowUpdate(AFrame);
    ftContinuation: ProcessContinuation(AFrame);
  end;
end;

procedure TServerConnectionCore.ProcessPriority(const AFrame: TFrame);
var
  DependsOn, Weight: LongWord;
  Exclusive: Boolean;
begin
  // RFC 9113 section 6.3 fixes the payload at 5 octets
  ParsePriority(AFrame, DependsOn, Weight, Exclusive);
  if AFrame.Header.StreamId = 0 then
  begin
    FailConnection('a PRIORITY frame needs a stream id', ecProtocolError);
    Exit;
  end;
  // RFC 9113 section 5.3.1: a stream cannot depend on itself, and the fault
  // is a stream error
  if DependsOn = AFrame.Header.StreamId then
  begin
    SendRstStream(AFrame.Header.StreamId, ecProtocolError);
    Exit;
  end;
  // the server keeps no priority tree, so the rest of the frame carries no
  // action and the stream continues
end;

procedure TServerConnectionCore.ProcessHeaders(const AFrame: TFrame);
var
  Stream: TServerStream;
  Block: TBytes;
begin
  // a HEADERS frame needs a stream id, and stream zero is not one
  if AFrame.Header.StreamId = 0 then
  begin
    FailConnection('a HEADERS frame needs a stream id', ecProtocolError);
    Exit;
  end;
  Stream := FindStream(AFrame.Header.StreamId);
  if Stream <> nil then
  begin
    // RFC 9113 section 5.1: once the peer ended its half, only trailers may
    // arrive, and a HEADERS frame there is a connection error
    if Stream.State in [ssHalfClosedRemote, ssClosed] then
    begin
      FailConnection('a HEADERS frame arrived after the peer ended its half',
        ecStreamClosed);
      Exit;
    end;
    if (Length(Stream.RemoteHeaders) > 0) and (not AFrame.IsEndStream) then
    begin
      FailConnection('a second HEADERS frame needs END_STREAM',
        ecProtocolError);
      Exit;
    end;
  end
  else
  begin
    // RFC 9113 section 5.1.1: a stream id that does not increase is a fault
    if not CheckStreamId(AFrame.Header.StreamId) then
      Exit;
    if OpenStreamCount >= Integer(FOptions.MaxConcurrentStreams) then
    begin
      // RFC 9113 section 5.1.2: a stream above the limit is refused, and the
      // connection stays open
      SendRstStream(AFrame.Header.StreamId, ecRefusedStream);
      Exit;
    end;
    Stream := NewStream(AFrame.Header.StreamId);
  end;
  // RFC 9113 section 5.3.1: a HEADERS frame may carry a priority block, and
  // a stream that depends on itself is a stream error
  if AFrame.IsPriority then
  begin
    if HeaderPriorityDependsOn(AFrame) = AFrame.Header.StreamId then
    begin
      SendRstStream(AFrame.Header.StreamId, ecProtocolError);
      Exit;
    end;
  end;
  Block := ExtractHeaderBlock(AFrame);
  FHpack.BeginBlock(AFrame.Header.StreamId, AFrame.IsEndStream, Block);
  if AFrame.IsEndHeaders then
    CompleteHeaderBlock;
end;

procedure TServerConnectionCore.ProcessContinuation(const AFrame: TFrame);
var
  Block: TBytes;
begin
  if not FHpack.InBlock then
  begin
    FailConnection('a CONTINUATION frame arrived with no header block',
      ecProtocolError);
    Exit;
  end;
  if AFrame.Header.StreamId <> FHpack.BlockStreamId then
  begin
    FailConnection('a CONTINUATION frame changed the stream',
      ecProtocolError);
    Exit;
  end;
  if FHpack.ContinuationCount + 1 > FOptions.MaxContinuations then
  begin
    FailConnection('too many CONTINUATION frames for one header block',
      ecEnhanceYourCalm);
    Exit;
  end;
  if FLimits <> nil then
    FLimits.Charge(lkContinuation, 1);
  Block := ExtractHeaderBlock(AFrame);
  // the count and the payload join the block only after the size check
  if FHpack.BlockByteLength + Length(Block) >
     Integer(FOptions.MaxHeaderBlockBytes) then
  begin
    FailConnection('the header block is larger than the server accepts',
      ecEnhanceYourCalm);
    Exit;
  end;
  FHpack.AddBlockPart(Block);
  if AFrame.IsEndHeaders then
    CompleteHeaderBlock;
end;

procedure TServerConnectionCore.CompleteHeaderBlock;
var
  Stream: TServerStream;
  Block: TBytes;
  Headers: THeaderBlock;
  IsTrailer: Boolean;
begin
  Stream := FindStream(FHpack.BlockStreamId);
  Block := FHpack.TakeBlock;
  if Stream = nil then
    Exit;
  try
    Headers := FHpack.Decode(Block);
  except
    on E: EHttpProtocolError do
    begin
      // the dynamic table state is lost, so the connection cannot continue
      FailConnection(E.Message, E.ErrorCode);
      Exit;
    end;
    on E: EHttpError do
    begin
      FailConnection(E.Message, ecCompressionError);
      Exit;
    end;
  end;
  // the first header block of a stream is the request head; a later block
  // is the trailer, because ProcessHeaders refuses any other second block
  IsTrailer := Stream.HasRequestHead;
  if IsTrailer and HasProtocolPseudo(Stream.RemoteHeaders) then
  begin
    // RFC 8441 section 5: an extended CONNECT stream carries DATA after its head, and
    // a trailer block is a stream error (RFC 9113 section 8.5)
    SendRstStream(Stream.StreamId, ecProtocolError);
    Stream.Cancel(ecProtocolError);
    CloseStream(Stream);
    Exit;
  end;
  Stream.SetRemoteHeaders(Headers);
  if FHpack.BlockEndStream then
    Stream.MarkRemoteEnded;
  if not ValidateRequestBlock(Stream, IsTrailer) then
    Exit;
  if FEvents <> nil then
    FEvents.RequestReady(Stream);
end;

function TServerConnectionCore.ValidateRequestBlock(
  const AStream: TServerStream; const AIsTrailer: Boolean): Boolean;
var
  Verdict: TRequestVerdict;
begin
  Verdict := ValidateRequestHeaders(AStream.RemoteHeaders, AIsTrailer,
    FOptions.ConnectProtocol);
  if not Verdict.Valid then
  begin
    // RFC 9113 section 8.1.2.6: a malformed request is a stream error, so
    // only this stream ends and the connection stays open
    SendRstStream(AStream.StreamId, ecProtocolError);
    AStream.Cancel(ecProtocolError);
    CloseStream(AStream);
    Exit(False);
  end;
  // a trailer carries no content-length, so the head declaration stands
  if not AIsTrailer then
  begin
    AStream.SetDeclaredLength(Verdict.DeclaredLength);
    AStream.MarkRequestHead;
  end;
  Result := True;
end;

procedure TServerConnectionCore.ProcessData(const AFrame: TFrame);
var
  Stream: TServerStream;
  Payload: TBytes;
  N: LongWord;
begin
  Payload := ExtractDataPayload(AFrame);
  N := LongWord(Length(Payload));
  if N = 0 then
  begin
    if FLimits <> nil then
      FLimits.Charge(lkEmptyData, 1);
  end;
  if AFrame.Header.StreamId = 0 then
  begin
    if N > 0 then
      FailConnection('a DATA frame needs a stream id', ecProtocolError);
    Exit;
  end;
  Stream := FindStream(AFrame.Header.StreamId);
  if Stream = nil then
  begin
    // RFC 9113 section 5.1: DATA on an idle or a closed stream is a
    // connection error, and the two states take different codes
    if AFrame.Header.StreamId > FLastStreamId then
      FailConnection('a DATA frame arrived on an idle stream',
        ecProtocolError)
    else
      FailConnection('a DATA frame arrived on a closed stream',
        ecStreamClosed);
    Exit;
  end;
  if (N > 0) and (Stream.State in [ssHalfClosedRemote, ssClosed]) then
  begin
    // the peer already ended this half, so no further DATA may arrive
    FailConnection('a DATA frame arrived after the peer ended its half',
      ecStreamClosed);
    Exit;
  end;
  if N > 0 then
  begin
    if not Stream.CountReceivedBody(N) then
    begin
      // RFC 9113 section 8.1.2.6: the body passed the declared content-length,
      // so this stream ends and the connection stays open
      SendRstStream(AFrame.Header.StreamId, ecProtocolError);
      Stream.Cancel(ecProtocolError);
      CloseStream(Stream);
      Exit;
    end;
    if Stream.InboundWouldOverflow(Length(Payload)) then
    begin
      // the handler is behind, so this stream ends and the connection stays
      SendRstStream(AFrame.Header.StreamId, ecFlowControlError);
      Stream.Cancel(ecFlowControlError);
      CloseStream(Stream);
      Exit;
    end;
    if not FFlow.TryConsume(AFrame.Header.StreamId, N) then
    begin
      FailConnection('a DATA frame overran a flow-control window',
        ecFlowControlError);
      Exit;
    end;
    // the connection credit returns as soon as the bytes are buffered, so a
    // handler that is slow on one stream stalls only that stream
    Inc(FConnUpdatePending, N);
    Stream.DeliverData(Payload, AFrame.IsEndStream);
  end
  else if AFrame.IsEndStream then
    // an empty DATA frame that ends the stream: a detached sink hears PeerClosed too
    Stream.DeliverData(nil, True);
  if AFrame.IsEndStream and (not Stream.DeclaredLengthMatches) then
  begin
    // the body length differs from the declared content-length
    SendRstStream(AFrame.Header.StreamId, ecProtocolError);
    Stream.Cancel(ecProtocolError);
    CloseStream(Stream);
  end;
end;

procedure TServerConnectionCore.ProcessSettings(const AFrame: TFrame);
var
  NewSettings: TConnectionSettings;
  Delta: Int64;
begin
  if AFrame.IsAck and (Length(AFrame.Payload) > 0) then
  begin
    // RFC 9113 section 6.5: a SETTINGS acknowledgment carries no payload
    FailConnection('a SETTINGS acknowledgment carries no payload',
      ecFrameSizeError);
    Exit;
  end;
  if AFrame.IsAck then
    Exit;
  if AFrame.Header.StreamId <> 0 then
  begin
    FailConnection('a SETTINGS frame needs stream zero', ecProtocolError);
    Exit;
  end;
  if FLimits <> nil then
    FLimits.Charge(lkSettings, 1);
  NewSettings := TConnectionSettings.Decode(AFrame.Payload);
  if (NewSettings.MaxFrameSize < MinAllowedFrameSize) or
     (NewSettings.MaxFrameSize > MaxAllowedFrameSize) then
  begin
    FailConnection('the peer sent a frame size outside the protocol range',
      ecProtocolError);
    Exit;
  end;
  Delta := Int64(NewSettings.InitialWindowSize) -
    Int64(FPeerSettings.InitialWindowSize);
  FPeerSettings := NewSettings;
  FHpack.ApplyPeerTableSize(FPeerSettings.HeaderTableSize);
  // the drain obeys the smaller of the two frame sizes
  FOut.ApplyPeerFrameSize(FPeerSettings.MaxFrameSize);
  // RFC 9113 section 6.9.2: a change reaches every stream that is open
  if Delta <> 0 then
    FFlow.ApplyInitialWindowDelta(Delta);
  QueueFrame(BuildSettingsAck);
end;

procedure TServerConnectionCore.ProcessRstStream(const AFrame: TFrame);
var
  Stream: TServerStream;
  Code: THttp2ErrorCode;
begin
  if AFrame.Header.StreamId = 0 then
  begin
    FailConnection('an RST_STREAM frame needs a stream id', ecProtocolError);
    Exit;
  end;
  ParseRstStream(AFrame, Code);
  Stream := FindStream(AFrame.Header.StreamId);
  if FLimits <> nil then
    // a reset that reached a handler costs more than one for an idle stream
    // - the charge precedes the idle check, so a flood of resets on idle
    //   streams still trips the bucket and answers ENHANCE_YOUR_CALM
    FLimits.ChargeReset(Stream <> nil);
  if (Stream = nil) and (AFrame.Header.StreamId > FLastStreamId) then
  begin
    // RFC 9113 section 5.1: RST_STREAM on an idle stream is a fault
    FailConnection('an RST_STREAM frame arrived on an idle stream',
      ecProtocolError);
    Exit;
  end;
  if Stream = nil then
    Exit;
  Stream.Cancel(Code);
  if FEvents <> nil then
    FEvents.StreamReset(Stream);
  CloseStream(Stream);
end;

procedure TServerConnectionCore.ProcessPing(const AFrame: TFrame);
var
  Payload: TBytes;
begin
  if AFrame.Header.StreamId <> 0 then
  begin
    FailConnection('a PING frame needs stream zero', ecProtocolError);
    Exit;
  end;
  if FLimits <> nil then
    FLimits.Charge(lkPing, 1);
  if AFrame.IsAck then
    Exit;
  Payload := ParsePing(AFrame);
  QueueFrame(BuildPingFrame(Payload, True));
end;

procedure TServerConnectionCore.ProcessGoAway(const AFrame: TFrame);
var
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
  Stream: TServerStream;
  I: Integer;
begin
  if AFrame.Header.StreamId <> 0 then
  begin
    FailConnection('a GOAWAY frame needs stream zero', ecProtocolError);
    Exit;
  end;
  ParseGoAway(AFrame, Id, Code, Debug);
  // RFC 9113 section 6.8: the peer may keep the connection in use until its
  // last stream ends, so the read loop must not stop on this frame
  FPeerGoAway := True;
  // the peer opens no stream after GOAWAY, so every open stream is cancelled
  for I := FStreams.Count - 1 downto 0 do
  begin
    Stream := FStreams[I];
    Stream.Cancel(Code);
    if FEvents <> nil then
      FEvents.StreamReset(Stream);
    CloseStream(Stream);
  end;
  // RFC 9113 section 6.8: a receiver of a GOAWAY that has no more use for the
  // connection SHOULD still send a GOAWAY frame before terminating.  The
  // answer names the last stream the server processed, and it is also what
  // makes the end of the connection visible: the peer learns that the socket
  // is going away instead of waiting for a frame that never comes.
  SendGoAway(FLastStreamId, ecNoError);
  FClosing := True;
  if FEvents <> nil then
    FEvents.ConnectionClosing;
end;

procedure TServerConnectionCore.ProcessWindowUpdate(const AFrame: TFrame);
var
  Increment: LongWord;
begin
  if FLimits <> nil then
    FLimits.Charge(lkWindowUpdate, 1);
  Increment := ParseWindowUpdate(AFrame);
  if AFrame.Header.StreamId = 0 then
    FFlow.ApplyConnectionUpdate(Increment)
  else
  begin
    if FindStream(AFrame.Header.StreamId) = nil then
    begin
      if AFrame.Header.StreamId > FLastStreamId then
        // RFC 9113 section 5.1: WINDOW_UPDATE on an idle stream is a fault
        FailConnection('a WINDOW_UPDATE arrived on an idle stream',
          ecProtocolError);
      // a closed stream needs no window, so the frame carries no action
      Exit;
    end;
    try
      FFlow.ApplyStreamUpdate(AFrame.Header.StreamId, Increment);
    except
      // RFC 9113 section 6.9.1: a stream window above the maximum ends the
      // stream, and the connection stays open
      on E: EHttpProtocolError do
      begin
        SendRstStream(AFrame.Header.StreamId, ecFlowControlError);
        Exit;
      end;
    end;
  end;
end;

end.
