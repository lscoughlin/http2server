{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, trust store, verify mode, openssl
notes:
  - This unit applies the client certificate trust and the verify mode to the
    server SSL_CTX that mORMot2 stores in AcceptCert after AfterBind.
  - mORMot2 takes one trust source only and has no optional mode, so the server
    sets the trust and the mode itself, in one place, for every mode.
  - The two entry points that mORMot2 does not declare are resolved from libssl
    with the same path rules as the ALPN binding.
---
}
/// The client certificate trust and verify mode of the server context
unit Http2Server.Tls.Client;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils,
  mormot.core.base, mormot.core.os, mormot.core.unicode, mormot.lib.openssl11,
  Http2Server.Mtls.Types;

/// TRUE when the libssl entry points of this unit resolved
function Http2ClientTrustBindingAvailable: Boolean;

/// apply trust, verify mode, depth and the renegotiation ban to a server context
// - the order is: anchors from the file, anchors from the system store, the
//   partial chain flag, the CA name list, the verify mode, the depth
// - answers FALSE when the context is nil, a binding is missing, or the CA file
//   cannot be loaded
function ApplyClientTrust(const ACtx: PSSL_CTX;
  const ATrust: TClientTrust): Boolean;

/// the verify mode that the context holds, or -1 when it cannot be read
function Http2TlsVerifyMode(const ACtx: PSSL_CTX): Integer;

/// the verify depth that the context holds, or -1 when it cannot be read
function Http2TlsVerifyDepth(const ACtx: PSSL_CTX): Integer;

implementation

type
  TSetVerifyDepth = procedure(ctx: PSSL_CTX; depth: Integer); cdecl;
  TGetVerifyDepth = function(ctx: PSSL_CTX): Integer; cdecl;
  TGetVerifyMode = function(ctx: PSSL_CTX): Integer; cdecl;

const
  OPENSSL_LIBPATH_NAME = 'OPENSSL_LIBPATH';
  // SSL_CTX_set_verify_depth is a function in libssl; X509_V_FLAG_PARTIAL_CHAIN
  // comes from mORMot2
var
  fLib: TSynLibrary;
  fSetDepth: TSetVerifyDepth;
  fGetDepth: TGetVerifyDepth;
  fGetMode: TGetVerifyMode;

function Http2ClientTrustBindingAvailable: Boolean;
var
  Dir: TFileName;
  Err: string;
begin
  Result := Assigned(fSetDepth) and Assigned(fGetMode) and Assigned(fGetDepth);
  if Result then
    Exit;
  GlobalLock;
  try
    if Assigned(fSetDepth) and Assigned(fGetMode) and Assigned(fGetDepth) then
      Exit(True);
    Dir := GetSystemEnvString(OPENSSL_LIBPATH_NAME);
    if Dir <> '' then
      if DirectoryExists(Dir) then
        Dir := IncludeTrailingPathDelimiter(Dir)
      else
        Dir := '';
    fLib := TSynLibrary.Create;
    if not fLib.TryLoadLibrary([Dir + LIB_SSL4, Dir + LIB_SSL3, Dir + LIB_SSL1],
             nil, @Err) then
    begin
      FreeAndNil(fLib);
      Exit(False);
    end;
    if not (fLib.Resolve(_PU, 'SSL_CTX_set_verify_depth', @@fSetDepth, nil,
              @Err) and
            fLib.Resolve(_PU, 'SSL_CTX_get_verify_depth', @@fGetDepth, nil,
              @Err) and
            fLib.Resolve(_PU, 'SSL_CTX_get_verify_mode', @@fGetMode, nil,
              @Err)) then
    begin
      fSetDepth := nil;
      fGetDepth := nil;
      fGetMode := nil;
      FreeAndNil(fLib);
      Exit(False);
    end;
    Result := True;
  finally
    GlobalUnLock;
  end;
end;

function Http2TlsVerifyMode(const ACtx: PSSL_CTX): Integer;
begin
  Result := -1;
  if (ACtx <> nil) and Http2ClientTrustBindingAvailable then
    Result := fGetMode(ACtx);
end;

function Http2TlsVerifyDepth(const ACtx: PSSL_CTX): Integer;
begin
  Result := -1;
  if (ACtx <> nil) and Http2ClientTrustBindingAvailable then
    Result := fGetDepth(ACtx);
end;

function ApplyClientTrust(const ACtx: PSSL_CTX;
  const ATrust: TClientTrust): Boolean;
var
  Names: Pstack_st_X509_NAME;
  CaFile: RawUtf8;
begin
  Result := False;
  if ACtx = nil then
    Exit;
  if ATrust.Mode = ccmNone then
    Exit(True);
  if not Http2ClientTrustBindingAvailable then
    Exit;
  CaFile := StringToUtf8(ATrust.CaFile);
  if CaFile <> '' then
  begin
    if SSL_CTX_load_verify_locations(ACtx, pointer(CaFile), nil) <> 1 then
      Exit;
    // the CertificateRequest names the anchors of the file. The system store
    // is large, so its names are not sent
    Names := SSL_load_client_CA_file(pointer(CaFile));
    if Names = nil then
      Exit;
    SSL_CTX_set_client_CA_list(ACtx, Names);   // the context owns the list
  end;
  if ATrust.SystemStore then
    if not SSL_CTX_get_cert_store(ACtx)^.AddCertificates(
             LoadCertificatesFromSystemStore) then
      Exit;
  if ATrust.PartialChain then
    X509_STORE_set_flags(SSL_CTX_get_cert_store(ACtx), X509_V_FLAG_PARTIAL_CHAIN);
  SSL_CTX_set_verify(ACtx, VerifyModeFor(ATrust.Mode), nil);
  fSetDepth(ACtx, ATrust.Depth);
  // RFC 9113 section 9.2.1: no renegotiation. The first handshake is the only
  // place a certificate is asked for
  SSL_CTX_set_options(ACtx, SSL_OP_NO_RENEGOTIATION);
  Result := True;
end;

initialization

finalization
  FreeAndNil(fLib);
end.
