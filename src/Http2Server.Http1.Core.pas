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

type
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
    FWaker: IWriteWaker;
    FCurrent: TH1Exchange;
    FCurrentRef: IInterface;
    FOrdinal: LongWord;
    FExchangeDone, FRequestDone: Boolean;
    FKeepAfter: Boolean;
    FCloseAfter: Boolean;
    FLost: Boolean;
    /// when the first octet of the request in progress arrived; 0 when none
    FHeadStartMs: QWord;
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

    // TH1Host: the exchange calls these through the link
    procedure EnqueueOutput(const AData: TBytes); override;
    function OutputBacklog: Int64; override;
    procedure RequestContinue; override;
    procedure ExchangeFinished(const AKeepAlive, AFailed: Boolean); override;
    procedure WatchDrain(const ALowWater: Int64; const ASink: IChannelSink); override;
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
end;

function TH1Core.TakeOutput(out AData: TBytes): Boolean;
var
  Watcher: IChannelSink;
begin
  AData := nil;
  Watcher := nil;
  FOutLock.Acquire;
  try
    Result := FOut.Count > 0;
    if Result then
    begin
      AData := FOut[0];
      FOut.Delete(0);
      Dec(FOutBytes, Length(AData));
      if (FDrainWatcher <> nil) and (FOutBytes <= FDrainLow) then
      begin
        Watcher := FDrainWatcher;
        FDrainWatcher := nil;
      end;
    end;
  finally
    FOutLock.Release;
  end;
  // the writer hears of the drain with no lock of the core held
  if Watcher <> nil then
    Watcher.WriteDrained;
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
begin
  if Length(AData) = 0 then
    Exit;
  FLock.Acquire;
  try
    // after an error answer or a close request, later octets are dropped: the
    // request behind a framing defect is never served
    if FLost or FCloseAfter then
      Exit;
    if (FHeadStartMs = 0) and (FCurrent = nil) then
      FHeadStartMs := GetTickCount64;
    FParser.Feed(AData[0], Length(AData));
  finally
    FLock.Release;
  end;
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
  Exchange := TH1Exchange.Create(FLink, AHead, Options, FOrdinal - 1);
  Ref := Exchange;
  FCurrentRef := Ref;
  FCurrent := Exchange;
  FExchangeDone := False;
  FRequestDone := False;
  FKeepAfter := AHead.KeepAlive;
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
  if (FCurrent <> nil) and not FExchangeDone then
  begin
    // the request broke after its head: the exchange answers if it has not, and
    // wakes the handler
    FCurrent.Fail(AVerdict.Status);
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
    FKeepAfter := AKeepAlive and not AFailed;
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
begin
  FLock.Acquire;
  try
    FLost := True;
    Ref := FCurrentRef;
    if FCurrent <> nil then
      FCurrent.Cancel;
  finally
    FLock.Release;
  end;
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
            (FOptions.Limits.BodyDeadlineMs > 0) and
            (FCurrent.BodyIdleMs(ANowMs) > QWord(FOptions.Limits.BodyDeadlineMs)) then
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
