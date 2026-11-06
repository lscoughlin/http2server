{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, output, budget, test, fpcunit
notes:
  - This unit tests the outbound frame budget.
  - The budget holds no socket, so the tests need none.
---
}
/// Unit tests for the outbound frame budget
// - run with `make test`.
unit Http2Server.OutboundBudget.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2Server.Frames, Http2Server.OutboundBudget;

type
  /// tests of TOutboundBudget
  TOutboundBudgetTest = class(TTestCase)
  private
    FBudget: TOutboundBudget;
    procedure MakeBudget(const AMaxFrames, AMaxControl: LongWord);
    procedure Count(const AFrameType: TFrameType; const AN: Integer);
  protected
    procedure TearDown; override;
  published
    /// counted frames raise the pending total
    procedure TestCountsRaiseThePendingTotal;
    /// only PING, SETTINGS and RST_STREAM count as control frames
    procedure TestKindsSplitControlFromData;
    /// Reset forgets every count, batch and total
    procedure TestResetForgetsEverything;
    /// a limit of 0 turns that cap off
    procedure TestZeroLimitIsOff;
    /// the control cap trips before the total cap
    procedure TestControlTripsBeforeTotal;
    /// the count passes the cap strictly above it
    procedure TestCapPassesStrictlyAbove;
    /// a closed batch stays pending until its octets are written
    procedure TestBatchReleasesAtItsEndOffset;
    /// a partial write releases the earlier batches only
    procedure TestPartialWriteReleasesEarlierBatchesOnly;
    /// a report above the handed-out total releases every batch
    procedure TestWrittenTotalClampsToHandedOut;
  end;

implementation

{ TOutboundBudgetTest }

procedure TOutboundBudgetTest.MakeBudget(const AMaxFrames,
  AMaxControl: LongWord);
begin
  FreeAndNil(FBudget);
  FBudget := TOutboundBudget.Create(AMaxFrames, AMaxControl);
end;

procedure TOutboundBudgetTest.Count(const AFrameType: TFrameType;
  const AN: Integer);
var
  I: Integer;
begin
  for I := 1 to AN do
    FBudget.CountFrame(AFrameType);
end;

procedure TOutboundBudgetTest.TearDown;
begin
  FreeAndNil(FBudget);
end;

procedure TOutboundBudgetTest.TestCountsRaiseThePendingTotal;
begin
  MakeBudget(10, 5);
  Count(ftData, 3);
  AssertEquals('three DATA frames wait', 3, FBudget.PendingFrames);
  AssertEquals('no control frame waits', 0, FBudget.PendingControlFrames);
  AssertFalse('the budget holds', FBudget.Exceeded);
end;

procedure TOutboundBudgetTest.TestKindsSplitControlFromData;
var
  Kind: TFrameType;
begin
  MakeBudget(100, 100);
  for Kind := Low(TFrameType) to High(TFrameType) do
    FBudget.CountFrame(Kind);
  AssertEquals('every kind waits in the total', 10, FBudget.PendingFrames);
  AssertEquals('PING, SETTINGS and RST_STREAM wait as control', 3,
    FBudget.PendingControlFrames);
end;

procedure TOutboundBudgetTest.TestResetForgetsEverything;
begin
  MakeBudget(10, 5);
  Count(ftPing, 4);
  FBudget.CloseBatch(100);
  Count(ftData, 2);
  FBudget.ReportWritten(50);
  FBudget.Reset;
  AssertEquals('no frame waits after a reset', 0, FBudget.PendingFrames);
  AssertEquals('no control frame waits after a reset', 0,
    FBudget.PendingControlFrames);
  AssertEquals('no octet is handed out after a reset', 0,
    FBudget.HandedOut);
  AssertFalse('the budget holds after a reset', FBudget.Exceeded);
  Count(ftData, 2);
  AssertEquals('the budget counts again after a reset', 2,
    FBudget.PendingFrames);
end;

procedure TOutboundBudgetTest.TestZeroLimitIsOff;
begin
  MakeBudget(0, 0);
  Count(ftPing, 10000);
  Count(ftData, 10000);
  AssertFalse('no cap trips when both caps are 0', FBudget.Exceeded);
  MakeBudget(10, 0);
  Count(ftPing, 10000);
  AssertFalse('the control cap is off at 0', FBudget.ControlCapPassed);
  AssertTrue('the total cap still trips', FBudget.FrameCapPassed);
  MakeBudget(0, 5);
  Count(ftData, 10000);
  AssertFalse('the total cap is off at 0', FBudget.FrameCapPassed);
  AssertFalse('no control frame trips the control cap',
    FBudget.ControlCapPassed);
end;

procedure TOutboundBudgetTest.TestControlTripsBeforeTotal;
begin
  MakeBudget(100, 5);
  Count(ftPing, 6);
  AssertTrue('the control cap passed', FBudget.ControlCapPassed);
  AssertFalse('the total cap holds', FBudget.FrameCapPassed);
  AssertTrue('the budget answers exceeded', FBudget.Exceeded);
end;

procedure TOutboundBudgetTest.TestCapPassesStrictlyAbove;
begin
  MakeBudget(10, 5);
  Count(ftData, 10);
  AssertFalse('ten frames meet the cap of ten', FBudget.FrameCapPassed);
  Count(ftData, 1);
  AssertTrue('eleven frames pass the cap of ten', FBudget.FrameCapPassed);
end;

procedure TOutboundBudgetTest.TestBatchReleasesAtItsEndOffset;
begin
  MakeBudget(100, 100);
  Count(ftPing, 2);
  Count(ftData, 1);
  FBudget.CloseBatch(100);
  AssertEquals('the handed-out total counts the batch', 100,
    FBudget.HandedOut);
  FBudget.ReportWritten(99);
  AssertEquals('one octet short releases nothing', 3, FBudget.PendingFrames);
  AssertEquals('the control frames wait too', 2,
    FBudget.PendingControlFrames);
  FBudget.ReportWritten(100);
  AssertEquals('the end offset releases the batch', 0,
    FBudget.PendingFrames);
  AssertEquals('the control count leaves with the batch', 0,
    FBudget.PendingControlFrames);
end;

procedure TOutboundBudgetTest.TestPartialWriteReleasesEarlierBatchesOnly;
begin
  MakeBudget(100, 100);
  Count(ftData, 3);
  FBudget.CloseBatch(100);
  Count(ftPing, 2);
  FBudget.CloseBatch(50);
  AssertEquals('five frames wait', 5, FBudget.PendingFrames);
  FBudget.ReportWritten(100);
  AssertEquals('the first batch leaves', 2, FBudget.PendingFrames);
  AssertEquals('the second batch is all control', 2,
    FBudget.PendingControlFrames);
  FBudget.ReportWritten(149);
  AssertEquals('one octet short keeps the second batch', 2,
    FBudget.PendingFrames);
  FBudget.ReportWritten(150);
  AssertEquals('the end offset releases the second batch', 0,
    FBudget.PendingFrames);
end;

procedure TOutboundBudgetTest.TestWrittenTotalClampsToHandedOut;
begin
  MakeBudget(100, 100);
  Count(ftData, 3);
  FBudget.CloseBatch(100);
  FBudget.ReportWritten(-1);
  AssertEquals('a negative total releases nothing', 3,
    FBudget.PendingFrames);
  FBudget.ReportWritten(1000000);
  AssertEquals('a total above the handed-out total releases all', 0,
    FBudget.PendingFrames);
end;

initialization
  RegisterTest(TOutboundBudgetTest);
end.
