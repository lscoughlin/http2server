{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: access log, handler, decorator, principal
notes:
  - This unit holds the handler decorator that writes one access log record for
    each request that the handler pool runs.
  - The decorator runs on the handler-pool thread. It never runs on an IO thread.
  - The decorator passes the request and the response through unchanged, so the
    upgrade and the detach interfaces of the response stay reachable.
  - WriteRefusalRecord logs a request that the pool refuses or times out before
    a handler runs.
---
}
/// The handler that wraps the handler of the application and logs each request
unit Http2Server.AccessLog.Handler;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.AccessLog;

type
  /// calls the inner handler, then gives the writer one record
  // - the record is written when the handler returns. A stream that the handler
  //   detached has the status and the body octets known at that moment
  // - a request that the pool refuses before the handler runs gets its record
  //   from WriteRefusalRecord; a request that is dropped because the peer
  //   cancelled it has no record
  TAccessLoggingHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FInner: IHttp2Handler;
    FWriter: IAccessLogWriter;
    procedure Emit(const ARequest: IServerRequest; const AResponse: IServerResponse;
      const AStart: TDateTime; const AStartTick: QWord; const AFailed: Boolean);
  public
    constructor Create(const AInner: IHttp2Handler; const AWriter: IAccessLogWriter);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

/// write the record of a request that the pool refused before a handler ran
// - AStatus is the status of the refusal answer; 0 means no response was sent
//   (an RST_STREAM), and the writer then sees status 0
// - AProbe can be nil
// - the call runs on the thread that refuses: an IO thread when the queue is
//   full, a pool thread when the queue wait limit passed
procedure WriteRefusalRecord(const AWriter: IAccessLogWriter;
  const ARequest: IServerRequest; const AProbe: IAccessLogProbe;
  const AStatus: Integer);

implementation

uses
  Http2Server.Encoding;

constructor TAccessLoggingHandler.Create(const AInner: IHttp2Handler;
  const AWriter: IAccessLogWriter);
begin
  inherited Create;
  FInner := AInner;
  FWriter := AWriter;
end;

procedure TAccessLoggingHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Start: TDateTime;
  StartTick: QWord;
begin
  Start := Now;
  StartTick := GetTickCount64;
  try
    FInner.Handle(ARequest, AResponse);
  except
    on EStreamCancelled do
    begin
      Emit(ARequest, AResponse, Start, StartTick, False);
      raise;
    end;
    on Exception do
    begin
      Emit(ARequest, AResponse, Start, StartTick, True);
      raise;
    end;
  end;
  Emit(ARequest, AResponse, Start, StartTick, False);
end;

function BuildRecord(const ARequest: IServerRequest;
  const AProbe: IAccessLogProbe; const AStart: TDateTime;
  const AStartTick: QWord): TAccessLogRecord;
var
  Headers: THeaderBlock;
begin
  Headers := ARequest.Headers;
  Result := Default(TAccessLogRecord);
  Result.StartTime := AStart;
  Result.UtcOffsetMinutes := LocalUtcOffsetMinutes;
  Result.Method := ARequest.Method;
  Result.Target := ARequest.Path;
  Result.StreamId := ARequest.StreamId;
  Result.DurationMs := Int64(GetTickCount64 - AStartTick);
  Result.UserAgent := HeaderValueOf(Headers, 'user-agent');
  Result.Referer := HeaderValueOf(Headers, 'referer');
  // an explicit principal wins over the unverified name of a Basic credential
  Result.Principal := ARequest.Principal;
  if Result.Principal = '' then
    Result.Principal := BasicAuthUser(Headers);
  Result.Protocol := 'HTTP/2.0';
  if AProbe <> nil then
  begin
    Result.RemoteAddress := AProbe.LoggedRemoteAddress;
    Result.Protocol := AProbe.LoggedProtocol;
    Result.Status := AProbe.LoggedStatus;
    Result.BodyOctets := AProbe.LoggedBodyOctets;
  end;
end;

procedure TAccessLoggingHandler.Emit(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AStart: TDateTime;
  const AStartTick: QWord; const AFailed: Boolean);
var
  Rec: TAccessLogRecord;
  Probe: IAccessLogProbe;
begin
  // a failure of the log must never end a pool thread or hide the handler error
  try
    if not Supports(AResponse, IAccessLogProbe, Probe) then
      Probe := nil;
    Rec := BuildRecord(ARequest, Probe, AStart, AStartTick);
    if AFailed and (Rec.Status = 0) then
      Rec.Status := 500;
    FWriter.Write(Rec);
  except
    // dropped on purpose
  end;
end;

procedure WriteRefusalRecord(const AWriter: IAccessLogWriter;
  const ARequest: IServerRequest; const AProbe: IAccessLogProbe;
  const AStatus: Integer);
var
  Rec: TAccessLogRecord;
begin
  if (AWriter = nil) or (ARequest = nil) then
    Exit;
  try
    Rec := BuildRecord(ARequest, AProbe, Now, GetTickCount64);
    Rec.Status := AStatus;
    Rec.BodyOctets := 0;
    AWriter.Write(Rec);
  except
    // dropped on purpose
  end;
end;

end.
