{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, driver, staged close, deadlines, async connection
notes:
  - The driver sits between an async connection and the HTTP/1.1 core. It holds
    the decisions that depend on time and on the state of the socket: when a close
    is due, when the staged close ends, and which deadline fired. It touches no
    socket, so a test calls it with plain numbers.
  - The staged close follows RFC 9112 section 9.6. The server sends the response,
    closes the write side, and drops the octets that still arrive until the peer
    closes or a short time passes. A close with unread input would send a reset
    that can destroy the response in the buffer of the peer.
  - The driver also reports the octets that the socket holds back. The backlog that
    a handler write waits on is the queue of the core plus those octets, so a
    client that never reads cannot make the memory of the connection grow.
---
}
/// The driver of an HTTP/1.1 async connection
unit Http2Server.Http1.Driver;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2Server.Output, Http2Server.Http1.Core;

type
  /// what the connection does next about the close
  TH1ClosePhase = (
    /// nothing: the connection serves on, or the staged close still waits
    cpNone,
    /// close the write side now; the staged close has begun
    cpHalfClose,
    /// close the connection now
    cpCloseNow);

  /// what the connection does at an idle check
  TH1IdleAction = (
    iaNone,
    /// an answer was queued; send it
    iaFlush,
    /// close the connection
    iaClose);

  TH1Driver = class
  private
    FCore: TH1Core;
    FCanHalfClose: Boolean;
    FDrainUntilSec: Cardinal;
  public
    /// ACanHalfClose is False for a TLS connection, which closes at once
    constructor Create(const ACore: TH1Core; const ACanHalfClose: Boolean);
    destructor Destroy; override;
    /// octets from the socket; they are dropped while the staged close drains
    // - a request half read past the head deadline gets a 408
    procedure Received(const AData: TBytes; const AHeadTimeoutMs: Integer);
    /// the close decision, given the octets the socket still holds
    function ClosePhase(const APendingWrite: Int64; const ANowSec: Cardinal;
      const ADrainSeconds: Cardinal): TH1ClosePhase;
    /// the idle check of the connection
    function IdleAction(const ANowSec, ALastOperationSec, AIdleSeconds: Cardinal;
      const ANowMs: QWord; const AHeadTimeoutMs: Integer): TH1IdleAction;
    property Core: TH1Core read FCore;
    function Draining: Boolean;
  end;

implementation

constructor TH1Driver.Create(const ACore: TH1Core; const ACanHalfClose: Boolean);
begin
  inherited Create;
  FCore := ACore;
  FCanHalfClose := ACanHalfClose;
end;

destructor TH1Driver.Destroy;
begin
  FCore.Free;
  inherited Destroy;
end;

function TH1Driver.Draining: Boolean;
begin
  Result := FDrainUntilSec <> 0;
end;

procedure TH1Driver.Received(const AData: TBytes; const AHeadTimeoutMs: Integer);
begin
  if (Length(AData) > 0) and (FDrainUntilSec = 0) then
    FCore.Feed(AData);
  FCore.CheckDeadlines(GetTickCount64, AHeadTimeoutMs);
end;

function TH1Driver.ClosePhase(const APendingWrite: Int64; const ANowSec: Cardinal;
  const ADrainSeconds: Cardinal): TH1ClosePhase;
begin
  Result := cpNone;
  if FDrainUntilSec <> 0 then
    Exit;
  if (APendingWrite <> 0) or not FCore.WantsClose then
    Exit;
  if not FCanHalfClose then
    Exit(cpCloseNow);
  FDrainUntilSec := ANowSec + ADrainSeconds;
  Result := cpHalfClose;
end;

function TH1Driver.IdleAction(const ANowSec, ALastOperationSec, AIdleSeconds: Cardinal;
  const ANowMs: QWord; const AHeadTimeoutMs: Integer): TH1IdleAction;
begin
  Result := iaNone;
  // a staged close ends when its drain time has passed
  if (FDrainUntilSec <> 0) and (ANowSec >= FDrainUntilSec) then
    Exit(iaClose);
  // a request half read past the head deadline gets a 408 and a close
  if FCore.CheckDeadlines(ANowMs, AHeadTimeoutMs) then
    Exit(iaFlush);
  // an idle connection holds no request; a stalled writer sends nothing
  if (AIdleSeconds <> 0) and (ANowSec - ALastOperationSec >= AIdleSeconds) and
     ((not FCore.Busy) or FCore.HasOutput) then
    Result := iaClose;
end;

end.
