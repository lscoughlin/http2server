{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, duplex channel, streaming pool, init, receive path, stop
notes:
  - A session runs on any IDuplexChannel that has been detached before its
    response head. It does not know whether the channel is an HTTP/1.1 connection
    or an HTTP/2 stream.
  - The IO thread that delivers octets parses the frames, answers Ping and Close at
    once, and queues each data message. The streaming pool runs the callbacks of the
    handler, one at a time for a session and in the order of the events. The
    handler never runs on an IO thread.
  - The credit of the octets of a message goes back to the channel while the message
    is assembled, so a message larger than the HTTP/2 window can arrive. When
    the queue of a session is half full, the credit of the data octets is held until
    the handler has taken messages, and a queue over its cap closes the session
    with 1008.
  - The state, the sender, the closing handshake and the timers are in
    Http2Server.Ws.SessionCore.
---
}
/// The WebSocket session on a duplex channel
unit Http2Server.Ws.Session;

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
  Http2Server.Ws.Reader, Http2Server.Ws.Close, Http2Server.Ws.SessionCore;

/// start a session on AChannel, which is detached and pending
// - ARequest is the upgrade request; the session keeps a copy of what it needs
// - AOffered holds the subprotocols that the client offered
// - the first task of the session is IWsHandler.Init, on the streaming pool
// - raises EHttpError when the server has no WebSocket environment or no pool
function WsStartSession(const AChannel: IDuplexChannel; const ARequest: IServerRequest;
  const AHandler: IWsHandler; const AHandshake: IWsHandshake;
  const AOffered: TArray<string>): IWsSession;

implementation

type
  TWsSession = class(TWsSessionCore, IChannelSink, IWsReaderSink, IChannelCloser,
    IWsInitWatch)
  protected
    procedure Post(const ATask: TWsTask); override;
    procedure UnwatchInit; override;
    procedure DropCloser; override;
    procedure RunTask;
    function Dropping: Boolean;
    procedure DoInit;
    procedure DoMessage(const ATask: TWsTask);
    procedure DoPong(const ATask: TWsTask);
    procedure DoClosed(const ATask: TWsTask);
    procedure DoReply(const ATask: TWsTask);
    procedure ProtocolFail(const ACode: Word; const AReason: string);
    procedure FinishReject(const AResult: TWsInitResult);
  public
    procedure Start;

    // IChannelSink: the IO thread calls these
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;

    // IWsReaderSink: called from BytesReceived
    procedure Message(const AText: Boolean; const AData: TBytes);
    procedure Control(const AOpcode: Byte; const AData: TBytes);

    // IChannelCloser, IWsInitWatch
    procedure CloseForStop(const AMode: TChannelClose);
    procedure InitTimedOut;
  end;

{ TWsSession }

procedure TWsSession.UnwatchInit;
begin
  FEnv.UnwatchInit(Self);
end;

procedure TWsSession.DropCloser;
begin
  if FRegistry <> nil then
    FRegistry.RemoveCloser(Self);
end;

procedure TWsSession.Start;
var
  T: TWsTask;
begin
  FSelf := Self;
  // the session closes its own channel when the server stops, so the registry
  // lists it as a closer and not as a plain channel
  if FRegistry <> nil then
  begin
    FRegistry.Remove(FChannel);
    FRegistry.AddCloser(Self);
  end;
  FChannel.SetSink(Self);
  FEnv.WatchInit(Self, GetTickCount64 + QWord(FOpts.InitTimeoutMs));
  T := Default(TWsTask);
  T.Kind := wtInit;
  Post(T);
end;

procedure TWsSession.Post(const ATask: TWsTask);
begin
  FLock.Acquire;
  try
    FTasks.Add(ATask);
  finally
    FLock.Release;
  end;
  if not FSource.Post(RunTask) then
    // the pool has stopped: nothing runs again
    EndQuietly;
end;

procedure TWsSession.RunTask;
var
  T: TWsTask;
  Keep: IInterface;
begin
  // the session lives while a task of it runs
  Keep := Self;
  Http2AssertStreamThread('TWsSession.RunTask');
  FLock.Acquire;
  try
    if FTasks.Count = 0 then
      Exit;
    T := FTasks[0];
    FTasks.Delete(0);
  finally
    FLock.Release;
  end;
  case T.Kind of
    wtInit: DoInit;
    wtMessage: DoMessage(T);
    wtPong: DoPong(T);
    wtClosed: DoClosed(T);
    wtReply: DoReply(T);
  end;
end;

procedure TWsSession.FinishReject(const AResult: TWsInitResult);
var
  Status: Integer;
begin
  Status := AResult.Status;
  if Status = 0 then
    Status := 403;
  EndQuietly;
  FEnv.Report(seWsRejected, Status, 'Init refused the upgrade');
  // the error response goes out and the connection returns to its protocol core
  try
    FChannel.Complete(Status, AResult.RejectHeaders, AResult.RejectBody);
  except
    FChannel.Close(ccAbort);
  end;
end;

procedure TWsSession.DoInit;
var
  R: TWsInitResult;
  Act: TWsActivation;
  I: Integer;
  Known: Boolean;
  Decided: Boolean;
begin
  if FSnapshot.IsCancelled then
    Exit;
  try
    R := FHandler.Init(FRequest, FOffered, Self);
  except
    on EStreamCancelled do
      Exit;
    on E: Exception do
    begin
      FLock.Acquire;
      try
        Decided := FInitDecided;
        FInitDecided := True;
      finally
        FLock.Release;
      end;
      if not Decided then
      begin
        FEnv.Report(seHandlerException, 500, E.ClassName + ' in Init');
        FinishReject(TWsInitResult.Rejected(500));
      end;
      Exit;
    end;
  end;
  FLock.Acquire;
  try
    Decided := FInitDecided;
    FInitDecided := True;
  finally
    FLock.Release;
  end;
  if Decided then
    Exit;   // the time limit passed; the upgrade was answered with 503
  UnwatchInit;
  if FState = wsEnded then
    Exit;   // the peer left while Init ran
  if not R.Accept then
  begin
    FinishReject(R);
    Exit;
  end;
  // a subprotocol that the client did not offer is an error of the application
  Known := R.Subprotocol = '';
  for I := 0 to High(FOffered) do
    if FOffered[I] = R.Subprotocol then
      Known := True;
  if not Known then
  begin
    FEnv.Report(seHandlerException, 500, 'Init chose a subprotocol that was not offered');
    FinishReject(TWsInitResult.Rejected(500));
    Exit;
  end;
  FSubprotocol := R.Subprotocol;
  try
    Act := FHandshake.Activation(R.Subprotocol, R.ResponseHeaders);
    FLock.Acquire;
    try
      if FState = wsEnded then
        Exit;
      if FOutputClosed then
        FState := wsClosing
      else
        FState := wsOpen;
      FCounted := True;
    finally
      FLock.Release;
    end;
    FEnv.SessionOpened;
    FLastInboundMs := GetTickCount64;
    // the response goes out, then the frames that Init queued, in order
    FChannel.Activate(Act.Status, Act.Headers);
  except
    on E: Exception do
    begin
      FEnv.Report(seHandlerException, 500, E.ClassName + ' in the handshake');
      EndQuietly;
      FChannel.Close(ccAbort);
      Exit;
    end;
  end;
  FEnv.Report(seWsOpened, 0, FSubprotocol);
  if FOutputClosed then
  begin
    FLock.Acquire;
    try
      FCloseSentMs := GetTickCount64;
    finally
      FLock.Release;
    end;
  end;
  if FStopRequested then
    Close(WsCloseGoingAway, 'the server stops');
  Arm;
end;

function TWsSession.Dropping: Boolean;
begin
  FLock.Acquire;
  try
    Result := FDropMessages;
  finally
    FLock.Release;
  end;
end;

procedure TWsSession.DoReply(const ATask: TWsTask);
begin
  // the IO thread could not take the send lock, so this thread sends the frame
  try
    SendControl(ATask.Opcode, ATask.Data);
  except
    ;   // the channel ended; the closing code below runs all the same
  end;
  FLock.Acquire;
  try
    if FDeferred > 0 then
      Dec(FDeferred);
  finally
    FLock.Release;
  end;
  if ATask.CloseAfter then
    FChannel.Close(ccGraceful);
end;

procedure TWsSession.DoMessage(const ATask: TWsTask);
begin
  // a message that arrived before a Close frame is delivered, whatever the state
  // of the session now. An abort, a failure of the session or a protocol error
  // drops the messages that wait
  if Dropping then
  begin
    ReleaseCredit(True);
    Exit;
  end;
  try
    FHandler.Message(Self, ATask.Data, ATask.Text);
  except
    on EStreamCancelled do
      ;
    on E: Exception do
      Fail(E);
  end;
  ReleaseCredit(True);
end;

procedure TWsSession.DoPong(const ATask: TWsTask);
begin
  if Dropping then
    Exit;
  try
    FHandler.Pong(Self, ATask.Data);
  except
    on EStreamCancelled do
      ;
    on E: Exception do
      Fail(E);
  end;
end;

procedure TWsSession.DoClosed(const ATask: TWsTask);
begin
  FLock.Acquire;
  try
    if FDelivered then
      Exit;
    FDelivered := True;
  finally
    FLock.Release;
  end;
  FEnv.Report(seWsClosed, ATask.Code, ATask.Reason);
  try
    FHandler.Closed(Self, ATask.Code, ATask.Reason, ATask.Clean);
  except
    on E: Exception do
      FEnv.Report(seWsFailed, 0, E.ClassName + ' in Closed');
  end;
  if FRegistry <> nil then
    FRegistry.RemoveCloser(Self);
  FSource.Close;
  FSelf := nil;
end;

{ the receive path }

procedure TWsSession.BytesReceived(const AData; const ACount: Integer);
var
  State: TWsState;
  Data: Int64;
  Hold: Boolean;
  Ok: Boolean;
  Failure: TWsFailure;
begin
  if ACount <= 0 then
    Exit;
  FReadLock.Acquire;
  try
    FLock.Acquire;
    try
      State := FState;
      FLastInboundMs := GetTickCount64;
    finally
      FLock.Release;
    end;
    if State = wsEnded then
      Exit;
    if State = wsInit then
    begin
      // WebSocket octets before the handshake response are a protocol error
      EndQuietly;
      FChannel.Close(ccAbort);
      Exit;
    end;
    Ok := FReader.Feed(AData, ACount, Self);
    // every octet is credited once, when it is consumed: the octets of a frame
    // that arrives in pieces are credited piece by piece, so a control frame in
    // pieces cannot raise the window above what the server consumed. The credit
    // waits when the queue of the session is half full, until the handler has
    // taken messages
    Data := ACount;
    FLock.Acquire;
    try
      Hold := FQueuedMsgs * 2 >= FOpts.QueuedMessages;
      if Hold then
        Inc(FHeldCredit, Data);
    finally
      FLock.Release;
    end;
    if not Hold then
      FChannel.ReturnCredit(Data);
    if not Ok then
    begin
      Failure := FReader.Failure;
      ProtocolFail(Failure.Code, Failure.Reason);
    end;
  finally
    FReadLock.Release;
  end;
end;

procedure TWsSession.ProtocolFail(const ACode: Word; const AReason: string);
var
  Send_: Boolean;
begin
  FLock.Acquire;
  try
    if FState = wsEnded then
      Exit;
    Send_ := not FOutputClosed;
    FOutputClosed := True;
  finally
    FLock.Release;
  end;
  FEnv.Count(wcProtocolErrors, 1);
  // a protocol error drops the messages that wait
  DropPending;
  if Send_ then
  begin
    // the IO thread runs here and never waits for the send lock. The Close frame
    // goes out, and the channel closes after it
    try
      IoSend(WsOpClose, ClosePayload(ACode, AReason), True);
    except
      FChannel.Close(ccGraceful);
    end;
    EndWithClosed(ACode, AReason, False);
  end
  else
  begin
    EndWithClosed(ACode, AReason, False);
    FChannel.Close(ccGraceful);
  end;
end;

procedure TWsSession.Message(const AText: Boolean; const AData: TBytes);
var
  T: TWsTask;
  TooMany, AfterClose: Boolean;
begin
  if not FMessages.TryTake(1) then
  begin
    FEnv.Report(seWsBucketTripped, 0, 'the message bucket is empty');
    ProtocolFail(WsClosePolicy, 'too many messages');
    Exit;
  end;
  FLock.Acquire;
  try
    if FState = wsEnded then
      Exit;
    AfterClose := FInputClosed;
    TooMany := FQueuedMsgs >= FOpts.QueuedMessages;
    if not (AfterClose or TooMany) then
      Inc(FQueuedMsgs);
  finally
    FLock.Release;
  end;
  if AfterClose then
  begin
    ProtocolFail(WsCloseProtocolError, 'a data frame after the Close frame');
    Exit;
  end;
  if TooMany then
  begin
    ProtocolFail(WsClosePolicy, 'too many messages wait for the application');
    Exit;
  end;
  FEnv.Count(wcMessagesIn, 1);
  FEnv.Count(wcBytesIn, Length(AData));
  T := Default(TWsTask);
  T.Kind := wtMessage;
  T.Text := AText;
  T.Data := AData;
  Post(T);
end;

procedure TWsSession.Control(const AOpcode: Byte; const AData: TBytes);
var
  T: TWsTask;
  Code: Integer;
  Reason: RawByteString;
  Already, Echo: Boolean;
  Echoed: Word;
begin
  if AOpcode = WsOpClose then
  begin
    // the reader checked the payload before this call, so only the values matter
    WsParseClosePayload(AData, Code, Reason);
    FLock.Acquire;
    try
      if FState = wsEnded then
        Exit;
      Already := FInputClosed;
      FInputClosed := True;
      Echo := not FOutputClosed;
      if Echo then
      begin
        FOutputClosed := True;
        if FState = wsOpen then
          FState := wsClosing;
      end;
    finally
      FLock.Release;
    end;
    if Already then
      Exit;
    if Echo then
    begin
      // the Close frame is answered with the same code, if the server may send it
      if (Code <> WsCloseNoStatus) and WsCloseCodeSendable(Code) then
        Echoed := Code
      else
        Echoed := WsCloseNormal;
      // the IO thread runs here and never waits for the send lock. The echo
      // goes out, and the channel closes after it
      try
        if Code = WsCloseNoStatus then
          IoSend(WsOpClose, nil, True)
        else
          IoSend(WsOpClose, ClosePayload(Echoed, ''), True);
      except
        FChannel.Close(ccGraceful);
      end;
      EndWithClosed(Word(Code), string(Reason), True);
    end
    else
    begin
      EndWithClosed(Word(Code), string(Reason), True);
      FChannel.Close(ccGraceful);
    end;
    Exit;
  end;
  if not FControl.TryTake(1) then
  begin
    FEnv.Report(seWsBucketTripped, 0, 'the control bucket is empty');
    ProtocolFail(WsClosePolicy, 'too many control frames');
    Exit;
  end;
  if AOpcode = WsOpPing then
  begin
    // answered before the application hears of anything, with the same payload
    FLock.Acquire;
    try
      Echo := (FState <> wsEnded) and not FOutputClosed;
    finally
      FLock.Release;
    end;
    if Echo then
      IoSend(WsOpPong, AData, False);
    Exit;
  end;
  // a Pong
  FLock.Acquire;
  try
    FPingSentMs := 0;
  finally
    FLock.Release;
  end;
  T := Default(TWsTask);
  T.Kind := wtPong;
  T.Data := AData;
  Post(T);
end;

procedure TWsSession.PeerClosed(const AClean: Boolean);
var
  State: TWsState;
begin
  FLock.Acquire;
  try
    State := FState;
  finally
    FLock.Release;
  end;
  if State = wsEnded then
    Exit;
  if State = wsInit then
  begin
    // a half close of a request that sends nothing is not the end; a reset is
    if AClean then
      Exit;
    EndQuietly;
    Exit;
  end;
  // the transport ended without a Close frame
  EndWithClosed(WsCloseAbnormal, '', False);
  // a half close leaves the other half open: END_STREAM answers it (RFC 8441 section 5)
  if AClean then
    FChannel.Close(ccGraceful);
end;

procedure TWsSession.WriteDrained;
begin
  // the application reads the result of Send; the session keeps no waiting writer
end;

{ the stop of the server, and the time limit of Init }

procedure TWsSession.CloseForStop(const AMode: TChannelClose);
var
  State: TWsState;
  Open: Boolean;
  Deliver: Boolean;
begin
  if AMode = ccGraceful then
  begin
    FLock.Acquire;
    try
      State := FState;
      if State = wsInit then
        FStopRequested := True;
      Open := (State = wsOpen) and not FOutputClosed;
    finally
      FLock.Release;
    end;
    if Open then
      try
        Close(WsCloseGoingAway, 'the server stops');
      except
        ;
      end;
    Exit;
  end;
  // the final stop: the pool is going away, so Closed is delivered here
  TryEnd;
  FLock.Acquire;
  try
    Deliver := FCounted and not FDelivered;
    if Deliver then
      FDelivered := True;
  finally
    FLock.Release;
  end;
  FChannel.Close(ccAbort);
  if Deliver then
  begin
    FEnv.Report(seWsClosed, WsCloseGoingAway, 'the server stopped');
    try
      FHandler.Closed(Self, WsCloseGoingAway, 'the server stopped', False);
    except
      ;
    end;
  end;
  if FRegistry <> nil then
    FRegistry.RemoveCloser(Self);
  FSource.Close;
  FSelf := nil;
end;

procedure TWsSession.InitTimedOut;
var
  Decided: Boolean;
begin
  FLock.Acquire;
  try
    Decided := FInitDecided or (FState = wsEnded);
    if not Decided then
      FInitDecided := True;
  finally
    FLock.Release;
  end;
  if Decided then
    Exit;
  // Init may hold the pool thread, so this runs on the watchdog: the upgrade is
  // answered, and the result of Init is dropped when it comes
  EndQuietly;
  FEnv.Report(seWsRejected, 503, 'Init passed its time limit');
  try
    FChannel.Complete(503, nil, nil);
  except
    FChannel.Close(ccAbort);
  end;
end;

function WsStartSession(const AChannel: IDuplexChannel; const ARequest: IServerRequest;
  const AHandler: IWsHandler; const AHandshake: IWsHandshake;
  const AOffered: TArray<string>): IWsSession;
var
  Env: IWsEnvironment;
  Source: IStreamSource;
  Session: TWsSession;
  Registry: IChannelRegistry;
begin
  Registry := AChannel.Registry;
  if (Registry = nil) or not Supports(Registry.WsEnvironment, IWsEnvironment, Env) then
    raise EHttpError.Create('the server has no WebSocket environment');
  Source := Registry.NewSource;
  if Source = nil then
    raise EHttpError.Create('the server has no streaming pool');
  Session := TWsSession.Create(Env, AChannel, Source, AHandler, AHandshake,
    ARequest, AOffered);
  Result := Session;
  Session.Start;
end;

end.
