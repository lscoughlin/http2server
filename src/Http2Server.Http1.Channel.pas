{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, detached stream, chunked channel, duplex channel, server-sent events
notes:
  - This unit holds the channel of a detached HTTP/1.1 response. It is the write
    side of a chunked response. Each Send is one chunk, and Close sends the last
    chunk. A response to an HTTP/1.0 request has no chunked coding, so its bytes go
    out as they are and the close of the connection ends the body.
  - The read side has no data. The request body of the exchange stays in the
    exchange. The sink hears only that the connection ended.
  - The channel talks to its exchange through IH1ChannelOwner, so this unit does
    not depend on the exchange unit.
---
}
/// The channel of a detached HTTP/1.1 response
unit Http2Server.Http1.Channel;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Duplex;

type
  /// what the channel needs from the exchange that it was detached from
  IH1ChannelOwner = interface
    ['{7E1F0C11-00B1-4A11-9C72-000000000E01}']
    /// queue bytes for the socket
    procedure OwnerEmit(const AData: TBytes);
    /// octets queued and not yet taken by the socket
    function OwnerBacklog: Int64;
    /// send the response head for a pending channel
    procedure OwnerHead(const AStatus: Integer; const AHeaders: THeaderBlock);
    /// send a whole response with a body and end the exchange
    procedure OwnerComplete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    /// the response has a chunked body
    function OwnerChunked: Boolean;
    /// the response has no body (HEAD, 204, 304)
    function OwnerNoBody: Boolean;
    /// end the exchange; AGraceful false cuts the connection
    procedure OwnerFinish(const AGraceful: Boolean);
    /// call WriteDrained once the backlog falls to ALowWater
    procedure OwnerWatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
  end;

  TH1ChunkedChannel = class(TInterfacedObject, IDuplexChannel)
  private
    FOwner: IH1ChannelOwner;
    FRegistry: IChannelRegistry;
    FLock: TCriticalSection;
    FState: TChannelState;
    FSink: IChannelSink;
    FHold: TBytes;
    FReleased: Boolean;
    /// Activate is sending the head and the held bytes; a Send joins the held bytes
    FActivating: Boolean;
    /// Close came while Activate ran; Activate closes at its end
    FCloseDuringActivate: Boolean;
    FCloseMode: TChannelClose;
    procedure Release;
    function Frame(const AData: TBytes): TBytes;
  public
    /// APending is True when the response head has not left yet
    constructor Create(const AOwner: IH1ChannelOwner;
      const ARegistry: IChannelRegistry; const APending: Boolean);
    destructor Destroy; override;
    /// the connection ended or the exchange broke; the sink is told
    procedure PeerGone;

    // IDuplexChannel
    function Send(const AData: TBytes): TSendResult;
    procedure Close(const AMode: TChannelClose);
    function IsOpen: Boolean;
    function State: TChannelState;
    function QueuedBytes: Int64;
    procedure SetSink(const ASink: IChannelSink);
    procedure ReturnCredit(const ACount: Int64);
    procedure Complete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    procedure Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
    function Registry: IChannelRegistry;
  end;

implementation

constructor TH1ChunkedChannel.Create(const AOwner: IH1ChannelOwner;
  const ARegistry: IChannelRegistry; const APending: Boolean);
begin
  inherited Create;
  FOwner := AOwner;
  FRegistry := ARegistry;
  FLock := TCriticalSection.Create;
  if APending then
    FState := csPending
  else
    FState := csActive;
end;

destructor TH1ChunkedChannel.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TH1ChunkedChannel.Release;
begin
  // the registry slot returns once
  if FReleased then
    Exit;
  FReleased := True;
  if FRegistry <> nil then
  begin
    FRegistry.Remove(Self as IDuplexChannel);
    FRegistry.Release;
  end;
end;

function TH1ChunkedChannel.Frame(const AData: TBytes): TBytes;
var
  Hex: string;
  Off: Integer;
begin
  Result := nil;
  if not FOwner.OwnerChunked then
  begin
    Result := AData;
    Exit;
  end;
  Hex := IntToHex(Length(AData), 1) + #13#10;
  SetLength(Result, Length(Hex) + Length(AData) + 2);
  Move(Hex[1], Result[0], Length(Hex));
  Off := Length(Hex);
  Move(AData[0], Result[Off], Length(AData));
  Result[Off + Length(AData)] := 13;
  Result[Off + Length(AData) + 1] := 10;
end;

function TH1ChunkedChannel.Send(const AData: TBytes): TSendResult;
var
  Owner: IH1ChannelOwner;
  State: TChannelState;
  Wire: TBytes;
begin
  Result := srClosed;
  if Length(AData) = 0 then
  begin
    if IsOpen then
      Result := srQueued;
    Exit;
  end;
  FLock.Acquire;
  try
    Owner := FOwner;
    State := FState;
    if (State = csClosed) or (Owner = nil) then
      Exit;
    if (State = csPending) or FActivating then
    begin
      // no body octet may leave before the head, so a pending channel holds it.
      // The same holds while Activate sends the head and the held bytes, or a
      // late Send could overtake them
      if (FRegistry <> nil) and (FRegistry.QueueLimit > 0) and
         (Length(FHold) + Length(AData) > FRegistry.QueueLimit) then
        Exit(srFull);
      SetLength(FHold, Length(FHold) + Length(AData));
      Move(AData[0], FHold[Length(FHold) - Length(AData)], Length(AData));
      Exit(srQueued);
    end;
  finally
    FLock.Release;
  end;
  if Owner.OwnerNoBody then
    Exit(srQueued);
  if (FRegistry <> nil) and (FRegistry.QueueLimit > 0) and
     (Owner.OwnerBacklog > FRegistry.QueueLimit) then
  begin
    // the writer is refused; it hears WriteDrained when the backlog falls
    if FSink <> nil then
      Owner.OwnerWatchDrain(FRegistry.LowWater, FSink);
    Exit(srFull);
  end;
  Wire := Frame(AData);
  Owner.OwnerEmit(Wire);
  Result := srQueued;
end;

procedure TH1ChunkedChannel.Activate(const AStatus: Integer;
  const AHeaders: THeaderBlock);
var
  Owner: IH1ChannelOwner;
  Held: TBytes;
  Mode: TChannelClose;
  CloseNow: Boolean;
begin
  FLock.Acquire;
  try
    if (FState <> csPending) or FActivating then
      raise EHttpError.Create('Activate needs a pending channel');
    Owner := FOwner;
    FActivating := True;
  finally
    FLock.Release;
  end;
  try
    Owner.OwnerHead(AStatus, AHeaders);
  except
    FLock.Acquire;
    try
      FActivating := False;
    finally
      FLock.Release;
    end;
    raise;
  end;
  // the held bytes go out in order. A Send that comes meanwhile joins the held
  // bytes, so the loop runs until the hold is empty, and only then does the
  // channel turn active
  repeat
    FLock.Acquire;
    try
      Held := FHold;
      FHold := nil;
      if Length(Held) = 0 then
      begin
        if FState = csPending then
          FState := csActive;
        FActivating := False;
      end;
    finally
      FLock.Release;
    end;
    if (Length(Held) > 0) and not Owner.OwnerNoBody then
      Owner.OwnerEmit(Frame(Held));
  until Length(Held) = 0;
  // a Close that came during the activation runs now
  FLock.Acquire;
  try
    CloseNow := FCloseDuringActivate;
    Mode := FCloseMode;
    FCloseDuringActivate := False;
  finally
    FLock.Release;
  end;
  if CloseNow then
    Close(Mode);
end;

procedure TH1ChunkedChannel.Complete(const AStatus: Integer;
  const AHeaders: THeaderBlock; const ABody: TBytes);
var
  Owner: IH1ChannelOwner;
begin
  FLock.Acquire;
  try
    if FState <> csPending then
      raise EHttpError.Create('Complete needs a pending channel');
    Owner := FOwner;
    FState := csClosed;
    FHold := nil;
  finally
    FLock.Release;
  end;
  Owner.OwnerComplete(AStatus, AHeaders, ABody);
  FLock.Acquire;
  try
    FOwner := nil;
    Release;
  finally
    FLock.Release;
  end;
end;

procedure TH1ChunkedChannel.Close(const AMode: TChannelClose);
var
  Owner: IH1ChannelOwner;
  Pending: Boolean;
begin
  FLock.Acquire;
  try
    if FState = csClosed then
      Exit;
    if FActivating then
    begin
      // the head and the held bytes are going out; Activate closes at its end
      FCloseDuringActivate := True;
      FCloseMode := AMode;
      Exit;
    end;
    Pending := FState = csPending;
    Owner := FOwner;
    FState := csClosed;
    FOwner := nil;
    FHold := nil;
    Release;
  finally
    FLock.Release;
  end;
  if Owner = nil then
    Exit;
  if (AMode = ccGraceful) and not Pending then
  begin
    // the last chunk ends the body
    if Owner.OwnerChunked then
      Owner.OwnerEmit(TBytes.Create(Ord('0'), 13, 10, 13, 10));
    Owner.OwnerFinish(True);
  end
  else
    Owner.OwnerFinish(False);
end;

function TH1ChunkedChannel.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := FState <> csClosed;
  finally
    FLock.Release;
  end;
end;

function TH1ChunkedChannel.State: TChannelState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TH1ChunkedChannel.QueuedBytes: Int64;
var
  Owner: IH1ChannelOwner;
begin
  FLock.Acquire;
  try
    Owner := FOwner;
  finally
    FLock.Release;
  end;
  if Owner = nil then
    Result := 0
  else
    Result := Owner.OwnerBacklog;
end;

procedure TH1ChunkedChannel.SetSink(const ASink: IChannelSink);
begin
  FLock.Acquire;
  try
    FSink := ASink;
  finally
    FLock.Release;
  end;
end;

procedure TH1ChunkedChannel.ReturnCredit(const ACount: Int64);
begin
  // the read side has no flow control
end;

function TH1ChunkedChannel.Registry: IChannelRegistry;
begin
  Result := FRegistry;
end;

procedure TH1ChunkedChannel.PeerGone;
var
  Sink: IChannelSink;
begin
  FLock.Acquire;
  try
    if FState = csClosed then
      Exit;
    FState := csClosed;
    FOwner := nil;
    FHold := nil;
    Sink := FSink;
    Release;
  finally
    FLock.Release;
  end;
  if Sink <> nil then
    Sink.PeerClosed(False);
end;

end.
