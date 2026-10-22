{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, upgrade, socket channel, duplex channel, websocket, raw bytes
notes:
  - This unit holds the channel of an upgraded HTTP/1.1 connection. After the 101
    response the connection carries raw bytes in both directions, and the HTTP/1.1
    parser never reads it again. Each Send is written as it is, with no chunk
    framing.
  - The channel is pending until Activate sends the 101 head. A Send before that
    waits in a hold buffer, and a Send that comes while Activate flushes the hold
    joins the hold, so no octet passes the head or the octets before it.
  - A reject through Complete answers the upgrade with an ordinary HTTP response and
    returns the connection to the HTTP/1.1 core.
  - The channel talks to its exchange through IH1UpgradeOwner, so this unit does not
    depend on the exchange unit.
---
}
/// The channel of an upgraded HTTP/1.1 connection
unit Http2Server.Http1.SocketChannel;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Duplex, Http2Server.Http1.Host;

type
  /// what the upgrade code reads from an HTTP/1.1 response and request
  IH1Upgradable = interface
    ['{7E1F0C11-00B4-4A11-9C72-000000000E04}']
    function UpgradeMethod: string;
    /// the minor version of the request: 0 or 1
    function UpgradeMinor: Integer;
    /// the request is a GET with Connection: Upgrade and Upgrade: websocket
    function UpgradeTokensPresent: Boolean;
    /// the request has a body
    function HasRequestBody: Boolean;
    /// octets of later requests that the parser holds
    function BufferedAfterHead: Int64;
    /// the WebSocket environment of the server; nil when none
    function WsEnvironment: IInterface;
    /// detach the response into a pending channel of raw bytes
    // - raises EDetachRefused when the server holds its limit of detached streams
    function DetachForUpgrade: IDuplexChannel;
  end;

  /// what the channel needs from the exchange that it was detached from
  IH1UpgradeOwner = interface
    ['{7E1F0C11-00B2-4A11-9C72-000000000E02}']
    procedure OwnerEmit(const AData: TBytes);
    function OwnerBacklog: Int64;
    /// send the head of the 101 response and switch the connection to raw bytes
    procedure OwnerUpgradeHead(const AStatus: Integer; const AHeaders: THeaderBlock);
    /// answer the upgrade with an ordinary HTTP response and resume HTTP/1.1
    procedure OwnerComplete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    /// close the connection once the queued octets have left
    procedure OwnerCloseAfterOutput;
    /// close the connection at once
    procedure OwnerAbort;
    procedure OwnerWatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
  end;

  TH1SocketChannel = class(TInterfacedObject, IDuplexChannel, IH1Inbound)
  private
    FOwner: IH1UpgradeOwner;
    FRegistry: IChannelRegistry;
    FLock: TCriticalSection;
    FState: TChannelState;
    FSink: IChannelSink;
    FHold: TBytes;
    FEarly: TBytes;
    FEarlyEnded: Boolean;
    FReleased: Boolean;
    FActivating: Boolean;
    FCloseDuringActivate: Boolean;
    FCloseMode: TChannelClose;
    procedure Release;
  public
    constructor Create(const AOwner: IH1UpgradeOwner; const ARegistry: IChannelRegistry);
    destructor Destroy; override;

    // IH1Inbound: the core of the connection calls these on an IO thread
    procedure Inbound(const AData; const ACount: Integer);
    procedure ConnectionEnded;

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

constructor TH1SocketChannel.Create(const AOwner: IH1UpgradeOwner;
  const ARegistry: IChannelRegistry);
begin
  inherited Create;
  FOwner := AOwner;
  FRegistry := ARegistry;
  FLock := TCriticalSection.Create;
  FState := csPending;
end;

destructor TH1SocketChannel.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TH1SocketChannel.Release;
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

procedure TH1SocketChannel.Inbound(const AData; const ACount: Integer);
var
  Sink: IChannelSink;
  At: Integer;
begin
  if ACount <= 0 then
    Exit;
  FLock.Acquire;
  try
    if FState = csClosed then
      Exit;
    Sink := FSink;
    if Sink = nil then
    begin
      // the session has not taken the sink yet; the octets wait for it
      At := Length(FEarly);
      SetLength(FEarly, At + ACount);
      Move(AData, FEarly[At], ACount);
      Exit;
    end;
  finally
    FLock.Release;
  end;
  Sink.BytesReceived(AData, ACount);
end;

procedure TH1SocketChannel.ConnectionEnded;
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
    if Sink = nil then
      FEarlyEnded := True;
    Release;
  finally
    FLock.Release;
  end;
  if Sink <> nil then
    Sink.PeerClosed(False);
end;

procedure TH1SocketChannel.SetSink(const ASink: IChannelSink);
var
  Early: TBytes;
  Ended: Boolean;
begin
  FLock.Acquire;
  try
    FSink := ASink;
    if ASink = nil then
      Exit;
    Early := FEarly;
    FEarly := nil;
    Ended := FEarlyEnded;
    FEarlyEnded := False;
  finally
    FLock.Release;
  end;
  if Length(Early) > 0 then
    ASink.BytesReceived(Early[0], Length(Early));
  if Ended then
    ASink.PeerClosed(False);
end;

function TH1SocketChannel.Send(const AData: TBytes): TSendResult;
var
  Owner: IH1UpgradeOwner;
  Sink: IChannelSink;
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
    if (FState = csClosed) or (Owner = nil) then
      Exit;
    if (FState = csPending) or FActivating then
    begin
      // no octet passes the 101 head or the octets that wait before it
      if (FRegistry <> nil) and (FRegistry.QueueLimit > 0) and
         (Length(FHold) + Length(AData) > FRegistry.QueueLimit) then
        Exit(srFull);
      SetLength(FHold, Length(FHold) + Length(AData));
      Move(AData[0], FHold[Length(FHold) - Length(AData)], Length(AData));
      Exit(srQueued);
    end;
    Sink := FSink;
  finally
    FLock.Release;
  end;
  if (FRegistry <> nil) and (FRegistry.QueueLimit > 0) and
     (Owner.OwnerBacklog > FRegistry.QueueLimit) then
  begin
    // the writer is refused; it hears WriteDrained when the backlog falls
    if Sink <> nil then
      Owner.OwnerWatchDrain(FRegistry.LowWater, Sink);
    Exit(srFull);
  end;
  Owner.OwnerEmit(AData);
  Result := srQueued;
end;

procedure TH1SocketChannel.Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
var
  Owner: IH1UpgradeOwner;
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
    Owner.OwnerUpgradeHead(AStatus, AHeaders);
  except
    FLock.Acquire;
    try
      FActivating := False;
    finally
      FLock.Release;
    end;
    raise;
  end;
  // the held octets go out in order; a Send that comes meanwhile joins them
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
    if Length(Held) > 0 then
      Owner.OwnerEmit(Held);
  until Length(Held) = 0;
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

procedure TH1SocketChannel.Complete(const AStatus: Integer;
  const AHeaders: THeaderBlock; const ABody: TBytes);
var
  Owner: IH1UpgradeOwner;
begin
  FLock.Acquire;
  try
    if FState <> csPending then
      raise EHttpError.Create('Complete needs a pending channel');
    Owner := FOwner;
    FState := csClosed;
    FHold := nil;
    FOwner := nil;
    Release;
  finally
    FLock.Release;
  end;
  // an ordinary response, and HTTP/1.1 resumes on the connection
  Owner.OwnerComplete(AStatus, AHeaders, ABody);
end;

procedure TH1SocketChannel.Close(const AMode: TChannelClose);
var
  Owner: IH1UpgradeOwner;
  Pending: Boolean;
begin
  FLock.Acquire;
  try
    if FState = csClosed then
      Exit;
    if FActivating then
    begin
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
    Owner.OwnerCloseAfterOutput
  else
    Owner.OwnerAbort;
end;

function TH1SocketChannel.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := FState <> csClosed;
  finally
    FLock.Release;
  end;
end;

function TH1SocketChannel.State: TChannelState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TH1SocketChannel.QueuedBytes: Int64;
var
  Owner: IH1UpgradeOwner;
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

procedure TH1SocketChannel.ReturnCredit(const ACount: Int64);
begin
  // a TCP connection has no flow-control window of its own to refill
end;

function TH1SocketChannel.Registry: IChannelRegistry;
begin
  Result := FRegistry;
end;

end.
