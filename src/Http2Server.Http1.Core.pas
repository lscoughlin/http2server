{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, connection core, keep-alive, pipelining, output queue, close
notes:
  - The core serves one HTTP/1.1 connection. It holds no socket. The async layer
    feeds it the octets that arrive and takes the octets that it queues.
  - One request is served at a time. The octets of later requests wait in the
    parser buffer until the response ends, so the handler contract stays as it is
    on HTTP/2. The number of waiting octets is capped by a limit.
  - A request that the guard rejects gets an error response, and the connection
    closes after the response. The core then discards the octets that follow, so
    a request behind a framing defect is never served.
  - The lock order is the core lock first and the lock of an exchange second. An
    exchange calls the core through its link, never while it holds its own lock.
---
}
/// The HTTP/1.1 connection core
unit Http2Server.Http1.Core;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Hpack, Http2Server.Output, Http2Server.HandlerJob, Http2Server.Duplex,
  Http2Server.Http1.Limits, Http2Server.Http1.Guard, Http2Server.Http1.Parser,
  Http2Server.Http1.Host, Http2Server.Http1.ResponseHead, Http2Server.Http1.Exchange;

const
  /// the most octets that the core keeps while an upgrade is undecided
  cH1HeldMax = 65536;

type
  /// the octets that the socket holds back, beyond the queue of the core
  TH1PendingProbe = function: Int64 of object;

  /// what the core needs from the server
  IH1Events = interface
    ['{7E1F0C11-00A1-4A11-9C72-000000000D01}']
    /// queue a request for a handler; the pool refuses by calling Job.Refuse
    procedure Admit(const AJob: IHandlerJob);
  end;

  TH1CoreOptions = record
    Limits: THttp11Limits;
    Scheme: string;
    /// the backlog of unsent octets at which a handler write waits
    OutboundLimit: Int64;
    /// a handler write that sees no progress for this time aborts the connection;
    /// 0 turns the check off
    WriteStallMs: Integer;
  end;

  /// the HTTP/1.1 core of one connection
  TH1Core = class(TH1Host, IH1ParserSink)
  private
    FOptions: TH1CoreOptions;
    FEvents: IH1Events;
    FLock: TCriticalSection;
    FParser: TH1Parser;
    FLink: THostLink;
    FLinkRef: IInterface;
    FOutLock: TCriticalSection;
    FOut: TList<TBytes>;
    FOutBytes: Int64;
    /// the writer of a detached stream that waits for the backlog to fall
    FDrainWatcher: IChannelSink;
    FDrainLow: Int64;
    FPendingProbe: TH1PendingProbe;
    FWaker: IWriteWaker;
    FCurrent: TH1Exchange;
    FCurrentRef: IInterface;
    FOrdinal: LongWord;
    FExchangeDone, FRequestDone: Boolean;
    FKeepAfter: Boolean;
    FCloseAfter: Boolean;
    FLost: Boolean;
    /// the connection closes without waiting for the queued octets
    FAbort: Boolean;
    /// the target of the octets that arrive while an upgrade is decided or done
    FInbound: IH1Inbound;
    /// the 101 response is out: the connection carries raw bytes
    FUpgraded: Boolean;
    /// the octets that went to the target while the upgrade was undecided; a
    /// refused upgrade hands them back to the parser
    FHeld: TBytes;
    /// more octets came than FHeld may hold
    FHeldLost: Boolean;
    /// when the first octet of the request in progress arrived; 0 when none
    FHeadStartMs: QWord;
    /// the server stops: no request of this connection keeps it alive
    FDraining: Boolean;
    /// a defect came behind the request in progress: it finishes, then the
    /// connection closes
    FStopAfter: Boolean;
    procedure Enqueue(const AData: TBytes);
    procedure Advance;
    procedure RefuseDirect(const AStatus: Integer);
    function GetBusy: Boolean;
    // IUnknown without a count
    function QueryInterface(constref IID: TGuid; out Obj): LongInt;
      {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    function _AddRef: LongInt; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    function _Release: LongInt; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
    // IH1ParserSink
    procedure HeadComplete(const AHead: TH1Head);
    procedure BodyBytes(const AData; const ACount: Integer);
    procedure BodyEnd;
    procedure Rejected(const AVerdict: TH1Verdict);
  public
    constructor Create(const AOptions: TH1CoreOptions; const AEvents: IH1Events);
    destructor Destroy; override;
    procedure SetWriteWaker(const AWaker: IWriteWaker);
    /// the octets that the socket holds back count in the backlog of a writer
    procedure SetPendingProbe(const AProbe: TH1PendingProbe);
    /// tell a refused writer that the backlog fell; call after the socket wrote
    procedure NotifyDrain;

    /// the octets that arrived on the socket; the call runs on an IO thread
    procedure Feed(const AData: TBytes);
    /// the next buffer for the socket; false when none waits
    function TakeOutput(out AData: TBytes): Boolean;
    function HasOutput: Boolean;
    /// the connection closes once the output has left the socket
    function WantsClose: Boolean;
    /// the socket is gone
    procedure ConnectionLost;
    /// a request is half read for longer than AHeadTimeoutMs, or its body stalled
    // - the call queues a 408 answer and arranges the close
    function CheckDeadlines(const ANowMs: QWord; const AHeadTimeoutMs: Integer): Boolean;
    /// a request is being read or served
    property Busy: Boolean read GetBusy;
    /// a writer asked for the connection to close without waiting
    function AbortRequested: Boolean;
    /// the server stops. An idle connection closes once its output has left. A
    /// request in progress finishes, and its response says `connection: close`
    procedure BeginDrain;
    /// cut the exchanges from this core, before the owner frees what a call reaches
    procedure ReleaseHost;
    /// the connection was upgraded and carries raw bytes
    function Upgraded: Boolean;

    // TH1Host: the exchange calls these through the link
    procedure EnqueueOutput(const AData: TBytes); override;
    function OutputBacklog: Int64; override;
    procedure RequestContinue; override;
    procedure ExchangeFinished(const AKeepAlive, AFailed: Boolean); override;
    procedure WatchDrain(const ALowWater: Int64; const ASink: IChannelSink); override;
    procedure AbortConnection; override;
    function BufferedAfterHead: Int64; override;
    procedure UpgradeBegin(const ATarget: IH1Inbound); override;
    procedure UpgradeDone; override;
    procedure UpgradeCancel; override;
    procedure CloseAfterOutput; override;
  end;

implementation

constructor TH1Core.Create(const AOptions: TH1CoreOptions; const AEvents: IH1Events);
begin
  inherited Create;
  FOptions := AOptions;
  FEvents := AEvents;
  FLock := TCriticalSection.Create;
  FOutLock := TCriticalSection.Create;
  FOut := TList<TBytes>.Create;
  FLink := THostLink.Create(Self);
  FLinkRef := FLink;
  FParser := TH1Parser.Create(AOptions.Limits, Self);
end;

destructor TH1Core.Destroy;
begin
  // a handler thread may still hold an exchange; the link makes its calls
  // harmless, and Orphan waits for a call that runs now
  FLink.Orphan;
  FLinkRef := nil;
  FParser.Free;
  FCurrentRef := nil;
  FCurrent := nil;
  FOut.Free;
  FOutLock.Free;
  FLock.Free;
  inherited Destroy;
end;

function TH1Core.QueryInterface(constref IID: TGuid; out Obj): LongInt;
begin
  if GetInterface(IID, Obj) then
    Result := 0
  else
    Result := LongInt($80004002);
end;

function TH1Core._AddRef: LongInt;
begin
  Result := -1;
end;

function TH1Core._Release: LongInt;
begin
  Result := -1;
end;

procedure TH1Core.SetWriteWaker(const AWaker: IWriteWaker);
begin
  FWaker := AWaker;
end;

procedure TH1Core.Enqueue(const AData: TBytes);
begin
  if Length(AData) = 0 then
    Exit;
  FOutLock.Acquire;
  try
    FOut.Add(AData);
    Inc(FOutBytes, Length(AData));
  finally
    FOutLock.Release;
  end;
  if FWaker <> nil then
    FWaker.Signal;
end;

procedure TH1Core.EnqueueOutput(const AData: TBytes);
begin
  Enqueue(AData);
end;

function TH1Core.OutputBacklog: Int64;
begin
  FOutLock.Acquire;
  try
    Result := FOutBytes;
  finally
    FOutLock.Release;
  end;
  // the octets that left the queue but not the socket count as well, or a client
  // that never reads would make the memory of the connection grow
  if Assigned(FPendingProbe) then
    Inc(Result, FPendingProbe());
end;

procedure TH1Core.SetPendingProbe(const AProbe: TH1PendingProbe);
begin
  FPendingProbe := AProbe;
end;

procedure TH1Core.NotifyDrain;
var
  Watcher: IChannelSink;
  Backlog: Int64;
begin
  Backlog := OutputBacklog;
  Watcher := nil;
  FOutLock.Acquire;
  try
    if (FDrainWatcher <> nil) and (Backlog <= FDrainLow) then
    begin
      Watcher := FDrainWatcher;
      FDrainWatcher := nil;
    end;
  finally
    FOutLock.Release;
  end;
  if Watcher <> nil then
    Watcher.WriteDrained;
end;

function TH1Core.TakeOutput(out AData: TBytes): Boolean;
begin
  AData := nil;
  FOutLock.Acquire;
  try
    Result := FOut.Count > 0;
    if Result then
    begin
      AData := FOut[0];
      FOut.Delete(0);
      Dec(FOutBytes, Length(AData));
    end;
  finally
    FOutLock.Release;
  end;
end;

function TH1Core.Upgraded: Boolean;
begin
  FLock.Acquire;
  try
    Result := FUpgraded;
  finally
    FLock.Release;
  end;
end;

function TH1Core.BufferedAfterHead: Int64;
begin
  FLock.Acquire;
  try
    Result := FParser.Buffered;
  finally
    FLock.Release;
  end;
end;

procedure TH1Core.UpgradeBegin(const ATarget: IH1Inbound);
begin
  FLock.Acquire;
  try
    FInbound := ATarget;
  finally
    FLock.Release;
  end;
end;

procedure TH1Core.UpgradeDone;
begin
  FLock.Acquire;
  try
    // the exchange ends without a close: the connection goes on as raw bytes
    FExchangeDone := True;
    FRequestDone := True;
    FCurrentRef := nil;
    FCurrent := nil;
    FUpgraded := True;
    FHeld := nil;
  finally
    FLock.Release;
  end;
end;

procedure TH1Core.UpgradeCancel;
begin
  FLock.Acquire;
  try
    FInbound := nil;
    // the octets that the closed channel dropped belong to the next request
    if FHeldLost then
      FCloseAfter := True
    else if Length(FHeld) > 0 then
      FParser.Feed(FHeld[0], Length(FHeld));
    FHeld := nil;
    FHeldLost := False;
  finally
    FLock.Release;
  end;
end;

procedure TH1Core.CloseAfterOutput;
begin
  FLock.Acquire;
  try
    FCloseAfter := True;
  finally
    FLock.Release;
  end;
  if FWaker <> nil then
    FWaker.Signal;
end;

procedure TH1Core.BeginDrain;
var
  Current: TH1Exchange;
begin
  FLock.Acquire;
  try
    FDraining := True;
    Current := FCurrent;
    // an idle connection has nothing to wait for
    if (Current = nil) and (FParser.Buffered = 0) and (FHeadStartMs = 0) and
       not FUpgraded then
      FCloseAfter := True;
  finally
    FLock.Release;
  end;
  if Current <> nil then
    Current.RequestClose;
end;

procedure TH1Core.ReleaseHost;
begin
  FLink.Orphan;
end;

function TH1Core.AbortRequested: Boolean;
begin
  FLock.Acquire;
  try
    Result := FAbort;
  finally
    FLock.Release;
  end;
end;

procedure TH1Core.AbortConnection;
begin
  FLock.Acquire;
  try
    FAbort := True;
    FCloseAfter := True;
  finally
    FLock.Release;
  end;
  if FWaker <> nil then
    FWaker.Signal;
end;

procedure TH1Core.WatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
begin
  FOutLock.Acquire;
  try
    FDrainWatcher := ASink;
    FDrainLow := ALowWater;
  finally
    FOutLock.Release;
  end;
end;

function TH1Core.HasOutput: Boolean;
begin
  FOutLock.Acquire;
  try
    Result := FOut.Count > 0;
  finally
    FOutLock.Release;
  end;
end;

function TH1Core.WantsClose: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FCloseAfter or FLost) and not HasOutput;
  finally
    FLock.Release;
  end;
end;

function TH1Core.GetBusy: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FCurrent <> nil) or (FParser.Buffered > 0) or (FHeadStartMs <> 0);
  finally
    FLock.Release;
  end;
end;

procedure TH1Core.RequestContinue;
begin
  Enqueue(H1ContinueResponse);
end;

procedure TH1Core.RefuseDirect(const AStatus: Integer);
var
  Extra: THeaderBlock;
begin
  Extra := nil;
  Enqueue(H1ErrorResponse(AStatus, 1, Extra));
  FCloseAfter := True;
end;

procedure TH1Core.Feed(const AData: TBytes);
var
  Target: IH1Inbound;
begin
  if Length(AData) = 0 then
    Exit;
  Target := nil;
  FLock.Acquire;
  try
    // after an error answer or a close request, later octets are dropped: the
    // request behind a framing defect is never served
    if FLost or FCloseAfter or FStopAfter then
      Exit;
    // an upgrade is decided or done: the octets belong to its channel
    Target := FInbound;
    if (Target <> nil) and not FUpgraded then
    begin
      // keep a copy until the upgrade is final; an overflow closes the
      // connection after a refusal, never serves a torn request
      if Length(FHeld) + Length(AData) <= cH1HeldMax then
      begin
        SetLength(FHeld, Length(FHeld) + Length(AData));
        Move(AData[0], FHeld[Length(FHeld) - Length(AData)], Length(AData));
      end
      else
        FHeldLost := True;
    end;
    if Target = nil then
    begin
      if (FHeadStartMs = 0) and (FCurrent = nil) then
        FHeadStartMs := GetTickCount64;
      FParser.Feed(AData[0], Length(AData));
    end;
  finally
    FLock.Release;
  end;
  // outside the lock: the channel calls into the session
  if Target <> nil then
    Target.Inbound(AData[0], Length(AData));
end;

procedure TH1Core.HeadComplete(const AHead: TH1Head);
var
  Options: TH1ExchangeOptions;
  Exchange: TH1Exchange;
  Ref: IInterface;
begin
  // the lock of the core is held by the caller
  FHeadStartMs := 0;
  Inc(FOrdinal, 2);
  Options.Scheme := FOptions.Scheme;
  Options.OutboundLimit := FOptions.OutboundLimit;
  Options.BodyDeadlineMs := FOptions.Limits.BodyDeadlineMs;
  Options.BodyTotalMs := FOptions.Limits.BodyTotalMs;
  Options.WriteStallMs := FOptions.WriteStallMs;
  Exchange := TH1Exchange.Create(FLink, AHead, Options, FOrdinal - 1);
  Ref := Exchange;
  FCurrentRef := Ref;
  FCurrent := Exchange;
  FExchangeDone := False;
  FRequestDone := False;
  FKeepAfter := AHead.KeepAlive and not FDraining;
  if FDraining then
    Exchange.RequestClose;
  // the request enters the same queue as an HTTP/2 stream. A refusal comes back
  // as a call of Refuse on the job, which ends the exchange
  FEvents.Admit(Exchange);
end;

procedure TH1Core.BodyBytes(const AData; const ACount: Integer);
begin
  if FCurrent <> nil then
    FCurrent.AppendBody(AData, ACount);
end;

procedure TH1Core.BodyEnd;
begin
  if FCurrent <> nil then
    FCurrent.EndBody;
  FRequestDone := True;
  Advance;
end;

procedure TH1Core.Rejected(const AVerdict: TH1Verdict);
begin
  FHeadStartMs := 0;
  if (FCurrent <> nil) and FRequestDone and not FExchangeDone then
  begin
    // the defect is in the octets behind the request that is served now (a
    // pipeline over its limit, or a malformed next request). The request in
    // progress is valid, so it finishes. The connection closes after it, and
    // the octets behind it are dropped
    FStopAfter := True;
    Exit;
  end;
  if (FCurrent <> nil) and not FExchangeDone then
  begin
    // the request broke after its head: the exchange answers if it has not, and
    // wakes the handler
    FCurrent.Fail(AVerdict.Status);
    FCloseAfter := True;
    Exit;
  end;
  if (FCurrent <> nil) and FExchangeDone then
  begin
    // the exchange ended already (an early response): the defect belongs to no
    // request, so no second response goes out. The connection closes
    FCloseAfter := True;
    Exit;
  end;
  // a defect in a request that no exchange holds: answer, then close
  RefuseDirect(AVerdict.Status);
end;

procedure TH1Core.ExchangeFinished(const AKeepAlive, AFailed: Boolean);
begin
  FLock.Acquire;
  try
    FExchangeDone := True;
    FKeepAfter := AKeepAlive and not AFailed and not FDraining and not FStopAfter;
    if not FKeepAfter then
      FCloseAfter := True;
    Advance;
  finally
    FLock.Release;
  end;
  if FWaker <> nil then
    FWaker.Signal;
end;

procedure TH1Core.Advance;
begin
  // the lock of the core is held by the caller
  if not (FExchangeDone and FRequestDone) then
    Exit;
  FCurrentRef := nil;
  FCurrent := nil;
  if FKeepAfter and not (FCloseAfter or FLost) then
  begin
    FExchangeDone := False;
    FRequestDone := False;
    // the octets of the next request are parsed now; a head may complete here
    FParser.NextRequest;
    if (FParser.Buffered > 0) and (FHeadStartMs = 0) and (FCurrent = nil) then
      FHeadStartMs := GetTickCount64;
  end
  else
    FCloseAfter := True;
end;

procedure TH1Core.ConnectionLost;
var
  Ref: IInterface;
  Target: IH1Inbound;
begin
  FLock.Acquire;
  try
    FLost := True;
    Ref := FCurrentRef;
    Target := FInbound;
    if FCurrent <> nil then
      FCurrent.Cancel;
  finally
    FLock.Release;
  end;
  if Target <> nil then
    Target.ConnectionEnded;
end;

function TH1Core.CheckDeadlines(const ANowMs: QWord;
  const AHeadTimeoutMs: Integer): Boolean;
var
  Stalled: Boolean;
begin
  Result := False;
  FLock.Acquire;
  try
    if FLost or FCloseAfter then
      Exit;
    Stalled := (FHeadStartMs <> 0) and (AHeadTimeoutMs > 0) and
      (ANowMs - FHeadStartMs > QWord(AHeadTimeoutMs));
    if Stalled then
    begin
      // a partial request that missed its deadline gets a 408 and a close
      FHeadStartMs := 0;
      RefuseDirect(408);
      Result := True;
    end
    else if (FCurrent <> nil) and not FRequestDone and
            (((FOptions.Limits.BodyDeadlineMs > 0) and
              (FCurrent.BodyIdleMs(ANowMs) > QWord(FOptions.Limits.BodyDeadlineMs))) or
             ((FOptions.Limits.BodyTotalMs > 0) and
              (FCurrent.BodyAgeMs(ANowMs) > QWord(FOptions.Limits.BodyTotalMs)))) then
    begin
      // the client stopped sending the body
      FCurrent.Fail(408);
      FCloseAfter := True;
      Result := True;
    end;
  finally
    FLock.Release;
  end;
  if Result and (FWaker <> nil) then
    FWaker.Signal;
end;

end.
