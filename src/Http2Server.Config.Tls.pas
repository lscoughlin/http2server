{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, tls, options
notes:
  - This unit holds the TLS settings of the listener.
  - Http2Server.Config re-exports the record, so a caller that uses the
    factory sees the same name as before the split.
---
}
/// The TLS settings of the listener
// - TTlsServerOptions is the record that the factory carries in its Tls
//   property
// - the record is a value, so a copy of the factory holds its own settings
unit Http2Server.Config.Tls;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Http2Server.Mtls.Types;

type
  /// the TLS version of the listener; no value below 1.2 exists, because
  /// RFC 9113 section 9.2 forbids older versions for HTTP/2
  TTlsVersion = (tvTls12, tvTls13);

  /// the TLS settings of the listener
  ///
  /// A record is a value, so a copy of the factory holds its own TLS
  /// settings.  The certificate file and the key file are paths on disk.
  /// The key password is empty for an unencrypted key.
  TTlsServerOptions = record
  private
    FCertificateFile: string;
    FKeyFile: string;
    FKeyPassword: string;
    FHandshakeTimeoutMs: Integer;
    FMinTlsVersion: TTlsVersion;
    FMaxTlsVersion: TTlsVersion;
    FClientCertMode: TClientCertMode;
    FClientCaFile: string;
    FClientTrustSystemStore: Boolean;
    FClientPartialChain: Boolean;
    FClientVerifyDepth: Integer;
    FClientCertPrincipal: TClientCertPrincipal;
  public
    /// the defaults of the TLS settings
    class function Create: TTlsServerOptions; static;
    /// the path of the certificate file, in PEM form
    function WithCertificateFile(const AValue: string): TTlsServerOptions;
    /// the path of the private key file, in PEM form
    function WithKeyFile(const AValue: string): TTlsServerOptions;
    /// the password of an encrypted key, or an empty string
    function WithKeyPassword(const AValue: string): TTlsServerOptions;
    /// the time a TLS handshake may take, in milliseconds
    function WithHandshakeTimeoutMs(
      const AValue: Integer): TTlsServerOptions;
    /// the lowest TLS version that the listener accepts
    function WithMinTlsVersion(
      const AValue: TTlsVersion): TTlsServerOptions;
    /// the highest TLS version that the listener accepts
    function WithMaxTlsVersion(
      const AValue: TTlsVersion): TTlsServerOptions;
    /// whether the server asks a client for a certificate (mutual TLS)
    function WithClientCertMode(
      const AValue: TClientCertMode): TTlsServerOptions;
    /// the PEM file with the trust anchors for client certificates
    function WithClientCaFile(const AValue: string): TTlsServerOptions;
    /// whether the operating system store adds trust anchors
    function WithClientTrustSystemStore(
      const AValue: Boolean): TTlsServerOptions;
    /// whether a leaf or intermediate trust anchor is enough
    function WithClientPartialChain(const AValue: Boolean): TTlsServerOptions;
    /// the longest accepted chain between a client and a trust anchor
    function WithClientVerifyDepth(const AValue: Integer): TTlsServerOptions;
    /// what the server writes to Principal for a verified client
    function WithClientCertPrincipal(
      const AValue: TClientCertPrincipal): TTlsServerOptions;

    property CertificateFile: string read FCertificateFile;
    property KeyFile: string read FKeyFile;
    property KeyPassword: string read FKeyPassword;
    property HandshakeTimeoutMs: Integer read FHandshakeTimeoutMs;
    property MinTlsVersion: TTlsVersion read FMinTlsVersion;
    property MaxTlsVersion: TTlsVersion read FMaxTlsVersion;
    property ClientCertMode: TClientCertMode read FClientCertMode;
    property ClientCaFile: string read FClientCaFile;
    property ClientTrustSystemStore: Boolean read FClientTrustSystemStore;
    property ClientPartialChain: Boolean read FClientPartialChain;
    property ClientVerifyDepth: Integer read FClientVerifyDepth;
    property ClientCertPrincipal: TClientCertPrincipal read FClientCertPrincipal;
    /// the client certificate settings as the TLS layer reads them
    function ClientTrust: TClientTrust;
  end;

implementation

{ TTlsServerOptions }

class function TTlsServerOptions.Create: TTlsServerOptions;
begin
  Result.FCertificateFile := '';
  Result.FKeyFile := '';
  Result.FKeyPassword := '';
  Result.FHandshakeTimeoutMs := 10000;
  Result.FMinTlsVersion := tvTls12;
  Result.FMaxTlsVersion := tvTls13;
  Result.FClientCertMode := ccmNone;
  Result.FClientCaFile := '';
  Result.FClientTrustSystemStore := False;
  Result.FClientPartialChain := False;
  Result.FClientVerifyDepth := 4;
  Result.FClientCertPrincipal := ccpNone;
end;

function TTlsServerOptions.WithCertificateFile(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FCertificateFile := AValue;
end;

function TTlsServerOptions.WithKeyFile(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FKeyFile := AValue;
end;

function TTlsServerOptions.WithKeyPassword(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FKeyPassword := AValue;
end;

function TTlsServerOptions.WithHandshakeTimeoutMs(
  const AValue: Integer): TTlsServerOptions;
begin
  Result := Self;
  Result.FHandshakeTimeoutMs := AValue;
end;

function TTlsServerOptions.WithMinTlsVersion(
  const AValue: TTlsVersion): TTlsServerOptions;
begin
  Result := Self;
  Result.FMinTlsVersion := AValue;
end;

function TTlsServerOptions.WithMaxTlsVersion(
  const AValue: TTlsVersion): TTlsServerOptions;
begin
  Result := Self;
  Result.FMaxTlsVersion := AValue;
end;

function TTlsServerOptions.WithClientCertMode(
  const AValue: TClientCertMode): TTlsServerOptions;
begin
  Result := Self;
  Result.FClientCertMode := AValue;
end;

function TTlsServerOptions.WithClientCaFile(
  const AValue: string): TTlsServerOptions;
begin
  Result := Self;
  Result.FClientCaFile := AValue;
end;

function TTlsServerOptions.WithClientTrustSystemStore(
  const AValue: Boolean): TTlsServerOptions;
begin
  Result := Self;
  Result.FClientTrustSystemStore := AValue;
end;

function TTlsServerOptions.WithClientPartialChain(
  const AValue: Boolean): TTlsServerOptions;
begin
  Result := Self;
  Result.FClientPartialChain := AValue;
end;

function TTlsServerOptions.WithClientVerifyDepth(
  const AValue: Integer): TTlsServerOptions;
begin
  Result := Self;
  Result.FClientVerifyDepth := AValue;
end;

function TTlsServerOptions.WithClientCertPrincipal(
  const AValue: TClientCertPrincipal): TTlsServerOptions;
begin
  Result := Self;
  Result.FClientCertPrincipal := AValue;
end;

function TTlsServerOptions.ClientTrust: TClientTrust;
begin
  Result.Mode := FClientCertMode;
  Result.CaFile := FClientCaFile;
  Result.SystemStore := FClientTrustSystemStore;
  Result.PartialChain := FClientPartialChain;
  Result.Depth := FClientVerifyDepth;
  Result.Principal := FClientCertPrincipal;
end;

end.
