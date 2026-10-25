{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, sse, hardening, deadlock, close, credit, options, test, fpcunit
notes:
  - This unit holds the tests of story 29 of the hardening plan. The findings are
    WS-1 (a lock-order inversion between the send lock and the connection lock),
    WS-2 (messages before a Close frame are dropped), WS-3 (a data frame after the
    Close frame), WS-4 (a close timeout fires late), WS-5 (credit is granted twice
    for a control frame in pieces), WS-7 and WS-8 (copying), WS-9 and WS-10 (SSE),
    WS-12 and WS-13 (options and the close reason).
  - The session tests use the fake channel of Http2Server.Ws.TestKit. A test that
    shows a deadlock gives the fake channel a lock that stands for the connection
    lock, and it watches the threads with a deadline.
---
}
/// Tests of the WebSocket and SSE corrections
unit Http2Server.WsHardening.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.os,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.Limits, Http2Server.StreamPool, Http2Server.Sse.Encoder,
  Http2Server.Sse, Http2Server.Sse.Test, Http2Server.Ws.Options,
  Http2Server.Ws.Types, Http2Server.Ws.Frames, Http2Server.Ws.Utf8,
  Http2Server.Ws.Session, Http2Server.Frames, Http2Server.StreamChannel,
  Http2Server.H2Peer, Http2Server.Ws.TestKit;

type
  /// the method a helper thread runs
  TProc_ = procedure of object;

  TProcThread = class(TThread)
  private
    FProc: TProc_;
  protected
    procedure Execute; override;
  public
    Done: TEvent;
    constructor Create(const AProc: TProc_);
    destructor Destroy; override;
  end;

  /// an IBodyWriter that yields chunks of one size
  TChunkWriter = class(TInterfacedObject, IBodyWriter)
  private
    FLeft, FSize: Integer;
  public
    constructor Create(const ACount, ASize: Integer);
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

  TWsHardeningTest = class(TTestCase)
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
    FBig: TBytes;
    function ChannelActivated: Boolean;
    function HandlerNeedle: Boolean;
    function PongCount: Boolean;
    procedure Build(const AOptions: TWsOptions);
    function Quick: TWsOptions;
    function WaitHandler(const AText: string; const AMs: Integer = 5000): Boolean;
    procedure SendLoop;
    procedure DeliverLoop;
    procedure SendBig;
  protected
    procedure TearDown; override;
  published
    procedure TestPingAndSendFromOppositeThreadsDoNotDeadlock;
    procedure TestMessagesBeforeCloseAreDelivered;
    procedure TestAbortDropsTheMessagesThatWait;
    procedure TestNoDataFrameFollowsTheCloseFrame;
    procedure TestCloseTimeoutFiresWithThePingTimerArmed;
    procedure TestPingInPiecesDoesNotGrowTheWindow;
    procedure TestCloseReasonThatIsNotUtf8IsRefused;
    procedure TestReasonTruncationKeepsWholeCharacters;
    procedure TestOptionsAreCrossChecked;
    procedure TestFourMebibyteMessageEncodesInBoundedTime;
    procedure TestSendStreamHasASizeCap;
  end;

  TSseHardeningTest = class(TTestCase)
  private
    FPool: TStreamPool;
    FRegistry: TChannelRegistry;
    FRegistryRef: IChannelRegistry;
    FChannel: TFakeChannel;
    FChannelRef: IDuplexChannel;
    FResponse: TFakeResponse;
    FResponseRef: IServerResponse;
    FRequest: TFakeRequest;
    FRequestRef: IServerRequest;
    FKeepClosed: Boolean;
    function ChannelClosed: Boolean;
    procedure Build(const AKeepAliveMs, AStallMs: Integer);
  protected
    procedure TearDown; override;
  published
    procedure TestAProgressingStreamIsNotAbortedByAnOldStall;
    procedure TestABadExtraHeaderLeavesNoOpenChannel;
    procedure TestManyShortLinesEncodeInBoundedTime;
  end;

  TChannelOrderTest = class(TTestCase)
  private
    FChan: IDuplexChannel;
    FQueued: Integer;
    procedure DoActivate;
    procedure DoSends;
  published
    procedure TestActivationNeverPutsDataBeforeHeaders;
  end;

implementation

{ TProcThread }

constructor TProcThread.Create(const AProc: TProc_);
begin
  Done := TEvent.Create(nil, True, False, '');
  FProc := AProc;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TProcThread.Destroy;
begin
  Done.Free;
  inherited Destroy;
end;

procedure TProcThread.Execute;
begin
  try
    FProc();
  finally
    Done.SetEvent;
  end;
end;

{ TChunkWriter }

constructor TChunkWriter.Create(const ACount, ASize: Integer);
begin
  inherited Create;
  FLeft := ACount;
  FSize := ASize;
end;

function TChunkWriter.NextChunk(out ABuffer: TBytes): Boolean;
begin
  ABuffer := nil;
  Result := FLeft > 0;
  if not Result then
    Exit;
  Dec(FLeft);
  SetLength(ABuffer, FSize);
  FillChar(ABuffer[0], FSize, Ord('x'));
end;

{ TWsHardeningTest }

function TWsHardeningTest.Quick: TWsOptions;
begin
  Result := TWsOptions.Create
    .WithPingIntervalMs(0)
    .WithCloseTimeoutMs(300)
    .WithInitTimeoutMs(5000);
end;

procedure TWsHardeningTest.Build(const AOptions: TWsOptions);
begin
  FRig := TWsRig.Create(AOptions);
  FHandler := TRecordingHandler.Create;
  FHandlerRef := FHandler;
  FChannel := FRig.NewChannel;
  FChannelRef := FChannel;
  FRequest := TFakeRequest.Create;
  FRequestRef := FRequest;
  FSession := WsStartSession(FChannelRef, FRequestRef, FHandlerRef,
    TFakeHandshake.Create, nil);
  AssertTrue('the session opened', WaitUntil(ChannelActivated));
end;

procedure TWsHardeningTest.TearDown;
begin
  if FRig <> nil then
  begin
    FRig.Registry.CloseAll(ccGraceful);
    FRig.Registry.CloseAll(ccAbort);
  end;
  if FChannel <> nil then
  begin
    FChannel.Sink := nil;
    FChannel.ConnLock.Free;
    FChannel.ConnLock := nil;
  end;
  FSession := nil;
  FreeAndNil(FRig);
  FChannelRef := nil;
  FRequestRef := nil;
  FHandlerRef := nil;
  inherited TearDown;
end;

function TWsHardeningTest.ChannelActivated: Boolean;
begin
  Result := FChannel.Activated;
end;

function TWsHardeningTest.HandlerNeedle: Boolean;
begin
  Result := Pos(FNeedle, FHandler.AllText) > 0;
end;

function TWsHardeningTest.WaitHandler(const AText: string; const AMs: Integer): Boolean;
begin
  FNeedle := AText;
  Result := WaitUntil(HandlerNeedle, AMs);
end;

function TWsHardeningTest.PongCount: Boolean;
var
  L: TStringList;
  I, N: Integer;
begin
  L := DecodeOutput(FChannel.SentBytes);
  try
    N := 0;
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, 2) = 'O:' then
        Inc(N);
    Result := N >= 10000;
  finally
    L.Free;
  end;
end;

procedure TWsHardeningTest.SendLoop;
var
  I: Integer;
begin
  for I := 1 to 10000 do
    FSession.Send(BytesOf('x'), True);
end;

procedure TWsHardeningTest.DeliverLoop;
var
  I: Integer;
  Ping: TBytes;
begin
  Ping := ClientFrame(WsOpPing, True, BytesOf('p'));
  for I := 1 to 10000 do
    FChannel.Deliver(Ping);
end;

procedure TWsHardeningTest.SendBig;
begin
  FSession.Send(FBig, False);
end;

procedure TWsHardeningTest.TestPingAndSendFromOppositeThreadsDoNotDeadlock;
var
  Sender, Deliverer: TProcThread;
  Lost: Boolean;
begin
  Build(Quick.WithControlBucket(TTokenBucketOptions.Create
    .WithCapacity(10000000).WithRefillPerSecond(10000000)));
  // this lock stands for the connection lock of a real channel: the sender takes
  // it inside Send, and the deliverer holds it while the session handles a Ping
  FChannel.ConnLock := TCriticalSection.Create;
  Sender := TProcThread.Create(SendLoop);
  Deliverer := TProcThread.Create(DeliverLoop);
  Lost := (Sender.Done.WaitFor(30000) <> wrSignaled) or
    (Deliverer.Done.WaitFor(30000) <> wrSignaled);
  if Lost then
  begin
    // the threads are stuck for good; the objects stay allocated
    Fail('WS-1: the sender and the deliverer deadlocked');
  end;
  Sender.WaitFor;
  Deliverer.WaitFor;
  Sender.Free;
  Deliverer.Free;
  AssertTrue('every Ping was answered', WaitUntil(PongCount, 20000));
end;

procedure TWsHardeningTest.TestMessagesBeforeCloseAreDelivered;
var
  Text: string;
begin
  Build(Quick);
  FChannel.Deliver(Cat(Cat(ClientText('first'), ClientText('second')),
    ClientClose(1000, '')));
  AssertTrue('Closed arrived', WaitHandler('closed 1000'));
  Text := FHandler.AllText;
  AssertTrue('the first message reached the handler', Pos('msg T first', Text) > 0);
  AssertTrue('the second message reached the handler', Pos('msg T second', Text) > 0);
  AssertTrue('Closed follows the last message',
    Pos('msg T second', Text) < Pos('closed 1000', Text));
end;

procedure TWsHardeningTest.TestAbortDropsTheMessagesThatWait;
begin
  Build(Quick);
  FHandler.Gate := RTLEventCreate;
  FChannel.Deliver(Cat(Cat(ClientText('one'), ClientText('two')), ClientText('three')));
  Sleep(50);
  FSession.Abort;
  RTLEventSetEvent(FHandler.Gate);
  Sleep(150);
  AssertTrue('the message in progress finished', WaitHandler('msg T one'));
  AssertTrue('an abort drops the messages that wait',
    Pos('msg T two', FHandler.AllText) = 0);
end;

procedure TWsHardeningTest.TestNoDataFrameFollowsTheCloseFrame;
var
  Sender: TProcThread;
  L: TStringList;
  I, CloseAt: Integer;
begin
  // the close timeout is long, so the channel stays open until the sender is done
  Build(Quick.WithMaxMessageSize(16777216).WithMaxFrameSize(16777216)
    .WithFrameSize(1024).WithCloseTimeoutMs(60000));
  // large enough that the sender is still encoding when the Close frame goes out
  SetLength(FBig, 6291456);
  FillChar(FBig[0], Length(FBig), 7);
  Sender := TProcThread.Create(SendBig);
  // the sender spends its time encoding between the open check and the send;
  // the Close frame goes out meanwhile
  Sleep(30);
  FSession.Close(1000, '');
  Sender.Done.WaitFor(60000);
  Sender.WaitFor;
  Sender.Free;
  L := DecodeOutput(FChannel.SentBytes);
  try
    CloseAt := -1;
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, 2) = 'C:' then
        CloseAt := I;
    AssertTrue('the Close frame is in the output', CloseAt >= 0);
    for I := CloseAt + 1 to L.Count - 1 do
      AssertTrue('RFC 6455 section 5.5.1: no data frame follows the Close frame',
        (Copy(L[I], 1, 2) <> 'B:') and (Copy(L[I], 1, 2) <> 'T:'));
  finally
    L.Free;
  end;
end;

procedure TWsHardeningTest.TestCloseTimeoutFiresWithThePingTimerArmed;
begin
  // the ping timer waits 30 s. The close timeout of 300 ms must not wait for it
  Build(Quick.WithPingIntervalMs(30000).WithPongTimeoutMs(10000));
  FSession.Close(1000, '');
  AssertTrue('H WS-4: the close timeout fired on time',
    WaitHandler('closed 1006', 3000));
end;

procedure TWsHardeningTest.TestPingInPiecesDoesNotGrowTheWindow;
var
  Ping: TBytes;
  I: Integer;
begin
  Build(Quick);
  Ping := ClientFrame(WsOpPing, True, BytesOf('0123456789'));
  for I := 0 to High(Ping) do
    FChannel.Deliver(Copy(Ping, I, 1));
  AssertEquals('the credit equals the octets that arrived', Length(Ping),
    FChannel.CreditSoFar);
end;

procedure TWsHardeningTest.TestCloseReasonThatIsNotUtf8IsRefused;
var
  Raised: Boolean;
begin
  Build(Quick);
  Raised := False;
  try
    FSession.Close(1000, #$FF#$FE);
  except
    on EHttpError do
      Raised := True;
  end;
  AssertTrue('WS-13: a reason that is not UTF-8 is refused', Raised);
  AssertTrue('the session is still open', FSession.IsOpen);
  FSession.Close(1000, 'caf' + #$C3#$A9);
  AssertTrue('a valid reason is sent', FSession.OutputClosed);
end;

procedure TWsHardeningTest.TestReasonTruncationKeepsWholeCharacters;
var
  S, R: RawByteString;
begin
  S := RawByteString(StringOfChar('a', 122)) + #$C3#$A9 + 'tail';
  R := WsTruncateUtf8(S, 123);
  AssertEquals('the cut moves back to the start of the character', 122, Length(R));
  AssertTrue(WsUtf8IsValid(R[1], Length(R)));
  R := WsTruncateUtf8(RawByteString(StringOfChar('b', 200)), 123);
  AssertEquals('ASCII is cut at the limit', 123, Length(R));
  R := WsTruncateUtf8('short', 123);
  AssertEquals('short', string(R));
end;

procedure TWsHardeningTest.TestOptionsAreCrossChecked;
var
  P: TArray<string>;

  function Text(const AOptions: TWsOptions): string;
  var
    I: Integer;
  begin
    P := nil;
    AOptions.Problems(P);
    Result := '';
    for I := 0 to High(P) do
      Result := Result + P[I] + ';';
  end;

begin
  AssertEquals('the defaults are valid', '', Text(TWsOptions.Create));
  AssertTrue('a message size above the Integer range is refused',
    Pos('message size', Text(TWsOptions.Create.WithMaxMessageSize(3000000000))) > 0);
  AssertTrue('a frame size above the message size is refused',
    Pos('frame size', Text(TWsOptions.Create.WithMaxMessageSize(1000)
      .WithMaxFrameSize(5000))) > 0);
end;

procedure TWsHardeningTest.TestFourMebibyteMessageEncodesInBoundedTime;
var
  Data, Wire: TBytes;
  Started: QWord;
begin
  SetLength(Data, 4 * 1024 * 1024);
  FillChar(Data[0], Length(Data), 1);
  Started := GetTickCount64;
  Wire := WsEncodeMessage(WsOpBinary, Data, 1024);
  AssertTrue('WS-7: the encoding takes linear time',
    GetTickCount64 - Started < 700);
  AssertEquals('payload plus 4 header octets for each of 4096 frames',
    Length(Data) + 4096 * 4, Length(Wire));
end;

procedure TWsHardeningTest.TestSendStreamHasASizeCap;
var
  Raised: Boolean;
begin
  Build(Quick.WithMaxMessageSize(1000).WithMaxFrameSize(1000));
  Raised := False;
  try
    FSession.SendStream(TChunkWriter.Create(5, 400), False);
  except
    on EHttpError do
      Raised := True;
  end;
  AssertTrue('WS-7: SendStream refuses a message over the size limit', Raised);
end;

{ TSseHardeningTest }

procedure TSseHardeningTest.Build(const AKeepAliveMs, AStallMs: Integer);
begin
  FPool := TStreamPool.Create(1);
  FRegistry := TChannelRegistry.Create(100, 1024, 0);
  FRegistry.KeepAliveMs := AKeepAliveMs;
  FRegistry.StallTimeoutMs := AStallMs;
  FRegistry.SourceProvider := FPool.NewSource;
  FRegistryRef := FRegistry;
  FChannel := TFakeChannel.Create(FRegistryRef);
  FChannelRef := FChannel;
  FResponse := TFakeResponse.Create;
  FResponse.Channel := FChannelRef;
  FResponseRef := FResponse;
  FRequest := TFakeRequest.Create;
  FRequestRef := FRequest;
end;

procedure TSseHardeningTest.TearDown;
begin
  if FRegistry <> nil then
    FRegistry.SourceProvider := nil;
  FreeAndNil(FPool);
  if FChannel <> nil then
    FChannel.Sink := nil;
  FChannelRef := nil;
  FResponseRef := nil;
  FRequestRef := nil;
  FRegistryRef := nil;
  inherited TearDown;
end;

function TSseHardeningTest.ChannelClosed: Boolean;
begin
  Result := FChannel.Closed;
end;

procedure TSseHardeningTest.TestAProgressingStreamIsNotAbortedByAnOldStall;
var
  Stream: ISseStream;
  Ev: TSseEvent;
begin
  Build(100, 250);
  Stream := StartSse(FRequestRef, FResponseRef);
  Ev := Default(TSseEvent);
  Ev.Data := TBytes.Create(Ord('x'));
  FChannel.Full := True;
  AssertTrue(Stream.Send(Ev) = srFull);
  FChannel.Full := False;
  // the next send is queued: the stream makes progress, so the old refusal ends
  AssertTrue(Stream.Send(Ev) = srQueued);
  AssertFalse('WS-9: the stream is still open after the stall time passed',
    WaitUntil(ChannelClosed, 700));
  Stream.Close;
end;

procedure TSseHardeningTest.TestABadExtraHeaderLeavesNoOpenChannel;
var
  Extra: THeaderBlock;
  Raised: Boolean;
begin
  Build(0, 0);
  SetLength(Extra, 1);
  Extra[0].Name := 'bad name';
  Extra[0].Value := 'x';
  Raised := False;
  try
    StartSse(FRequestRef, FResponseRef, Extra);
  except
    on EHttpError do
      Raised := True;
  end;
  AssertTrue('the bad header is refused', Raised);
  AssertEquals('WS-10: the response was not detached', 0, FResponse.DetachCount);
end;

procedure TSseHardeningTest.TestManyShortLinesEncodeInBoundedTime;
var
  Ev: TSseEvent;
  Data: TBytes;
  I: Integer;
  Wire: TBytes;
  Started: QWord;
begin
  SetLength(Data, 1000000);
  for I := 0 to High(Data) do
    if I mod 2 = 0 then
      Data[I] := Ord('a')
    else
      Data[I] := 10;
  Ev := Default(TSseEvent);
  Ev.Data := Data;
  Started := GetTickCount64;
  Wire := SseEncodeEvent(Ev);
  AssertTrue('WS-8: the encoder takes linear time', GetTickCount64 - Started < 500);
  AssertTrue(Length(Wire) > 1000000);
end;

{ TChannelOrderTest }

procedure TChannelOrderTest.DoActivate;
begin
  FChan.Activate(200, nil);
end;

procedure TChannelOrderTest.DoSends;
var
  K: Integer;
begin
  for K := 1 to 20 do
    if FChan.Send(BytesOf('d')) = srQueued then
      Inc(FQueued);
end;

procedure TChannelOrderTest.TestActivationNeverPutsDataBeforeHeaders;
const
  Rounds = 300;
var
  Options: TPeerOptions;
  Peer: TH2Peer;
  I, J, FirstHeaders, FirstData: Integer;
  Id: LongWord;
  A, B: TProcThread;
  Queued: TArray<Integer>;
begin
  Options := TPeerOptions.Default;
  Options.Core.MaxConcurrentStreams := 1000;
  Peer := TH2Peer.Create(Options);
  try
    Peer.SendPreface;
    Peer.SendSettings([], []);
    Peer.Pump;
    SetLength(Queued, Rounds);
    for I := 0 to Rounds - 1 do
    begin
      Id := 1 + 2 * LongWord(I);
      Peer.SendGet(Id);
      FChan := THttp2StreamChannel.Attach(Peer.Core.StreamById(Id), nil, True);
      FQueued := 0;
      A := TProcThread.Create(DoActivate);
      B := TProcThread.Create(DoSends);
      A.Done.WaitFor(10000);
      B.Done.WaitFor(10000);
      A.WaitFor;
      B.WaitFor;
      A.Free;
      B.Free;
      Queued[I] := FQueued;
      FChan := nil;
      Peer.Core.Flush;
    end;
    Peer.Pump;
    for I := 0 to Rounds - 1 do
    begin
      Id := 1 + 2 * LongWord(I);
      FirstHeaders := -1;
      FirstData := -1;
      for J := 0 to Peer.Received.Count - 1 do
        if Peer.Received[J].Frame.Header.StreamId = Id then
        begin
          if (Peer.Received[J].Frame.Header.FrameType = ftHeaders) and (FirstHeaders < 0) then
            FirstHeaders := J;
          if (Peer.Received[J].Frame.Header.FrameType = ftData) and (FirstData < 0) then
            FirstData := J;
        end;
      AssertTrue('stream ' + IntToStr(Id) + ' has its HEADERS', FirstHeaders >= 0);
      if FirstData >= 0 then
        AssertTrue('WS-6: DATA of stream ' + IntToStr(Id) + ' follows its HEADERS',
          FirstHeaders < FirstData);
      AssertEquals('no queued byte is lost on stream ' + IntToStr(Id), Queued[I],
        Integer(Peer.DataOctets(Id)));
    end;
    AssertEquals(0, Peer.Violations.Count);
  finally
    Peer.Free;
  end;
end;

initialization
  RegisterTest(TWsHardeningTest);
  RegisterTest(TSseHardeningTest);
  RegisterTest(TChannelOrderTest);
end.
