{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream, buffers, cancellation, test, fpcunit
notes:
  - This unit tests the bounded stream buffers and the handler-side calls.
  - The blocked-read and blocked-write tests run the call on a real thread,
    because the contract says which thread observes a cancellation.
---
}
/// Unit tests for TServerStream
// - run with `make test`.
// - the large round trip uses a deterministic byte pattern that covers all
//   256 values, so a byte-order or truncation fault shows up.
// - the lock probe counts the acquire and release calls of the connection
//   lock, so a lock held across a wait is visible.
unit Http2Server.Stream.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Seam, Http2Server.Waiter,
  Http2Server.Stream, Http2Server.FlowControl, Http2Server.Hpack;

type
  /// the connection lock, with a count of the holds for the lock probe
  TCountingLock = class(TCriticalSection)
  public
    procedure Acquire; override;
    procedure Release; override;
  end;

  /// a stream host that records the credit the handler consumed
  TRecordingHost = class(TInterfacedObject, IStreamHost)
  private
    FUpdates: LongWord;
    FCalls: Integer;
  public
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    property Updates: LongWord read FUpdates;
    property Calls: Integer read FCalls;
  end;

  /// a thread that parks in a stream read and records the outcome
  TStreamReadProbe = class(TThread)
  private
    FStream: TObject;            // weak reference to TServerStream
    FGot: Integer;
    FError: string;
    FCancelled: Boolean;
    FStarted: Boolean;
    FLimit: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AStream: TObject; const ALimit: Integer = 128);
  end;

  /// a thread that parks in a stream write against a full buffer
  TStreamWriteProbe = class(TThread)
  private
    FStream: TObject;
    FError: string;
    FStarted: Boolean;
    FCount: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AStream: TObject; const ACount: Integer = 256);
  end;

  /// tests of TServerStream
  TServerStreamTest = class(TTestCase)
  private
    FLock: TCountingLock;
    FHost: TRecordingHost;
    FHostRef: IStreamHost;
    FStream: TServerStream;
    FReadProbe: TStreamReadProbe;
    FWriteProbe: TStreamWriteProbe;
    function MakePattern(const ACount: Integer): TBytes;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFreshState;
    procedure TestDeliverAndRead;
    procedure TestBodyEndReturnsZero;
    procedure TestReadChunkDrainsBuffer;
    procedure TestReadWaitsForDelivery;
    procedure TestCancelWakesBlockedRead;
    procedure TestReadAfterCancelRaises;
    procedure TestWriteBlocksWhenFullAndDrains;
    procedure TestCancelWakesBlockedWrite;
    procedure TestMegaByteRoundTrip;
    procedure TestAllByteValuesRoundTrip;
    procedure TestReadDeadlineRaisesTimeout;
    procedure TestLockIsNeverHeldAcrossWait;
    procedure TestReadEmitsWindowCredit;
    procedure TestInboundOverflowIsVisible;
    procedure TestRemoteHeadersRoundTrip;
    procedure TestPendingHeadersTake;
    procedure TestFinishFlagRoundTrip;
    procedure TestMarkRemoteEndedClosesRemoteSide;
  end;

implementation

function WaitForFlag(var AFlag: Boolean; const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (not AFlag) and (GetTickCount64 < Deadline) do
    Sleep(2);
  Result := AFlag;
end;

function WaitForThread(const AThread: TThread;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (not AThread.Finished) and (GetTickCount64 < Deadline) do
    Sleep(2);
  Result := AThread.Finished;
end;

{ TCountingLock }

procedure TCountingLock.Acquire;
begin
  inherited Acquire;
end;

procedure TCountingLock.Release;
begin
  inherited Release;
end;

{ TRecordingHost }

procedure TRecordingHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
  Inc(FCalls);
  Inc(FUpdates, AIncrement);
end;

{ TStreamReadProbe }

constructor TStreamReadProbe.Create(const AStream: TObject;
  const ALimit: Integer);
begin
  FStream := AStream;
  FLimit := ALimit;
  FStarted := False;
  inherited Create(False);
end;

procedure TStreamReadProbe.Execute;
var
  S: TServerStream;
  Buf: TBytes;
begin
  S := TServerStream(FStream);
  SetLength(Buf, FLimit);
  FStarted := True;
  try
    FGot := S.Read(Buf[0], FLimit);
  except
    on E: EStreamCancelled do
    begin
      FCancelled := True;
      FError := E.Message;
    end;
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

{ TStreamWriteProbe }

constructor TStreamWriteProbe.Create(const AStream: TObject;
  const ACount: Integer);
begin
  FStream := AStream;
  FCount := ACount;
  FStarted := False;
  inherited Create(False);
end;

procedure TStreamWriteProbe.Execute;
var
  S: TServerStream;
  Buf: TBytes;
begin
  S := TServerStream(FStream);
  SetLength(Buf, FCount);
  FillChar(Buf[0], FCount, 42);
  FStarted := True;
  try
    S.Write(Buf[0], FCount);
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

{ TServerStreamTest }

procedure TServerStreamTest.SetUp;
begin
  inherited SetUp;
  FLock := TCountingLock.Create;
  FHost := TRecordingHost.Create;
  // the host reference keeps the host alive across the fixture stream: the
  // stream holds the only other interface reference, so freeing the stream
  // would otherwise leave the class field pointing at a destroyed object
  FHostRef := FHost;
  FStream := TServerStream.Create(1, FLock, FHost, 65536, 65536);
  FReadProbe := nil;
  FWriteProbe := nil;
end;

procedure TServerStreamTest.TearDown;
begin
  if FReadProbe <> nil then
  begin
    FStream.Cancel(ecNoError);
    FReadProbe.WaitFor;
    FReadProbe.Free;
    FReadProbe := nil;
  end;
  if FWriteProbe <> nil then
  begin
    FStream.Cancel(ecNoError);
    FWriteProbe.WaitFor;
    FWriteProbe.Free;
    FWriteProbe := nil;
  end;
  FStream.Free;
  FHost := nil;
  FHostRef := nil;
  FLock.Free;
  inherited TearDown;
end;

function TServerStreamTest.MakePattern(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte(I and $FF);
end;

procedure TServerStreamTest.TestFreshState;
begin
  AssertEquals('the stream keeps its id', LongWord(1), FStream.StreamId);
  AssertEquals('a fresh stream is open', Ord(ssOpen), Ord(FStream.State));
  AssertEquals('the inbound limit is the configured one', 65536,
    FStream.InboundLimit);
  AssertEquals('the outbound limit is the configured one', 65536,
    FStream.OutboundLimit);
  AssertFalse('a fresh stream is not cancelled', FStream.IsCancelled);
  AssertFalse('a fresh stream holds no inbound bytes',
    FStream.BodyIsComplete);
end;

procedure TServerStreamTest.TestDeliverAndRead;
var
  Data, Buf: TBytes;
  N: Integer;
begin
  Data := MakePattern(10);
  FStream.DeliverData(Data, False);
  AssertEquals('the buffer holds the bytes', 10, FStream.InboundCount);
  SetLength(Buf, 4);
  N := FStream.Read(Buf[0], 4);
  AssertEquals('the read answers four bytes', 4, N);
  AssertEquals('the bytes arrive in order', 3, Buf[3]);
  AssertEquals('six bytes stay buffered', 6, FStream.InboundCount);
  SetLength(Buf, 16);
  N := FStream.Read(Buf[0], 16);
  AssertEquals('the next read drains the rest', 6, N);
  AssertEquals('the buffer is empty', 0, FStream.InboundCount);
end;

procedure TServerStreamTest.TestBodyEndReturnsZero;
var
  Buf: TBytes;
begin
  FStream.DeliverData(nil, True);
  AssertTrue('the body is complete', FStream.BodyIsComplete);
  SetLength(Buf, 8);
  AssertEquals('a read of a complete body answers zero',
    0, FStream.Read(Buf[0], 8));
end;

procedure TServerStreamTest.TestReadChunkDrainsBuffer;
var
  Data, Chunk: TBytes;
begin
  Data := MakePattern(20);
  FStream.DeliverData(Data, False);
  AssertTrue('a chunk is available', FStream.ReadChunk(Chunk));
  AssertEquals('the chunk holds every buffered byte', 20, Length(Chunk));
  AssertEquals('the chunk starts at the first byte', 0, Chunk[0]);
  AssertEquals('the buffer is empty', 0, FStream.InboundCount);
  FStream.DeliverData(nil, True);
  // a drained buffer over a complete body answers False without a reset
  AssertFalse('a chunk after the body end answers False',
    FStream.ReadChunk(Chunk));
end;

procedure TServerStreamTest.TestReadWaitsForDelivery;
var
  Data: TBytes;
begin
  FReadProbe := TStreamReadProbe.Create(FStream);
  AssertTrue('the probe started', WaitForFlag(FReadProbe.FStarted, 2000));
  AssertFalse('the read is parked on an empty buffer',
    WaitForThread(FReadProbe, 40));
  Data := MakePattern(5);
  FStream.DeliverData(Data, False);
  AssertTrue('the delivery released the read',
    WaitForThread(FReadProbe, 2000));
  AssertEquals('the parked read got the bytes', 5, FReadProbe.FGot);
  AssertEquals('no error was raised', '', FReadProbe.FError);
end;

procedure TServerStreamTest.TestCancelWakesBlockedRead;
begin
  FReadProbe := TStreamReadProbe.Create(FStream);
  AssertTrue('the probe started', WaitForFlag(FReadProbe.FStarted, 2000));
  AssertFalse('the read is parked', WaitForThread(FReadProbe, 40));
  FStream.Cancel(ecCancel);
  AssertTrue('the cancellation released the read',
    WaitForThread(FReadProbe, 2000));
  AssertTrue('the read raised EStreamCancelled', FReadProbe.FCancelled);
  AssertEquals('the reset code is CANCEL', Ord(ecCancel),
    Ord(FStream.ResetCode));
end;

procedure TServerStreamTest.TestReadAfterCancelRaises;
var
  Buf: TBytes;
  Raised: Boolean;
begin
  FStream.Cancel(ecCancel);
  SetLength(Buf, 8);
  Raised := False;
  try
    FStream.Read(Buf[0], 8);
  except
    on E: EStreamCancelled do
      Raised := True;
  end;
  AssertTrue('a read after a cancellation raises', Raised);
  AssertTrue('the stream reports the cancellation', FStream.IsCancelled);
end;

procedure TServerStreamTest.TestWriteBlocksWhenFullAndDrains;
var
  Data, Out1: TBytes;
begin
  // a smaller outbound limit than the fixture one makes the buffer fill with
  // one write; the fixture stream is freed before the replacement is built
  FStream.Free;
  FStream := TServerStream.Create(1, FLock, FHost, 65536, 256);
  SetLength(Data, 256);
  FStream.Write(Data[0], 256);
  AssertEquals('the buffer is full', 256, FStream.OutboundCount);
  FWriteProbe := TStreamWriteProbe.Create(FStream);
  AssertTrue('the write probe started', WaitForFlag(FWriteProbe.FStarted, 2000));
  AssertFalse('the full buffer parks the write',
    WaitForThread(FWriteProbe, 40));
  AssertTrue('a drain answers bytes', FStream.TakeOutbound(Out1, 256));
  AssertEquals('the drained block holds 256 bytes', 256, Length(Out1));
  AssertTrue('the drain released the write',
    WaitForThread(FWriteProbe, 2000));
  AssertEquals('no error was raised', '', FWriteProbe.FError);
  AssertEquals('the second block is buffered', 256, FStream.OutboundCount);
end;

procedure TServerStreamTest.TestCancelWakesBlockedWrite;
var
  Data: TBytes;
begin
  FStream.Free;
  FStream := TServerStream.Create(1, FLock, FHost, 65536, 64);
  SetLength(Data, 64);
  FStream.Write(Data[0], 64);
  FWriteProbe := TStreamWriteProbe.Create(FStream);
  AssertTrue('the write probe started', WaitForFlag(FWriteProbe.FStarted, 2000));
  AssertFalse('the full buffer parks the write',
    WaitForThread(FWriteProbe, 40));
  FStream.Cancel(ecCancel);
  AssertTrue('the cancellation released the write',
    WaitForThread(FWriteProbe, 2000));
  AssertTrue('the write reports the cancellation',
    Pos('EStreamCancelled', FWriteProbe.FError) = 1);
end;

procedure TServerStreamTest.TestMegaByteRoundTrip;
const
  cTotal = 1024 * 1024;
var
  Data, Buf: TBytes;
  Total, N, Bad: Integer;
begin
  Data := MakePattern(cTotal);
  FStream.DeliverData(Data, True);
  SetLength(Buf, cTotal);
  Total := 0;
  while Total < cTotal do
  begin
    N := FStream.Read(Buf[Total], cTotal - Total);
    if N = 0 then
      Break;
    Inc(Total, N);
  end;
  AssertEquals('the whole megabyte arrived', cTotal, Total);
  Bad := -1;
  for N := 0 to cTotal - 1 do
    if Buf[N] <> Byte(N and $FF) then
    begin
      Bad := N;
      Break;
    end;
  AssertEquals('every byte round trips unchanged', -1, Bad);
  AssertEquals('the body is complete', 0, FStream.InboundCount);
end;

procedure TServerStreamTest.TestAllByteValuesRoundTrip;
var
  Data, Buf: TBytes;
  I, Bad: Integer;
begin
  SetLength(Data, 256);
  for I := 0 to 255 do
    Data[I] := Byte(I);
  FStream.DeliverData(Data, True);
  SetLength(Buf, 256);
  AssertEquals('the read answers every byte', 256, FStream.Read(Buf[0], 256));
  Bad := -1;
  for I := 0 to 255 do
    if Buf[I] <> Byte(I) then
    begin
      Bad := I;
      Break;
    end;
  AssertEquals('all 256 values round trip unchanged', -1, Bad);
end;

procedure TServerStreamTest.TestReadDeadlineRaisesTimeout;
var
  Buf: TBytes;
  Raised: Boolean;
begin
  FStream.ReadTimeoutMs := 60;
  SetLength(Buf, 8);
  Raised := False;
  try
    FStream.Read(Buf[0], 8);
  except
    on E: EHttpTimeout do
      Raised := True;
  end;
  AssertTrue('an empty body past the deadline raises a timeout', Raised);
end;

procedure TServerStreamTest.TestLockIsNeverHeldAcrossWait;
begin
  FReadProbe := TStreamReadProbe.Create(FStream);
  AssertTrue('the probe started', WaitForFlag(FReadProbe.FStarted, 2000));
  AssertFalse('the read is parked', WaitForThread(FReadProbe, 60));
  // the parked read must not hold the per-stream lock: another thread can
  // take it, and the deepest hold the stream ever counted stays at one
  AssertTrue('the lock is free while a read is parked', FLock.TryEnter);
  FLock.Leave;
  AssertEquals('the stream never held a lock across a wait', 1,
    FStream.MaxLockDepth);
  FStream.DeliverData(MakePattern(4), True);
  AssertTrue('the delivery released the read',
    WaitForThread(FReadProbe, 2000));
  AssertEquals('the parked read got the bytes', 4, FReadProbe.FGot);
end;

procedure TServerStreamTest.TestReadEmitsWindowCredit;
var
  Data, Buf: TBytes;
begin
  Data := MakePattern(100);
  FStream.DeliverData(Data, False);
  SetLength(Buf, 100);
  FStream.Read(Buf[0], 100);
  AssertEquals('the host learned of one credit update', 1, FHost.Calls);
  AssertEquals('the credit equals the bytes read', 100, FHost.Updates);
  AssertEquals('the stream remembers the consumed amount', 100,
    FStream.ConsumedSinceUpdate);
  FStream.ClearConsumed;
  AssertEquals('the consumed amount can be cleared', 0,
    FStream.ConsumedSinceUpdate);
end;

procedure TServerStreamTest.TestInboundOverflowIsVisible;
var
  Data: TBytes;
begin
  FStream.Free;
  FStream := TServerStream.Create(1, FLock, FHost, 32, 65536);
  AssertTrue('a delivery past the limit is visible',
    FStream.InboundWouldOverflow(33));
  AssertFalse('a delivery at the limit fits',
    FStream.InboundWouldOverflow(32));
  Data := MakePattern(32);
  FStream.DeliverData(Data, False);
  AssertTrue('a delivery onto a full buffer is visible',
    FStream.InboundWouldOverflow(1));
end;

procedure TServerStreamTest.TestRemoteHeadersRoundTrip;
var
  H: THeaderBlock;
begin
  AssertEquals('a fresh stream holds no request headers',
    0, Length(FStream.RemoteHeaders));
  SetLength(H, 2);
  H[0].Name := ':method';
  H[0].Value := 'GET';
  H[1].Name := ':path';
  H[1].Value := '/index';
  FStream.SetRemoteHeaders(H);
  H := FStream.RemoteHeaders;
  AssertEquals('the request block holds two fields', 2, Length(H));
  AssertEquals('the first field name survives', ':method', H[0].Name);
  AssertEquals('the second field value survives', '/index', H[1].Value);
end;

procedure TServerStreamTest.TestPendingHeadersTake;
var
  H, Got: THeaderBlock;
  Status: Integer;
  EndStream: Boolean;
begin
  AssertFalse('a fresh stream holds no response headers',
    FStream.HasPendingHeaders);
  SetLength(H, 1);
  H[0].Name := ':status';
  H[0].Value := '200';
  FStream.QueueResponseHeaders(200, H, False);
  AssertTrue('the response block is pending', FStream.HasPendingHeaders);
  AssertTrue('the block is taken once',
    FStream.TakePendingHeaders(Status, Got, EndStream));
  AssertEquals('the status survives', 200, Status);
  AssertEquals('the block holds one field', 1, Length(Got));
  AssertEquals('the field name survives', ':status', Got[0].Name);
  AssertFalse('the block did not ask for the body end', EndStream);
  AssertFalse('nothing is pending after the take',
    FStream.HasPendingHeaders);
end;

procedure TServerStreamTest.TestFinishFlagRoundTrip;
begin
  AssertFalse('a fresh stream does not ask for the end',
    FStream.WantsFinish);
  FStream.RequestFinish;
  AssertTrue('the end request is recorded', FStream.WantsFinish);
  FStream.ClearFinish;
  AssertFalse('the end request can be cleared', FStream.WantsFinish);
end;

procedure TServerStreamTest.TestMarkRemoteEndedClosesRemoteSide;
begin
  AssertEquals('a fresh stream is open', Ord(ssOpen), Ord(FStream.State));
  FStream.MarkRemoteEnded;
  AssertEquals('the remote half is closed', Ord(ssHalfClosedRemote),
    Ord(FStream.State));
  AssertTrue('the body is complete', FStream.BodyIsComplete);
  FStream.MarkLocalEnded;
  AssertEquals('both halves closed the stream', Ord(ssClosed),
    Ord(FStream.State));
end;

initialization
  RegisterTest(TServerStreamTest);

end.
