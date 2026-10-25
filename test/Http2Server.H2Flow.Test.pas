{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, flow control, send window, receive window, test
notes:
  - This unit holds the tests of story 25b of the hardening plan. They test the
    finding H2-1, that one flow-control object served both directions.
  - Each test drives the core in memory with the strict peer of
    Http2Server.H2Peer, which fails when the server sends more than a window
    allows.
---
}
/// Tests of the two flow-control directions
unit Http2Server.H2Flow.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.H2Peer;

type
  TH2FlowTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Start(const AOptions: TPeerOptions);
  protected
    procedure TearDown; override;
  published
    procedure TestStalledDownloadDoesNotFailAnUpload;
    procedure TestServerNeverSendsMoreThanThePeerWindow;
    procedure TestInitialConnectionWindowIsAnnounced;
    procedure TestNoAnnouncementForTheDefaultConnectionWindow;
    procedure TestStreamSendWindowOpensFromThePeerInitialSize;
    procedure TestUploadUsesTheReceiveWindowOnly;
  end;

implementation

procedure TH2FlowTest.TearDown;
begin
  FreeAndNil(FPeer);
end;

procedure TH2FlowTest.Start(const AOptions: TPeerOptions);
begin
  FPeer := TH2Peer.Create(AOptions);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

procedure TH2FlowTest.TestStalledDownloadDoesNotFailAnUpload;
var
  Code: THttp2ErrorCode;
  I: Integer;
begin
  Start(TPeerOptions.Default);
  FPeer.SendGet(1);
  FPeer.Pump;
  // the download fills the whole send window of the connection
  FPeer.Respond(1, 200, 65535);
  FPeer.Pump;
  AssertEquals('the send window is empty', 0, FPeer.Core.SendConnectionWindowSize);
  // an upload on another stream uses the receive window, which is separate
  FPeer.SendPostHead(3);
  for I := 1 to 4 do
    FPeer.SendData(3, 10000);
  FPeer.Pump;
  if FPeer.GoAwayCode(Code) then
    Fail('the upload raised a connection error: ' + Http2ErrorCodeName(Code));
  AssertEquals('the upload was not reset', 0, FPeer.CountOnStream(ftRstStream, 3));
end;

procedure TH2FlowTest.TestServerNeverSendsMoreThanThePeerWindow;
var
  Options: TPeerOptions;
begin
  Options := TPeerOptions.Default;
  Options.Core.InitialStreamWindow := 1000000;
  Options.Core.ConnectionWindow := 1000000;
  Options.Core.InboundBufferLimit := 1000000;
  Options.Core.OutboundBufferLimit := 300000;
  Start(Options);
  FPeer.SendGet(1);
  FPeer.Pump;
  FPeer.Respond(1, 200, 200000);
  FPeer.Pump;
  AssertEquals('the peer window is the protocol default of 65535', 0,
    FPeer.Violations.Count);
  AssertTrue('the server sent at most 65535 octets', FPeer.DataOctets(1) <= 65535);
end;

procedure TH2FlowTest.TestInitialConnectionWindowIsAnnounced;
var
  Options: TPeerOptions;
begin
  Options := TPeerOptions.Default;
  Options.Core.ConnectionWindow := 1000000;
  Start(Options);
  AssertEquals('the server raises the connection window with a WINDOW_UPDATE',
    1000000 - 65535, FPeer.WindowUpdateSum(0));
end;

procedure TH2FlowTest.TestNoAnnouncementForTheDefaultConnectionWindow;
begin
  Start(TPeerOptions.Default);
  AssertEquals(0, FPeer.WindowUpdateSum(0));
end;

procedure TH2FlowTest.TestStreamSendWindowOpensFromThePeerInitialSize;
var
  Options: TPeerOptions;
begin
  Options := TPeerOptions.Default;
  Options.Core.InitialStreamWindow := 1000000;
  Options.Core.InboundBufferLimit := 1000000;
  Start(Options);
  FPeer.SendSettings([4], [1000]);
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  AssertEquals('the send window follows the peer SETTINGS_INITIAL_WINDOW_SIZE',
    1000, FPeer.Core.SendStreamWindowSize(1));
end;

procedure TH2FlowTest.TestUploadUsesTheReceiveWindowOnly;
begin
  Start(TPeerOptions.Default);
  FPeer.SendPostHead(1);
  FPeer.SendData(1, 1000);
  FPeer.Pump;
  AssertEquals('an upload leaves the send window alone', 65535,
    FPeer.Core.SendConnectionWindowSize);
  AssertEquals('an upload leaves the send window of the stream alone', 65535,
    FPeer.Core.SendStreamWindowSize(1));
end;

initialization
  RegisterTest(TH2FlowTest);
end.
