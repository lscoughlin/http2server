{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: sse, server-sent events, encoder, keep-alive, stall, test, fpcunit
notes:
  - This unit tests the event encoder and the event stream.
  - The encoder tests assert the exact bytes of the rules E1 to E18 of the WHATWG
    HTML Living Standard section 9.2.
  - The stream tests use a fake channel, so that a refusal, a drain and a peer
    reset happen at a chosen instant. The pool is a real streaming pool of one
    thread.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Unit tests for Http2Server.Sse.Encoder and Http2Server.Sse
unit Http2Server.Sse.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.StreamPool, Http2Server.Sse.Encoder, Http2Server.Sse,
  Http2Server.ClientCert;

type
  /// a channel that records what the stream does to it
  TFakeChannel = class(TInterfacedObject, IDuplexChannel)
  private
    FLock: TCriticalSection;
    FRegistry: IChannelRegistry;
  public
    Sent: TList<TBytes>;
    ActivatedStatus: Integer;
    ActivatedHeaders: THeaderBlock;
    Sink: IChannelSink;
    /// when True, Send answers srFull and queues nothing
    Full: Boolean;
    Closed: Boolean;
    CloseMode: TChannelClose;
    Credit: Int64;
    constructor Create(const ARegistry: IChannelRegistry);
    destructor Destroy; override;
    function Send(const AData: TBytes): TSendResult;
    procedure Close(const AMode: TChannelClose);
    function IsOpen: Boolean;
    function State: TChannelState;
    function QueuedBytes: Int64;
    procedure SetSink(const ASink: IChannelSink);
    procedure ReturnCredit(const ACount: Int64);
    procedure Complete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    procedure Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
    function Registry: IChannelRegistry;
    function SentCount: Integer;
    function SentText(const AIndex: Integer): string;
    /// call the sink the way the real channel does: with the channel lock held
    procedure DrainUnderLock;
    procedure ResetUnderLock;
  end;

  TFakeResponse = class(TInterfacedObject, IServerResponse)
  public
    Channel: IDuplexChannel;
    /// how often the response was detached
    DetachCount: Integer;
    procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure Write(const AData: TBytes); overload;
    procedure Write(const ABuffer; const ACount: Integer); overload;
    procedure SetBodyWriter(const AWriter: IBodyWriter);
    procedure Finish;
    procedure RegisterCancelHook(const AHook: TCancelHook);
    function IsCancelled: Boolean;
    function StreamId: LongWord;
    function Detach: IDuplexChannel;
  end;

  TFakeRequest = class(TInterfacedObject, IServerRequest)
  public
    Header: THeaderBlock;
    Who: string;
    function GetPrincipal: string;
    procedure SetPrincipal(const AValue: string);
    function GetClientCertificate: IClientCertificate;
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

  TSseEncoderTest = class(TTestCase)
  private
    function Enc(const AEvent: TSseEvent): string;
    function Ev(const AData: string; const AId: string = '';
      const AEvent: string = ''; const ARetry: Integer = 0): TSseEvent;
    procedure ExpectError(const AEvent: TSseEvent; const AName: string);
  published
    procedure TestOneDataLine;
    procedure TestMultiLineDataSplitsAtLfCrAndCrlf;
    procedure TestDataEndingWithABreakWritesAFinalEmptyField;
    procedure TestEmptyDataWritesOneEmptyField;
    procedure TestFieldsAndTheirOrder;
    procedure TestALeadingSpaceKeepsItsFirstSpace;
    procedure TestEmptyIdIsLegal;
    procedure TestInjectionIsRejected;
    procedure TestNulIsRejected;
    procedure TestInvalidUtf8IsRejected;
    procedure TestRetryRules;
    procedure TestMultiByteTextPassesThrough;
    procedure TestCommentEncoding;
    procedure TestLastEventIdCleaning;
    procedure TestNoBomAndAlwaysABlankLine;
  end;

  TSseStreamTest = class(TTestCase)
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
    procedure Build(const AKeepAliveMs, AStallMs: Integer;
      const APoolSize: Integer = 1);
    function Start(const ALastEventId: string = ''): ISseStream;
    function WaitSent(const ACount, ATimeoutMs: Integer): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestStartSendsTheHeadersAndDetaches;
    procedure TestExtraHeadersAreAdded;
    procedure TestEventsArriveInOrder;
    procedure TestTwoProducersNeverInterleave;
    procedure TestKeepAliveCommentArrives;
    procedure TestKeepAliveWaitsWhileEventsFlow;
    procedure TestManyStreamsShareOnePoolThread;
    procedure TestStalledReaderIsClosed;
    procedure TestDrainEndsTheStall;
    procedure TestPeerResetEndsTheStream;
    procedure TestCleanHalfCloseOfTheRequestKeepsTheStreamOpen;
    procedure TestCloseIsGraceful;
    procedure TestSendAfterCloseAnswersClosed;
    procedure TestLastEventIdReachesTheHandler;
    procedure TestBadEventIsRaisedAndNothingIsSent;
    procedure TestRequestBodyCreditGoesBack;
    procedure TestCallbacksUnderTheChannelLockDoNotDeadlock;
  end;

implementation

function BytesOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

{ TFakeChannel }

constructor TFakeChannel.Create(const ARegistry: IChannelRegistry);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRegistry := ARegistry;
  Sent := TList<TBytes>.Create;
end;

destructor TFakeChannel.Destroy;
begin
  Sent.Free;
  FLock.Free;
  inherited Destroy;
end;

function TFakeChannel.Send(const AData: TBytes): TSendResult;
begin
  FLock.Acquire;
  try
    if Closed then
      Exit(srClosed);
    if Full then
      Exit(srFull);
    Sent.Add(AData);
    Result := srQueued;
  finally
    FLock.Release;
  end;
end;

procedure TFakeChannel.Close(const AMode: TChannelClose);
begin
  FLock.Acquire;
  try
    Closed := True;
    CloseMode := AMode;
  finally
    FLock.Release;
  end;
end;

function TFakeChannel.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := not Closed;
  finally
    FLock.Release;
  end;
end;

function TFakeChannel.State: TChannelState;
begin
  if IsOpen then
    Result := csActive
  else
    Result := csClosed;
end;

function TFakeChannel.QueuedBytes: Int64;
begin
  Result := 0;
end;

procedure TFakeChannel.SetSink(const ASink: IChannelSink);
begin
  Sink := ASink;
end;

procedure TFakeChannel.ReturnCredit(const ACount: Int64);
begin
  FLock.Acquire;
  try
    Inc(Credit, ACount);
  finally
    FLock.Release;
  end;
end;

procedure TFakeChannel.Complete(const AStatus: Integer;
  const AHeaders: THeaderBlock; const ABody: TBytes);
begin
  raise EHttpError.Create('Complete is not part of the SSE path');
end;

procedure TFakeChannel.Activate(const AStatus: Integer;
  const AHeaders: THeaderBlock);
begin
  ActivatedStatus := AStatus;
  ActivatedHeaders := AHeaders;
end;

function TFakeChannel.Registry: IChannelRegistry;
begin
  Result := FRegistry;
end;

function TFakeChannel.SentCount: Integer;
begin
  FLock.Acquire;
  try
    Result := Sent.Count;
  finally
    FLock.Release;
  end;
end;

procedure TFakeChannel.DrainUnderLock;
begin
  FLock.Acquire;
  try
    if Sink <> nil then
      Sink.WriteDrained;
  finally
    FLock.Release;
  end;
end;

procedure TFakeChannel.ResetUnderLock;
begin
  FLock.Acquire;
  try
    if Sink <> nil then
      Sink.PeerClosed(False);
  finally
    FLock.Release;
  end;
end;

function TFakeChannel.SentText(const AIndex: Integer): string;
begin
  FLock.Acquire;
  try
    Result := TextOf(Sent[AIndex]);
  finally
    FLock.Release;
  end;
end;

{ TFakeResponse }

procedure TFakeResponse.SendHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
begin
  raise EHttpError.Create('a detached response sends no headers by itself');
end;

procedure TFakeResponse.Write(const AData: TBytes);
begin
  raise EHttpError.Create('a detached response writes through the channel');
end;

procedure TFakeResponse.Write(const ABuffer; const ACount: Integer);
begin
  raise EHttpError.Create('a detached response writes through the channel');
end;

procedure TFakeResponse.SetBodyWriter(const AWriter: IBodyWriter);
begin
  raise EHttpError.Create('not used');
end;

procedure TFakeResponse.Finish;
begin
  raise EHttpError.Create('not used');
end;

procedure TFakeResponse.RegisterCancelHook(const AHook: TCancelHook);
begin
end;

function TFakeResponse.IsCancelled: Boolean;
begin
  Result := False;
end;

function TFakeResponse.StreamId: LongWord;
begin
  Result := 1;
end;

function TFakeResponse.Detach: IDuplexChannel;
begin
  Inc(DetachCount);
  Result := Channel;
end;

{ TFakeRequest }

function TFakeRequest.GetPrincipal: string;
begin
  Result := Who;
end;

procedure TFakeRequest.SetPrincipal(const AValue: string);
begin
  Who := AValue;
end;

function TFakeRequest.GetClientCertificate: IClientCertificate;
begin
  Result := nil;
end;

function TFakeRequest.Method: string;
begin
  Result := 'GET';
end;

function TFakeRequest.Scheme: string;
begin
  Result := 'http';
end;

function TFakeRequest.Authority: string;
begin
  Result := 'localhost';
end;

function TFakeRequest.Path: string;
begin
  Result := '/events';
end;

function TFakeRequest.Headers: THeaderBlock;
begin
  Result := Header;
end;

function TFakeRequest.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
end;

function TFakeRequest.ReadChunk(out AChunk: TBytes): Boolean;
begin
  AChunk := nil;
  Result := False;
end;

function TFakeRequest.BodyIsComplete: Boolean;
begin
  Result := True;
end;

function TFakeRequest.IsCancelled: Boolean;
begin
  Result := False;
end;

function TFakeRequest.StreamId: LongWord;
begin
  Result := 1;
end;

{ TSseEncoderTest }

function TSseEncoderTest.Enc(const AEvent: TSseEvent): string;
begin
  Result := TextOf(SseEncodeEvent(AEvent));
end;

function TSseEncoderTest.Ev(const AData, AId, AEvent: string;
  const ARetry: Integer): TSseEvent;
begin
  Result := TSseEvent.Text(UTF8String(AData));
  Result.Id := UTF8String(AId);
  Result.Event := UTF8String(AEvent);
  Result.Retry := ARetry;
end;

procedure TSseEncoderTest.ExpectError(const AEvent: TSseEvent;
  const AName: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    SseEncodeEvent(AEvent);
  except
    on ESseError do
      Raised := True;
  end;
  AssertTrue(AName + ' is rejected', Raised);
end;

procedure TSseEncoderTest.TestOneDataLine;
begin
  AssertEquals('data: hello'#10#10, Enc(Ev('hello')));
end;

procedure TSseEncoderTest.TestMultiLineDataSplitsAtLfCrAndCrlf;
begin
  AssertEquals('LF', 'data: a'#10'data: b'#10#10, Enc(Ev('a'#10'b')));
  AssertEquals('CR', 'data: a'#10'data: b'#10#10, Enc(Ev('a'#13'b')));
  AssertEquals('CRLF is one break', 'data: a'#10'data: b'#10#10,
    Enc(Ev('a'#13#10'b')));
  AssertEquals('CR LF CR is two breaks', 'data: a'#10'data:'#10'data: b'#10#10,
    Enc(Ev('a'#13#10#13'b')));
  AssertEquals('an empty line inside the data', 'data: a'#10'data:'#10'data: b'#10#10,
    Enc(Ev('a'#10#10'b')));
end;

procedure TSseEncoderTest.TestDataEndingWithABreakWritesAFinalEmptyField;
begin
  AssertEquals('data: a'#10'data:'#10#10, Enc(Ev('a'#10)));
  AssertEquals('data: a'#10'data:'#10#10, Enc(Ev('a'#13#10)));
end;

procedure TSseEncoderTest.TestEmptyDataWritesOneEmptyField;
var
  E: TSseEvent;
begin
  AssertEquals('data:'#10#10, Enc(Ev('')));
  Finalize(E);
  FillChar(E, SizeOf(E), 0);
  AssertEquals('a default event writes one empty data field', 'data:'#10#10, Enc(E));
end;

procedure TSseEncoderTest.TestFieldsAndTheirOrder;
begin
  AssertEquals('retry: 3000'#10'id: 7'#10'event: tick'#10'data: x'#10#10,
    Enc(Ev('x', '7', 'tick', 3000)));
end;

procedure TSseEncoderTest.TestALeadingSpaceKeepsItsFirstSpace;
begin
  // the client removes one space after the colon, so two spaces keep one
  AssertEquals('data:  x'#10#10, Enc(Ev(' x')));
  AssertEquals('id:  7'#10'data: x'#10#10, Enc(Ev('x', ' 7')));
end;

procedure TSseEncoderTest.TestEmptyIdIsLegal;
begin
  // the data is empty here, and an empty id field is not written: Id is empty
  AssertEquals('data: x'#10#10, Enc(Ev('x', '')));
end;

procedure TSseEncoderTest.TestInjectionIsRejected;
begin
  ExpectError(Ev('x', 'a'#10'data: injected'), 'LF in id');
  ExpectError(Ev('x', 'a'#13'b'), 'CR in id');
  ExpectError(Ev('x', '', 'a'#10#10'data: injected'), 'LF in event');
  ExpectError(Ev('x', '', 'a'#13'b'), 'CR in event');
end;

procedure TSseEncoderTest.TestNulIsRejected;
begin
  ExpectError(Ev('x', 'a'#0'b'), 'NUL in id');
  ExpectError(Ev('a'#0'b'), 'NUL in data');
end;

procedure TSseEncoderTest.TestInvalidUtf8IsRejected;
begin
  ExpectError(Ev('a'#$FF), 'data');
  ExpectError(Ev('x', 'a'#$C0#$80), 'id');
  ExpectError(Ev('x', '', #$ED#$A0#$80), 'event');
end;

procedure TSseEncoderTest.TestRetryRules;
begin
  AssertEquals('retry: 1'#10'data: x'#10#10, Enc(Ev('x', '', '', 1)));
  AssertEquals('retry: 86400000'#10'data: x'#10#10,
    Enc(Ev('x', '', '', cSseMaxRetryMs)));
  ExpectError(Ev('x', '', '', -1), 'a negative retry');
  ExpectError(Ev('x', '', '', cSseMaxRetryMs + 1), 'a retry over the cap');
end;

procedure TSseEncoderTest.TestMultiByteTextPassesThrough;
begin
  AssertEquals('data: é€😀'#10#10, Enc(Ev('é€😀')));
  AssertEquals('U+2028 is not a break', 'data: a'#$E2#$80#$A8'b'#10#10,
    Enc(Ev('a'#$E2#$80#$A8'b')));
end;

procedure TSseEncoderTest.TestCommentEncoding;
var
  Raised: Boolean;
begin
  AssertEquals(': keep-alive'#10#10, TextOf(SseEncodeComment('keep-alive')));
  AssertEquals(': '#10#10, TextOf(SseEncodeComment('')));
  Raised := False;
  try
    SseEncodeComment('a'#10'data: x');
  except
    on ESseError do
      Raised := True;
  end;
  AssertTrue('a break in a comment is rejected', Raised);
end;

procedure TSseEncoderTest.TestLastEventIdCleaning;
begin
  AssertEquals('42', string(SseCleanLastEventId('42')));
  AssertEquals('', string(SseCleanLastEventId('')));
  AssertEquals('a break makes it absent', '', string(SseCleanLastEventId('a'#10'b')));
  AssertEquals('a NUL makes it absent', '', string(SseCleanLastEventId('a'#0'b')));
  AssertEquals('bad UTF-8 makes it absent', '', string(SseCleanLastEventId(#$FF)));
  AssertEquals('é', string(SseCleanLastEventId('é')));
end;

procedure TSseEncoderTest.TestNoBomAndAlwaysABlankLine;
var
  S: string;
begin
  S := Enc(Ev('x'));
  AssertTrue('no BOM', Copy(S, 1, 3) <> #$EF#$BB#$BF);
  AssertEquals('every event ends with a blank line', #10#10,
    Copy(S, Length(S) - 1, 2));
  S := Enc(Ev('a'#10#10#10));
  AssertEquals(#10#10, Copy(S, Length(S) - 1, 2));
end;

{ TSseStreamTest }

procedure TSseStreamTest.Build(const AKeepAliveMs, AStallMs, APoolSize: Integer);
begin
  FPool := TStreamPool.Create(APoolSize);
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

procedure TSseStreamTest.TearDown;
begin
  FRegistry.SourceProvider := nil;
  FPool.Free;
  FPool := nil;
  FChannel.Sink := nil;
  FChannelRef := nil;
  FResponseRef := nil;
  FRequestRef := nil;
  FRegistryRef := nil;
  inherited TearDown;
end;

function TSseStreamTest.Start(const ALastEventId: string): ISseStream;
begin
  if ALastEventId <> '' then
  begin
    SetLength(FRequest.Header, 1);
    FRequest.Header[0].Name := 'Last-Event-ID';
    FRequest.Header[0].Value := ALastEventId;
  end;
  Result := StartSse(FRequestRef, FResponseRef);
end;

function TSseStreamTest.WaitSent(const ACount, ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while (FChannel.SentCount < ACount) and (Waited < ATimeoutMs) do
  begin
    Sleep(5);
    Inc(Waited, 5);
  end;
  Result := FChannel.SentCount >= ACount;
end;

procedure TSseStreamTest.TestStartSendsTheHeadersAndDetaches;
var
  S: ISseStream;
  I: Integer;
  Found: Integer;
begin
  Build(0, 0);
  S := Start;
  AssertEquals(200, FChannel.ActivatedStatus);
  Found := 0;
  for I := 0 to High(FChannel.ActivatedHeaders) do
  begin
    if (FChannel.ActivatedHeaders[I].Name = 'content-type') then
    begin
      AssertEquals('text/event-stream', FChannel.ActivatedHeaders[I].Value);
      Inc(Found);
    end;
    if FChannel.ActivatedHeaders[I].Name = 'cache-control' then
    begin
      AssertEquals('no-store', FChannel.ActivatedHeaders[I].Value);
      Inc(Found);
    end;
    AssertTrue('the stream sets no content-length',
      FChannel.ActivatedHeaders[I].Name <> 'content-length');
  end;
  AssertEquals('both headers are present', 2, Found);
  AssertTrue(S.IsOpen);
end;

procedure TSseStreamTest.TestExtraHeadersAreAdded;
var
  Extra: THeaderBlock;
  S: ISseStream;
  I: Integer;
  Seen: Boolean;
begin
  Build(0, 0);
  SetLength(Extra, 1);
  Extra[0].Name := 'x-accel-buffering';
  Extra[0].Value := 'no';
  S := StartSse(FRequestRef, FResponseRef, Extra);
  Seen := False;
  for I := 0 to High(FChannel.ActivatedHeaders) do
    if FChannel.ActivatedHeaders[I].Name = 'x-accel-buffering' then
      Seen := True;
  AssertTrue(Seen);
end;

procedure TSseStreamTest.TestEventsArriveInOrder;
var
  S: ISseStream;
  I: Integer;
begin
  Build(0, 0);
  S := Start;
  for I := 1 to 20 do
    AssertTrue(S.Send(TSseEvent.Text(UTF8String(IntToStr(I)))) = srQueued);
  AssertEquals(20, FChannel.SentCount);
  for I := 1 to 20 do
    AssertEquals('data: ' + IntToStr(I) + #10#10, FChannel.SentText(I - 1));
end;

type
  TProducer = class(TThread)
  public
    Stream: ISseStream;
    Tag: string;
    Count: Integer;
    procedure Execute; override;
  end;

procedure TProducer.Execute;
var
  I: Integer;
begin
  for I := 1 to Count do
    Stream.Send(TSseEvent.Text(UTF8String(Tag + IntToStr(I) + #10 + Tag + 'b')));
end;

procedure TSseStreamTest.TestTwoProducersNeverInterleave;
var
  S: ISseStream;
  A, B: TProducer;
  I: Integer;
  Text: string;
begin
  Build(0, 0);
  S := Start;
  A := TProducer.Create(True);
  B := TProducer.Create(True);
  try
    A.Stream := S; A.Tag := 'a'; A.Count := 500;
    B.Stream := S; B.Tag := 'b'; B.Count := 500;
    A.Start;
    B.Start;
    A.WaitFor;
    B.WaitFor;
  finally
    A.Free;
    B.Free;
  end;
  AssertEquals(1000, FChannel.SentCount);
  for I := 0 to 999 do
  begin
    Text := FChannel.SentText(I);
    // every write is one whole event of two data lines with the same tag
    AssertTrue('event ' + IntToStr(I) + ' is whole: ' + Text,
      ((Text[7] = 'a') and (Pos(#10'data: ab'#10#10, Text) > 0)) or
      ((Text[7] = 'b') and (Pos(#10'data: bb'#10#10, Text) > 0)));
  end;
end;

procedure TSseStreamTest.TestKeepAliveCommentArrives;
var
  S: ISseStream;
begin
  Build(30, 0);
  S := Start;
  AssertTrue('a keep-alive comment arrives', WaitSent(1, 3000));
  AssertEquals(': keep-alive'#10#10, FChannel.SentText(0));
  AssertTrue('and more follow', WaitSent(3, 3000));
  S.Close;
end;

procedure TSseStreamTest.TestKeepAliveWaitsWhileEventsFlow;
var
  S: ISseStream;
  I: Integer;
  Comments: Integer;
begin
  Build(300, 0);
  S := Start;
  // an event every 20 ms for 250 ms keeps the stream busy: no comment is due
  for I := 1 to 12 do
  begin
    S.Send(TSseEvent.Text('e'));
    Sleep(20);
  end;
  Comments := 0;
  for I := 0 to FChannel.SentCount - 1 do
    if Copy(FChannel.SentText(I), 1, 1) = ':' then
      Inc(Comments);
  AssertEquals('no keep-alive while events flow', 0, Comments);
  S.Close;
end;

procedure TSseStreamTest.TestManyStreamsShareOnePoolThread;
const
  cStreams = 1000;
var
  Channels: array of TFakeChannel;
  Refs: array of IDuplexChannel;
  Streams: array of ISseStream;
  Resp: array of IServerResponse;
  I, Got, Waited: Integer;
begin
  Build(40, 0);
  SetLength(Channels, cStreams);
  SetLength(Refs, cStreams);
  SetLength(Streams, cStreams);
  SetLength(Resp, cStreams);
  for I := 0 to cStreams - 1 do
  begin
    Channels[I] := TFakeChannel.Create(FRegistryRef);
    Refs[I] := Channels[I];
    Resp[I] := TFakeResponse.Create;
    TFakeResponse(Resp[I] as TObject).Channel := Refs[I];
    Streams[I] := StartSse(FRequestRef, Resp[I]);
  end;
  Waited := 0;
  repeat
    Got := 0;
    for I := 0 to cStreams - 1 do
      if Channels[I].SentCount > 0 then
        Inc(Got);
    if Got < cStreams then
      Sleep(20);
    Inc(Waited, 20);
  until (Got = cStreams) or (Waited > 8000);
  AssertEquals('every stream got a keep-alive comment', cStreams, Got);
  AssertEquals('one pool thread served all of them', 1, FPool.Stats.Threads);
  for I := 0 to cStreams - 1 do
  begin
    Streams[I].Close;
    Channels[I].Sink := nil;
  end;
end;

procedure TSseStreamTest.TestStalledReaderIsClosed;
var
  S: ISseStream;
  Waited: Integer;
begin
  Build(0, 80);
  S := Start;
  FChannel.Full := True;
  AssertTrue(S.Send(TSseEvent.Text('x')) = srFull);
  Waited := 0;
  while FChannel.IsOpen and (Waited < 3000) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  AssertFalse('the server closed the stalled stream', FChannel.IsOpen);
  AssertTrue('and aborted it', FChannel.CloseMode = ccAbort);
  AssertFalse(S.IsOpen);
end;

procedure TSseStreamTest.TestDrainEndsTheStall;
var
  S: ISseStream;
begin
  Build(0, 150);
  S := Start;
  FChannel.Full := True;
  AssertTrue(S.Send(TSseEvent.Text('x')) = srFull);
  FChannel.Full := False;
  FChannel.Sink.WriteDrained;
  Sleep(400);
  AssertTrue('a drained stream is not closed', FChannel.IsOpen);
  AssertTrue(S.Send(TSseEvent.Text('y')) = srQueued);
  S.Close;
end;

procedure TSseStreamTest.TestPeerResetEndsTheStream;
var
  S: ISseStream;
begin
  Build(50, 0);
  S := Start;
  FChannel.Sink.PeerClosed(False);
  FChannel.Closed := True;
  AssertFalse(S.IsOpen);
  AssertTrue(S.Send(TSseEvent.Text('x')) = srClosed);
end;

procedure TSseStreamTest.TestCleanHalfCloseOfTheRequestKeepsTheStreamOpen;
var
  S: ISseStream;
begin
  Build(0, 0);
  S := Start;
  // a GET ends its own half at once; the response goes on
  FChannel.Sink.PeerClosed(True);
  AssertTrue(S.IsOpen);
  AssertTrue(S.Send(TSseEvent.Text('x')) = srQueued);
end;

procedure TSseStreamTest.TestCloseIsGraceful;
var
  S: ISseStream;
begin
  Build(20, 0);
  S := Start;
  S.Close;
  AssertTrue(FChannel.Closed);
  AssertTrue(FChannel.CloseMode = ccGraceful);
  AssertFalse(S.IsOpen);
  Sleep(100);
  AssertEquals('the keep-alive timer is gone', 0, FChannel.SentCount);
end;

procedure TSseStreamTest.TestSendAfterCloseAnswersClosed;
var
  S: ISseStream;
begin
  Build(0, 0);
  S := Start;
  S.Close;
  AssertTrue(S.Send(TSseEvent.Text('x')) = srClosed);
  AssertTrue(S.SendComment('c') = srClosed);
end;

procedure TSseStreamTest.TestLastEventIdReachesTheHandler;
var
  S: ISseStream;
begin
  Build(0, 0);
  S := Start('41');
  AssertEquals('41', string(S.LastEventId));
end;

procedure TSseStreamTest.TestBadEventIsRaisedAndNothingIsSent;
var
  S: ISseStream;
  E: TSseEvent;
  Raised: Boolean;
begin
  Build(0, 0);
  S := Start;
  E := TSseEvent.Text('x');
  E.Id := 'a'#10'b';
  Raised := False;
  try
    S.Send(E);
  except
    on ESseError do
      Raised := True;
  end;
  AssertTrue(Raised);
  AssertEquals(0, FChannel.SentCount);
  AssertTrue('the stream stays open', S.IsOpen);
end;

procedure TSseStreamTest.TestRequestBodyCreditGoesBack;
var
  S: ISseStream;
  B: Byte;
begin
  Build(0, 0);
  S := Start;
  B := 1;
  FChannel.Sink.BytesReceived(B, 1);
  AssertEquals(1, FChannel.Credit);
end;

type
  /// sends events until told to stop
  TSendLoop = class(TThread)
  public
    Stream: ISseStream;
    Rounds: Integer;
    procedure Execute; override;
  end;

  /// delivers the sink callbacks under the channel lock
  TCallbackLoop = class(TThread)
  public
    Channel: TFakeChannel;
    Rounds: Integer;
    procedure Execute; override;
  end;

procedure TSendLoop.Execute;
var
  I: Integer;
begin
  for I := 1 to Rounds do
    Stream.Send(TSseEvent.Text('x'));
end;

procedure TCallbackLoop.Execute;
var
  I: Integer;
begin
  for I := 1 to Rounds do
    Channel.DrainUnderLock;
end;

procedure TSseStreamTest.TestCallbacksUnderTheChannelLockDoNotDeadlock;
var
  S: ISseStream;
  A, B: TSendLoop;
  C: TCallbackLoop;
  Waited: Integer;
begin
  Build(0, 0);
  S := Start;
  A := TSendLoop.Create(True);
  B := TSendLoop.Create(True);
  C := TCallbackLoop.Create(True);
  A.Stream := S; A.Rounds := 20000;
  B.Stream := S; B.Rounds := 20000;
  C.Channel := FChannel; C.Rounds := 20000;
  A.FreeOnTerminate := False; B.FreeOnTerminate := False; C.FreeOnTerminate := False;
  A.Start; B.Start; C.Start;
  Waited := 0;
  while (not (A.Finished and B.Finished and C.Finished)) and (Waited < 20000) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  AssertTrue('producers and channel callbacks finish: no lock-order deadlock',
    A.Finished and B.Finished and C.Finished);
  A.WaitFor; B.WaitFor; C.WaitFor;
  A.Free; B.Free; C.Free;
  // a reset under the channel lock ends the stream without a deadlock too
  FChannel.ResetUnderLock;
  FChannel.Closed := True;
  AssertFalse(S.IsOpen);
end;

initialization
  RegisterTest(TSseEncoderTest);
  RegisterTest(TSseStreamTest);

end.
