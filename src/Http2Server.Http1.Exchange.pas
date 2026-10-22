{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, exchange, request, response, chunked, framing, keep-alive, handler job
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
  - The response framing follows RFC 9112 section 6.3. A response that the
    handler gives a Content-Length is sent with that length. Any other response to
    an HTTP/1.1 request is chunked, and an HTTP/1.0 client gets a response that
    ends with the close of the connection.
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
  Http2Server.HandlerJob, Http2Server.Http1.Guard;

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
  end;

  /// the link between an exchange and its core
  // - every call takes the lock of the link, so Orphan waits for a call that runs
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
  end;

  TH1ExchangeOptions = record
    Scheme: string;
    /// the greatest backlog of unsent octets before a write waits
    OutboundLimit: Int64;
    /// the greatest wait between two arrivals of body octets, in milliseconds
    BodyDeadlineMs: Integer;
  end;

  TH1Exchange = class(TInterfacedObject, IServerRequest, IServerResponse,
    IHandlerJob)
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
    FNoBody: Boolean;
    FChunked: Boolean;
    FCloseDelimited: Boolean;
    FKeep: Boolean;
    FRemaining: Int64;
    FDetached: Boolean;
    function BuildHead(const AStatus: Integer; const AHeaders: THeaderBlock): TBytes;
    procedure CheckCanWrite;
    procedure WaitForRoom;
    procedure Emit(const AData: TBytes);
    procedure CompleteExchange(const AFailed: Boolean);
    procedure SendError(const AStatus: Integer);
    function ClaimResponse: Boolean;
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

/// a complete response with no body, for an error before or instead of a handler
// - the response closes the connection and has Content-Length 0
function H1ErrorResponse(const AStatus, AMinor: Integer;
  const AExtra: THeaderBlock): TBytes;

/// the 100 Continue interim response
function H1ContinueResponse: TBytes;

implementation

uses
  Http2Server.Http1.Status, Http2Server.ResponseWriter;

const
  cWaitSliceMs = 5;

function StrToBytes(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function H1ContinueResponse: TBytes;
begin
  Result := StrToBytes('HTTP/1.1 100 Continue'#13#10#13#10);
end;

function H1ErrorResponse(const AStatus, AMinor: Integer;
  const AExtra: THeaderBlock): TBytes;
var
  S: string;
  I: Integer;
begin
  S := Http1StatusLine(AStatus, AMinor);
  for I := 0 to High(AExtra) do
    S := S + AExtra[I].Name + ': ' + AExtra[I].Value + #13#10;
  S := S + 'content-length: 0'#13#10'connection: close'#13#10'date: ' + HttpDateNow +
    #13#10#13#10;
  Result := StrToBytes(S);
end;

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
  // a request with no body has ended its body already
  FBodyEnded := False;
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
begin
  FLock.Acquire;
  try
    FCancelled := True;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FBodyEv);
  RTLEventSetEvent(FRoomEv);
end;

procedure TH1Exchange.RegisterCancelHook(const AHook: TCancelHook);
begin
  // cancel hooks do not run in this server (see doc/design/threading.md)
end;

function TH1Exchange.Detach: IDuplexChannel;
begin
  Result := nil;
  raise EDetachRefused.Create('a detached stream is not available on HTTP/1.1');
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
begin
  // a write waits while the socket holds a backlog; a peer that reads slowly
  // slows the handler and does not grow the memory of the connection
  while FLink.Alive and (FLink.OutputBacklog > FOptions.OutboundLimit) do
  begin
    if IsCancelled then
      raise EStreamCancelled.Create('the connection ended during a write');
    RTLEventWaitFor(FRoomEv, cWaitSliceMs);
  end;
  if (not FLink.Alive) or IsCancelled then
    raise EStreamCancelled.Create('the connection ended');
end;

function TH1Exchange.BuildHead(const AStatus: Integer;
  const AHeaders: THeaderBlock): TBytes;
var
  I: Integer;
  S, N: string;
  HasLength: Boolean;
  Len: Int64;
begin
  CheckResponseHeaders(AHeaders);
  HasLength := False;
  Len := 0;
  S := '';
  for I := 0 to High(AHeaders) do
  begin
    N := LowerCase(AHeaders[I].Name);
    if (N = 'connection') or (N = 'keep-alive') or (N = 'transfer-encoding') or
       (N = 'upgrade') or (N = 'proxy-connection') then
      raise EHttpError.Create('a handler never sets the connection field ' + N);
    if N = 'content-length' then
    begin
      if (AStatus = 204) or (AStatus < 200) then
        Continue;
      if HasLength then
        raise EHttpError.Create('a handler set Content-Length twice');
      if not TryStrToInt64(Trim(AHeaders[I].Value), Len) or (Len < 0) then
        raise EHttpError.Create('Content-Length is not a number');
      HasLength := True;
    end;
    S := S + AHeaders[I].Name + ': ' + AHeaders[I].Value + #13#10;
  end;

  FNoBody := (FHead.Line.Method = 'HEAD') or (AStatus = 204) or (AStatus = 304);
  FChunked := False;
  FCloseDelimited := False;
  FRemaining := 0;
  if HasLength then
    FRemaining := Len
  else if not FNoBody then
  begin
    if FHead.Line.Minor = 1 then
    begin
      FChunked := True;
      S := S + 'transfer-encoding: chunked'#13#10;
    end
    else
      FCloseDelimited := True;
  end;

  // persistence: the connection stays open when the request allows it and the
  // end of the response is known to the client
  if FCloseDelimited then
    FKeep := False;
  if FHead.Line.Minor = 0 then
  begin
    if FKeep then
      S := S + 'connection: keep-alive'#13#10;
  end;
  if not FKeep then
    S := S + 'connection: close'#13#10;

  // RFC 9110 section 6.6.1: the server adds Date unless the handler set one
  if not ResponseHasHeader(AHeaders, 'date') then
    S := S + 'date: ' + HttpDateNow + #13#10;
  Result := StrToBytes(Http1StatusLine(AStatus, FHead.Line.Minor) + S + #13#10);
end;

procedure TH1Exchange.SendHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
var
  Bytes: TBytes;
begin
  CheckCanWrite;
  if (AStatus < 100) or (AStatus > 599) or (AStatus = 101) then
    raise EHttpError.Create('the status is not usable for a response');
  if AStatus < 200 then
  begin
    // an interim response; a final response follows
    if FHead.Line.Minor = 1 then
      Emit(StrToBytes(Http1StatusLine(AStatus, 1) + #13#10));
    Exit;
  end;
  Bytes := BuildHead(AStatus, AHeaders);
  if not ClaimResponse then
  begin
    // the core ended the exchange with an error answer, or the handler sent twice
    if FFinished then
      raise EStreamCancelled.Create('the exchange ended before the response');
    raise EHttpError.Create('the response headers were sent already');
  end;
  WaitForRoom;
  Emit(Bytes);
  if AEndStream then
    Finish;
end;

procedure TH1Exchange.Write(const AData: TBytes);
begin
  if Length(AData) > 0 then
    Write(AData[0], Length(AData));
end;

procedure TH1Exchange.Write(const ABuffer; const ACount: Integer);
var
  Frame: TBytes;
  Hex: string;
  Off: Integer;
begin
  CheckCanWrite;
  if not FHeadersSent then
    raise EHttpError.Create('Write before SendHeaders');
  if ACount <= 0 then
    Exit;
  if FNoBody then
    Exit;   // a HEAD response and a 204 or 304 response carry no body
  WaitForRoom;
  if FChunked then
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
    if (not FCloseDelimited) and (ACount > FRemaining) then
      raise EHttpError.Create('the handler wrote more than its Content-Length');
    SetLength(Frame, ACount);
    Move(ABuffer, Frame[0], ACount);
    if not FCloseDelimited then
      Dec(FRemaining, ACount);
  end;
  Emit(Frame);
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

procedure TH1Exchange.Finish;
var
  Failed: Boolean;
begin
  if FDetached then
    Exit;
  if FFinished then
    Exit;
  if not FHeadersSent then
    raise EHttpError.Create('Finish before SendHeaders');
  Failed := False;
  if FChunked then
    Emit(StrToBytes('0'#13#10#13#10))
  else if (not FCloseDelimited) and (not FNoBody) and (FRemaining > 0) then
    // the handler promised more octets than it wrote; the client would wait
    Failed := True;
  if FCloseDelimited then
    FKeep := False;
  CompleteExchange(Failed);
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

end.
