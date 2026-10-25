{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http/1.1, early response, pipeline, body deadline
notes:
  - These live tests hold the corrections of the HTTP/1.1 path. An early final
    response to Expect 100-continue closes the connection, a defect behind a
    served request does not cancel it, a malformed chunk after an early response
    gets no second answer, and a trickled body ends at the total body time.
---
}
unit Http2Server.Http1.Hardening.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  SyncObjs, Http2Server, Http2Server.Duplex, Http2Server.Http1.SocketChannel,
  Http2Server.Http1.RawClient, Http2Server.Http1.Limits, Http2Server.Http1.Parser,
  Http2Server.Http1.TestKit, Http2Server.Http1.Core, Http2Server.Http1.Host,
  Http2Server.HandlerJob;

type
  /// a sink that records the octets in the order of delivery
  TOrderSink = class(TInterfacedObject, IChannelSink)
  private
    FLock: TCriticalSection;
    FData: string;
    FFirst: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;
    function Data: string;
  end;

  /// takes the jobs of a core and the octets of an undecided upgrade
  TCoreProbe = class(TInterfacedObject, IH1Events, IH1Inbound)
  public
    Jobs: Integer;
    Octets: Integer;
    /// the pool refuses each job at once
    Refusing: Boolean;
    Depth, MaxDepth: Integer;
    procedure Admit(const AJob: IHandlerJob);
    procedure Inbound(const AData; const ACount: Integer);
    procedure ConnectionEnded;
  end;

  /// feeds numbered octets to a channel from a second thread
  TFeeder = class(TThread)
  private
    FChannel: TH1SocketChannel;
    FFrom, FTo: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AChannel: TH1SocketChannel; const AFrom, ATo: Integer);
  end;

  THttp1HardeningTest = class(TTestCase)
  private
    FHandler: TTestHandler;
    FHandlerRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEarlyAnswerToExpectClosesTheConnection;
    procedure TestMalformedChunkAfterAnEarlyAnswerGetsNoSecondResponse;
    procedure TestPipelineOverflowDoesNotCancelTheRequestInProgress;
    procedure TestTrickledBodyEndsAtTheTotalDeadline;
    procedure TestEarlyOctetsReachTheSinkBeforeNewerOnes;
    procedure TestHeaderScanCostGrowsLinearly;
    procedure TestOctetsDuringARefusedUpgradeReturnToTheParser;
    procedure TestRefusedPipelineDoesNotNestTheCalls;
  end;

implementation

{ TOrderSink }

constructor TOrderSink.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FFirst := True;
end;

destructor TOrderSink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TOrderSink.BytesReceived(const AData; const ACount: Integer);
var
  Part: string;
  First: Boolean;
begin
  SetLength(Part, ACount);
  Move(AData, Part[1], ACount);
  FLock.Acquire;
  try
    First := FFirst;
    FFirst := False;
  finally
    FLock.Release;
  end;
  // the first delivery is slow, so a second thread can pass it
  if First then
    Sleep(30);
  FLock.Acquire;
  try
    FData := FData + Part;
  finally
    FLock.Release;
  end;
end;

procedure TOrderSink.PeerClosed(const AClean: Boolean);
begin
end;

procedure TOrderSink.WriteDrained;
begin
end;

function TOrderSink.Data: string;
begin
  FLock.Acquire;
  try
    Result := FData;
  finally
    FLock.Release;
  end;
end;

{ TFeeder }

constructor TFeeder.Create(const AChannel: TH1SocketChannel; const AFrom, ATo: Integer);
begin
  FChannel := AChannel;
  FFrom := AFrom;
  FTo := ATo;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TFeeder.Execute;
var
  I: Integer;
  B: Byte;
begin
  for I := FFrom to FTo do
  begin
    B := Byte(I mod 200 + 33);
    FChannel.Inbound(B, 1);
    Sleep(1);
  end;
end;

procedure THttp1HardeningTest.SetUp;
begin
  FHandler := TTestHandler.Create;
  FHandlerRef := FHandler;
end;

procedure THttp1HardeningTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandlerRef := nil;
end;

procedure THttp1HardeningTest.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

procedure THttp1HardeningTest.TestEarlyAnswerToExpectClosesTheConnection;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /ignore-body HTTP/1.1' + CRLF + 'Host: a' + CRLF +
      'Expect: 100-continue' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('H1-1: the answer says close', 'close',
      LowerCase(R.Header('connection')));
    AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1HardeningTest.TestMalformedChunkAfterAnEarlyAnswerGetsNoSecondResponse;
var
  C: TRawHttp;
  R: TRawResponse;
  Extra: string;
begin
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('POST /ignore-body HTTP/1.1' + CRLF + 'Host: a' + CRLF +
      'Transfer-Encoding: chunked' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals('ok', R.Body);
    C.Send('ZZ' + CRLF);
    Extra := C.ReadSome(700);
    AssertEquals('H1-4: no second response follows', '', Extra);
    AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
  finally
    C.Free;
  end;
end;

procedure THttp1HardeningTest.TestPipelineOverflowDoesNotCancelTheRequestInProgress;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  FHandler.SlowMs := 400;
  StartServer(LiveFactory(FHandlerRef));
  C := TRawHttp.Create(FServer.Port);
  try
    // a slow GET, and behind it a POST larger than the pipeline limit
    C.Send('GET /slow HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF +
      'POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 200000' +
      CRLF + CRLF + StringOfChar('x', 200000));
    AssertTrue('H1-2: the GET in progress is answered', C.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('slow', R.Body);
  finally
    C.Free;
  end;
end;

procedure THttp1HardeningTest.TestTrickledBodyEndsAtTheTotalDeadline;
var
  C: TRawHttp;
  R: TRawResponse;
  I: Integer;
  Started: QWord;
begin
  StartServer(LiveFactory(FHandlerRef).WithHttp11Limits(
    THttp11Limits.Create.WithBodyDeadlineMs(5000).WithBodyTotalMs(700)));
  C := TRawHttp.Create(FServer.Port);
  try
    Started := GetTickCount64;
    C.Send('POST /echo HTTP/1.1' + CRLF + 'Host: a' + CRLF +
      'Content-Length: 100' + CRLF + CRLF);
    for I := 1 to 10 do
    begin
      C.Send('x');
      Sleep(200);
    end;
    // the handler is cancelled at 700 ms: an error answer or a close, never the echo
    if C.ReadResponse(False, ResponseMs, R) then
      AssertTrue('H1-3: the answer is an error: ' + IntToStr(R.Status), R.Status >= 400)
    else
      AssertTrue('the connection ended', C.WaitClosed(ResponseMs));
    AssertTrue('the body did not finish', GetTickCount64 - Started < 4000);
  finally
    C.Free;
  end;
end;

procedure THttp1HardeningTest.TestEarlyOctetsReachTheSinkBeforeNewerOnes;
const
  Rounds = 40;
  Octets = 60;
var
  Channel: TH1SocketChannel;
  Ref: IDuplexChannel;
  Sink: TOrderSink;
  SinkRef: IChannelSink;
  Feeder: TFeeder;
  Round, I: Integer;
  First: Byte;
  Expected: string;
begin
  Expected := '';
  for I := 1 to Octets do
    Expected := Expected + Chr(I mod 200 + 33);
  for Round := 1 to Rounds do
  begin
    Channel := TH1SocketChannel.Create(nil, nil);
    Ref := Channel;
    Sink := TOrderSink.Create;
    SinkRef := Sink;
    // octet 1 waits before the sink arrives; the feeder sends 2 to Octets
    // while the sink takes the early octet
    First := 1 mod 200 + 33;
    Channel.Inbound(First, 1);
    Feeder := TFeeder.Create(Channel, 2, Octets);
    Channel.SetSink(SinkRef);
    Feeder.WaitFor;
    Feeder.Free;
    AssertEquals('H1-6: round ' + IntToStr(Round) + ' keeps the order', Expected,
      Sink.Data);
    Channel.ConnectionEnded;
    SinkRef := nil;
    Ref := nil;
  end;
end;

procedure THttp1HardeningTest.TestHeaderScanCostGrowsLinearly;
var
  Sink: TH1Capture;
  Ref: IH1ParserSink;
  Parser: TH1Parser;
  Head, Filler: string;
  I: Integer;
  C: Char;
begin
  Sink := TH1Capture.Create(True);
  Ref := Sink;
  Parser := TH1Parser.Create(THttp11Limits.Create.WithMaxHeaderLine(8192), Ref);
  try
    Head := 'GET / HTTP/1.1'#13#10'Host: x'#13#10'X-Slow: ';
    Parser.Feed(Head[1], Length(Head));
    C := 'a';
    for I := 1 to 6000 do
      Parser.Feed(C, 1);
    // H1-7: a scan that restarts at the line start costs about 18 million
    // comparisons here; a scan that resumes costs about 6000
    AssertTrue('H1-7: the scan work is linear in the octets, was ' +
      IntToStr(Parser.ScanWork), Parser.ScanWork < 4 * (6000 + Length(Head)));
    Filler := #13#10#13#10;
    Parser.Feed(Filler[1], Length(Filler));
    AssertTrue('the request is complete', Pos('E', Sink.Text) > 0);
    Sink.Attach(nil);
  finally
    Parser.Free;
  end;
end;

{ TCoreProbe }

procedure TCoreProbe.Admit(const AJob: IHandlerJob);
begin
  Inc(Jobs);
  Inc(Depth);
  if Depth > MaxDepth then
    MaxDepth := Depth;
  if Refusing then
    AJob.Refuse(jrQueueFull);
  Dec(Depth);
end;

procedure TCoreProbe.Inbound(const AData; const ACount: Integer);
begin
  Inc(Octets, ACount);
end;

procedure TCoreProbe.ConnectionEnded;
begin
end;

procedure THttp1HardeningTest.TestOctetsDuringARefusedUpgradeReturnToTheParser;
var
  Options: TH1CoreOptions;
  Probe: TCoreProbe;
  EventsRef: IH1Events;
  InboundRef: IH1Inbound;
  Core: TH1Core;
  Head, Next: TBytes;
begin
  FillChar(Options, SizeOf(Options), 0);
  Options.Limits := THttp11Limits.Create;
  Options.Scheme := 'http';
  Probe := TCoreProbe.Create;
  EventsRef := Probe;
  InboundRef := Probe;
  Core := TH1Core.Create(Options, EventsRef);
  try
    Head := TEncoding.ASCII.GetBytes('GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10);
    Core.Feed(Head);
    AssertEquals('the request is admitted', 1, Probe.Jobs);
    Core.UpgradeBegin(InboundRef);
    Next := TEncoding.ASCII.GetBytes('GET /next HTTP/1.1'#13#10);
    Core.Feed(Next);
    AssertEquals('the channel saw the octets', Length(Next), Probe.Octets);
    Core.UpgradeCancel;
    // H1-5: the channel drops its copy, so the parser must hold the octets
    AssertEquals('H1-5: the parser holds the octets of the next request',
      Length(Next), Core.BufferedAfterHead);
  finally
    Core.ReleaseHost;
    Core.Free;
  end;
end;

procedure THttp1HardeningTest.TestRefusedPipelineDoesNotNestTheCalls;
var
  Options: TH1CoreOptions;
  Probe: TCoreProbe;
  EventsRef: IH1Events;
  Core: TH1Core;
  One, All: TBytes;
  I, Count: Integer;
begin
  FillChar(Options, SizeOf(Options), 0);
  Options.Limits := THttp11Limits.Create;
  Options.Scheme := 'http';
  Probe := TCoreProbe.Create;
  Probe.Refusing := True;
  EventsRef := Probe;
  Core := TH1Core.Create(Options, EventsRef);
  try
    One := TEncoding.ASCII.GetBytes('GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10);
    Count := 400;
    SetLength(All, Length(One) * Count);
    for I := 0 to Count - 1 do
      Move(One[0], All[I * Length(One)], Length(One));
    // the first request is in progress while the others arrive in one read
    Core.Feed(All);
    // H1-10: each refused request used to run the next one inside its own call
    AssertTrue('H1-10: the admit calls do not nest, depth ' + IntToStr(Probe.MaxDepth),
      Probe.MaxDepth <= 2);
  finally
    Core.ReleaseHost;
    Core.Free;
  end;
end;

initialization
  RegisterTest(THttp1HardeningTest);

end.
