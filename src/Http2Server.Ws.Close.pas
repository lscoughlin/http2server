{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, close handshake, heartbeat, ping, pong, timers, rfc 6455
notes:
  - This unit decides what the timer of a session does. It is a pure function of
    the times and the flags, so a test calls it with numbers and needs no clock.
  - The heartbeat follows RFC 6455 section 5.5.2 and 5.5.3. The server sends a Ping
    when a session has had no inbound traffic for the ping interval, and it closes
    the session when the Pong does not come in time.
  - The closing handshake follows section 7. After the Close frame of the server,
    the server waits for the Close frame of the peer for the close timeout, and then
    closes the channel.
  - The table of close codes that the server sends and the codes that it takes from
    a peer is in doc/design/websocket.md.
---
}
/// The timer rules of a WebSocket session
unit Http2Server.Ws.Close;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// what the timer of a session does now
  TWsTimerAction = (
    /// nothing is due
    taNone,
    /// the session was idle for the ping interval: send a Ping
    taSendPing,
    /// the Pong did not come in time: close with 1011
    taPongTimeout,
    /// the peer did not answer the Close frame in time: close the channel
    taCloseTimeout);

  TWsTimerInput = record
    NowMs: QWord;
    /// when the last octet arrived from the peer
    LastInboundMs: QWord;
    /// when the Ping went out; 0 while none waits for its Pong
    PingSentMs: QWord;
    /// when the Close frame of the server went out; 0 if it did not
    CloseSentMs: QWord;
    /// the session is open and no Close frame has gone out
    Open: Boolean;
    InputClosed: Boolean;
    PingIntervalMs: Integer;
    PongTimeoutMs: Integer;
    CloseTimeoutMs: Integer;
  end;

/// the action that is due now, and the wait before the next check
// - ANextDelayMs is 0 when no timer is needed
function WsTimerStep(const AInput: TWsTimerInput; out ANextDelayMs: Integer): TWsTimerAction;

implementation

const
  /// no timer re-arms sooner than this, so a clock that is a few milliseconds
  /// short of a deadline does not make a tight loop
  cMinDelayMs = 20;

function Elapsed(const ANow, ASince: QWord): QWord;
begin
  if ANow > ASince then
    Result := ANow - ASince
  else
    Result := 0;
end;

function WsTimerStep(const AInput: TWsTimerInput; out ANextDelayMs: Integer): TWsTimerAction;
var
  Gone: QWord;
  Left: Int64;
begin
  Result := taNone;
  ANextDelayMs := 0;
  // the closing handshake first: the Close frame went out and the peer is silent
  if (AInput.CloseSentMs <> 0) and not AInput.InputClosed then
  begin
    Gone := Elapsed(AInput.NowMs, AInput.CloseSentMs);
    if Gone >= QWord(AInput.CloseTimeoutMs) then
      Exit(taCloseTimeout);
    Left := Int64(AInput.CloseTimeoutMs) - Int64(Gone);
    ANextDelayMs := Integer(Left);
    if ANextDelayMs < cMinDelayMs then
      ANextDelayMs := cMinDelayMs;
    Exit;
  end;
  if not AInput.Open then
    Exit;
  if AInput.PingSentMs <> 0 then
  begin
    Gone := Elapsed(AInput.NowMs, AInput.PingSentMs);
    if Gone >= QWord(AInput.PongTimeoutMs) then
      Exit(taPongTimeout);
    Left := Int64(AInput.PongTimeoutMs) - Int64(Gone);
  end
  else if AInput.PingIntervalMs > 0 then
  begin
    Gone := Elapsed(AInput.NowMs, AInput.LastInboundMs);
    if Gone >= QWord(AInput.PingIntervalMs) then
      Exit(taSendPing);
    Left := Int64(AInput.PingIntervalMs) - Int64(Gone);
  end
  else
    Exit;
  ANextDelayMs := Integer(Left);
  if ANextDelayMs < cMinDelayMs then
    ANextDelayMs := cMinDelayMs;
end;

end.
