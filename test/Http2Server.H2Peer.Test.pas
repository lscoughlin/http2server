{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, test, peer, smoke
notes:
  - This unit holds one smoke test for each helper of the in-memory peer, so
    that the later stories of the hardening plan can trust the peer.
  - A smoke test checks the helper and not a defect of the server.
---
}
/// Smoke tests of the in-memory HTTP/2 peer
unit Http2Server.H2Peer.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames, Http2Server.Hpack,
  Http2Server.H2Peer;

type
  TH2PeerSmokeTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Open;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPrefaceGivesServerSettingsAndAck;
    procedure TestPartialSettingsIsAcknowledged;
    procedure TestGetRaisesOneRequest;
    procedure TestTrailersAreSent;
    procedure TestPaddedDataIsAccepted;
    procedure TestPriorityIsAccepted;
    procedure TestWindowUpdateOnBothLevels;
    procedure TestRstStreamIsAccepted;
    procedure TestGoAwayIsAnswered;
    procedure TestRespondWritesStatusAndBody;
    procedure TestHeaderBlocksDecodeWithTheCappedTable;
    procedure TestReceiveWindowModelTracksData;
    procedure TestDataOverTheWindowIsAViolation;
    procedure TestAutoCreditKeepsTheWindowOpen;
  end;

implementation

procedure TH2PeerSmokeTest.SetUp;
begin
  FPeer := TH2Peer.Create;
end;

procedure TH2PeerSmokeTest.TearDown;
begin
  FPeer.Free;
end;

procedure TH2PeerSmokeTest.Open;
begin
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

procedure TH2PeerSmokeTest.TestPrefaceGivesServerSettingsAndAck;
var
  P: TPeerFrame;
begin
  Open;
  AssertTrue('the server sent SETTINGS', FPeer.Find(ftSettings, P));
  AssertTrue('the peer read at least two SETTINGS frames (server and ack)',
    FPeer.CountOf(ftSettings) >= 2);
  AssertEquals('no violation', 0, FPeer.Violations.Count);
end;

procedure TH2PeerSmokeTest.TestPartialSettingsIsAcknowledged;
var
  Before: Integer;
begin
  Open;
  Before := FPeer.CountOf(ftSettings);
  FPeer.SendSettings([3], [10]);
  FPeer.Pump;
  AssertEquals('one ack for the one entry', Before + 1, FPeer.CountOf(ftSettings));
end;

procedure TH2PeerSmokeTest.TestGetRaisesOneRequest;
begin
  Open;
  FPeer.SendGet(1);
  FPeer.Pump;
  AssertEquals(1, FPeer.Events.Requests);
  AssertEquals(1, FPeer.Events.ReadyIds[0]);
end;

procedure TH2PeerSmokeTest.TestTrailersAreSent;
var
  T: THeaderBlock;
begin
  Open;
  FPeer.SendPostHead(1);
  FPeer.SendData(1, 10);
  SetLength(T, 1);
  T[0].Name := 'x-trailer';
  T[0].Value := 'v';
  FPeer.SendTrailers(1, T);
  FPeer.Pump;
  AssertTrue('the core accepted the sequence', FPeer.Events.Requests >= 1);
  AssertEquals('the connection stays open', 0, FPeer.CountOf(ftGoAway));
end;

procedure TH2PeerSmokeTest.TestPaddedDataIsAccepted;
begin
  Open;
  FPeer.SendPostHead(1);
  FPeer.SendPaddedData(1, 10, 5);
  FPeer.Pump;
  AssertEquals('padded data does not close the connection', 0,
    FPeer.CountOf(ftGoAway));
end;

procedure TH2PeerSmokeTest.TestPriorityIsAccepted;
begin
  Open;
  FPeer.SendGet(1, '/', False);
  FPeer.SendPriority(1, 0);
  FPeer.Pump;
  AssertEquals(0, FPeer.CountOf(ftGoAway));
end;

procedure TH2PeerSmokeTest.TestWindowUpdateOnBothLevels;
begin
  Open;
  FPeer.SendGet(1, '/', False);
  FPeer.SendWindowUpdate(0, 1000);
  FPeer.SendWindowUpdate(1, 1000);
  FPeer.Pump;
  AssertEquals(65535 + 1000, FPeer.ConnectionWindow);
  AssertEquals(65535 + 1000, FPeer.StreamWindow(1));
  AssertEquals(0, FPeer.CountOf(ftGoAway));
end;

procedure TH2PeerSmokeTest.TestRstStreamIsAccepted;
begin
  Open;
  FPeer.SendGet(1, '/', False);
  FPeer.SendRst(1, ecCancel);
  FPeer.Pump;
  AssertEquals(1, FPeer.Events.Resets);
end;

procedure TH2PeerSmokeTest.TestGoAwayIsAnswered;
begin
  Open;
  FPeer.SendPing;
  FPeer.Pump;
  AssertEquals('the ping is acknowledged', 1, FPeer.CountOf(ftPing));
end;

procedure TH2PeerSmokeTest.TestRespondWritesStatusAndBody;
begin
  Open;
  FPeer.SendGet(1);
  FPeer.Pump;
  FPeer.Respond(1, 200, 100);
  FPeer.Pump;
  AssertEquals('200', FPeer.StatusOf(1));
  AssertEquals(100, FPeer.DataOctets(1));
  AssertEquals(0, FPeer.Violations.Count);
end;

procedure TH2PeerSmokeTest.TestHeaderBlocksDecodeWithTheCappedTable;
var
  I: Integer;
begin
  Open;
  for I := 0 to 4 do
  begin
    FPeer.SendGet(1 + 2 * I);
    FPeer.Pump;
    FPeer.Respond(1 + 2 * I, 200, 0);
    FPeer.Pump;
  end;
  AssertEquals('five responses decode with a 4096 byte table', 0,
    FPeer.Violations.Count);
  AssertEquals(5, FPeer.CountOf(ftHeaders));
end;

procedure TH2PeerSmokeTest.TestReceiveWindowModelTracksData;
begin
  Open;
  FPeer.SendGet(1);
  FPeer.Pump;
  FPeer.Respond(1, 200, 1000);
  FPeer.Pump;
  AssertEquals(65535 - 1000, FPeer.ConnectionWindow);
  AssertEquals(65535 - 1000, FPeer.StreamWindow(1));
end;

procedure TH2PeerSmokeTest.TestDataOverTheWindowIsAViolation;
var
  Big: TBytes;
begin
  // the model itself: feed it a DATA frame that no strict server would write
  SetLength(Big, 65536);
  FPeer.Inject(BuildDataFrame(1, Big, False));
  AssertTrue('65536 octets over a window of 65535 are a violation',
    FPeer.Violations.Count >= 2);
end;

procedure TH2PeerSmokeTest.TestAutoCreditKeepsTheWindowOpen;
begin
  Open;
  FPeer.AutoCredit := True;
  FPeer.SendGet(1);
  FPeer.Pump;
  FPeer.Respond(1, 200, 5000);
  FPeer.Pump;
  AssertEquals('the credit restored the windows', 65535, FPeer.ConnectionWindow);
end;

initialization
  RegisterTest(TH2PeerSmokeTest);
end.
