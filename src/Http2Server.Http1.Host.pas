{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, connection core, link, exchange, in-flight, orphan
notes:
  - This unit holds the two classes that join an HTTP/1.1 exchange to its
    connection core. TH1Host is what the core offers. THostLink is the cut-able
    link that an exchange holds.
  - The link holds no lock across a call into the core. A call counts itself in
    flight, and Orphan waits for the calls that run, so a handler thread that runs
    on after the connection ended never calls a core that is gone, and no lock-order
    cycle can form between the link and the core.
---
}
/// The link between an HTTP/1.1 exchange and its connection core
unit Http2Server.Http1.Host;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Http2Server.Duplex;

type
  /// what the exchange needs from the connection core
  TH1Host = class
  public
    /// queue bytes for the socket
    procedure EnqueueOutput(const AData: TBytes); virtual; abstract;
    /// octets queued and not yet taken by the socket
    function OutputBacklog: Int64; virtual; abstract;
    /// the handler first reads a body that the client holds back for 100 Continue
    procedure RequestContinue; virtual; abstract;
    /// the response ended
    // - AKeepAlive is the persistence decision; AFailed says that the response
    //   was cut or the exchange broke, so the connection closes
    procedure ExchangeFinished(const AKeepAlive, AFailed: Boolean); virtual; abstract;
    /// the writer cannot go on (a stalled client, an abort): close the connection
    // without waiting for the queued octets
    procedure AbortConnection; virtual; abstract;
    /// call ASink.WriteDrained once the backlog falls to ALowWater, then forget it
    procedure WatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
      virtual; abstract;
  end;

  /// the link between an exchange and its core
  // - a call counts itself in flight, and Orphan waits for the calls that run
  THostLink = class(TInterfacedObject)
  private
    FLock: TCriticalSection;
    FHost: TH1Host;
    /// calls that run in the core now; the lock is not held across a call
    FInFlight: Integer;
    function Enter: TH1Host;
    procedure Leave;
  public
    constructor Create(const AHost: TH1Host);
    destructor Destroy; override;
    /// the core is going away; later calls do nothing
    procedure Orphan;
    function Alive: Boolean;
    procedure EnqueueOutput(const AData: TBytes);
    function OutputBacklog: Int64;
    procedure RequestContinue;
    procedure ExchangeFinished(const AKeepAlive, AFailed: Boolean);
    procedure WatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
    procedure AbortConnection;
  end;

implementation

{ THostLink }

constructor THostLink.Create(const AHost: TH1Host);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHost := AHost;
end;

destructor THostLink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function THostLink.Enter: TH1Host;
begin
  FLock.Acquire;
  try
    Result := FHost;
    if Result <> nil then
      Inc(FInFlight);
  finally
    FLock.Release;
  end;
end;

procedure THostLink.Leave;
begin
  FLock.Acquire;
  try
    Dec(FInFlight);
  finally
    FLock.Release;
  end;
end;

procedure THostLink.Orphan;
var
  Deadline: QWord;
  Busy: Boolean;
begin
  FLock.Acquire;
  try
    FHost := nil;
  finally
    FLock.Release;
  end;
  // a call that began before the cut finishes; the wait is bounded
  Deadline := GetTickCount64 + 10000;
  repeat
    FLock.Acquire;
    try
      Busy := FInFlight > 0;
    finally
      FLock.Release;
    end;
    if Busy then
      Sleep(1);
  until (not Busy) or (GetTickCount64 > Deadline);
end;

function THostLink.Alive: Boolean;
begin
  FLock.Acquire;
  try
    Result := FHost <> nil;
  finally
    FLock.Release;
  end;
end;

procedure THostLink.EnqueueOutput(const AData: TBytes);
var
  H: TH1Host;
begin
  H := Enter;
  if H = nil then
    Exit;
  try
    H.EnqueueOutput(AData);
  finally
    Leave;
  end;
end;

function THostLink.OutputBacklog: Int64;
var
  H: TH1Host;
begin
  Result := 0;
  H := Enter;
  if H = nil then
    Exit;
  try
    Result := H.OutputBacklog;
  finally
    Leave;
  end;
end;

procedure THostLink.RequestContinue;
var
  H: TH1Host;
begin
  H := Enter;
  if H = nil then
    Exit;
  try
    H.RequestContinue;
  finally
    Leave;
  end;
end;

procedure THostLink.ExchangeFinished(const AKeepAlive, AFailed: Boolean);
var
  H: TH1Host;
begin
  H := Enter;
  if H = nil then
    Exit;
  try
    H.ExchangeFinished(AKeepAlive, AFailed);
  finally
    Leave;
  end;
end;
procedure THostLink.AbortConnection;
var
  H: TH1Host;
begin
  H := Enter;
  if H = nil then
    Exit;
  try
    H.AbortConnection;
  finally
    Leave;
  end;
end;

procedure THostLink.WatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
var
  H: TH1Host;
begin
  H := Enter;
  if H = nil then
    Exit;
  try
    H.WatchDrain(ALowWater, ASink);
  finally
    Leave;
  end;
end;

end.
