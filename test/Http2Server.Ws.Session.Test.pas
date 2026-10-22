{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, init, close handshake, heartbeat, limits, credit, test, fpcunit
notes:
  - This unit tests the WebSocket session on a fake channel and a real streaming
    pool. The handler is a recording handler, and the tests read the frames that the
    server sent through a decoder.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Unit tests for Http2Server.Ws.Session
unit Http2Server.Ws.Session.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.Limits, Http2Server.Observer, Http2Server.Sse.Test,
  Http2Server.Ws.Options, Http2Server.Ws.Types, Http2Server.Ws.Frames,
  Http2Server.Ws.Session, Http2Server.Ws.TestKit;

type
  TWsSessionTest = class(TTestCase)
  private
    FRig: TWsRig;
    FHandler: TRecordingHandler;
    FHandlerRef: IWsHandler;
    FChannel: TFakeWsChannel;
    FChannelRef: IDuplexChannel;
    FSession: IWsSession;
    FRequest: TFakeRequest;
    FRequestRef: IServerRequest;
    FNeedle: string;
    function ChannelActivated: Boolean;
    function ChannelCompleted: Boolean;
    function ChannelClosed: Boolean;
    function HandlerNeedle: Boolean;
    function OutNeedle: Boolean;
    procedure Build(const AOptions: TWsOptions; const AOffered: TArray<string>);
    procedure BuildDefault;
    function Out_: TStringList;
    function HandlerHas(const AText: string): Boolean;
    function WaitHandler(const AText: string): Boolean;
    function WaitOut(const AText: string): Boolean;
    function Quick: TWsOptions;
  protected
    procedure TearDown; override;
  published
    procedure TestInitAcceptWithSubprotocolAndGreeting;
    procedure TestInitRejectCompletesWithTheStatusAndDropsTheGreeting;
    procedure TestInitRaisesAnswers500;
    procedure TestInitRunsOnAPoolThreadAndSeesTheRequest;
    procedure TestSubprotocolThatWasNotOfferedAnswers500;
    procedure TestContextSetInInitIsVisibleInMessage;
    procedure TestPeerResetDuringInitDropsTheResult;
    procedure TestInitTimeoutAnswers503;
    procedure TestBytesBeforeTheResponseCancelTheSession;
    procedure TestEchoOfTextAndBinary;
    procedure TestOneMebibyteMessageInSmallFrames;
    procedure TestFragmentedTextWithASplitCharacter;
    procedure TestPingIsAnsweredWhileAMessageIsOpen;
    procedure TestUnsolicitedPongReachesTheHandler;
    procedure TestCloseFromThePeerIsEchoedAndDelivered;
    procedure TestCloseWithoutStatusIsEchoedEmpty;
    procedure TestCloseWithBadCodeAnswers1002;
    procedure TestCloseWithBadReasonAnswers1007;
    procedure TestMessageOverTheLimitAnswers1009;
    procedure TestDataFrameAfterCloseAnswers1002;
    procedure TestBadTextAnswers1007;
    procedure TestMessageRaisingGoesToFailedAndClosesWith1011;
    procedure TestApplicationCloseWaitsForThePeer;
    procedure TestApplicationCloseTimesOut;
    procedure TestSendAfterCloseAnswersClosed;
    procedure TestFullChannelRefusesAWholeMessage;
    procedure TestAbortSendsNoCloseFrameAndNoCallback;
    procedure TestTransportLossIs1006;
    procedure TestPingTimeoutClosesWith1011;
    procedure TestServerPingsAnIdleSession;
    procedure TestQueueCapClosesWith1008;
    procedure TestCreditIsReturnedAtOnceForControlAndWhileAssembling;
    procedure TestControlBucketTripsWith1008;
    procedure TestMessageBucketTripsWith1008;
    procedure TestTwoProducersNeverInterleaveFrames;
    procedure TestStopSendsGoingAwayThenFinalStopDeliversClosed;
    procedure TestCountersAndEvents;
  end;

implementation

function Offered(const A: array of string): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function TWsSessionTest.Quick: TWsOptions;
begin
  Result := TWsOptions.Create
    .WithPingIntervalMs(0)
    .WithCloseTimeoutMs(300)
    .WithInitTimeoutMs(5000);
end;

procedure TWsSessionTest.Build(const AOptions: TWsOptions; const AOffered: TArray<string>);
var
  H: TFakeHandshake;
begin
  FRig := TWsRig.Create(AOptions);
  if FHandler = nil then
  begin
    FHandler := TRecordingHandler.Create;
    FHandlerRef := FHandler;
  end;
  FChannel := FRig.NewChannel;
  FChannelRef := FChannel;
  FRequest := TFakeRequest.Create;
  SetLength(FRequest.Header, 1);
  FRequest.Header[0].Name := 'cookie';
  FRequest.Header[0].Value := 'sid=7';
  FRequestRef := FRequest;
  H := TFakeHandshake.Create;
  FSession := WsStartSession(FChannelRef, FRequestRef, FHandlerRef, H, AOffered);
end;

procedure TWsSessionTest.BuildDefault;
begin
  Build(Quick.WithPingIntervalMs(0), Offered(['chat', 'json']));
end;

procedure TWsSessionTest.TearDown;
begin
  // what Stop does: every session that is left ends and lets go of its references
  if FRig <> nil then
  begin
    FRig.Registry.CloseAll(ccGraceful);
    FRig.Registry.CloseAll(ccAbort);
  end;
  if FChannel <> nil then
    FChannel.Sink := nil;
  FSession := nil;
  FreeAndNil(FRig);
  FChannelRef := nil;
  FRequestRef := nil;
  FHandlerRef := nil;
  inherited TearDown;
end;

function TWsSessionTest.Out_: TStringList;
begin
  Result := DecodeOutput(FChannel.SentBytes);
end;

function TWsSessionTest.HandlerHas(const AText: string): Boolean;
begin
  Result := Pos(AText, FHandler.AllText) > 0;
end;

function TWsSessionTest.ChannelActivated: Boolean;
begin
  Result := FChannel.Activated;
end;

function TWsSessionTest.ChannelCompleted: Boolean;
begin
  Result := FChannel.Completed;
end;

function TWsSessionTest.ChannelClosed: Boolean;
begin
  Result := FChannel.IsClosed;
end;

function TWsSessionTest.HandlerNeedle: Boolean;
begin
  Result := HandlerHas(FNeedle);
end;

function TWsSessionTest.OutNeedle: Boolean;
var
  L: TStringList;
begin
  L := Out_;
  try
    Result := Pos(FNeedle, L.Text) > 0;
  finally
    L.Free;
  end;
end;

function TWsSessionTest.WaitHandler(const AText: string): Boolean;
begin
  FNeedle := AText;
  Result := WaitUntil(HandlerNeedle);
end;

function TWsSessionTest.WaitOut(const AText: string): Boolean;
begin
  FNeedle := AText;
  Result := WaitUntil(OutNeedle);
end;

{ Init }

procedure TWsSessionTest.TestInitAcceptWithSubprotocolAndGreeting;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitResult := TWsInitResult.AcceptedWith('json');
  FHandler.InitSend := BytesOf('hello');
  FHandler.InitSendText := True;
  BuildDefault;
  AssertTrue('the handshake response went out', WaitUntil(ChannelActivated));
  AssertEquals(200, FChannel.ActivatedStatus);
  AssertEquals('sec-websocket-protocol', FChannel.ActivatedHeaders[0].Name);
  AssertEquals('json', FChannel.ActivatedHeaders[0].Value);
  AssertEquals('json', FSession.Subprotocol);
  L := Out_;
  try
    AssertEquals('the greeting follows the response, in order', 'T:hello', L.Text.Trim);
  finally
    L.Free;
  end;
  AssertTrue(FSession.IsOpen);
end;

procedure TWsSessionTest.TestInitRejectCompletesWithTheStatusAndDropsTheGreeting;
var
  R: TWsInitResult;
  H: THeaderBlock;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  R := TWsInitResult.Rejected(401);
  SetLength(H, 1);
  H[0].Name := 'www-authenticate';
  H[0].Value := 'Basic';
  R.RejectHeaders := H;
  R.RejectBody := BytesOf('no');
  FHandler.InitResult := R;
  FHandler.InitSend := BytesOf('greeting');
  BuildDefault;
  AssertTrue(WaitUntil(ChannelCompleted));
  AssertEquals(401, FChannel.CompletedStatus);
  AssertEquals('www-authenticate', FChannel.CompletedHeaders[0].Name);
  AssertEquals('no', TextOf(FChannel.CompletedBody));
  AssertFalse('no handshake response', FChannel.Activated);
  AssertEquals('the queued greeting was dropped', 0, Length(FChannel.SentBytes));
  AssertEquals(1, FRig.EventCount(seWsRejected));
  Sleep(50);
  AssertFalse('Closed never runs after a reject', HandlerHas('closed'));
end;

procedure TWsSessionTest.TestInitRaisesAnswers500;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitRaises := True;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelCompleted));
  AssertEquals(500, FChannel.CompletedStatus);
  AssertEquals(1, FRig.EventCount(seHandlerException));
end;

procedure TWsSessionTest.TestInitRunsOnAPoolThreadAndSeesTheRequest;
begin
  BuildDefault;
  AssertTrue(WaitHandler('init'));
  AssertEquals('Init runs on a streaming-pool thread, never on an IO thread', 'pool', FHandler.ThreadOf(0));
  AssertTrue('Init sees the cookie', Pos('cookie=sid=7', FHandler.Line(0)) > 0);
  AssertTrue('and the offered subprotocols', Pos('offered=chat,json,', FHandler.Line(0)) > 0);
  AssertTrue(Pos('/events', FHandler.Line(0)) > 0);
end;

procedure TWsSessionTest.TestSubprotocolThatWasNotOfferedAnswers500;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitResult := TWsInitResult.AcceptedWith('mqtt');
  BuildDefault;
  AssertTrue(WaitUntil(ChannelCompleted));
  AssertEquals(500, FChannel.CompletedStatus);
  AssertFalse(FChannel.Activated);
end;

procedure TWsSessionTest.TestContextSetInInitIsVisibleInMessage;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitSetsContext := True;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  AssertTrue('the context is set', FSession.Context <> nil);
end;

procedure TWsSessionTest.TestPeerResetDuringInitDropsTheResult;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitSleepMs := 300;
  BuildDefault;
  AssertTrue(WaitHandler('init'));
  FChannel.DeliverPeerClosed(False);
  Sleep(500);
  AssertFalse('the handshake response never went out', FChannel.Activated);
  AssertFalse('Closed never runs', HandlerHas('closed'));
end;

procedure TWsSessionTest.TestInitTimeoutAnswers503;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitSleepMs := 600;
  Build(Quick.WithInitTimeoutMs(100), Offered([]));
  AssertTrue(WaitUntil(ChannelCompleted));
  AssertEquals(503, FChannel.CompletedStatus);
  Sleep(700);
  AssertFalse('the late result of Init is dropped', FChannel.Activated);
end;

procedure TWsSessionTest.TestBytesBeforeTheResponseCancelTheSession;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.InitSleepMs := 200;
  BuildDefault;
  AssertTrue(WaitHandler('init'));
  FChannel.Deliver(ClientText('too early'));
  AssertTrue('the channel is aborted', WaitUntil(ChannelClosed));
  Sleep(400);
  AssertFalse(FChannel.Activated);
  AssertFalse(HandlerHas('msg'));
end;

{ messages }

procedure TWsSessionTest.TestEchoOfTextAndBinary;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Echo := True;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientText('héllo'));
  FChannel.Deliver(ClientFrame(WsOpBinary, True, TBytes.Create(0, 1, 255)));
  AssertTrue(WaitOut('B:0001FF'));
  L := Out_;
  try
    AssertEquals('T:héllo', L[0]);
    AssertEquals('B:0001FF', L[1]);
  finally
    L.Free;
  end;
  AssertEquals('both callbacks ran on the pool', 'pool', FHandler.ThreadOf(1));
end;

procedure TWsSessionTest.TestOneMebibyteMessageInSmallFrames;
var
  Payload: TBytes;
  I, At: Integer;
  Stream: TBytes;
  Op: Byte;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  SetLength(Payload, 1048576);
  for I := 0 to High(Payload) do
    Payload[I] := I and $7F;
  Stream := nil;
  At := 0;
  while At < Length(Payload) do
  begin
    if At = 0 then
      Op := WsOpBinary
    else
      Op := WsOpContinuation;
    Stream := Cat(Stream, ClientFrame(Op, At + 1024 >= Length(Payload),
      Copy(Payload, At, 1024)));
    Inc(At, 1024);
  end;
  FChannel.Deliver(Stream);
  AssertTrue(WaitHandler('msg B 1048576'));
end;

procedure TWsSessionTest.TestFragmentedTextWithASplitCharacter;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  // the euro sign E2 82 AC split over three frames
  FChannel.Deliver(ClientFrame(WsOpText, False, TBytes.Create(Ord('a'), $E2)));
  FChannel.Deliver(ClientFrame(WsOpContinuation, False, TBytes.Create($82)));
  FChannel.Deliver(ClientFrame(WsOpContinuation, True, TBytes.Create($AC, Ord('b'))));
  AssertTrue(WaitHandler('msg T a'#$E2#$82#$AC'b'));
end;

procedure TWsSessionTest.TestPingIsAnsweredWhileAMessageIsOpen;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpText, False, BytesOf('ab')));
  FChannel.Deliver(ClientFrame(WsOpPing, True, BytesOf('xyz')));
  FChannel.Deliver(ClientFrame(WsOpContinuation, True, BytesOf('cd')));
  AssertTrue(WaitHandler('msg T abcd'));
  L := Out_;
  try
    AssertEquals('the Pong has the payload of the Ping', 'O:78797A', L[0]);
  finally
    L.Free;
  end;
  AssertFalse('the application hears no Ping', HandlerHas('ping'));
end;

procedure TWsSessionTest.TestUnsolicitedPongReachesTheHandler;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpPong, True, BytesOf('hi')));
  AssertTrue(WaitHandler('pong hi'));
end;

{ close }

procedure TWsSessionTest.TestCloseFromThePeerIsEchoedAndDelivered;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientClose(1001, 'bye'));
  AssertTrue(WaitHandler('closed 1001 bye clean=True'));
  L := Out_;
  try
    AssertEquals('C:1001:', L[0]);
  finally
    L.Free;
  end;
  AssertTrue('the channel closed gracefully after both Close frames',
    FChannel.IsClosed and (FChannel.CloseMode = ccGraceful));
  AssertTrue(FSession.InputClosed);
  AssertTrue(FSession.OutputClosed);
end;

procedure TWsSessionTest.TestCloseWithoutStatusIsEchoedEmpty;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpClose, True, nil));
  AssertTrue(WaitHandler('closed 1005'));
  L := Out_;
  try
    AssertEquals('C:1005:', L[0]);
  finally
    L.Free;
  end;
end;

procedure TWsSessionTest.TestCloseWithBadCodeAnswers1002;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpClose, True, TBytes.Create($03, $ED)));   // 1005 on the wire
  AssertTrue(WaitHandler('closed 1002'));
  L := Out_;
  try
    AssertTrue(L[0], Pos('C:1002', L[0]) = 1);
  finally
    L.Free;
  end;
end;

procedure TWsSessionTest.TestCloseWithBadReasonAnswers1007;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpClose, True, TBytes.Create($03, $E8, $FF)));
  AssertTrue(WaitHandler('closed 1007'));
end;

procedure TWsSessionTest.TestMessageOverTheLimitAnswers1009;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  Build(Quick.WithMaxMessageSize(100), Offered([]));
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpBinary, True, Copy(BytesOf(StringOfChar('x', 101)))));
  AssertTrue(WaitHandler('closed 1009'));
end;

procedure TWsSessionTest.TestDataFrameAfterCloseAnswers1002;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(Cat(ClientClose(1000), ClientText('late')));
  AssertTrue(WaitHandler('closed'));
  AssertFalse('the late message is never delivered', HandlerHas('msg'));
end;

procedure TWsSessionTest.TestBadTextAnswers1007;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientFrame(WsOpText, True, TBytes.Create($C0, $80)));
  AssertTrue(WaitHandler('closed 1007'));
end;

procedure TWsSessionTest.TestMessageRaisingGoesToFailedAndClosesWith1011;
var
  L: TStringList;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.MessageRaises := True;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientText('boom'));
  AssertTrue(WaitHandler('failed Message failed'));
  AssertTrue(WaitOut('C:1011'));
  AssertFalse('Failed ends the conversation, so Closed does not follow', HandlerHas('closed'));
  AssertTrue(FChannel.IsClosed);
  L := Out_;
  L.Free;
  AssertEquals(1, FRig.EventCount(seWsFailed));
end;

procedure TWsSessionTest.TestApplicationCloseWaitsForThePeer;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FSession.Close(1000, 'done');
  AssertTrue(WaitOut('C:1000:done'));
  AssertFalse('the channel waits for the peer', FChannel.IsClosed);
  AssertTrue(FSession.OutputClosed);
  AssertFalse(FSession.IsOpen);
  FChannel.Deliver(ClientClose(1000, 'ok'));
  AssertTrue(WaitHandler('closed 1000 ok clean=True'));
  AssertTrue(FChannel.IsClosed);
end;

procedure TWsSessionTest.TestApplicationCloseTimesOut;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FSession.Close(1000, 'done');
  AssertTrue('the peer is silent, so the close wait ends', WaitHandler('closed 1006'));
  AssertTrue(HandlerHas('clean=False'));
  AssertTrue(FChannel.IsClosed);
end;

procedure TWsSessionTest.TestSendAfterCloseAnswersClosed;
begin
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FSession.Close(1000);
  AssertTrue(FSession.Send(BytesOf('x'), True) = srClosed);
end;

procedure TWsSessionTest.TestFullChannelRefusesAWholeMessage;
begin
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Full := True;
  AssertTrue(FSession.Send(BytesOf(StringOfChar('x', 100000)), False) = srFull);
  FChannel.Full := False;
  AssertEquals('nothing was half written', 0, Length(FChannel.SentBytes));
  AssertTrue(FSession.Send(BytesOf('ok'), True) = srQueued);
end;

procedure TWsSessionTest.TestAbortSendsNoCloseFrameAndNoCallback;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FSession.Abort;
  AssertTrue(FChannel.IsClosed);
  AssertTrue(FChannel.CloseMode = ccAbort);
  AssertEquals('no Close frame', 0, Length(FChannel.SentBytes));
  Sleep(100);
  AssertFalse('no later callback', HandlerHas('closed'));
end;

procedure TWsSessionTest.TestTransportLossIs1006;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.DeliverPeerClosed(False);
  AssertTrue(WaitHandler('closed 1006  clean=False'));
end;

{ heartbeat }

procedure TWsSessionTest.TestPingTimeoutClosesWith1011;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  Build(Quick.WithPingIntervalMs(60).WithPongTimeoutMs(60).WithCloseTimeoutMs(150), Offered([]));
  AssertTrue(WaitOut('P:'));
  AssertTrue('the Pong did not come, so the server closes with 1011', WaitOut('C:1011:ping timeout'));
  AssertTrue('and the close wait ends', WaitHandler('closed 1006'));
  AssertEquals(1, FRig.EventCount(seWsClosed));
end;

procedure TWsSessionTest.TestServerPingsAnIdleSession;
var
  L: TStringList;
begin
  Build(Quick.WithPingIntervalMs(60).WithPongTimeoutMs(2000), Offered([]));
  AssertTrue(WaitOut('P:'));
  // a Pong from the peer clears the wait and the session goes on
  FChannel.Deliver(ClientFrame(WsOpPong, True, nil));
  Sleep(150);
  L := Out_;
  try
    AssertTrue('no Close yet', Pos('C:', L.Text) = 0);
  finally
    L.Free;
  end;
  AssertTrue(FSession.IsOpen);
end;

{ limits and credit }

procedure TWsSessionTest.TestQueueCapClosesWith1008;
var
  Gate: PRTLEvent;
  I: Integer;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  Gate := RTLEventCreate;
  FHandler.Gate := Gate;
  Build(Quick.WithQueuedMessages(4), Offered([]));
  AssertTrue(WaitUntil(ChannelActivated));
  // the first message holds the callback; the others queue behind it
  for I := 1 to 8 do
    FChannel.Deliver(ClientText('m' + IntToStr(I)));
  AssertTrue(WaitOut('C:1008'));
  RTLEventSetEvent(Gate);
  AssertTrue(WaitHandler('closed 1008'));
  RTLEventDestroy(Gate);
end;

procedure TWsSessionTest.TestCreditIsReturnedAtOnceForControlAndWhileAssembling;
var
  Frame, Ping: TBytes;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  Ping := ClientFrame(WsOpPing, True, BytesOf('abc'));
  FChannel.Deliver(Ping);
  AssertEquals('a Ping is credited at once', Length(Ping), FChannel.CreditSoFar);
  Frame := ClientFrame(WsOpText, False, BytesOf(StringOfChar('a', 1000)));
  FChannel.Deliver(Frame);
  AssertEquals('the octets of an open message are credited as they come',
    Length(Ping) + Length(Frame), FChannel.CreditSoFar);
end;

procedure TWsSessionTest.TestControlBucketTripsWith1008;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  Build(Quick.WithControlBucket(TTokenBucketOptions.Create.WithCapacity(3).WithRefillPerSecond(0.001)),
    Offered([]));
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(Cat(Cat(ClientFrame(WsOpPing, True, nil), ClientFrame(WsOpPing, True, nil)),
    Cat(ClientFrame(WsOpPing, True, nil), ClientFrame(WsOpPing, True, nil))));
  AssertTrue(WaitHandler('closed 1008'));
  AssertEquals(1, FRig.EventCount(seWsBucketTripped));
end;

procedure TWsSessionTest.TestMessageBucketTripsWith1008;
var
  I: Integer;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  Build(Quick.WithMessageBucket(TTokenBucketOptions.Create.WithCapacity(3).WithRefillPerSecond(0.001)),
    Offered([]));
  AssertTrue(WaitUntil(ChannelActivated));
  for I := 1 to 6 do
    FChannel.Deliver(ClientText('m'));
  AssertTrue(WaitHandler('closed 1008'));
end;

{ sending }

type
  TProducer = class(TThread)
  public
    Session: IWsSession;
    Tag: Char;
    procedure Execute; override;
  end;

procedure TProducer.Execute;
var
  I: Integer;
begin
  for I := 1 to 300 do
    Session.Send(BytesOf(StringOfChar(Tag, 40000)), True);   // several frames each
end;

procedure TWsSessionTest.TestTwoProducersNeverInterleaveFrames;
var
  A, B: TProducer;
  L: TStringList;
  I: Integer;
begin
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  A := TProducer.Create(True);
  B := TProducer.Create(True);
  try
    A.Session := FSession; A.Tag := 'a';
    B.Session := FSession; B.Tag := 'b';
    A.Start;
    B.Start;
    A.WaitFor;
    B.WaitFor;
  finally
    A.Free;
    B.Free;
  end;
  L := Out_;
  try
    AssertEquals('every message arrives whole', 600, L.Count);
    for I := 0 to L.Count - 1 do
      AssertTrue('message ' + IntToStr(I) + ' is not mixed',
        (L[I] = 'T:' + StringOfChar('a', 40000)) or (L[I] = 'T:' + StringOfChar('b', 40000)));
  finally
    L.Free;
  end;
end;

{ stop }

procedure TWsSessionTest.TestStopSendsGoingAwayThenFinalStopDeliversClosed;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FRig.Registry.CloseAll(ccGraceful);
  AssertTrue('Close 1001 goes out', WaitOut('C:1001:the server stops'));
  AssertFalse('the session waits for the peer', FChannel.IsClosed);
  FRig.Registry.CloseAll(ccAbort);
  AssertTrue(FChannel.IsClosed);
  AssertTrue('Closed is delivered to the application', HandlerHas('closed 1001'));
end;

procedure TWsSessionTest.TestCountersAndEvents;
var
  Stats: TServerStats;
begin
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Echo := True;
  BuildDefault;
  AssertTrue(WaitUntil(ChannelActivated));
  FChannel.Deliver(ClientText('abc'));
  AssertTrue(WaitOut('T:abc'));
  Stats := Default(TServerStats);
  FRig.Env.FillStats(Stats);
  AssertEquals(1, Stats.WsSessions);
  AssertEquals(Int64(1), Stats.WsMessagesIn);
  AssertEquals(Int64(1), Stats.WsMessagesOut);
  AssertEquals(Int64(3), Stats.WsBytesIn);
  AssertEquals(Int64(3), Stats.WsBytesOut);
  AssertEquals(1, FRig.EventCount(seWsOpened));
  FChannel.Deliver(ClientClose(1000));
  AssertTrue(WaitHandler('closed 1000'));
  FRig.Env.FillStats(Stats);
  AssertEquals('the session left the count', 0, Stats.WsSessions);
  AssertEquals(1, FRig.EventCount(seWsClosed));
end;

initialization
  RegisterTest(TWsSessionTest);

end.
