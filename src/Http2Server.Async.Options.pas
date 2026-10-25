{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, options, tls policy, connection core, handshake deadline
notes:
  - This unit turns the factory into the option records that the async server
    hands to the TLS layer and to each connection core.
  - The functions read the factory and hold no state, so the async server unit
    stays under the file size limit.
---
}
/// The option records of the async server, built from the factory
unit Http2Server.Async.Options;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils,
  mormot.core.base, mormot.net.sock,
  Http2Server.Config, Http2Server.Connection, Http2Server.Tls,
  Http2Server.Limits;

/// the address text that mORMot2 binds: the host, a colon and the port
// - an empty host binds every IPv4 address
function BindAddressText(const AHost: string; const APort: Integer): RawUtf8;

/// the period of the idle callback, in whole seconds
// - the callback is the one place that checks both timeouts, so it runs at the
//   earlier of the two. A sub-second timeout rounds up to one second, because
//   the base class compares in 32-bit seconds. 0 means no check
function IdleCheckSeconds(const AIdleMs, AHeaderMs: Integer): Cardinal;

/// the TLS policy of the listener, with the client certificate settings
function BuildTlsPolicy(const AFactory: THttp2ServerFactory): TTlsPolicy;

/// the options that every connection core of the server uses
function BuildConnectionCoreOptions(
  const AFactory: THttp2ServerFactory): TConnectionCoreOptions;

/// the single control bucket that the core charges for every non-reset kind
// - the factory offers five control buckets. The least capacity is the
//   conservative choice: the server enforces the strictest of the five
function LeastControlBucket(
  const AFactory: THttp2ServerFactory): TTokenBucketOptions;

/// set the socket deadlines of the handshake, after the mORMot2 bound
// - a deadline is a convenience: Darwin answers EINVAL for SO_RCVTIMEO on a
//   socket whose peer already sent RST, so a failure here forbids no valid
//   connection and never raises
procedure SetHandshakeDeadline(const ASocket: TNetSocket;
  const ARequestedMs: LongWord);

implementation

function IdleCheckSeconds(const AIdleMs, AHeaderMs: Integer): Cardinal;

  function Seconds(const AValue: Integer): Cardinal;
  begin
    if AValue <= 0 then
      exit(0);
    result := Cardinal(AValue div 1000);
    if result = 0 then
      result := 1;
  end;

begin
  result := Seconds(AIdleMs);
  if (AHeaderMs > 0) and ((result = 0) or (Seconds(AHeaderMs) < result)) then
    result := Seconds(AHeaderMs);
end;

function BindAddressText(const AHost: string; const APort: Integer): RawUtf8;
var
  Host: string;
begin
  Host := AHost;
  if Host = '' then
    Host := '0.0.0.0';
  // mORMot2 splits the text at the last colon, so an IPv6 host needs no bracket
  result := RawUtf8(Host + ':' + IntToStr(APort));
end;

function BuildTlsPolicy(const AFactory: THttp2ServerFactory): TTlsPolicy;
begin
  result.CertificateFile := AFactory.Tls.CertificateFile;
  result.KeyFile := AFactory.Tls.KeyFile;
  result.KeyPassword := AFactory.Tls.KeyPassword;
  result.HandshakeTimeoutMs := LongWord(AFactory.Tls.HandshakeTimeoutMs);
  result.AllowClearText := AFactory.ClearTextAllowed;
  result.AllowHttp11 := AFactory.Http11Fallback;
  result.IgnoreCertificateErrors := True;
  result.ClientTrust := AFactory.Tls.ClientTrust;
end;

function BuildConnectionCoreOptions(
  const AFactory: THttp2ServerFactory): TConnectionCoreOptions;
begin
  result.ConnectionWindow := LongInt(AFactory.InitialConnectionWindow);
  result.InitialStreamWindow := LongInt(AFactory.InitialStreamWindow);
  result.MaxConcurrentStreams := AFactory.MaxConcurrentStreams;
  result.MaxFrameSize := AFactory.MaxFrameSize;
  result.MaxHeaderListSize := AFactory.MaxHeaderListSize;
  result.MaxHeaderTableSize := AFactory.HeaderTableSize;
  result.MaxContinuations := AFactory.MaxContinuationFrames;
  // the header block bound is twice the header list bound, so one block that
  // meets the list limit always fits
  result.MaxHeaderBlockBytes := AFactory.MaxHeaderListSize * 2;
  // the inbound buffer is the initial stream window, so a peer cannot buffer
  // more than the server granted it
  result.InboundBufferLimit := Integer(AFactory.InitialStreamWindow);
  result.OutboundBufferLimit := Integer(AFactory.InitialStreamWindow);
  result.ConnectionUpdateThreshold := AFactory.InitialConnectionWindow div 2;
  result.StreamUpdateThreshold := AFactory.InitialStreamWindow div 2;
  result.ConnectProtocol := AFactory.WebSocketsEnabled;
  result.MaxOutputBytes := LongWord(AFactory.MaxOutputQueueBytes);
end;

function LeastControlBucket(
  const AFactory: THttp2ServerFactory): TTokenBucketOptions;

  function Least(const A, B: TTokenBucketOptions): TTokenBucketOptions;
  begin
    if B.Capacity < A.Capacity then
      result := B
    else
      result := A;
  end;

begin
  result := Least(Least(AFactory.PingBucket, AFactory.SettingsBucket),
    Least(AFactory.EmptyDataBucket, AFactory.WindowUpdateBucket));
  result := Least(result, AFactory.ContinuationBucket);
end;

procedure SetHandshakeDeadline(const ASocket: TNetSocket;
  const ARequestedMs: LongWord);
var
  Ms: LongWord;
begin
  Ms := EffectiveHandshakeTimeoutMs(ARequestedMs);
  if Ms = 0 then
    exit;
  try
    ASocket.SetReceiveTimeout(Integer(Ms));
    ASocket.SetSendTimeout(Integer(Ms));
  except
    on ENetSock do
      ;   // no deadline is set; the connection still proceeds
  end;
end;

end.
