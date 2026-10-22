{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, detach, channel, stream, sink, credit, pending
notes:
  - This unit holds the channel of a detached HTTP/2 stream. The channel wraps
    one TServerStream. It is the sink of the stream and forwards to the sink of
    the application, so bytes that arrive before the application sets its sink
    wait in a small buffer.
  - A channel that detaches before the response headers is pending. Its sends
    wait in a hold buffer until Activate queues the headers, so no DATA frame
    can leave before HEADERS.
  - The lock order is the connection lock first, then the channel lock. The channel
    never calls a stream method while it holds its own lock.
---
}
/// The channel of a detached HTTP/2 stream
// - one channel owns one reference to its stream until the channel ends
// - the channel ends when the stream is reset, when Close ran and the peer
//   ended its half, or when Complete or an abort ran
unit Http2Server.StreamChannel;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Stream,
  Http2Server.Duplex, Http2Server.ResponseWriter;

type
  /// the channel of one detached HTTP/2 stream
  THttp2StreamChannel = class(TInterfacedObject, IDuplexChannel, IChannelSink)
  private
    FStream: TServerStream;
    FRegistry: IChannelRegistry;
    FLock: TCriticalSection;
    FState: TChannelState;
    /// the receiver of the application; nil until SetSink
    FAppSink: IChannelSink;
    /// inbound bytes that arrived before SetSink
    FEarly: TBytes;
    FEarlyEnded: Boolean;
    FEarlyClean: Boolean;
    /// outbound bytes held while the channel is pending
    FHold: TBytes;
    /// the peer ended its half with END_STREAM
    FPeerEnded: Boolean;
    /// Close ran: the local half is ending
    FLocalClosed: Boolean;
    FReleased: Boolean;
    /// the end of the inbound half reached the application sink
    FEndDelivered: Boolean;
    procedure Release;
    function StreamOutboundLimit: Integer;
  public
    /// detach AStream and answer its channel
    // - APending is True when the response headers have not left yet
    // - ARegistry is optional; a nil registry means no limit and no list
    // - raises EDetachRefused when the registry has no free slot
    class function Attach(const AStream: TServerStream;
      const ARegistry: IChannelRegistry; const APending: Boolean): IDuplexChannel;
    destructor Destroy; override;

    // IDuplexChannel
    function Send(const AData: TBytes): TSendResult;
    procedure Close(const AMode: TChannelClose);
    function IsOpen: Boolean;
    function State: TChannelState;
    function QueuedBytes: Int64;
    function Registry: IChannelRegistry;
    procedure SetSink(const ASink: IChannelSink);
    procedure ReturnCredit(const ACount: Int64);
    procedure Complete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    procedure Activate(const AStatus: Integer; const AHeaders: THeaderBlock);

    // IChannelSink: the stream calls these on an IO thread
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;
  end;

implementation

{ THttp2StreamChannel }

class function THttp2StreamChannel.Attach(const AStream: TServerStream;
  const ARegistry: IChannelRegistry; const APending: Boolean): IDuplexChannel;
var
  Channel: THttp2StreamChannel;
begin
  if (ARegistry <> nil) and not ARegistry.TryAcquire then
    raise EDetachRefused.Create(
      'the limit of detached streams is reached');
  Channel := THttp2StreamChannel.Create;
  Channel.FStream := AStream;
  // a GET that arrived with END_STREAM has no inbound half to wait for
  Channel.FPeerEnded := AStream.HasRemoteEnded;
  Channel.FRegistry := ARegistry;
  Channel.FLock := TCriticalSection.Create;
  if APending then
    Channel.FState := csPending
  else
    Channel.FState := csActive;
  // the channel owns one reference to the stream until it ends
  AStream.AddRef;
  // a detached stream has its own queue limit, apart from the ordinary streams
  if (ARegistry <> nil) and (ARegistry.QueueLimit > 0) then
  begin
    AStream.OutboundLimit := ARegistry.QueueLimit;
    AStream.DrainLowWater := ARegistry.LowWater;
  end;
  // the interface reference below keeps the channel alive from here on
  Result := Channel;
  AStream.SetSink(Channel as IChannelSink);
  if ARegistry <> nil then
    ARegistry.Add(Result);
  if AStream.IsCancelled then
    Channel.Release;
end;

destructor THttp2StreamChannel.Destroy;
begin
  // Release ran before this point: the stream held the channel as its sink
  // until then, so the destructor cannot run earlier.  The channel keeps its
  // reference to the stream until now, so a late call from another thread
  // still meets a live stream.
  if FStream <> nil then
    FStream.ReleaseRef;
  FLock.Free;
  inherited Destroy;
end;

function THttp2StreamChannel.StreamOutboundLimit: Integer;
begin
  Result := FStream.OutboundLimit;
end;

procedure THttp2StreamChannel.Release;
var
  DoRelease: Boolean;
  Self_: IDuplexChannel;
begin
  FLock.Acquire;
  try
    DoRelease := not FReleased;
    FReleased := True;
    FState := csClosed;
  finally
    FLock.Release;
  end;
  if not DoRelease then
    Exit;
  // keep the channel alive until the end of this call: the stream and the
  // registry may hold the last references
  Self_ := Self;
  FStream.SetSink(nil);
  if FRegistry <> nil then
  begin
    FRegistry.Remove(Self_);
    FRegistry.Release;
  end;
end;

function THttp2StreamChannel.Send(const AData: TBytes): TSendResult;
var
  Held: Boolean;
begin
  Result := srClosed;
  if Length(AData) = 0 then
  begin
    if IsOpen then
      Result := srQueued;
    Exit;
  end;
  Held := False;
  FLock.Acquire;
  try
    if FReleased or FLocalClosed then
      Exit;
    if FState = csPending then
    begin
      // no DATA may leave before HEADERS, so a pending channel holds the bytes
      if (StreamOutboundLimit > 0) and (Length(FHold) > 0) and
         (Length(FHold) + Length(AData) > StreamOutboundLimit) then
        Exit(srFull);
      SetLength(FHold, Length(FHold) + Length(AData));
      Move(AData[0], FHold[Length(FHold) - Length(AData)], Length(AData));
      Held := True;
      Result := srQueued;
    end;
  finally
    FLock.Release;
  end;
  if Held then
    Exit;
  if FStream.IsCancelled then
    Exit(srClosed);
  // the stream write takes the connection lock, so the channel lock is free here
  if FStream.TryWrite(AData) then
    Result := srQueued
  else
    Result := srFull;
end;

procedure THttp2StreamChannel.Close(const AMode: TChannelClose);
var
  Pending, Graceful, Ended: Boolean;
begin
  FLock.Acquire;
  try
    if FReleased or FLocalClosed then
      Exit;
    Pending := FState = csPending;
    Graceful := (AMode = ccGraceful) and not Pending;
    if Graceful then
      FLocalClosed := True;
    Ended := FPeerEnded;
  finally
    FLock.Release;
  end;
  if FRegistry <> nil then
    FRegistry.Remove(Self as IDuplexChannel);
  if Graceful then
  begin
    // queued bytes drain first, then the END_STREAM frame follows
    FStream.RequestFinish;
    // the stream ends on its own once both halves are over
    if Ended then
      Release;
  end
  else
  begin
    // an abort, or a pending channel that has no response to finish
    FStream.Refuse(ecCancel);
    Release;
  end;
end;

function THttp2StreamChannel.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FState in [csPending, csActive]) and not FReleased and
      not FLocalClosed;
  finally
    FLock.Release;
  end;
  if Result and FStream.IsCancelled then
    Result := False;
end;

function THttp2StreamChannel.State: TChannelState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function THttp2StreamChannel.Registry: IChannelRegistry;
begin
  Result := FRegistry;
end;

function THttp2StreamChannel.QueuedBytes: Int64;
begin
  FLock.Acquire;
  try
    Result := Length(FHold);
    if FReleased then
      Exit;
  finally
    FLock.Release;
  end;
  Result := Result + FStream.OutboundCount;
end;

procedure THttp2StreamChannel.SetSink(const ASink: IChannelSink);
var
  Early: TBytes;
  Ended, Clean: Boolean;
begin
  FLock.Acquire;
  try
    FAppSink := ASink;
    if ASink = nil then
      Exit;
    Early := FEarly;
    FEarly := nil;
    Ended := FEarlyEnded;
    Clean := FEarlyClean;
    FEarlyEnded := False;
    if (not Ended) and FPeerEnded and (not FEndDelivered) then
    begin
      // the peer half-closed before the request reached the handler (a GET)
      Ended := True;
      Clean := True;
    end;
    // the lock stays held while the early bytes go out, so no byte of the IO
    // thread overtakes them; the sink only queues work and never blocks
    if Length(Early) > 0 then
      ASink.BytesReceived(Early[0], Length(Early));
    if Ended then
    begin
      FEndDelivered := True;
      ASink.PeerClosed(Clean);
    end;
  finally
    FLock.Release;
  end;
end;

procedure THttp2StreamChannel.ReturnCredit(const ACount: Int64);
var
  Ended: Boolean;
begin
  if ACount <= 0 then
    Exit;
  FLock.Acquire;
  try
    Ended := FReleased;
  finally
    FLock.Release;
  end;
  // an ended channel has nothing left to credit
  if Ended then
    Exit;
  if ACount > High(Cardinal) then
    FStream.AddCredit(High(Cardinal))
  else
    FStream.AddCredit(LongWord(ACount));
end;

procedure THttp2StreamChannel.Complete(const AStatus: Integer;
  const AHeaders: THeaderBlock; const ABody: TBytes);
begin
  FLock.Acquire;
  try
    if FState <> csPending then
      raise EHttpError.Create('Complete needs a pending channel');
    FLocalClosed := True;
    FHold := nil;
  finally
    FLock.Release;
  end;
  if FRegistry <> nil then
    FRegistry.Remove(Self as IDuplexChannel);
  CheckResponseHeaders(AHeaders);
  FStream.QueueResponseHeaders(AStatus, WithDate(AHeaders, AStatus), Length(ABody) = 0);
  if Length(ABody) > 0 then
  begin
    FStream.TryWrite(ABody);
    FStream.RequestFinish;
  end;
  // the response is complete; the core finishes the stream
  Release;
end;

procedure THttp2StreamChannel.Activate(const AStatus: Integer;
  const AHeaders: THeaderBlock);
var
  Hold: TBytes;
begin
  FLock.Acquire;
  try
    if FState <> csPending then
      raise EHttpError.Create('Activate needs a pending channel');
    FState := csActive;
    Hold := FHold;
    FHold := nil;
  finally
    FLock.Release;
  end;
  CheckResponseHeaders(AHeaders);
  FStream.QueueResponseHeaders(AStatus, WithDate(AHeaders, AStatus), False);
  if Length(Hold) > 0 then
    FStream.TryWrite(Hold);
end;

procedure THttp2StreamChannel.BytesReceived(const AData; const ACount: Integer);
var
  Early: Integer;
begin
  FLock.Acquire;
  try
    if FAppSink <> nil then
      FAppSink.BytesReceived(AData, ACount)
    else if ACount > 0 then
    begin
      // the application has not set its sink yet; the window bounds this buffer
      Early := Length(FEarly);
      SetLength(FEarly, Early + ACount);
      Move(AData, FEarly[Early], ACount);
    end;
  finally
    FLock.Release;
  end;
end;

procedure THttp2StreamChannel.PeerClosed(const AClean: Boolean);
var
  EndedBoth: Boolean;
begin
  FLock.Acquire;
  try
    if AClean then
      FPeerEnded := True;
    if FAppSink <> nil then
    begin
      FEndDelivered := True;
      FAppSink.PeerClosed(AClean);
    end
    else
    begin
      FEarlyEnded := True;
      FEarlyClean := AClean;
    end;
    EndedBoth := (not AClean) or FLocalClosed;
  finally
    FLock.Release;
  end;
  // a reset ends the channel; a clean end ends it once the local half is over
  if EndedBoth then
    Release;
end;

procedure THttp2StreamChannel.WriteDrained;
begin
  FLock.Acquire;
  try
    if FAppSink <> nil then
      FAppSink.WriteDrained;
  finally
    FLock.Release;
  end;
end;

end.
