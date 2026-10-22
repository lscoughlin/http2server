{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: sse, server-sent events, detached stream, keep-alive, stall, streaming pool
notes:
  - StartSse turns a response into an event stream. The handler may return at
    once, and any thread may send events later.
  - An event stream costs no thread. The keep-alive and the stall check are
    timers of one work source of the streaming pool.
  - A send that the channel refuses is not queued. The producer sees srFull and
    decides to wait, to drop the event or to close the stream.
  - The server stores no event. A client that reconnects sends Last-Event-ID,
    and the application replays.
---
}
/// Server-sent event streams over a detached stream (WHATWG HTML section 9.2)
unit Http2Server.Sse;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.Sse.Encoder;

type
  /// an open event stream
  ISseStream = interface
    ['{7E1F0C11-0071-4A11-9C72-000000000A01}']
    /// send one event; the call is safe from any thread and never blocks
    // - events of several threads never interleave
    // - srFull: the channel queue is full and the event is dropped
    // - srClosed: the stream has ended
    // - raises ESseError for a value that the format cannot carry
    function Send(const AEvent: TSseEvent): TSendResult;
    /// send a comment line; a client ignores it
    function SendComment(const AText: UTF8String): TSendResult;
    /// end the stream after the queued events
    procedure Close;
    /// false once the stream ended: by Close, by the peer or by the server
    function IsOpen: Boolean;
    /// the Last-Event-ID request header; empty when absent or not safe
    function LastEventId: UTF8String;
  end;

/// answer AResponse with an event stream and detach it
// - the status is 200, the content type is text/event-stream and the cache
//   control is no-store
// - AExtraHeaders go out too; a caller adds CORS or x-accel-buffering here
// - raises EDetachRefused when the server holds its limit of detached streams;
//   the response is then still usable
function StartSse(const ARequest: IServerRequest;
  const AResponse: IServerResponse;
  const AExtraHeaders: THeaderBlock = nil): ISseStream;

implementation

type
  TSseStream = class(TInterfacedObject, ISseStream, IChannelSink)
  private
    FLock: TCriticalSection;
    FChannel: IDuplexChannel;
    FSource: IStreamSource;
    /// a reference to self while a timer is armed; a pool task holds no reference
    FSelf: IInterface;
    FOpen: Boolean;
    FKeepAliveMs: Integer;
    FStallMs: Integer;
    FLastSendMs: QWord;
    /// when the channel first refused bytes; 0 while it takes them
    FFullSince: QWord;
    FLastEventId: UTF8String;
    function SendBytes(const ABytes: TBytes): TSendResult;
    procedure Tick;
    procedure Arm;
    procedure Terminate(const AMode: TChannelClose);
  public
    constructor Create(const AChannel: IDuplexChannel; const ASource: IStreamSource;
      const AKeepAliveMs, AStallMs: Integer; const ALastEventId: UTF8String);
    destructor Destroy; override;
    procedure Start;
    // ISseStream
    function Send(const AEvent: TSseEvent): TSendResult;
    function SendComment(const AText: UTF8String): TSendResult;
    procedure Close;
    function IsOpen: Boolean;
    function LastEventId: UTF8String;
    // IChannelSink: an IO thread calls these
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;
  end;

function HeaderValue(const AHeaders: THeaderBlock; const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
      Exit(AHeaders[I].Value);
  Result := '';
end;

function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

constructor TSseStream.Create(const AChannel: IDuplexChannel;
  const ASource: IStreamSource; const AKeepAliveMs, AStallMs: Integer;
  const ALastEventId: UTF8String);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FChannel := AChannel;
  FSource := ASource;
  FKeepAliveMs := AKeepAliveMs;
  FStallMs := AStallMs;
  FLastEventId := ALastEventId;
  FOpen := True;
  FLastSendMs := NowMs;
end;

destructor TSseStream.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TSseStream.Start;
begin
  FChannel.SetSink(Self);
  Arm;
end;

procedure TSseStream.Arm;
var
  Period: Integer;
begin
  if FSource = nil then
    Exit;
  Period := FKeepAliveMs;
  if (FStallMs > 0) and ((Period = 0) or (FStallMs < Period)) then
    Period := FStallMs;
  if Period <= 0 then
    Exit;
  FLock.Acquire;
  try
    if not FOpen then
      Exit;
    FSelf := Self;
  finally
    FLock.Release;
  end;
  if not FSource.PostAfter(Period, Tick) then
    Terminate(ccAbort);
end;

procedure TSseStream.Tick;
var
  Now_: QWord;
  Dead: Boolean;
  Bytes: TBytes;
begin
  Dead := False;
  Bytes := nil;
  FLock.Acquire;
  try
    if not FOpen then
      Exit;
    Now_ := NowMs;
    if (FStallMs > 0) and (FFullSince <> 0) and
       (Now_ - FFullSince >= QWord(FStallMs)) then
      Dead := True
    else if (FKeepAliveMs > 0) and (Now_ - FLastSendMs >= QWord(FKeepAliveMs)) then
      Bytes := SseEncodeComment('keep-alive');
  finally
    FLock.Release;
  end;
  if Dead then
  begin
    Terminate(ccAbort);
    Exit;
  end;
  if Bytes <> nil then
    SendBytes(Bytes);
  Arm;
end;

function TSseStream.SendBytes(const ABytes: TBytes): TSendResult;
var
  Ended: Boolean;
begin
  Ended := False;
  FLock.Acquire;
  try
    if not FOpen then
      Exit(srClosed);
    Result := FChannel.Send(ABytes);
    case Result of
      srQueued:
        begin
          FLastSendMs := NowMs;
          // a refusal that lasts is the stall; the drain callback ends it
        end;
      srFull:
        if FFullSince = 0 then
          FFullSince := NowMs;
      srClosed:
        Ended := True;
    end;
  finally
    FLock.Release;
  end;
  // the channel ended under us: drop the timer and the self reference
  if Ended then
    Terminate(ccAbort);
end;

procedure TSseStream.Terminate(const AMode: TChannelClose);
var
  Keep: IInterface;
  Chan: IDuplexChannel;
begin
  FLock.Acquire;
  try
    FOpen := False;
    Keep := FSelf;
    FSelf := nil;
    Chan := FChannel;
  finally
    FLock.Release;
  end;
  if FSource <> nil then
    FSource.Close;
  if Chan <> nil then
    Chan.Close(AMode);
end;

function TSseStream.Send(const AEvent: TSseEvent): TSendResult;
begin
  Result := SendBytes(SseEncodeEvent(AEvent));
end;

function TSseStream.SendComment(const AText: UTF8String): TSendResult;
begin
  Result := SendBytes(SseEncodeComment(AText));
end;

procedure TSseStream.Close;
begin
  Terminate(ccGraceful);
end;

function TSseStream.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := FOpen and FChannel.IsOpen;
  finally
    FLock.Release;
  end;
end;

function TSseStream.LastEventId: UTF8String;
begin
  Result := FLastEventId;
end;

procedure TSseStream.BytesReceived(const AData; const ACount: Integer);
begin
  // an event stream reads no body; the credit goes back at once
  FChannel.ReturnCredit(ACount);
end;

procedure TSseStream.PeerClosed(const AClean: Boolean);
var
  Keep: IInterface;
begin
  FLock.Acquire;
  try
    // a GET request ends its half at once; that is not the end of the stream
    if AClean and FOpen and FChannel.IsOpen then
      Exit;
    FOpen := False;
    Keep := FSelf;
    FSelf := nil;
  finally
    FLock.Release;
  end;
  if FSource <> nil then
    FSource.Close;
end;

procedure TSseStream.WriteDrained;
begin
  FLock.Acquire;
  try
    FFullSince := 0;
  finally
    FLock.Release;
  end;
end;

function StartSse(const ARequest: IServerRequest;
  const AResponse: IServerResponse;
  const AExtraHeaders: THeaderBlock): ISseStream;
var
  Channel: IDuplexChannel;
  Headers: THeaderBlock;
  Registry: IChannelRegistry;
  Stream: TSseStream;
  Source: IStreamSource;
  KeepMs, StallMs, I: Integer;
begin
  Channel := AResponse.Detach;
  SetLength(Headers, 2 + Length(AExtraHeaders));
  Headers[0].Name := 'content-type';
  Headers[0].Value := 'text/event-stream';
  Headers[1].Name := 'cache-control';
  Headers[1].Value := 'no-store';
  for I := 0 to High(AExtraHeaders) do
    Headers[2 + I] := AExtraHeaders[I];
  Channel.Activate(200, Headers);
  Registry := Channel.Registry;
  KeepMs := 0;
  StallMs := 0;
  if Registry <> nil then
  begin
    KeepMs := Registry.SseKeepAliveMs;
    StallMs := Registry.SseStallTimeoutMs;
  end;
  Source := nil;
  if Registry <> nil then
    Source := Registry.NewSource;
  Stream := TSseStream.Create(Channel, Source, KeepMs, StallMs,
    SseCleanLastEventId(HeaderValue(ARequest.Headers, 'last-event-id')));
  Result := Stream;
  Stream.Start;
end;

end.
