{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session core, sending, closing handshake, heartbeat, state
notes:
  - This unit holds the part of a WebSocket session that does not depend on how
    events reach it. It holds the state, the sender, the closing handshake, the end of
    the session, the credit rule and the timers. The class in Http2Server.Ws.Session
    adds the task queue, Init, the receive path and the stop of the server.
  - The lock of a session guards its flags and its task queue only. It is never
    held across a call into the channel or the handler.
  - A Send writes the frames of one message with one call of the channel, so the
    frames of two messages never mix and a refusal leaves nothing half written.
---
}
/// The state, the sender and the timers of a WebSocket session
unit Http2Server.Ws.SessionCore;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.Limits, Http2Server.Observer, Http2Server.Ws.Options,
  Http2Server.Ws.Types, Http2Server.Ws.Frames, Http2Server.Ws.Parser,
  Http2Server.Ws.Reader, Http2Server.Ws.Close;

type
  TWsState = (wsInit, wsOpen, wsClosing, wsEnded);

  TWsTaskKind = (wtInit, wtMessage, wtPong, wtClosed);

  TWsTask = record
    Kind: TWsTaskKind;
    Data: TBytes;
    Text: Boolean;
    Code: Word;
    Reason: string;
    Clean: Boolean;
  end;

  /// a read-only copy of the handshake request
  TWsRequestSnapshot = class(TInterfacedObject, IServerRequest)
  private
    FMethod, FScheme, FAuthority, FPath: string;
    FHeaders: THeaderBlock;
    FCancelled: Boolean;
  public
    constructor Create(const ARequest: IServerRequest);
    procedure Cancel;
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
  end;

  TWsSessionCore = class(TInterfacedObject, IWsSession)
  protected
    FEnv: IWsEnvironment;
    FOpts: TWsOptions;
    FChannel: IDuplexChannel;
    FRegistry: IChannelRegistry;
    FSource: IStreamSource;
    FHandler: IWsHandler;
    FHandshake: IWsHandshake;
    FSnapshot: TWsRequestSnapshot;
    FRequest: IServerRequest;
    FOffered: TArray<string>;
    FId: Int64;
    FLock: TCriticalSection;
    FSendLock: TCriticalSection;
    FReadLock: TCriticalSection;
    FState: TWsState;
    FInputClosed, FOutputClosed: Boolean;
    FInitDecided: Boolean;
    FCounted: Boolean;
    FDelivered: Boolean;
    FStopRequested: Boolean;
    FTimerArmed: Boolean;
    FSubprotocol: string;
    FContext: IInterface;
    FTasks: TList<TWsTask>;
    FQueuedMsgs: Integer;
    FHeldCredit: Int64;
    FChunkControl: Int64;
    FReader: TWsReader;
    FControl, FMessages: TTokenBucket;
    FLastInboundMs, FPingSentMs, FCloseSentMs: QWord;
    FSelf: IInterface;
    /// queue a task for the application and run it on the streaming pool
    procedure Post(const ATask: TWsTask); virtual; abstract;
    /// stop the time limit of Init
    procedure UnwatchInit; virtual; abstract;
    /// the session no longer closes its channel when the server stops
    procedure DropCloser; virtual; abstract;
    procedure DoTick;
    procedure TickEntry;
    procedure Arm;
    procedure Fail(const E: Exception);
    function TryEnd: Boolean;
    procedure EndWithClosed(const ACode: Word; const AReason: string; const AClean: Boolean);
    procedure EndQuietly;
    function SendControl(const AOpcode: Byte; const APayload: TBytes): TSendResult;
    procedure SendCloseFrame(const ACode: Word; const AReason: string);
    procedure ReleaseCredit(const AMessageDone: Boolean);
  public
    constructor Create(const AEnv: IWsEnvironment; const AChannel: IDuplexChannel;
      const ASource: IStreamSource; const AHandler: IWsHandler;
      const AHandshake: IWsHandshake; const ARequest: IServerRequest;
      const AOffered: TArray<string>);
    destructor Destroy; override;

    // IWsSession
    function Send(const AData: TBytes; const AText: Boolean): TSendResult;
    function SendStream(const AReader: IBodyWriter; const AText: Boolean): TSendResult;
    procedure Ping(const AData: TBytes);
    procedure Close(const ACode: Word = 1000; const AReason: string = '');
    procedure Abort;
    function IsOpen: Boolean;
    function InputClosed: Boolean;
    function OutputClosed: Boolean;
    function Subprotocol: string;
    function Request: IServerRequest;
    function Id: Int64;
    function Context: IInterface;
    procedure SetContext(const AValue: IInterface);
  end;

implementation

{ TWsRequestSnapshot }

constructor TWsRequestSnapshot.Create(const ARequest: IServerRequest);
begin
  inherited Create;
  FMethod := ARequest.Method;
  FScheme := ARequest.Scheme;
  FAuthority := ARequest.Authority;
  FPath := ARequest.Path;
  FHeaders := Copy(ARequest.Headers);
end;

procedure TWsRequestSnapshot.Cancel;
begin
  FCancelled := True;
end;

function TWsRequestSnapshot.Method: string;
begin
  Result := FMethod;
end;

function TWsRequestSnapshot.Scheme: string;
begin
  Result := FScheme;
end;

function TWsRequestSnapshot.Authority: string;
begin
  Result := FAuthority;
end;

function TWsRequestSnapshot.Path: string;
begin
  Result := FPath;
end;

function TWsRequestSnapshot.Headers: THeaderBlock;
begin
  Result := FHeaders;
end;

function TWsRequestSnapshot.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
end;

function TWsRequestSnapshot.ReadChunk(out AChunk: TBytes): Boolean;
begin
  AChunk := nil;
  Result := False;
end;

function TWsRequestSnapshot.BodyIsComplete: Boolean;
begin
  Result := True;
end;

function TWsRequestSnapshot.IsCancelled: Boolean;
begin
  Result := FCancelled;
end;

function TWsRequestSnapshot.StreamId: LongWord;
begin
  Result := 0;
end;

{ TWsSessionCore }

constructor TWsSessionCore.Create(const AEnv: IWsEnvironment;
  const AChannel: IDuplexChannel; const ASource: IStreamSource;
  const AHandler: IWsHandler; const AHandshake: IWsHandshake;
  const ARequest: IServerRequest; const AOffered: TArray<string>);
var
  Limits: TWsLimits;
begin
  inherited Create;
  FEnv := AEnv;
  FOpts := AEnv.Options;
  FChannel := AChannel;
  FRegistry := AChannel.Registry;
  FSource := ASource;
  FHandler := AHandler;
  FHandshake := AHandshake;
  FSnapshot := TWsRequestSnapshot.Create(ARequest);
  FRequest := FSnapshot;
  FOffered := Copy(AOffered);
  FId := AEnv.NextId;
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
  FReadLock := TCriticalSection.Create;
  FTasks := TList<TWsTask>.Create;
  Limits.MaxFrameSize := FOpts.MaxFrameSize;
  Limits.MaxMessageSize := FOpts.MaxMessageSize;
  Limits.MaxFragments := FOpts.MaxFragments;
  FReader := TWsReader.Create(Limits, {ARequireMasked=}True);
  FControl := TTokenBucket.Create(AEnv.Clock, FOpts.ControlBucket);
  FMessages := TTokenBucket.Create(AEnv.Clock, FOpts.MessageBucket);
  FLastInboundMs := GetTickCount64;
  FState := wsInit;
end;

destructor TWsSessionCore.Destroy;
begin
  FReader.Free;
  FControl.Free;
  FMessages.Free;
  FTasks.Free;
  FReadLock.Free;
  FSendLock.Free;
  FLock.Free;
  inherited Destroy;
end;

function TWsSessionCore.TryEnd: Boolean;
begin
  FLock.Acquire;
  try
    Result := FState <> wsEnded;
    if Result then
      FState := wsEnded;
  finally
    FLock.Release;
  end;
  if not Result then
    Exit;
  UnwatchInit;
  if FCounted then
    FEnv.SessionClosed;
  FSnapshot.Cancel;
end;

/// the session ends and the application hears Closed
procedure TWsSessionCore.EndWithClosed(const ACode: Word; const AReason: string;
  const AClean: Boolean);
var
  T: TWsTask;
begin
  if not TryEnd then
    Exit;
  T := Default(TWsTask);
  T.Kind := wtClosed;
  T.Code := ACode;
  T.Reason := AReason;
  T.Clean := AClean;
  Post(T);
end;

/// the session ends and no callback follows
procedure TWsSessionCore.EndQuietly;
begin
  TryEnd;
  if FRegistry <> nil then
    DropCloser;
  FSource.Close;
  FSelf := nil;
end;

procedure TWsSessionCore.Fail(const E: Exception);
begin
  // a callback raised: Failed is the one ending call, then a Close frame 1011
  if not TryEnd then
    Exit;
  FEnv.Report(seWsFailed, 0, E.ClassName + ': ' + E.Message);
  try
    FHandler.Failed(Self, E);
  except
    ;   // Failed must not raise; if it does, the session ends all the same
  end;
  if not FOutputClosed then
  begin
    FOutputClosed := True;
    try
      SendCloseFrame(WsCloseInternal, 'the handler failed');
    except
      ;
    end;
  end;
  FChannel.Close(ccGraceful);
  if FRegistry <> nil then
    DropCloser;
  FSource.Close;
  FSelf := nil;
end;

procedure TWsSessionCore.ReleaseCredit(const AMessageDone: Boolean);
var
  Give: Int64;
begin
  Give := 0;
  FLock.Acquire;
  try
    if AMessageDone and (FQueuedMsgs > 0) then
      Dec(FQueuedMsgs);
    if (FHeldCredit > 0) and (FQueuedMsgs * 2 < FOpts.QueuedMessages) then
    begin
      Give := FHeldCredit;
      FHeldCredit := 0;
    end;
  finally
    FLock.Release;
  end;
  if Give > 0 then
    FChannel.ReturnCredit(Give);
end;

{ the timer }

procedure TWsSessionCore.Arm;
var
  In_: TWsTimerInput;
  Delay: Integer;
begin
  FLock.Acquire;
  try
    if (FState = wsEnded) or FTimerArmed then
      Exit;
    In_.NowMs := GetTickCount64;
    In_.LastInboundMs := FLastInboundMs;
    In_.PingSentMs := FPingSentMs;
    In_.CloseSentMs := FCloseSentMs;
    In_.Open := (FState = wsOpen) and not FOutputClosed;
    In_.InputClosed := FInputClosed;
    In_.PingIntervalMs := FOpts.PingIntervalMs;
    In_.PongTimeoutMs := FOpts.PongTimeoutMs;
    In_.CloseTimeoutMs := FOpts.CloseTimeoutMs;
    WsTimerStep(In_, Delay);
    if Delay = 0 then
      Exit;
    FTimerArmed := True;
  finally
    FLock.Release;
  end;
  if not FSource.PostAfter(Delay, TickEntry) then
    FTimerArmed := False;
end;

procedure TWsSessionCore.TickEntry;
var
  Keep: IInterface;
begin
  Keep := Self;
  Http2AssertStreamThread('TWsSessionCore.TickEntry');
  DoTick;
end;

procedure TWsSessionCore.DoTick;
var
  In_: TWsTimerInput;
  Delay: Integer;
  Action: TWsTimerAction;
begin
  FLock.Acquire;
  try
    FTimerArmed := False;
    if FState = wsEnded then
      Exit;
    In_.NowMs := GetTickCount64;
    In_.LastInboundMs := FLastInboundMs;
    In_.PingSentMs := FPingSentMs;
    In_.CloseSentMs := FCloseSentMs;
    In_.Open := (FState = wsOpen) and not FOutputClosed;
    In_.InputClosed := FInputClosed;
    In_.PingIntervalMs := FOpts.PingIntervalMs;
    In_.PongTimeoutMs := FOpts.PongTimeoutMs;
    In_.CloseTimeoutMs := FOpts.CloseTimeoutMs;
    Action := WsTimerStep(In_, Delay);
  finally
    FLock.Release;
  end;
  case Action of
    taSendPing:
      begin
        FLock.Acquire;
        try
          FPingSentMs := GetTickCount64;
        finally
          FLock.Release;
        end;
        SendControl(WsOpPing, nil);
      end;
    taPongTimeout:
      begin
        FEnv.Count(wcPingTimeouts, 1);
        Close(WsCloseInternal, 'ping timeout');
      end;
    taCloseTimeout:
      begin
        // the peer is silent: the closing handshake did not finish
        EndWithClosed(WsCloseAbnormal, 'the peer did not answer the Close frame', False);
        FChannel.Close(ccAbort);
      end;
  end;
  Arm;
end;

{ sending }

function TWsSessionCore.SendControl(const AOpcode: Byte; const APayload: TBytes): TSendResult;
var
  Key: TWsMaskKey;
begin
  Key := WsMaskKeyFromLongWord(0);
  FSendLock.Acquire;
  try
    Result := FChannel.Send(WsEncodeFrame(AOpcode, True, APayload, False, Key));
  finally
    FSendLock.Release;
  end;
end;

procedure TWsSessionCore.SendCloseFrame(const ACode: Word; const AReason: string);
var
  Reason: RawByteString;
begin
  Reason := RawByteString(AReason);
  if Length(Reason) > WsMaxCloseReason then
    SetLength(Reason, WsMaxCloseReason);
  SendControl(WsOpClose, WsBuildClosePayload(ACode, Reason));
end;

function TWsSessionCore.Send(const AData: TBytes; const AText: Boolean): TSendResult;
var
  Op: Byte;
  Wire: TBytes;
begin
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit(srClosed);
  finally
    FLock.Release;
  end;
  if AText then
    Op := WsOpText
  else
    Op := WsOpBinary;
  Wire := WsEncodeMessage(Op, AData, FOpts.FrameSize);
  FSendLock.Acquire;
  try
    Result := FChannel.Send(Wire);
  finally
    FSendLock.Release;
  end;
  if Result = srQueued then
  begin
    FEnv.Count(wcMessagesOut, 1);
    FEnv.Count(wcBytesOut, Length(AData));
  end
  else if Result = srClosed then
    EndWithClosed(WsCloseAbnormal, 'the channel is closed', False);
end;

function TWsSessionCore.SendStream(const AReader: IBodyWriter; const AText: Boolean): TSendResult;
var
  All, Chunk: TBytes;
  At: Integer;
begin
  All := nil;
  while AReader.NextChunk(Chunk) do
  begin
    At := Length(All);
    SetLength(All, At + Length(Chunk));
    if Length(Chunk) > 0 then
      Move(Chunk[0], All[At], Length(Chunk));
  end;
  Result := Send(All, AText);
end;

procedure TWsSessionCore.Ping(const AData: TBytes);
begin
  if Length(AData) > WsMaxControlPayload then
    raise EHttpError.Create('a Ping payload is over 125 octets');
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit;
    if FPingSentMs = 0 then
      FPingSentMs := GetTickCount64;
  finally
    FLock.Release;
  end;
  SendControl(WsOpPing, AData);
end;

procedure TWsSessionCore.Close(const ACode: Word; const AReason: string);
var
  Finish: Boolean;
begin
  if not WsCloseCodeSendable(ACode) then
    raise EHttpError.CreateFmt('the close code %d cannot be sent', [ACode]);
  if Length(AReason) > WsMaxCloseReason then
    raise EHttpError.Create('a close reason is over 123 octets');
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit;
    FOutputClosed := True;
    if FState = wsOpen then
      FState := wsClosing;
    if FState <> wsInit then
      FCloseSentMs := GetTickCount64;
    Finish := FInputClosed;
  finally
    FLock.Release;
  end;
  SendCloseFrame(ACode, AReason);
  if Finish then
    // the peer closed first: both Close frames are out
    FChannel.Close(ccGraceful)
  else
    Arm;
end;

procedure TWsSessionCore.Abort;
begin
  if TryEnd then
  begin
    FChannel.Close(ccAbort);
    if FRegistry <> nil then
      DropCloser;
    FSource.Close;
    FSelf := nil;
  end;
end;

function TWsSessionCore.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FState in [wsInit, wsOpen]) and not FOutputClosed;
  finally
    FLock.Release;
  end;
end;

function TWsSessionCore.InputClosed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FInputClosed;
  finally
    FLock.Release;
  end;
end;

function TWsSessionCore.OutputClosed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FOutputClosed;
  finally
    FLock.Release;
  end;
end;

function TWsSessionCore.Subprotocol: string;
begin
  Result := FSubprotocol;
end;

function TWsSessionCore.Request: IServerRequest;
begin
  Result := FRequest;
end;

function TWsSessionCore.Id: Int64;
begin
  Result := FId;
end;

function TWsSessionCore.Context: IInterface;
begin
  FLock.Acquire;
  try
    Result := FContext;
  finally
    FLock.Release;
  end;
end;

procedure TWsSessionCore.SetContext(const AValue: IInterface);
begin
  FLock.Acquire;
  try
    FContext := AValue;
  finally
    FLock.Release;
  end;
end;

end.
