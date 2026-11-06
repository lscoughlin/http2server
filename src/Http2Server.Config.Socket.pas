{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, socket, tcp, keep-alive
notes:
  - This unit holds the socket options of the listener.
  - Http2Server.Config carries the record in its Socket property.
  - The factory Validate calls the Validate of this record, so one call
    reports every problem of the settings.
---
}
/// The socket options of the listener
// - TSocketOptions is the record that the factory carries in its Socket
//   property
// - the record is a value, so a copy of the factory holds its own settings
unit Http2Server.Config.Socket;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// the socket options of the listener
  ///
  /// A record is a value, so a copy of the factory holds its own settings.
  /// A size of 0 keeps the operating system default.
  TSocketOptions = record
  private
    FTcpNoDelay: Boolean;
    FKeepAliveIdleSec: Integer;
    FKeepAliveIntervalSec: Integer;
    FKeepAliveCount: Integer;
    FSendBufferBytes: Integer;
    FRecvBufferBytes: Integer;
    FReusePort: Boolean;
  public
    /// the defaults of the socket options
    class function Create: TSocketOptions; static;
    /// send a small packet at once, without the delay of Nagle
    function WithTcpNoDelay(const AValue: Boolean): TSocketOptions;
    /// the idle time before the first keep-alive probe, in seconds; 0
    /// turns keep-alive off
    function WithKeepAliveIdleSec(const AValue: Integer): TSocketOptions;
    /// the time between two keep-alive probes, in seconds
    function WithKeepAliveIntervalSec(const AValue: Integer): TSocketOptions;
    /// the number of failed probes before the peer is declared dead
    function WithKeepAliveCount(const AValue: Integer): TSocketOptions;
    /// the size of the send buffer, in bytes; 0 keeps the operating
    /// system default
    function WithSendBufferBytes(const AValue: Integer): TSocketOptions;
    /// the size of the receive buffer, in bytes; 0 keeps the operating
    /// system default
    function WithRecvBufferBytes(const AValue: Integer): TSocketOptions;
    /// let more than one listener bind the same port
    function WithReusePort(const AValue: Boolean): TSocketOptions;

    /// add one text to AProblems for each setting that is not usable
    procedure Validate(var AProblems: TArray<string>);

    property TcpNoDelay: Boolean read FTcpNoDelay;
    property KeepAliveIdleSec: Integer read FKeepAliveIdleSec;
    property KeepAliveIntervalSec: Integer read FKeepAliveIntervalSec;
    property KeepAliveCount: Integer read FKeepAliveCount;
    property SendBufferBytes: Integer read FSendBufferBytes;
    property RecvBufferBytes: Integer read FRecvBufferBytes;
    property ReusePort: Boolean read FReusePort;
  end;

implementation

{ TSocketOptions }

class function TSocketOptions.Create: TSocketOptions;
begin
  // Nagle holds a small packet for an ack, which delays a multiplexed
  // connection, so no-delay is on
  Result.FTcpNoDelay := True;
  // an idle time of 0 turns keep-alive off; the interval and the count
  // are then unused
  Result.FKeepAliveIdleSec := 0;
  Result.FKeepAliveIntervalSec := 0;
  Result.FKeepAliveCount := 0;
  // a buffer size of 0 keeps the operating system default
  Result.FSendBufferBytes := 0;
  Result.FRecvBufferBytes := 0;
  Result.FReusePort := False;
end;

function TSocketOptions.WithTcpNoDelay(const AValue: Boolean): TSocketOptions;
begin
  Result := Self;
  Result.FTcpNoDelay := AValue;
end;

function TSocketOptions.WithKeepAliveIdleSec(
  const AValue: Integer): TSocketOptions;
begin
  Result := Self;
  Result.FKeepAliveIdleSec := AValue;
end;

function TSocketOptions.WithKeepAliveIntervalSec(
  const AValue: Integer): TSocketOptions;
begin
  Result := Self;
  Result.FKeepAliveIntervalSec := AValue;
end;

function TSocketOptions.WithKeepAliveCount(
  const AValue: Integer): TSocketOptions;
begin
  Result := Self;
  Result.FKeepAliveCount := AValue;
end;

function TSocketOptions.WithSendBufferBytes(
  const AValue: Integer): TSocketOptions;
begin
  Result := Self;
  Result.FSendBufferBytes := AValue;
end;

function TSocketOptions.WithRecvBufferBytes(
  const AValue: Integer): TSocketOptions;
begin
  Result := Self;
  Result.FRecvBufferBytes := AValue;
end;

function TSocketOptions.WithReusePort(const AValue: Boolean): TSocketOptions;
begin
  Result := Self;
  Result.FReusePort := AValue;
end;

procedure TSocketOptions.Validate(var AProblems: TArray<string>);

  procedure Add(const AText: string);
  begin
    SetLength(AProblems, Length(AProblems) + 1);
    AProblems[High(AProblems)] := AText;
  end;

begin
  if (FKeepAliveIdleSec < 0) or (FKeepAliveIntervalSec < 0) or
     (FKeepAliveCount < 0) or ((FKeepAliveIdleSec > 0) and
     ((FKeepAliveIntervalSec = 0) or (FKeepAliveCount = 0))) then
    Add('the keep-alive values are not valid');
  if (FSendBufferBytes < 0) or (FRecvBufferBytes < 0) then
    Add('the socket buffer size is below 0');
end;

end.
