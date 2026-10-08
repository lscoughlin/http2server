{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, alpn, openssl, h2c, handshake
notes:
  - applies the server TLS context and installs the h2 ALPN callback
  - the bind order is AfterBind, then the ALPN callback, because mORMot2
    creates the server SSL_CTX inside AfterBind
  - the transport decision, the handshake deadline and the negotiated-name
    check are pure functions, so a test reaches every branch without a socket
  - cleartext h2c is offered only when the policy allows it
  - the mORMot2 INetTls layer already bounds SSL_accept at 5000 ms, so a
    larger factory deadline can never take effect and is clamped to it
---
}
/// The TLS plug-in of the server, on route A
// - the server takes the mORMot2 INetTls interface, which wraps OpenSSL,
//   and adds the one ALPN-select callback that mORMot2 does not set
// - the plug-in keeps every decision in a pure function: which transport a
//   policy offers, when a handshake has used up its deadline, and whether a
//   finished handshake negotiated h2.  A test reaches every branch of those
//   decisions without a socket and without OpenSSL
// - the handshake itself runs inside INetTls.AfterAccept.  mORMot2 bounds the
//   SSL_accept loop at 5000 ms, and the server clamps the factory deadline to
//   that bound, so a stalled handshake never holds an IO thread without end
unit Http2Server.Tls;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.lib.openssl11,
  mormot.net.sock,
  Http2Server.Alpn;

const
  /// the longest handshake the mORMot2 INetTls layer permits, in milliseconds
  // - TOpenSslNetTls.WaitRetry sets this deadline in the SSL_accept loop
  //   (mormot.lib.openssl11.pas:12162-12166, read 2026-10-07)
  MaxHandshakeTimeoutMs = 5000;

type
  /// the transport that a connection is allowed to use
  TTransport = (
    /// the connection runs TLS, and h2 must be negotiated
    trTls,
    /// the connection runs cleartext HTTP/2 (h2c prior knowledge)
    trClearText,
    /// the connection is refused
    trRefused);

  /// The TLS settings that the server applies to a bound socket.
  ///
  /// The record is a plain value, so a caller fills it from the factory
  /// without this unit depending on the factory unit.
  TTlsPolicy = record
    /// the PEM certificate chain file, empty when no TLS is offered
    CertificateFile: TFileName;
    /// the PEM private key file, empty when it sits in the certificate file
    KeyFile: TFileName;
    /// the private key password, empty for an unencrypted key
    KeyPassword: RawUtf8;
    /// the TLS handshake deadline in milliseconds, zero for no deadline
    HandshakeTimeoutMs: LongWord;
    /// when TRUE a cleartext h2c connection is accepted as well
    AllowClearText: boolean;
    /// when TRUE the ALPN callback also selects http/1.1
    AllowHttp11: boolean;
    /// when TRUE the peer certificate is not verified
    IgnoreCertificateErrors: boolean;
  end;

/// the transport that this policy offers for a connection
// - an empty certificate means TLS is absent, so cleartext is the only
// possible transport when the policy allows it
function TransportFor(const APolicy: TTlsPolicy): TTransport;

/// TRUE when the handshake has used up its deadline
// - a zero timeout never expires
function HandshakeExpired(const AStartedMs, ANowMs: Int64;
  const ATimeoutMs: LongWord): boolean;

/// the handshake deadline the server applies, after the mORMot2 bound
function EffectiveHandshakeTimeoutMs(const ARequestedMs: LongWord): LongWord;

/// TRUE when the TLS connection negotiated h2 as its ALPN protocol
// - a nil TLS instance answers FALSE, so a cleartext connection is honoured
function NegotiatedH2(const ATls: INetTls): boolean;

/// the ALPN name that a finished handshake selected, or '' when none
function NegotiatedAlpnName(const ATls: INetTls): RawUtf8;

/// apply the policy to a bound socket: the TLS context, then the ALPN callback
// - returns FALSE when TLS is requested but the certificate is missing, or
// when the ALPN entry point of libssl is unavailable
// - the bind order is AfterBind, then the ALPN callback, because mORMot2
// creates the server SSL_CTX inside AfterBind
function ApplyTls(const ABound: TCrtSocket;
  const APolicy: TTlsPolicy): boolean;

implementation

function TransportFor(const APolicy: TTlsPolicy): TTransport;
begin
  if APolicy.CertificateFile <> '' then
    result := trTls
  else if APolicy.AllowClearText then
    result := trClearText
  else
    result := trRefused;
end;

function HandshakeExpired(const AStartedMs, ANowMs: Int64;
  const ATimeoutMs: LongWord): boolean;
begin
  if ATimeoutMs = 0 then
    exit(false);
  result := ANowMs - AStartedMs >= ATimeoutMs;
end;

function EffectiveHandshakeTimeoutMs(const ARequestedMs: LongWord): LongWord;
begin
  // INetTls.AfterAccept already bounds SSL_accept with a 5000 ms deadline,
  // so a larger factory value can never take effect and a smaller value is
  // the stricter deadline that the server asks for
  if ARequestedMs = 0 then
    result := MaxHandshakeTimeoutMs
  else if ARequestedMs > MaxHandshakeTimeoutMs then
    result := MaxHandshakeTimeoutMs
  else
    result := ARequestedMs;
end;

function NegotiatedAlpnName(const ATls: INetTls): RawUtf8;
begin
  result := '';
  if ATls = nil then
    exit;
  result := Http2AlpnSelected(PSSL(ATls.GetRawTls));
end;

function NegotiatedH2(const ATls: INetTls): boolean;
begin
  result := NegotiatedAlpnName(ATls) = 'h2';
end;

function ApplyTls(const ABound: TCrtSocket;
  const APolicy: TTlsPolicy): boolean;
begin
  result := false;
  if ABound = nil then
    exit;
  if APolicy.CertificateFile = '' then
    exit;
  if not FileExists(APolicy.CertificateFile) then
    exit;
  ABound.TLS.CertificateFile := APolicy.CertificateFile;
  if APolicy.KeyFile <> '' then
    ABound.TLS.PrivateKeyFile := APolicy.KeyFile;
  if APolicy.KeyPassword <> '' then
    ABound.TLS.PrivatePassword := APolicy.KeyPassword;
  ABound.TLS.IgnoreCertificateErrors := APolicy.IgnoreCertificateErrors;
  // AfterBind creates the server SSL_CTX and stores it in TLS.AcceptCert,
  // so the ALPN callback can only be installed after this call returns
  ABound.DoTlsAfter(cstaBind);
  result := Http2AlpnAttach(ABound, APolicy.AllowHttp11);
end;

end.
