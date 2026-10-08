{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, limits, tokenbucket, test, fpcunit
notes:
  - This unit tests the per-connection token bucket with a manual clock.
  - Every test drives the clock by hand, so no test waits on wall-clock time.
---
}
/// Unit tests for the per-connection token bucket limits
// - run with `make test`.
// - the tests inject TManualMonotonicClock, so the refill is exact and no
//   test sleeps.
// - the thousand-call test in the third task drives the bucket to empty with
//   single-token takes and checks that the capacity is exactly consumed.
unit Http2Server.Limits.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2Server.Limits;

type
  /// tests of TTokenBucket and TConnectionLimits with a manual clock
  TTokenBucketTest = class(TTestCase)
  private
    FClock: TManualMonotonicClock;
    FTrips: Integer;
    FLastTripKind: TLimitKind;
    procedure HandleTrip(const AKind: TLimitKind);
    function TakeCount(const ABucket: TTokenBucket;
      const ACost, ACount: Integer): Integer;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestBurstUpToCapacity;
    procedure TestRefillRate;
    procedure TestCostWeights;
    procedure TestCapacityCapAfterLongIdle;
    procedure TestZeroRefillRate;
    procedure TestStickyTrip;
    procedure TestRefillDoesNotRunBackwards;
    procedure TestThousandCallsConsumeExactCapacity;
    procedure TestConnectionLimitsChargePerKind;
    procedure TestObserverTripsOnceWithKind;
    procedure TestControlBucketsAreIndependentPerKind;
  end;

implementation

{ TTokenBucketTest }

procedure TTokenBucketTest.SetUp;
begin
  inherited SetUp;
  FClock := TManualMonotonicClock.Create;
  FTrips := 0;
  FLastTripKind := lkReset;
end;

procedure TTokenBucketTest.TearDown;
begin
  FClock := nil;
  inherited TearDown;
end;

procedure TTokenBucketTest.HandleTrip(const AKind: TLimitKind);
begin
  Inc(FTrips);
  FLastTripKind := AKind;
end;

function TTokenBucketTest.TakeCount(const ABucket: TTokenBucket;
  const ACost, ACount: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to ACount do
    if ABucket.TryTake(ACost) then
      Inc(Result);
end;

procedure TTokenBucketTest.TestBurstUpToCapacity;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  Options := TTokenBucketOptions.Create
    .WithCapacity(5)
    .WithRefillPerSecond(0);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    // a burst of five single-token takes empties the full bucket
    AssertEquals('five takes succeed from a full bucket of five',
      5, TakeCount(Bucket, 1, 5));
    // the sixth take finds the bucket empty
    AssertFalse('the sixth take fails', Bucket.TryTake(1));
    AssertTrue('the bucket reports the trip', Bucket.Tripped);
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestRefillRate;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  // capacity two, ten tokens per second: 100 ms adds one token
  Options := TTokenBucketOptions.Create
    .WithCapacity(2)
    .WithRefillPerSecond(10);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    AssertEquals('the full bucket serves two', 2, TakeCount(Bucket, 1, 2));
    AssertFalse('the empty bucket refuses before the refill', Bucket.TryTake(1));
  finally
    Bucket.Free;
  end;
  // a fresh bucket: spend two, wait 100 ms, and take exactly one
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    AssertEquals('the full bucket serves two', 2, TakeCount(Bucket, 1, 2));
    FClock.Advance(100);
    AssertTrue('100 ms at ten per second serves one take', Bucket.TryTake(1));
    AssertFalse('the refill served only one take', Bucket.TryTake(1));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestCostWeights;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  // the reset bucket: a reset after dispatch costs more than one before it
  Options := TTokenBucketOptions.Create
    .WithCapacity(10)
    .WithRefillPerSecond(0)
    .WithCostBeforeDispatch(1)
    .WithCostAfterDispatch(5);
  AssertEquals('the before-dispatch cost is one',
    1, Options.CostBeforeDispatch);
  AssertEquals('the after-dispatch cost is five',
    5, Options.CostAfterDispatch);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    // two after-dispatch resets take ten tokens and empty the bucket
    AssertTrue('the first after-dispatch reset fits', Bucket.TryTake(5));
    AssertTrue('the second after-dispatch reset fits', Bucket.TryTake(5));
    AssertEquals('ten tokens are spent', 0, Round(Bucket.Tokens));
    AssertFalse('the bucket is empty', Bucket.TryTake(5));
    // ten before-dispatch resets fit in the same capacity
    Bucket.Free;
    Bucket := TTokenBucket.Create(FClock, Options);
    AssertEquals('ten before-dispatch resets fit in ten tokens',
      10, TakeCount(Bucket, 1, 10));
    AssertFalse('the eleventh before-dispatch reset fails',
      Bucket.TryTake(1));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestCapacityCapAfterLongIdle;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  Options := TTokenBucketOptions.Create
    .WithCapacity(4)
    .WithRefillPerSecond(100);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    AssertEquals('the full bucket serves four', 4, TakeCount(Bucket, 1, 4));
    // one hour of idle time adds far more than the capacity, so the bucket
    // stays at the cap
    FClock.Advance(3600 * MSecsPerSec);
    AssertEquals('one hour of idle time serves no more than the cap',
      4, TakeCount(Bucket, 1, 20));
    AssertEquals('the bucket is empty again', 0, Round(Bucket.Tokens));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestZeroRefillRate;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  Options := TTokenBucketOptions.Create
    .WithCapacity(3)
    .WithRefillPerSecond(0);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    AssertEquals('the full bucket serves three', 3, TakeCount(Bucket, 1, 3));
    FClock.Advance(1000 * MSecsPerSec);
    AssertEquals('a zero refill rate adds no token', 0,
      TakeCount(Bucket, 1, 3));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestStickyTrip;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  Options := TTokenBucketOptions.Create
    .WithCapacity(1)
    .WithRefillPerSecond(1000);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    AssertTrue('the first take fits', Bucket.TryTake(1));
    AssertFalse('the second take trips the bucket', Bucket.TryTake(1));
    // the clock moves far enough to refill many tokens, but the trip stays
    FClock.Advance(10 * MSecsPerSec);
    AssertFalse('a tripped bucket stays empty', Bucket.TryTake(1));
    AssertFalse('a tripped bucket stays empty on a higher cost',
      Bucket.TryTake(1));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestRefillDoesNotRunBackwards;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
begin
  Options := TTokenBucketOptions.Create
    .WithCapacity(2)
    .WithRefillPerSecond(100);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    AssertEquals('the full bucket serves two', 2, TakeCount(Bucket, 1, 2));
    // a repeated clock value adds no token
    AssertFalse('a repeated clock value adds no token', Bucket.TryTake(1));
    // a lower clock value adds no token either
    FClock.SetNowMs(0);
    AssertFalse('a lower clock value adds no token', Bucket.TryTake(1));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestThousandCallsConsumeExactCapacity;
const
  // the capacity is large enough that a short burst cannot exhaust it, and
  // the exact take is proven by the final pair of answers
  cCapacity = 1000;
var
  Bucket: TTokenBucket;
  Options: TTokenBucketOptions;
  I: Integer;
  Served: Integer;
begin
  Options := TTokenBucketOptions.Create
    .WithCapacity(cCapacity)
    .WithRefillPerSecond(0);
  Bucket := TTokenBucket.Create(FClock, Options);
  try
    // one thousand takes at one clock value consume exactly the capacity
    Served := 0;
    for I := 1 to cCapacity do
      if Bucket.TryTake(1) then
        Inc(Served);
    AssertEquals('exactly the capacity is served', cCapacity, Served);
    AssertFalse('the bucket is empty after the capacity is consumed',
      Bucket.TryTake(1));
    AssertEquals('no token remains', 0, Round(Bucket.Tokens));
  finally
    Bucket.Free;
  end;
end;

procedure TTokenBucketTest.TestConnectionLimitsChargePerKind;
var
  Limits: TConnectionLimits;
  ResetOptions: TTokenBucketOptions;
  ControlOptions: TTokenBucketOptions;
begin
  ResetOptions := TTokenBucketOptions.Create
    .WithCapacity(10)
    .WithRefillPerSecond(0)
    .WithCostBeforeDispatch(1)
    .WithCostAfterDispatch(5);
  ControlOptions := TTokenBucketOptions.Create
    .WithCapacity(3)
    .WithRefillPerSecond(0);
  Limits := TConnectionLimits.Create(FClock, ResetOptions, ControlOptions);
  try
    // the control bucket of PING and the control bucket of SETTINGS are
    // separate: three PING charges do not affect SETTINGS
    AssertTrue('PING charge one', Limits.Charge(lkPing, 1));
    AssertTrue('PING charge two', Limits.Charge(lkPing, 1));
    AssertTrue('PING charge three', Limits.Charge(lkPing, 1));
    AssertTrue('SETTINGS still has its own tokens',
      Limits.Charge(lkSettings, 1));
    // a reset before dispatch costs one, after dispatch costs five
    AssertTrue('a reset before dispatch fits',
      Limits.ChargeReset(False));
    AssertTrue('a reset after dispatch fits',
      Limits.ChargeReset(True));
  finally
    Limits.Free;
  end;
end;

procedure TTokenBucketTest.TestControlBucketsAreIndependentPerKind;
var
  Limits: TConnectionLimits;
  ResetOptions: TTokenBucketOptions;
  Fallback: TTokenBucketOptions;
  Burst: TTokenBucketOptions;
  I: Integer;
begin
  ResetOptions := TTokenBucketOptions.Create
    .WithCapacity(10)
    .WithRefillPerSecond(0);
  // the fallback control bucket is small, as the default PING bucket is
  Fallback := TTokenBucketOptions.Create
    .WithCapacity(2)
    .WithRefillPerSecond(0);
  // the WINDOW_UPDATE bucket is large, as a large body needs many frames
  Burst := TTokenBucketOptions.Create
    .WithCapacity(50)
    .WithRefillPerSecond(0);
  Limits := TConnectionLimits.CreateByKind(FClock, ResetOptions, Fallback,
    [TControlBucketOption.Create(lkWindowUpdate, Burst)]);
  try
    // a large burst of WINDOW_UPDATE frames runs to its own capacity, with
    // no effect on the small PING bucket.  One shared bucket of the least
    // capacity would have tripped on the third frame and closed a healthy
    // connection that streamed a large body
    AssertEquals('the WINDOW_UPDATE bucket holds the named options',
      50, Limits.ControlOptionsOf(lkWindowUpdate).Capacity);
    AssertEquals('an unnamed kind keeps the fallback capacity',
      2, Limits.ControlOptionsOf(lkPing).Capacity);
    for I := 1 to 50 do
      AssertTrue('WINDOW_UPDATE charge ' + IntToStr(I),
        Limits.Charge(lkWindowUpdate, 1));
    AssertTrue('the small PING bucket is untouched',
      Limits.Charge(lkPing, 1));
    AssertTrue('the PING bucket still has its second token',
      Limits.Charge(lkPing, 1));
    AssertFalse('the PING bucket now trips on its own limit',
      Limits.Charge(lkPing, 1));
  finally
    Limits.Free;
  end;
end;

procedure TTokenBucketTest.TestObserverTripsOnceWithKind;
var
  Limits: TConnectionLimits;
  ResetOptions: TTokenBucketOptions;
  ControlOptions: TTokenBucketOptions;
begin
  ResetOptions := TTokenBucketOptions.Create
    .WithCapacity(10)
    .WithRefillPerSecond(0)
    .WithCostBeforeDispatch(1)
    .WithCostAfterDispatch(5);
  ControlOptions := TTokenBucketOptions.Create
    .WithCapacity(1)
    .WithRefillPerSecond(0);
  Limits := TConnectionLimits.Create(FClock, ResetOptions, ControlOptions);
  try
    Limits.OnTrip := HandleTrip;
    AssertTrue('the first CONTINUATION charge fits',
      Limits.Charge(lkContinuation, 1));
    AssertFalse('the second CONTINUATION charge trips',
      Limits.Charge(lkContinuation, 1));
    AssertEquals('the observer fired once', 1, FTrips);
    AssertEquals('the observer names CONTINUATION',
      Ord(lkContinuation), Ord(FLastTripKind));
    // every later charge is refused and raises no further event
    AssertFalse('a later charge is refused', Limits.Charge(lkPing, 1));
    AssertEquals('the observer did not fire again', 1, FTrips);
    AssertTrue('the set reports the trip', Limits.Tripped);
  finally
    Limits.Free;
  end;
end;

initialization
  RegisterTest(TTokenBucketTest);

end.
