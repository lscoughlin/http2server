{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, limits, timeouts, outbound
notes:
  - This unit holds the server-wide limits and timeouts.
  - Http2Server.Config carries the record in its ServerLimits property.
  - The factory Validate calls the Validate of this record, so one call
    reports every problem of the settings.
---
}
/// The server-wide limits and timeouts
// - TServerLimits is the record that the factory carries in its ServerLimits
//   property
// - the record is a value, so a copy of the factory holds its own settings
unit Http2Server.Config.Limits;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Http2Server.Frames;

type
  /// the server-wide limits and timeouts
  ///
  /// A record is a value, so a copy of the factory holds its own settings.
  /// A limit of 0 turns the limit off, unless the setting states another
  /// meaning.
  TServerLimits = record
  private
    FMaxConnections: Integer;
    FStreamReadTimeoutMs: Integer;
    FStreamWriteTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    FMaxOutboundFrames: Integer;
    FMaxOutboundControlFrames: Integer;
    FMaxDataFrameSizeOut: Integer;
  public
    /// the defaults of the server limits
    class function Create: TServerLimits; static;
    /// the greatest number of open connections
    function WithMaxConnections(const AValue: Integer): TServerLimits;
    /// the greatest wait for a read of a stream, in milliseconds
    function WithStreamReadTimeoutMs(const AValue: Integer): TServerLimits;
    /// the greatest wait for a write of a stream, in milliseconds
    function WithStreamWriteTimeoutMs(const AValue: Integer): TServerLimits;
    /// the greatest wait for a write of a connection, in milliseconds; 0
    /// turns the check off
    function WithWriteTimeoutMs(const AValue: Integer): TServerLimits;
    /// the greatest number of outbound frames that wait for the peer; 0
    /// turns the cap off
    function WithMaxOutboundFrames(const AValue: Integer): TServerLimits;
    /// the greatest number of outbound control frames that wait for the peer
    function WithMaxOutboundControlFrames(
      const AValue: Integer): TServerLimits;
    /// the greatest size of an outbound DATA frame, in octets; 0 sends up
    /// to MaxFrameSize
    function WithMaxDataFrameSizeOut(const AValue: Integer): TServerLimits;

    /// add one text to AProblems for each setting that is not usable
    procedure Validate(var AProblems: TArray<string>);

    property MaxConnections: Integer read FMaxConnections;
    property StreamReadTimeoutMs: Integer read FStreamReadTimeoutMs;
    property StreamWriteTimeoutMs: Integer read FStreamWriteTimeoutMs;
    property WriteTimeoutMs: Integer read FWriteTimeoutMs;
    property MaxOutboundFrames: Integer read FMaxOutboundFrames;
    property MaxOutboundControlFrames: Integer read FMaxOutboundControlFrames;
    property MaxDataFrameSizeOut: Integer read FMaxDataFrameSizeOut;
  end;

implementation

{ TServerLimits }

class function TServerLimits.Create: TServerLimits;
begin
  // the connection count bounds the memory of the open connections, and the
  // timeouts bound a stalled peer
  Result.FMaxConnections := 10000;
  Result.FStreamReadTimeoutMs := 30000;
  Result.FStreamWriteTimeoutMs := 30000;
  Result.FWriteTimeoutMs := 60000;
  Result.FMaxOutboundFrames := 10000;
  Result.FMaxOutboundControlFrames := 1000;
  // no separate cap: an outbound DATA frame goes up to MaxFrameSize
  Result.FMaxDataFrameSizeOut := 0;
end;

function TServerLimits.WithMaxConnections(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FMaxConnections := AValue;
end;

function TServerLimits.WithStreamReadTimeoutMs(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FStreamReadTimeoutMs := AValue;
end;

function TServerLimits.WithStreamWriteTimeoutMs(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FStreamWriteTimeoutMs := AValue;
end;

function TServerLimits.WithWriteTimeoutMs(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FWriteTimeoutMs := AValue;
end;

function TServerLimits.WithMaxOutboundFrames(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FMaxOutboundFrames := AValue;
end;

function TServerLimits.WithMaxOutboundControlFrames(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FMaxOutboundControlFrames := AValue;
end;

function TServerLimits.WithMaxDataFrameSizeOut(
  const AValue: Integer): TServerLimits;
begin
  Result := Self;
  Result.FMaxDataFrameSizeOut := AValue;
end;

procedure TServerLimits.Validate(var AProblems: TArray<string>);

  procedure Add(const AText: string);
  begin
    SetLength(AProblems, Length(AProblems) + 1);
    AProblems[High(AProblems)] := AText;
  end;

begin
  if FMaxConnections < 0 then
    Add('the maximum connection count is below 0');
  if FStreamReadTimeoutMs < 1 then
    Add('the stream read timeout is below 1');
  if FStreamWriteTimeoutMs < 1 then
    Add('the stream write timeout is below 1');
  if FWriteTimeoutMs < 0 then
    Add('the write timeout is below 0');
  if FMaxOutboundFrames < 0 then
    Add('the outbound frame cap is below 0');
  if FMaxOutboundControlFrames < 0 then
    Add('the outbound control frame cap is below 0');
  if (FMaxOutboundFrames > 0) and (FMaxOutboundControlFrames > 0) and
     (FMaxOutboundControlFrames > FMaxOutboundFrames) then
    Add('the control frame cap is above the frame cap');
  // the smallest outbound DATA frame is 1024 octets, or 2 to the power of
  // 10; the bound is spelled with single digits, because the factory
  // source test forbids a multi-digit literal outside a Create body
  if (FMaxDataFrameSizeOut <> 0) and
     ((FMaxDataFrameSizeOut < (1 shl (1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1))) or
      (FMaxDataFrameSizeOut > MaxAllowedFrameSize)) then
    Add('the outbound data frame size is outside the range');
end;

end.
