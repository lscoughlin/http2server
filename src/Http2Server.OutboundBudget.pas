{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, output, budget, frames, denial of service
notes:
  - This unit counts the outbound frames that wait for the peer.
  - The count falls as the frames leave the socket, as in Envoy.
  - The unit holds no socket and no lock. The caller holds the
    connection lock for every call.
---
}
/// The outbound frame budget of one connection
// - the budget counts the frames that the core queued and the peer has not
//   received yet. A reader that drains steadily keeps the count low whatever
//   the total over the life of the connection.
// - the count of a batch leaves the budget once the octets of the batch left
//   the socket, so a slow peer and not a large response trips the caps.
// - a limit of 0 turns that cap off.
unit Http2Server.OutboundBudget;

{$mode delphi}{$H+}

interface

uses
  Http2Server.Frames;

type
  /// counts the queued outbound frames of one connection
  TOutboundBudget = class
  private
    FMaxFrames: LongWord;
    FMaxControlFrames: LongWord;
    /// the frames of the open batch, not yet handed to the IO side
    FOpenTotal: Integer;
    FOpenControl: Integer;
    /// the frames that wait for the peer: the open batch and the batches
    /// that the IO side holds
    FPendingTotal: Integer;
    FPendingControl: Integer;
    /// the octets the core handed to the IO side so far
    FHandedOut: Int64;
    /// one entry per closed batch: the octet offset at which it ends
    FBatchEnd: TArray<Int64>;
    FBatchTotal: TArray<Integer>;
    FBatchControl: TArray<Integer>;
    /// the first batch that the peer has not received yet
    FReleased: Integer;
    function IsControlFrame(const AFrameType: TFrameType): Boolean;
  public
    /// build a budget with the two caps; 0 turns a cap off
    constructor Create(const AMaxFrames,
      AMaxControlFrames: LongWord);
    /// count one frame of the open batch
    procedure CountFrame(const AFrameType: TFrameType);
    /// close the open batch of AOctets octets and hand it to the IO side
    procedure CloseBatch(const AOctets: Int64);
    /// release every closed batch whose end offset is at or below the
    /// total of written octets
    procedure ReportWritten(const AWrittenTotal: Int64);
    /// forget every count, batch and total; the caps stay
    procedure Reset;
    /// true when the pending frames pass the frame cap
    function FrameCapPassed: Boolean;
    /// true when the pending control frames pass the control cap
    function ControlCapPassed: Boolean;
    /// true when either cap passed
    function Exceeded: Boolean;
    /// the frames that wait for the peer now
    property PendingFrames: Integer read FPendingTotal;
    /// the PING, SETTINGS and RST_STREAM frames that wait now
    property PendingControlFrames: Integer read FPendingControl;
    /// the octets the core handed to the IO side so far
    property HandedOut: Int64 read FHandedOut;
    /// the greatest number of frames that may wait; 0 is off
    property MaxOutboundFrames: LongWord read FMaxFrames;
    /// the greatest number of control frames that may wait; 0 is off
    property MaxOutboundControlFrames: LongWord read FMaxControlFrames;
  end;

implementation

{ TOutboundBudget }

constructor TOutboundBudget.Create(const AMaxFrames,
  AMaxControlFrames: LongWord);
begin
  inherited Create;
  FMaxFrames := AMaxFrames;
  FMaxControlFrames := AMaxControlFrames;
end;

function TOutboundBudget.IsControlFrame(
  const AFrameType: TFrameType): Boolean;
begin
  // RFC 9113 section 10.5 names the answers a peer can force without a
  // bound: a PING answer, a SETTINGS acknowledgment and an RST_STREAM
  Result := AFrameType in [ftPing, ftSettings, ftRstStream];
end;

procedure TOutboundBudget.CountFrame(const AFrameType: TFrameType);
begin
  Inc(FOpenTotal);
  Inc(FPendingTotal);
  if IsControlFrame(AFrameType) then
  begin
    Inc(FOpenControl);
    Inc(FPendingControl);
  end;
end;

procedure TOutboundBudget.CloseBatch(const AOctets: Int64);
var
  At: Integer;
begin
  // the frames stay pending: they wait in the write path of the IO side
  At := Length(FBatchEnd);
  SetLength(FBatchEnd, At + 1);
  SetLength(FBatchTotal, At + 1);
  SetLength(FBatchControl, At + 1);
  Inc(FHandedOut, AOctets);
  FBatchEnd[At] := FHandedOut;
  FBatchTotal[At] := FOpenTotal;
  FBatchControl[At] := FOpenControl;
  FOpenTotal := 0;
  FOpenControl := 0;
end;

procedure TOutboundBudget.ReportWritten(const AWrittenTotal: Int64);
var
  Written: Int64;
begin
  Written := AWrittenTotal;
  if Written < 0 then
    Exit;
  if Written > FHandedOut then
    Written := FHandedOut;
  while (FReleased < Length(FBatchEnd)) and
        (FBatchEnd[FReleased] <= Written) do
  begin
    Dec(FPendingTotal, FBatchTotal[FReleased]);
    Dec(FPendingControl, FBatchControl[FReleased]);
    Inc(FReleased);
  end;
  // a long connection closes many batches, so the released prefix leaves
  // once in a while and the arrays stay short
  if FReleased >= 256 then
  begin
    Delete(FBatchEnd, 0, FReleased);
    Delete(FBatchTotal, 0, FReleased);
    Delete(FBatchControl, 0, FReleased);
    FReleased := 0;
  end;
end;

procedure TOutboundBudget.Reset;
begin
  FOpenTotal := 0;
  FOpenControl := 0;
  FPendingTotal := 0;
  FPendingControl := 0;
  FHandedOut := 0;
  FBatchEnd := nil;
  FBatchTotal := nil;
  FBatchControl := nil;
  FReleased := 0;
end;

function TOutboundBudget.FrameCapPassed: Boolean;
begin
  Result := (FMaxFrames > 0) and (FPendingTotal > Integer(FMaxFrames));
end;

function TOutboundBudget.ControlCapPassed: Boolean;
begin
  Result := (FMaxControlFrames > 0) and
    (FPendingControl > Integer(FMaxControlFrames));
end;

function TOutboundBudget.Exceeded: Boolean;
begin
  Result := FrameCapPassed or ControlCapPassed;
end;

end.
