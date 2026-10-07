{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, limits, tokenbucket, rapid-reset
notes:
  - This unit holds the per-connection abuse limits of the HTTP/2 server.
  - A token bucket counts a client action that a peer can repeat at a high
    rate, such as a reset or a control frame.
  - The bucket has no lock; the caller holds the connection lock.
  - No numeric limit is in this unit; every limit comes from the options.
---
}
/// Per-connection abuse limits for the HTTP/2 server
// - the connection core charges a token for each client action of a limited
//   kind.  When a bucket is empty, the caller sends GOAWAY with
//   ENHANCE_YOUR_CALM and closes the connection after the open streams drain.
// - the token bucket refills from an injected IMonotonicClock, so a test
//   supplies a manual clock and a long idle wait costs no wall-clock time.
// - a token bucket has no lock.  The caller holds the connection lock, and
//   every call of one bucket runs on one thread at a time.
// - the trip state is sticky.  The first empty-bucket answer closes the
//   connection, so every later answer is also "no".
unit Http2Server.Limits;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils;

type
  /// a clock that only moves forward, in milliseconds
  ///
  /// The real implementation reads GetTickCount64.  A test injects
  /// TManualMonotonicClock instead.
  IMonotonicClock = interface
    ['{A1B2C3D4-0004-4A61-9C72-000000000004}']
    /// the number of milliseconds since an unspecified start point
    function NowMs: QWord;
  end;

  /// the process clock, backed by GetTickCount64
  TMonotonicClock = class(TInterfacedObject, IMonotonicClock)
  public
    function NowMs: QWord;
  end;

  /// a clock for tests.  The value moves only when Advance moves it, so a
  /// test controls every refill and needs no real wait.
  TManualMonotonicClock = class(TInterfacedObject, IMonotonicClock)
  private
    FNowMs: QWord;
  public
    constructor Create(const AStartMs: QWord = 0);
    /// move the clock forward by ADeltaMs milliseconds
    procedure Advance(const ADeltaMs: QWord);
    /// set the clock to an exact value
    procedure SetNowMs(const AValue: QWord);
    function NowMs: QWord;
  end;

  /// the fluent options of one token bucket
  ///
  /// Create returns a zeroed record.  The caller sets every field with a
  /// WithX method.  The reset bucket uses CostBeforeDispatch and
  /// CostAfterDispatch; every other bucket takes its cost from the caller.
  TTokenBucketOptions = record
  private
    FCapacity: Integer;
    FRefillPerSecond: Double;
    FCostBeforeDispatch: Integer;
    FCostAfterDispatch: Integer;
  public
    /// a zeroed record.  The caller sets every field.
    class function Create: TTokenBucketOptions; static;
    /// the greatest number of tokens the bucket holds
    function WithCapacity(const AValue: Integer): TTokenBucketOptions;
    /// the tokens added each second, possibly fractional
    function WithRefillPerSecond(const AValue: Double): TTokenBucketOptions;
    /// the token cost of a reset before the stream reaches a handler
    function WithCostBeforeDispatch(const AValue: Integer): TTokenBucketOptions;
    /// the token cost of a reset after the stream reaches a handler
    function WithCostAfterDispatch(const AValue: Integer): TTokenBucketOptions;
    property Capacity: Integer read FCapacity;
    property RefillPerSecond: Double read FRefillPerSecond;
    property CostBeforeDispatch: Integer read FCostBeforeDispatch;
    property CostAfterDispatch: Integer read FCostAfterDispatch;
  end;

  /// a token bucket with an injected clock and no lock
  ///
  /// The bucket starts full.  TryTake refills from the clock, then takes
  /// ACost tokens when the bucket holds enough.  The first call that the
  /// bucket cannot serve trips the bucket, and every later call returns
  /// False.  The caller holds the connection lock.
  TTokenBucket = class
  private
    FClock: IMonotonicClock;
    FCapacity: Integer;
    FRefillPerSecond: Double;
    FTokens: Double;
    FLastMs: QWord;
    FTripped: Boolean;
    procedure Refill;
  public
    constructor Create(const AClock: IMonotonicClock;
      const AOptions: TTokenBucketOptions);
    /// take ACost tokens.  False means the bucket is empty and the
    /// connection is closing.
    function TryTake(const ACost: Integer): Boolean;
    /// the tokens held now, before any refill
    property Tokens: Double read FTokens;
    /// True after the first empty-bucket answer
    property Tripped: Boolean read FTripped;
  end;

  /// the kind of client action that a bucket limits
  TLimitKind = (lkReset, lkPing, lkSettings, lkEmptyData,
    lkWindowUpdate, lkContinuation);

  /// the trip notification of one bucket
  TBucketTripEvent = procedure(const AKind: TLimitKind) of object;

  /// the limit set of one connection
  ///
  /// The set holds the reset bucket and one bucket per control frame kind.
  /// Charge sends a cost to one bucket.  The first empty-bucket answer trips
  /// the whole set, so every later Charge returns False while the connection
  /// closes.  The observer of the server receives OnTrip once, with the kind
  /// that tripped.
  TConnectionLimits = class
  private
    FResetOptions: TTokenBucketOptions;
    FControlOptions: TTokenBucketOptions;
    FBuckets: array[TLimitKind] of TTokenBucket;
    FTripped: Boolean;
    FOnTrip: TBucketTripEvent;
  public
    constructor Create(const AClock: IMonotonicClock;
      const AResetOptions: TTokenBucketOptions;
      const AControlOptions: TTokenBucketOptions);
    destructor Destroy; override;
    /// take ACost tokens from the bucket of AKind.  False means the
    /// connection is closing.
    function Charge(const AKind: TLimitKind; const ACost: Integer): Boolean;
    /// take the reset cost that matches the dispatch state.  A reset after
    /// dispatch costs more than a reset before it.
    function ChargeReset(const AAfterDispatch: Boolean): Boolean;
    /// True after the first empty-bucket answer of any kind
    property Tripped: Boolean read FTripped;
    /// the event raised once when a bucket trips
    property OnTrip: TBucketTripEvent read FOnTrip write FOnTrip;
    property ResetOptions: TTokenBucketOptions read FResetOptions;
    property ControlOptions: TTokenBucketOptions read FControlOptions;
  end;

implementation

{ TMonotonicClock }

function TMonotonicClock.NowMs: QWord;
begin
  Result := GetTickCount64;
end;

{ TManualMonotonicClock }

constructor TManualMonotonicClock.Create(const AStartMs: QWord);
begin
  inherited Create;
  FNowMs := AStartMs;
end;

procedure TManualMonotonicClock.Advance(const ADeltaMs: QWord);
begin
  FNowMs := FNowMs + ADeltaMs;
end;

procedure TManualMonotonicClock.SetNowMs(const AValue: QWord);
begin
  FNowMs := AValue;
end;

function TManualMonotonicClock.NowMs: QWord;
begin
  Result := FNowMs;
end;

{ TTokenBucketOptions }

class function TTokenBucketOptions.Create: TTokenBucketOptions;
begin
  Result.FCapacity := 0;
  Result.FRefillPerSecond := 0;
  Result.FCostBeforeDispatch := 0;
  Result.FCostAfterDispatch := 0;
end;

function TTokenBucketOptions.WithCapacity(
  const AValue: Integer): TTokenBucketOptions;
begin
  Result := Self;
  Result.FCapacity := AValue;
end;

function TTokenBucketOptions.WithRefillPerSecond(
  const AValue: Double): TTokenBucketOptions;
begin
  Result := Self;
  Result.FRefillPerSecond := AValue;
end;

function TTokenBucketOptions.WithCostBeforeDispatch(
  const AValue: Integer): TTokenBucketOptions;
begin
  Result := Self;
  Result.FCostBeforeDispatch := AValue;
end;

function TTokenBucketOptions.WithCostAfterDispatch(
  const AValue: Integer): TTokenBucketOptions;
begin
  Result := Self;
  Result.FCostAfterDispatch := AValue;
end;

{ TTokenBucket }

constructor TTokenBucket.Create(const AClock: IMonotonicClock;
  const AOptions: TTokenBucketOptions);
begin
  inherited Create;
  FClock := AClock;
  FCapacity := AOptions.Capacity;
  FRefillPerSecond := AOptions.RefillPerSecond;
  FTokens := AOptions.Capacity;
  FLastMs := AClock.NowMs;
  FTripped := False;
end;

procedure TTokenBucket.Refill;
var
  Now: QWord;
  ElapsedMs: QWord;
  Added: Double;
begin
  Now := FClock.NowMs;
  // a repeated or backward clock value adds no token, so time never runs
  // backwards
  if Now <= FLastMs then
    Exit;
  ElapsedMs := Now - FLastMs;
  FLastMs := Now;
  if FRefillPerSecond <= 0 then
    Exit;
  Added := FRefillPerSecond * ElapsedMs / MSecsPerSec;
  FTokens := FTokens + Added;
  // the bucket never holds more than its capacity, however long the idle
  // time is
  if FTokens > FCapacity then
    FTokens := FCapacity;
end;

function TTokenBucket.TryTake(const ACost: Integer): Boolean;
begin
  if FTripped then
    Exit(False);
  Refill;
  if FTokens >= ACost then
  begin
    FTokens := FTokens - ACost;
    Result := True;
  end
  else
  begin
    FTripped := True;
    Result := False;
  end;
end;

{ TConnectionLimits }

constructor TConnectionLimits.Create(const AClock: IMonotonicClock;
  const AResetOptions: TTokenBucketOptions;
  const AControlOptions: TTokenBucketOptions);
var
  Kind: TLimitKind;
begin
  inherited Create;
  FResetOptions := AResetOptions;
  FControlOptions := AControlOptions;
  for Kind := Low(TLimitKind) to High(TLimitKind) do
    if Kind = lkReset then
      FBuckets[Kind] := TTokenBucket.Create(AClock, AResetOptions)
    else
      FBuckets[Kind] := TTokenBucket.Create(AClock, AControlOptions);
end;

destructor TConnectionLimits.Destroy;
var
  Kind: TLimitKind;
begin
  for Kind := Low(TLimitKind) to High(TLimitKind) do
    FBuckets[Kind].Free;
  inherited Destroy;
end;

function TConnectionLimits.Charge(const AKind: TLimitKind;
  const ACost: Integer): Boolean;
begin
  if FTripped then
    Exit(False);
  Result := FBuckets[AKind].TryTake(ACost);
  if not Result then
  begin
    FTripped := True;
    if Assigned(FOnTrip) then
      FOnTrip(AKind);
  end;
end;

function TConnectionLimits.ChargeReset(const AAfterDispatch: Boolean): Boolean;
begin
  if AAfterDispatch then
    Result := Charge(lkReset, FResetOptions.CostAfterDispatch)
  else
    Result := Charge(lkReset, FResetOptions.CostBeforeDispatch);
end;

end.
