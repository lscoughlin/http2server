{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, tls, verify mode, principal
notes:
  - This unit holds the enumerations of the mutual TLS settings and the pure
    maps from a setting to an OpenSSL flag or to a principal text.
  - The unit has no dependency on OpenSSL, so a test reaches every branch
    without a socket.
---
}
/// The mutual TLS enumerations and their pure maps
unit Http2Server.Mtls.Types;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// whether the server asks a client for a certificate
  TClientCertMode = (
    /// the server asks for no certificate
    ccmNone,
    /// the server asks, and serves a client that sends none
    ccmOptional,
    /// the server asks, and refuses a client that sends none
    ccmRequired);

  /// what the server writes to Principal for a verified client certificate
  TClientCertPrincipal = (
    /// nothing; the principal stays empty
    ccpNone,
    /// the subject distinguished name
    ccpSubjectDn,
    /// the first common name of the subject
    ccpCommonName);

  /// the client certificate settings of one listener
  TClientTrust = record
    /// whether the server asks for a client certificate
    Mode: TClientCertMode;
    /// the PEM file with the trust anchors, or empty
    CaFile: string;
    /// whether the operating system store adds trust anchors
    SystemStore: Boolean;
    /// whether a leaf or intermediate anchor is enough (partial chain)
    PartialChain: Boolean;
    /// the longest accepted chain between the client and an anchor
    Depth: Integer;
    /// what the server writes to Principal for a verified client
    Principal: TClientCertPrincipal;
  end;

const
  /// the OpenSSL verify flags, from openssl/ssl.h
  cVerifyNone = $00;
  cVerifyPeer = $01;
  cVerifyFailIfNoPeerCert = $02;
  cVerifyClientOnce = $04;

  /// the longest chain depth the settings accept
  cMaxClientVerifyDepth = 16;

/// the OpenSSL verify mode of a client certificate mode
// - ccmNone answers SSL_VERIFY_NONE; the optional mode asks and never insists
function VerifyModeFor(const AMode: TClientCertMode): Integer;

/// the principal text of a subject, by the principal setting
function PrincipalTextFor(const APrincipal: TClientCertPrincipal;
  const ASubjectDn, ACommonName: string): string;

implementation

function VerifyModeFor(const AMode: TClientCertMode): Integer;
begin
  case AMode of
    ccmOptional:
      Result := cVerifyPeer or cVerifyClientOnce;
    ccmRequired:
      Result := cVerifyPeer or cVerifyFailIfNoPeerCert or cVerifyClientOnce;
  else
    Result := cVerifyNone;
  end;
end;

function PrincipalTextFor(const APrincipal: TClientCertPrincipal;
  const ASubjectDn, ACommonName: string): string;
begin
  case APrincipal of
    ccpSubjectDn:
      Result := ASubjectDn;
    ccpCommonName:
      Result := ACommonName;
  else
    Result := '';
  end;
end;

end.
