{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, lifetime, test
notes:
  - Tests for the connection lifetime limits. The stream cap retires the
    connection, Retire sends the two-step GOAWAY, and open WebSocket
    streams are counted for the age sweep.
  - The fixture comes from the unit Http2Server.Connection.Test. The frame
    inputs follow RFC 9113 sections 5.1.2 (REFUSED_STREAM, safe retry) and
    6.8 (the two-step GOAWAY).
---
}
/// Connection lifetime tests for Http2Server.Connection
unit Http2Server.Connection.Lifetime.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Observer,
  Http2Server.Connection.Test;

type
  /// the lifetime tests share the connection core fixture of the unit
  /// Http2Server.Connection.Test and add the capped-core helper
  TConnectionLifetimeFixture = class(TConnectionFixture)
  protected
    procedure CappedCore(const ACap: LongWord);
    function ConnectFrame(AStreamId: LongWord;
      const AProtocol: string): TFrame;
  end;

  TConnectionLifetimeTest = class(TConnectionLifetimeFixture)
  published
    procedure TestStreamCapRetiresTheConnection;
    procedure TestStreamCapZeroSendsNoGoAway;
    procedure TestConcurrencyRefusedStreamIsNotCounted;
    procedure TestRetireWarnsOnceThenFinalGoAway;
    procedure TestOpenWebSocketStreamCount;
  end;

implementation

procedure TConnectionLifetimeFixture.CappedCore(const ACap: LongWord);
begin
  FOptions := PlainOptions;
  FOptions.MaxStreams := ACap;
  MakeCoreWith(FOptions, 10000);
end;

function TConnectionLifetimeFixture.ConnectFrame(AStreamId: LongWord;
  const AProtocol: string): TFrame;
var
  Block: TBytes;
begin
  Block := BlockOf([':method', ':scheme', ':authority', ':path', ':protocol'],
    ['CONNECT', 'https', 'example.com', '/chat', AProtocol]);
  Result := TFrame.Create(ftHeaders, [ffEndHeaders, ffEndStream], AStreamId,
    Block);
end;

procedure TConnectionLifetimeTest.TestStreamCapRetiresTheConnection;
var
  Frames: TArray<TFrame>;
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
begin
  CappedCore(2);
  FCore.Feed(Pack(True, [RequestFrame(1)]));
  FCore.Feed(Pack(False, [RequestFrame(3)]));
  AssertEquals('two requests reached the handler', 2, FEvents.Requests);
  Frames := OutputFrames;
  AssertEquals('the cap sends one GOAWAY', 1, CountOf(Frames, ftGoAway));
  ParseGoAway(AnyOf(Frames, ftGoAway), Id, Code, Debug);
  AssertEquals('the cap GOAWAY carries NO_ERROR', Ord(ecNoError), Ord(Code));
  AssertEquals('the cap GOAWAY names stream 3', 3, Id);
  FCore.Feed(Pack(False, [RequestFrame(5)]));
  Frames := OutputFrames;
  AssertEquals('stream 5 is refused', 5,
    AnyOf(Frames, ftRstStream).Header.StreamId);
  ParseRstStream(AnyOf(Frames, ftRstStream), Code);
  AssertEquals('the refusal is REFUSED_STREAM', Ord(ecRefusedStream),
    Ord(Code));
  AssertEquals('one retire event fired', 1, Length(FEvents.Retired));
  AssertEquals('the kind is seConnectionRetired', Ord(seConnectionRetired),
    Ord(FEvents.Retired[0].Kind));
  AssertEquals('the detail names the stream cap', RetireDetailMaxStreams,
    FEvents.Retired[0].Detail);
  AssertEquals('the retire names stream zero', 0, FEvents.Retired[0].StreamId);
end;

procedure TConnectionLifetimeTest.TestStreamCapZeroSendsNoGoAway;
var
  Frames: TArray<TFrame>;
begin
  CappedCore(0);
  FCore.Feed(Pack(True, [RequestFrame(1), RequestFrame(3), RequestFrame(5)]));
  Frames := OutputFrames;
  AssertEquals('three requests arrived', 3, FEvents.Requests);
  AssertEquals('no GOAWAY leaves the core', 0, CountOf(Frames, ftGoAway));
  AssertEquals('no retire fired', 0, Length(FEvents.Retired));
end;

procedure TConnectionLifetimeTest.TestConcurrencyRefusedStreamIsNotCounted;
var
  Frames: TArray<TFrame>;
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
begin
  FOptions := PlainOptions;
  FOptions.MaxConcurrentStreams := 1;
  FOptions.MaxStreams := 2;
  MakeCoreWith(FOptions, 10000);
  FCore.Feed(Pack(True, [RequestFrame(1, False)]));
  FCore.Feed(Pack(False, [RequestFrame(3, False)]));
  AssertEquals('only the first request arrived', 1, FEvents.Requests);
  AssertFalse('no GOAWAY leaves yet', FCore.GoAwaySent);
  FCore.Feed(Pack(False,
    [TFrame.Create(ftRstStream, [], 1, RstPayload(ecCancel))]));
  FCore.Feed(Pack(False, [RequestFrame(5)]));
  AssertEquals('two requests arrived', 2, FEvents.Requests);
  Frames := OutputFrames;
  ParseGoAway(AnyOf(Frames, ftGoAway), Id, Code, Debug);
  AssertEquals('the cap GOAWAY names stream 5', 5, Id);
  AssertEquals('one retire fired', 1, Length(FEvents.Retired));
end;

procedure TConnectionLifetimeTest.TestRetireWarnsOnceThenFinalGoAway;
var
  Frames: TArray<TFrame>;
  Id: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
begin
  NewCore;
  FCore.Feed(Pack(True, [RequestFrame(1)]));
  OutputFrames;
  FCore.Retire(RetireDetailMaxAge);
  FCore.Retire(RetireDetailMaxAge);
  Frames := OutputFrames;
  AssertEquals('two retires send one GOAWAY', 1, CountOf(Frames, ftGoAway));
  ParseGoAway(AnyOf(Frames, ftGoAway), Id, Code, Debug);
  AssertEquals('the warning carries NO_ERROR', Ord(ecNoError), Ord(Code));
  AssertEquals('the warning names 2^31-1', $7FFFFFFF, Id);
  AssertTrue('the connection is closing', FCore.IsClosing);
  AssertEquals('one retire fired', 1, Length(FEvents.Retired));
  AssertEquals('the detail names the age', RetireDetailMaxAge,
    FEvents.Retired[0].Detail);
  FCore.SendFinalGoAway;
  FCore.SendFinalGoAway;
  Frames := OutputFrames;
  AssertEquals('two finals send one GOAWAY', 1, CountOf(Frames, ftGoAway));
  ParseGoAway(AnyOf(Frames, ftGoAway), Id, Code, Debug);
  AssertEquals('the final names the real last stream', 1, Id);
end;

procedure TConnectionLifetimeTest.TestOpenWebSocketStreamCount;
begin
  FOptions := PlainOptions;
  FOptions.ConnectProtocol := True;
  MakeCoreWith(FOptions, 10000);
  FCore.Feed(Pack(True, [ConnectFrame(1, 'websocket')]));
  AssertEquals('the CONNECT arrived', 1, FEvents.Requests);
  AssertEquals('one WebSocket stream is open', 1, FCore.OpenWebSocketStreams);
  FCore.Feed(Pack(False, [ConnectFrame(3, 'other')]));
  AssertEquals('the plain CONNECT arrived', 2, FEvents.Requests);
  AssertEquals('it is no WebSocket stream', 1, FCore.OpenWebSocketStreams);
  FCore.Feed(Pack(False,
    [TFrame.Create(ftRstStream, [], 1, RstPayload(ecCancel))]));
  AssertEquals('no WebSocket stream is open', 0, FCore.OpenWebSocketStreams);
end;

initialization
  RegisterTest(TConnectionLifetimeTest);
end.
