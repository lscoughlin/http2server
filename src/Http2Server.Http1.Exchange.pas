{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, exchange, request, response, handler job, detach
notes:
  - One TH1Exchange is one HTTP/1.1 request with its response. The same object
    is the IServerRequest and the IServerResponse that the handler sees, and the
    IHandlerJob that the handler pool runs, so the handler contract is the same
    on both protocols.
  - The IO thread writes the request body into a buffer, and the handler reads it
    and blocks until bytes arrive. The buffer is bounded by the body limit of the
    parser, because the parser checks the limit before it delivers the octets.
  - The exchange reaches the connection core through a link. The core cuts the
    link when the connection ends, so a handler thread that runs on never calls a
    core that is gone.
  - The head of the response and its framing come from Http2Server.Http1.ResponseHead.
  - A handler can detach the response. The exchange then answers through a
    TH1ChunkedChannel, and the handler thread is free.
---
}
/// One HTTP/1.1 request and its response
unit Http2Server.Http1.Exchange;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.HandlerJob, Http2Server.Http1.Guard, Http2Server.Http1.Host,
  Http2Server.Http1.ResponseHead, Http2Server.Http1.Channel,
  Http2Server.Http1.SocketChannel;

type
  TH1ExchangeOptions = record
    Scheme: string;
    /// the greatest backlog of unsent octets before a write waits
    OutboundLimit: Int64;
    /// the greatest wait between two arrivals of body octets, in milliseconds
    BodyDeadlineMs: Integer;
    /// a write that sees no progress for this time aborts the connection
    WriteStallMs: Integer;
  end;

  TH1Exchange = class(TInterfacedObject, IServerRequest, IServerResponse,
    IHandlerJob, IH1ChannelOwner, IH1UpgradeOwner, IH1Upgradable)
  private
    FLink: THostLink;
    FLinkRef: IInterface;
    FHead: TH1Head;
    FOptions: TH1ExchangeOptions;
    FOrdinal: LongWord;
    FLock: TCriticalSection;
    FBodyEv: PRTLEvent;
    FRoomEv: PRTLEvent;
    FBody: TBytes;
    FBodyHead, FBodyTail: Integer;
    FBodyEnded: Boolean;
    FCancelled: Boolean;
    FExpectAsked: Boolean;
    FLastProgressMs: QWord;
    // the response
    FHeadersSent: Boolean;
    FFinished: Boolean;
    FFraming: TH1ResponseFraming;
    FKeep: Boolean;
    FRemaining: Int64;
    FDetached: Boolean;
    FRegistry: IChannelRegistry;
    FChannel: TH1ChunkedChannel;
    FChannelRef: IDuplexChannel;
    FSocketChannel: IDuplexChannel;
    procedure CheckCanWrite;
    procedure WaitForRoom;
    procedure Emit(const AData: TBytes);
    procedure CompleteExchange(const AFailed: Boolean);
    procedure SendError(const AStatus: Integer);
    function ClaimResponse: Boolean;
    procedure SendHead(const AStatus: Integer; const AHeaders: THeaderBlock);
    procedure WriteBody(const ABuffer; const ACount: Integer);
    procedure EndResponse;
    // IH1ChannelOwner
    procedure OwnerEmit(const AData: TBytes);
    function OwnerBacklog: Int64;
    procedure OwnerHead(const AStatus: Integer; const AHeaders: THeaderBlock);
    procedure OwnerComplete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    function OwnerChunked: Boolean;
    function OwnerNoBody: Boolean;
    procedure OwnerFinish(const AGraceful: Boolean);
    procedure OwnerWatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
    // IH1UpgradeOwner (the other methods are shared with IH1ChannelOwner)
    procedure OwnerUpgradeHead(const AStatus: Integer; const AHeaders: THeaderBlock);
    procedure OwnerCloseAfterOutput;
    procedure OwnerAbort;
    // IH1Upgradable
    function UpgradeMethod: string;
    function UpgradeMinor: Integer;
    function UpgradeTokensPresent: Boolean;
    function HasRequestBody: Boolean;
    function BufferedAfterHead: Int64;
    function WsEnvironment: IInterface;
    function DetachForUpgrade: IDuplexChannel;
  public
    constructor Create(const ALink: THostLink; const AHead: TH1Head;
      const AOptions: TH1ExchangeOptions; const AOrdinal: LongWord);
    destructor Destroy; override;

    // the core feeds the body
    procedure AppendBody(const AData; const ACount: Integer);
    procedure EndBody;
    /// the request broke after the head: answer AStatus if no answer started,
    /// wake the handler and end the exchange so the connection closes
    procedure Fail(const AStatus: Integer);
    function ResponseStarted: Boolean;
    /// milliseconds since body octets last arrived; 0 once the body has ended
    function BodyIdleMs(const ANowMs: QWord): QWord;
    /// the request has ended and the body was read or dropped
    function BodyEnded: Boolean;
    function ResponseFinished: Boolean;

    // IServerRequest
    function Method: string;
    function Scheme: string;
    function Authority: string;
    function Path: string;
    function Headers: THeaderBlock;
    function Read(var ABuffer; const ACount: Integer): Integer;
    function ReadChunk(out AChunk: TBytes): Boolean;
    function BodyIsComplete: Boolean;
    function IsCancelled: Boolean;
    function StreamId: LongWord;

    // IServerResponse
    procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure Write(const AData: TBytes); overload;
    procedure Write(const ABuffer; const ACount: Integer); overload;
    procedure SetBodyWriter(const AWriter: IBodyWriter);
    procedure Finish;
    procedure RegisterCancelHook(const AHook: TCancelHook);
    function Detach: IDuplexChannel;

    // IHandlerJob
    procedure Run(const AHandler: IHttp2Handler; const ARegistry: IChannelRegistry);
    procedure Refuse(const AReason: THandlerJobRefusal);
    procedure Cancel;

    property Head: TH1Head read FHead;
  end;

implementation

uses
  Http2Server.Http1.Status, Http2Server.ResponseWriter;

const
  cWaitSliceMs = 5;

{ TH1Exchange }

constructor TH1Exchange.Create(const ALink: THostLink; const AHead: TH1Head;
  const AOptions: TH1ExchangeOptions; const AOrdinal: LongWord);
begin
  inherited Create;
  FLink := ALink;
  FLinkRef := ALink;
  FHead := AHead;
  FOptions := AOptions;
  FOrdinal := AOrdinal;
  FLock := TCriticalSection.Create;
  FBodyEv := RTLEventCreate;
  FRoomEv := RTLEventCreate;
  FLastProgressMs := GetTickCount64;
  FKeep := AHead.KeepAlive;
end;

destructor TH1Exchange.Destroy;
begin
  RTLEventDestroy(FBodyEv);
  RTLEventDestroy(FRoomEv);
  FLock.Free;
  inherited Destroy;
end;

procedure TH1Exchange.AppendBody(const AData; const ACount: Integer);
var
  Need: Integer;
begin
  if ACount <= 0 then
    Exit;
  FLock.Acquire;
  try
    // a response that finished without the body drops the rest of it
    if FCancelled or FFinished then
      Exit;
    if FBodyHead = FBodyTail then
    begin
      FBodyHead := 0;
      FBodyTail := 0;
    end;
    Need := FBodyTail + ACount;
    if Need > Length(FBody) then
      SetLength(FBody, Need + Need div 2 + 256);
    Move(AData, FBody[FBodyTail], ACount);
    FBodyTail := Need;
    FLastProgressMs := GetTickCount64;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FBodyEv);
end;

procedure TH1Exchange.EndBody;
begin
  FLock.Acquire;
  try
    FBodyEnded := True;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FBodyEv);
end;

function TH1Exchange.BodyEnded: Boolean;
begin
  FLock.Acquire;
  try
    Result := FBodyEnded;
  finally
    FLock.Release;
  end;
end;

function TH1Exchange.BodyIdleMs(const ANowMs: QWord): QWord;
begin
  FLock.Acquire;
  try
    if FBodyEnded or (ANowMs < FLastProgressMs) then
      Result := 0
    else
      Result := ANowMs - FLastProgressMs;
  finally
    FLock.Release;
  end;
end;

function TH1Exchange.ResponseFinished: Boolean;
begin
  FLock.Acquire;
  try
    Result := FFinished;
  finally
    FLock.Release;
  end;
end;

function TH1Exchange.Method: string;
begin
  Result := FHead.Line.Method;
end;

function TH1Exchange.Scheme: string;
begin
  Result := FOptions.Scheme;
end;

function TH1Exchange.Authority: string;
begin
  Result := FHead.Authority;
end;

function TH1Exchange.Path: string;
begin
  Result := FHead.Line.Target;
end;

function TH1Exchange.Headers: THeaderBlock;
begin
  Result := FHead.Fields;
end;

function TH1Exchange.IsCancelled: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCancelled;
  finally
    FLock.Release;
  end;
end;

function TH1Exchange.StreamId: LongWord;
begin
  Result := FOrdinal;
end;

function TH1Exchange.Read(var ABuffer; const ACount: Integer): Integer;
var
  Avail: Integer;
  Ask, Late: Boolean;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  while True do
  begin
    Ask := False;
    Late := False;
    FLock.Acquire;
    try
      if FCancelled then
        raise EStreamCancelled.Create('the request was cancelled');
      Avail := FBodyTail - FBodyHead;
      if Avail > 0 then
      begin
        if Avail > ACount then
          Avail := ACount;
        Move(FBody[FBodyHead], ABuffer, Avail);
        Inc(FBodyHead, Avail);
        Exit(Avail);
      end;
      if FBodyEnded then
        Exit(0);
      if FHead.Expect100 and not FExpectAsked then
      begin
        FExpectAsked := True;
        Ask := True;
      end;
      if (FOptions.BodyDeadlineMs > 0) and
         (GetTickCount64 - FLastProgressMs > QWord(FOptions.BodyDeadlineMs)) then
        Late := True;
    finally
      FLock.Release;
    end;
    if Ask then
      FLink.RequestContinue;
    if Late then
    begin
      Cancel;
      raise EStreamCancelled.Create('the request body stalled');
    end;
    RTLEventWaitFor(FBodyEv, cWaitSliceMs * 10);
  end;
end;

function TH1Exchange.ReadChunk(out AChunk: TBytes): Boolean;
var
  Buf: TBytes;
  N: Integer;
begin
  AChunk := nil;
  SetLength(Buf, 16384);
  N := Read(Buf[0], Length(Buf));
  Result := N > 0;
  if Result then
  begin
    SetLength(Buf, N);
    AChunk := Buf;
  end;
end;

function TH1Exchange.BodyIsComplete: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FBodyEnded and (FBodyTail = FBodyHead)) or FCancelled;
  finally
    FLock.Release;
  end;
end;

procedure TH1Exchange.Cancel;
var
  Channel: TH1ChunkedChannel;
begin
  FLock.Acquire;
  try
    FCancelled := True;
    Channel := FChannel;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FBodyEv);
  RTLEventSetEvent(FRoomEv);
  // the application that holds a detached channel learns that the peer is gone
  if Channel <> nil then
    Channel.PeerGone;
end;

procedure TH1Exchange.RegisterCancelHook(const AHook: TCancelHook);
begin
  // cancel hooks do not run in this server (see doc/design/threading.md)
end;

function TH1Exchange.Detach: IDuplexChannel;
var
  Pending: Boolean;
begin
  FLock.Acquire;
  try
    if FDetached then
      raise EDetachRefused.Create('the response is detached already');
    if FFinished then
      raise EHttpError.Create('the response has ended');
    Pending := not FHeadersSent;
  finally
    FLock.Release;
  end;
  if (FRegistry <> nil) and not FRegistry.TryAcquire then
    raise EDetachRefused.Create('the server holds its limit of detached streams');
  FLock.Acquire;
  try
    FDetached := True;
    FChannel := TH1ChunkedChannel.Create(Self, FRegistry, Pending);
    FChannelRef := FChannel;
    Result := FChannelRef;
  finally
    FLock.Release;
  end;
  if FRegistry <> nil then
    FRegistry.Add(Result);
end;

procedure TH1Exchange.CheckCanWrite;
begin
  if FDetached then
    raise EHttpError.Create('the response is detached');
  if FFinished then
    raise EHttpError.Create('the response has ended');
end;

procedure TH1Exchange.Emit(const AData: TBytes);
begin
  FLink.EnqueueOutput(AData);
end;

procedure TH1Exchange.WaitForRoom;
var
  Backlog, Least: Int64;
  Since: QWord;
begin
  // a write waits while the socket holds a backlog; a peer that reads slowly
  // slows the handler and does not grow the memory of the connection. A peer that
  // reads nothing for the stall time loses the connection, or the handler thread
  // would wait for it for ever: mORMot2 counts a retried write as activity, so
  // the idle check of the connection cannot see this peer
  Least := High(Int64);
  Since := GetTickCount64;
  Backlog := FLink.OutputBacklog;
  while FLink.Alive and (Backlog > FOptions.OutboundLimit) do
  begin
    if IsCancelled then
      raise EStreamCancelled.Create('the connection ended during a write');
    if Backlog < Least then
    begin
      Least := Backlog;
      Since := GetTickCount64;
    end
    else if (FOptions.WriteStallMs > 0) and
            (GetTickCount64 - Since > QWord(FOptions.WriteStallMs)) then
    begin
      FLink.AbortConnection;
      raise EStreamCancelled.Create('the peer stopped reading');
    end;
    RTLEventWaitFor(FRoomEv, cWaitSliceMs);
    Backlog := FLink.OutputBacklog;
  end;
  if (not FLink.Alive) or IsCancelled then
    raise EStreamCancelled.Create('the connection ended');
end;

procedure TH1Exchange.SendHead(const AStatus: Integer; const AHeaders: THeaderBlock);
var
  Bytes: TBytes;
  Framing: TH1ResponseFraming;
begin
  if (AStatus < 100) or (AStatus > 599) or (AStatus = 101) then
    raise EHttpError.Create('the status is not usable for a response');
  if AStatus < 200 then
  begin
    // an interim response; a final response follows
    if FHead.Line.Minor = 1 then
      Emit(H1TextBytes(Http1StatusLine(AStatus, 1) + #13#10));
    Exit;
  end;
  Bytes := H1BuildResponseHead(FHead.Line.Method, FHead.Line.Minor, FKeep,
    AStatus, AHeaders, Framing);
  if not ClaimResponse then
  begin
    // the core ended the exchange with an error answer, or the handler sent twice
    if FFinished then
      raise EStreamCancelled.Create('the exchange ended before the response');
    raise EHttpError.Create('the response headers were sent already');
  end;
  FFraming := Framing;
  FKeep := Framing.Keep;
  FRemaining := Framing.Remaining;
  WaitForRoom;
  Emit(Bytes);
end;

procedure TH1Exchange.SendHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
begin
  CheckCanWrite;
  SendHead(AStatus, AHeaders);
  if AEndStream then
    Finish;
end;

procedure TH1Exchange.Write(const AData: TBytes);
begin
  if Length(AData) > 0 then
    Write(AData[0], Length(AData));
end;

procedure TH1Exchange.WriteBody(const ABuffer; const ACount: Integer);
var
  Frame: TBytes;
  Hex: string;
  Off: Integer;
begin
  if not FHeadersSent then
    raise EHttpError.Create('Write before SendHeaders');
  if ACount <= 0 then
    Exit;
  if FFraming.NoBody then
    Exit;   // a HEAD response and a 204 or 304 response carry no body
  WaitForRoom;
  if FFraming.Chunked then
  begin
    Hex := IntToHex(ACount, 1) + #13#10;
    SetLength(Frame, Length(Hex) + ACount + 2);
    Move(Hex[1], Frame[0], Length(Hex));
    Off := Length(Hex);
    Move(ABuffer, Frame[Off], ACount);
    Frame[Off + ACount] := 13;
    Frame[Off + ACount + 1] := 10;
  end
  else
  begin
    if (not FFraming.CloseDelimited) and (ACount > FRemaining) then
      raise EHttpError.Create('the handler wrote more than its Content-Length');
    SetLength(Frame, ACount);
    Move(ABuffer, Frame[0], ACount);
    if not FFraming.CloseDelimited then
      Dec(FRemaining, ACount);
  end;
  Emit(Frame);
end;

procedure TH1Exchange.Write(const ABuffer; const ACount: Integer);
begin
  CheckCanWrite;
  WriteBody(ABuffer, ACount);
end;

procedure TH1Exchange.SetBodyWriter(const AWriter: IBodyWriter);
var
  Chunk: TBytes;
begin
  CheckCanWrite;
  while AWriter.NextChunk(Chunk) do
    Write(Chunk);
  Finish;
end;

procedure TH1Exchange.CompleteExchange(const AFailed: Boolean);
begin
  FLock.Acquire;
  try
    if FFinished then
      Exit;
    FFinished := True;
  finally
    FLock.Release;
  end;
  FLink.ExchangeFinished(FKeep and not AFailed, AFailed);
end;

procedure TH1Exchange.EndResponse;
var
  Failed: Boolean;
begin
  Failed := False;
  if FFraming.Chunked then
    Emit(H1TextBytes('0'#13#10#13#10))
  else if (not FFraming.CloseDelimited) and (not FFraming.NoBody) and (FRemaining > 0) then
    // the handler promised more octets than it wrote; the client would wait
    Failed := True;
  if FFraming.CloseDelimited then
    FKeep := False;
  CompleteExchange(Failed);
end;

procedure TH1Exchange.Finish;
begin
  if FDetached or FFinished then
    Exit;
  if not FHeadersSent then
    raise EHttpError.Create('Finish before SendHeaders');
  EndResponse;
end;

procedure TH1Exchange.SendError(const AStatus: Integer);
var
  Extra: THeaderBlock;
begin
  Extra := nil;
  if not ClaimResponse then
    Exit;
  FKeep := False;
  Emit(H1ErrorResponse(AStatus, FHead.Line.Minor, Extra));
  CompleteExchange(True);
end;

procedure TH1Exchange.Fail(const AStatus: Integer);
begin
  // wake the handler first, then answer if the handler has not
  Cancel;
  SendError(AStatus);
  // a response that was already under way is cut: the connection closes
  CompleteExchange(True);
end;

function TH1Exchange.ClaimResponse: Boolean;
begin
  FLock.Acquire;
  try
    Result := not FHeadersSent;
    FHeadersSent := True;
  finally
    FLock.Release;
  end;
end;

function TH1Exchange.ResponseStarted: Boolean;
begin
  FLock.Acquire;
  try
    Result := FHeadersSent;
  finally
    FLock.Release;
  end;
end;

procedure TH1Exchange.Run(const AHandler: IHttp2Handler;
  const ARegistry: IChannelRegistry);
begin
  FRegistry := ARegistry;
  try
    AHandler.Handle(Self, Self);
  except
    on EStreamCancelled do
      ;   // the cancellation ends the handler quietly
    on E: Exception do
    begin
      if not FDetached then
        if not FHeadersSent then
          SendError(500)
        else
          // the response is cut: a truncated chunked body must not look whole
          CompleteExchange(True);
      raise;
    end;
  end;
  if FDetached or FFinished then
    Exit;
  if FHeadersSent then
    Finish
  else if not IsCancelled then
    SendError(500)
  else
    CompleteExchange(True);
end;

procedure TH1Exchange.Refuse(const AReason: THandlerJobRefusal);
var
  Extra: THeaderBlock;
begin
  Extra := nil;
  FKeep := False;
  FHeadersSent := True;
  if AReason <> jrStopped then
  begin
    SetLength(Extra, 1);
    Extra[0].Name := 'retry-after';
    Extra[0].Value := '1';
  end;
  Emit(H1ErrorResponse(503, FHead.Line.Minor, Extra));
  CompleteExchange(True);
end;

{ IH1ChannelOwner }

procedure TH1Exchange.OwnerEmit(const AData: TBytes);
begin
  Emit(AData);
end;

function TH1Exchange.OwnerBacklog: Int64;
begin
  Result := FLink.OutputBacklog;
end;

procedure TH1Exchange.OwnerHead(const AStatus: Integer; const AHeaders: THeaderBlock);
begin
  SendHead(AStatus, AHeaders);
end;

procedure TH1Exchange.OwnerComplete(const AStatus: Integer;
  const AHeaders: THeaderBlock; const ABody: TBytes);
var
  H: THeaderBlock;
  N: Integer;
begin
  // a refused upgrade: HTTP/1.1 resumes on the connection after this response
  if FSocketChannel <> nil then
    FLink.UpgradeCancel;
  // a whole response with a body: the length is known, so the head carries it
  H := Copy(AHeaders);
  N := Length(H);
  SetLength(H, N + 1);
  H[N].Name := 'content-length';
  H[N].Value := IntToStr(Length(ABody));
  H[N].Sensitive := False;
  SendHead(AStatus, H);
  if Length(ABody) > 0 then
    WriteBody(ABody[0], Length(ABody));
  EndResponse;
end;

function TH1Exchange.OwnerChunked: Boolean;
begin
  Result := FFraming.Chunked;
end;

function TH1Exchange.OwnerNoBody: Boolean;
begin
  Result := FFraming.NoBody;
end;

procedure TH1Exchange.OwnerFinish(const AGraceful: Boolean);
begin
  if AGraceful and FFraming.CloseDelimited then
    FKeep := False;
  FChannel := nil;
  CompleteExchange(not AGraceful);
  // an abort drops the connection at once, with the octets that wait
  if not AGraceful then
    FLink.AbortConnection;
end;

procedure TH1Exchange.OwnerWatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
begin
  FLink.WatchDrain(ALowWater, ASink);
end;

{ upgrade }

function TH1Exchange.UpgradeMethod: string;
begin
  Result := FHead.Line.Method;
end;

function TH1Exchange.UpgradeMinor: Integer;
begin
  Result := FHead.Line.Minor;
end;

function TH1Exchange.UpgradeTokensPresent: Boolean;
begin
  Result := FHead.WebSocketUpgrade;
end;

function TH1Exchange.HasRequestBody: Boolean;
begin
  Result := FHead.Framing <> bfNone;
end;

function TH1Exchange.BufferedAfterHead: Int64;
begin
  Result := FLink.BufferedAfterHead;
end;

function TH1Exchange.WsEnvironment: IInterface;
begin
  if FRegistry = nil then
    Result := nil
  else
    Result := FRegistry.WsEnvironment;
end;

function TH1Exchange.DetachForUpgrade: IDuplexChannel;
var
  Channel: TH1SocketChannel;
begin
  FLock.Acquire;
  try
    if FDetached then
      raise EDetachRefused.Create('the response is detached already');
    if FFinished or FHeadersSent then
      raise EHttpError.Create('the response has started');
  finally
    FLock.Release;
  end;
  if (FRegistry <> nil) and not FRegistry.TryAcquire then
    raise EDetachRefused.Create('the server holds its limit of detached streams');
  Channel := TH1SocketChannel.Create(Self, FRegistry);
  FLock.Acquire;
  try
    FDetached := True;
    FSocketChannel := Channel;
    Result := FSocketChannel;
  finally
    FLock.Release;
  end;
  // from now on the octets of the connection belong to the channel, and the HTTP
  // parser reads no further request until the upgrade is refused
  FLink.UpgradeBegin(Channel);
  if FRegistry <> nil then
    FRegistry.Add(Result);
end;

procedure TH1Exchange.OwnerUpgradeHead(const AStatus: Integer; const AHeaders: THeaderBlock);
var
  S: string;
  I: Integer;
begin
  CheckResponseHeaders(AHeaders);
  if not ClaimResponse then
    raise EHttpError.Create('the response headers were sent already');
  S := Http1StatusLine(AStatus, 1);
  for I := 0 to High(AHeaders) do
    S := S + AHeaders[I].Name + ': ' + AHeaders[I].Value + #13#10;
  S := S + #13#10;
  FKeep := False;
  Emit(H1TextBytes(S));
  FLock.Acquire;
  try
    FFinished := True;
  finally
    FLock.Release;
  end;
  // the connection carries raw bytes from now on; no close follows
  FLink.UpgradeDone;
end;

procedure TH1Exchange.OwnerCloseAfterOutput;
begin
  FLink.CloseAfterOutput;
end;

procedure TH1Exchange.OwnerAbort;
begin
  FLink.AbortConnection;
end;

end.
