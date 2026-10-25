{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, stream, reset, closed state, bounded set
notes:
  - This unit holds a small bounded set of stream ids. The connection core uses
    it for the streams that the server reset.
  - RFC 9113 section 5.1 lets an endpoint ignore the frames that arrive on a
    stream after it sent RST_STREAM, for a limited period. The size of the set
    is that period, and the oldest id leaves when the set is full.
---
}
/// A bounded set of recently reset stream ids
unit Http2Server.StreamIdSet;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// a ring of stream ids; the oldest id leaves when the ring is full
  // - Add and Contains cost at most Capacity comparisons, and the memory is
  //   fixed, so a peer cannot grow the set
  TStreamIdSet = class
  private
    FIds: array of LongWord;
    FHead: Integer;
    FCount: Integer;
  public
    constructor Create(const ACapacity: Integer);
    procedure Add(const AStreamId: LongWord);
    function Contains(const AStreamId: LongWord): Boolean;
    property Count: Integer read FCount;
  end;

implementation

constructor TStreamIdSet.Create(const ACapacity: Integer);
begin
  inherited Create;
  SetLength(FIds, ACapacity);
end;

procedure TStreamIdSet.Add(const AStreamId: LongWord);
begin
  if Length(FIds) = 0 then
    Exit;
  if Contains(AStreamId) then
    Exit;
  FIds[FHead] := AStreamId;
  FHead := (FHead + 1) mod Length(FIds);
  if FCount < Length(FIds) then
    Inc(FCount);
end;

function TStreamIdSet.Contains(const AStreamId: LongWord): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FCount - 1 do
    if FIds[I] = AStreamId then
      Exit(True);
end;

end.
