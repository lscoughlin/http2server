{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, config, verify mode, trust, test, fpcunit
notes:
  - This unit tests the parts of mutual TLS that need no socket. These are the settings
    and their validation, the map from a mode to an OpenSSL flag, the trust
    setup on a bare server context and the identity record of a certificate.
  - The server context is read back with SSL_CTX_get_verify_mode, so a change
    of mORMot2 that weakens the mode fails a test.
  - The live handshake cases are in the separate program in test/mtls.
---
}
/// Tests of the mutual TLS settings, trust setup and identity record
unit Http2Server.Mtls.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  mormot.core.base, mormot.core.os, mormot.lib.openssl11,
  Http2Server.Seam, Http2Server.Config, Http2Server.Mtls.Types,
  Http2Server.Tls.Client, Http2Server.ClientCert;

type
  /// a handler that does nothing, only to satisfy the factory
  TMtlsNullHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the pure maps and the settings
  TMtlsConfigTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function Problems(const ATls: TTlsServerOptions;
      const AClearText: Boolean): string;
  protected
    procedure SetUp; override;
  published
    procedure TestVerifyModeMap;
    procedure TestPrincipalTextMap;
    procedure TestDefaultsAskForNothing;
    procedure TestTrustCopiesTheSettings;
    procedure TestModeNeedsATrustAnchor;
    procedure TestSystemStoreIsATrustAnchor;
    procedure TestMissingCaFileIsReported;
    procedure TestDepthRange;
    procedure TestModeNeedsACertificate;
    procedure TestRequiredModeRefusesCleartext;
    procedure TestOptionalModeAllowsCleartext;
  end;

  /// the trust setup on a bare server context and the identity record
  TMtlsContextTest = class(TTestCase)
  private
    function CaFile: string;
    function NewCtx: PSSL_CTX;
  protected
    procedure SetUp; override;
  published
    procedure TestNoneLeavesTheContextAlone;
    procedure TestOptionalModeFlags;
    procedure TestRequiredModeFlags;
    procedure TestDepthIsApplied;
    procedure TestMissingCaFileFails;
    procedure TestSystemStoreAloneSucceeds;
    procedure TestPartialChainSucceeds;
    procedure TestIdentityOfACertificate;
    procedure TestIdentityPrincipalFollowsTheSetting;
    procedure TestNilTlsGivesNoIdentity;
  end;

implementation

var
  GPkiDir: string = '';
  GPkiTried: Boolean = False;

/// the test PKI, made once by the script tools/certs/make_mtls_pki.sh
// - answers an empty text when the script cannot run (no openssl command)
function PkiDir: string;
begin
  if not GPkiTried then
  begin
    GPkiTried := True;
    GPkiDir := IncludeTrailingPathDelimiter(GetTempDir) + 'http2server-mtls-test-' +
      IntToStr(GetProcessID);
    if ExecuteProcess('/bin/sh', ['tools/certs/make_mtls_pki.sh', GPkiDir]) <> 0 then
      GPkiDir := '';
  end;
  Result := GPkiDir;
end;

function PkiFile(const AName: string): string;
begin
  Result := PkiDir;
  if Result <> '' then
    Result := IncludeTrailingPathDelimiter(Result) + AName;
end;

procedure TMtlsNullHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
end;

{ TMtlsConfigTest }

procedure TMtlsConfigTest.SetUp;
begin
  if PkiDir = '' then
    Ignore('the openssl command cannot make the test PKI');
  FHandler := TMtlsNullHandler.Create;
end;

function TMtlsConfigTest.Problems(const ATls: TTlsServerOptions;
  const AClearText: Boolean): string;
var
  F: THttp2ServerFactory;
  P: TArray<string>;
  i: Integer;
begin
  F := THttp2ServerFactory.Create
    .WithClearTextAllowed(AClearText)
    .WithTls(ATls)
    .WithHandler(FHandler);
  P := nil;
  F.Validate(P);
  Result := '';
  for i := 0 to High(P) do
    Result := Result + P[i] + '; ';
end;

procedure TMtlsConfigTest.TestVerifyModeMap;
begin
  AssertEquals('none', 0, VerifyModeFor(ccmNone));
  AssertEquals('optional', 1 or 4, VerifyModeFor(ccmOptional));
  AssertEquals('required', 1 or 2 or 4, VerifyModeFor(ccmRequired));
end;

procedure TMtlsConfigTest.TestPrincipalTextMap;
begin
  AssertEquals('', PrincipalTextFor(ccpNone, 'CN=a,O=b', 'a'));
  AssertEquals('CN=a,O=b', PrincipalTextFor(ccpSubjectDn, 'CN=a,O=b', 'a'));
  AssertEquals('a', PrincipalTextFor(ccpCommonName, 'CN=a,O=b', 'a'));
end;

procedure TMtlsConfigTest.TestDefaultsAskForNothing;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create;
  AssertTrue(T.ClientCertMode = ccmNone);
  AssertEquals('', T.ClientCaFile);
  AssertFalse(T.ClientTrustSystemStore);
  AssertFalse(T.ClientPartialChain);
  AssertEquals(4, T.ClientVerifyDepth);
  AssertTrue('the principal default is ccpNone', T.ClientCertPrincipal = ccpNone);
end;

procedure TMtlsConfigTest.TestTrustCopiesTheSettings;
var
  T: TClientTrust;
begin
  T := TTlsServerOptions.Create
    .WithClientCertMode(ccmRequired)
    .WithClientCaFile('ca.pem')
    .WithClientTrustSystemStore(True)
    .WithClientPartialChain(True)
    .WithClientVerifyDepth(7)
    .WithClientCertPrincipal(ccpCommonName).ClientTrust;
  AssertTrue(T.Mode = ccmRequired);
  AssertEquals('ca.pem', T.CaFile);
  AssertTrue(T.SystemStore);
  AssertTrue(T.PartialChain);
  AssertEquals(7, T.Depth);
  AssertTrue(T.Principal = ccpCommonName);
end;

procedure TMtlsConfigTest.TestModeNeedsATrustAnchor;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithCertificateFile(PkiFile('server.crt'))
    .WithKeyFile(PkiFile('server.key'))
    .WithClientCertMode(ccmOptional);
  AssertTrue(Pos('no trust anchor', Problems(T, False)) > 0);
end;

procedure TMtlsConfigTest.TestSystemStoreIsATrustAnchor;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithCertificateFile(PkiFile('server.crt'))
    .WithKeyFile(PkiFile('server.key'))
    .WithClientCertMode(ccmRequired)
    .WithClientTrustSystemStore(True);
  AssertEquals('', Problems(T, False));
end;

procedure TMtlsConfigTest.TestMissingCaFileIsReported;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithCertificateFile(PkiFile('server.crt'))
    .WithKeyFile(PkiFile('server.key'))
    .WithClientCertMode(ccmRequired)
    .WithClientCaFile(PkiFile('absent.pem'));
  AssertTrue(Pos('CA file is not present', Problems(T, False)) > 0);
end;

procedure TMtlsConfigTest.TestDepthRange;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithCertificateFile(PkiFile('server.crt'))
    .WithKeyFile(PkiFile('server.key'))
    .WithClientCertMode(ccmRequired)
    .WithClientCaFile(PkiFile('ca.crt'));
  AssertEquals('', Problems(T.WithClientVerifyDepth(1), False));
  AssertEquals('', Problems(T.WithClientVerifyDepth(cMaxClientVerifyDepth), False));
  AssertTrue(Pos('verify depth', Problems(T.WithClientVerifyDepth(0), False)) > 0);
  AssertTrue(Pos('verify depth',
    Problems(T.WithClientVerifyDepth(cMaxClientVerifyDepth + 1), False)) > 0);
end;

procedure TMtlsConfigTest.TestModeNeedsACertificate;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithClientCertMode(ccmOptional)
    .WithClientCaFile(PkiFile('ca.crt'));
  AssertTrue(Pos('needs a TLS certificate file', Problems(T, True)) > 0);
end;

procedure TMtlsConfigTest.TestRequiredModeRefusesCleartext;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithCertificateFile(PkiFile('server.crt'))
    .WithKeyFile(PkiFile('server.key'))
    .WithClientCertMode(ccmRequired)
    .WithClientCaFile(PkiFile('ca.crt'));
  AssertTrue(Pos('needs cleartext off', Problems(T, True)) > 0);
  AssertEquals('', Problems(T, False));
end;

procedure TMtlsConfigTest.TestOptionalModeAllowsCleartext;
var
  T: TTlsServerOptions;
begin
  T := TTlsServerOptions.Create
    .WithCertificateFile(PkiFile('server.crt'))
    .WithKeyFile(PkiFile('server.key'))
    .WithClientCertMode(ccmOptional)
    .WithClientCaFile(PkiFile('ca.crt'));
  AssertEquals('', Problems(T, True));
end;

{ TMtlsContextTest }

procedure TMtlsContextTest.SetUp;
begin
  if PkiDir = '' then
    Ignore('the openssl command cannot make the test PKI');
  // libssl loads on first use; a bare context needs it loaded now
  AssertTrue('OpenSSL is available', OpenSslIsAvailable);
end;

function TMtlsContextTest.CaFile: string;
begin
  Result := PkiFile('ca.crt');
end;

function TMtlsContextTest.NewCtx: PSSL_CTX;
begin
  Result := SSL_CTX_new_server('');
  AssertTrue('a server context', Result <> nil);
end;

procedure TMtlsContextTest.TestNoneLeavesTheContextAlone;
var
  Ctx: PSSL_CTX;
  T: TClientTrust;
begin
  Ctx := NewCtx;
  try
    T := TTlsServerOptions.Create.ClientTrust;
    AssertTrue(ApplyClientTrust(Ctx, T));
    AssertEquals('no verify flag', 0, Http2TlsVerifyMode(Ctx));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestOptionalModeFlags;
var
  Ctx: PSSL_CTX;
begin
  Ctx := NewCtx;
  try
    AssertTrue(ApplyClientTrust(Ctx, TTlsServerOptions.Create
      .WithClientCertMode(ccmOptional).WithClientCaFile(CaFile).ClientTrust));
    AssertEquals('peer and once, no fail-if-no-cert', cVerifyPeer or cVerifyClientOnce,
      Http2TlsVerifyMode(Ctx));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestRequiredModeFlags;
var
  Ctx: PSSL_CTX;
begin
  Ctx := NewCtx;
  try
    AssertTrue(ApplyClientTrust(Ctx, TTlsServerOptions.Create
      .WithClientCertMode(ccmRequired).WithClientCaFile(CaFile).ClientTrust));
    AssertEquals('fail-if-no-cert is set',
      cVerifyPeer or cVerifyFailIfNoPeerCert or cVerifyClientOnce,
      Http2TlsVerifyMode(Ctx));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestDepthIsApplied;
var
  Ctx: PSSL_CTX;
begin
  Ctx := NewCtx;
  try
    AssertTrue(ApplyClientTrust(Ctx, TTlsServerOptions.Create
      .WithClientCertMode(ccmRequired).WithClientCaFile(CaFile)
      .WithClientVerifyDepth(3).ClientTrust));
    AssertEquals(3, Http2TlsVerifyDepth(Ctx));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestMissingCaFileFails;
var
  Ctx: PSSL_CTX;
begin
  Ctx := NewCtx;
  try
    AssertFalse(ApplyClientTrust(Ctx, TTlsServerOptions.Create
      .WithClientCertMode(ccmRequired)
      .WithClientCaFile(PkiFile('absent.pem')).ClientTrust));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestSystemStoreAloneSucceeds;
var
  Ctx: PSSL_CTX;
begin
  Ctx := NewCtx;
  try
    AssertTrue(ApplyClientTrust(Ctx, TTlsServerOptions.Create
      .WithClientCertMode(ccmOptional).WithClientTrustSystemStore(True)
      .ClientTrust));
    AssertEquals(cVerifyPeer or cVerifyClientOnce, Http2TlsVerifyMode(Ctx));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestPartialChainSucceeds;
var
  Ctx: PSSL_CTX;
begin
  Ctx := NewCtx;
  try
    AssertTrue(ApplyClientTrust(Ctx, TTlsServerOptions.Create
      .WithClientCertMode(ccmRequired).WithClientCaFile(CaFile)
      .WithClientPartialChain(True).ClientTrust));
  finally
    Ctx^.Free;
  end;
end;

procedure TMtlsContextTest.TestIdentityOfACertificate;
var
  Pem: RawByteString;
  X: PX509;
  C: IClientCertificate;
  Dns: TArray<string>;
begin
  Pem := StringFromFile(PkiFile('alice.crt'));
  X := LoadCertificate(Pem);
  AssertTrue('the fixture loads', X <> nil);
  try
    C := ClientCertificateFromX509(X, ccpNone);
  finally
    X^.Free;
  end;
  AssertTrue(C <> nil);
  AssertTrue('subject names alice', Pos('CN=alice', C.SubjectDn) > 0);
  AssertTrue('subject keeps the organisation', Pos('O=Example', C.SubjectDn) > 0);
  AssertTrue('issuer is the test root', Pos('CN=Test Root CA', C.IssuerDn) > 0);
  AssertEquals('alice', C.CommonName);
  AssertEquals('sha-256 in hex', 64, Length(C.Sha256));
  AssertEquals('lower case', LowerCase(C.Sha256), C.Sha256);
  AssertTrue('a serial', C.SerialHex <> '');
  AssertEquals('upper case', UpperCase(C.SerialHex), C.SerialHex);
  Dns := C.SanDns;
  AssertEquals(1, Length(Dns));
  AssertEquals('alice.example', Dns[0]);
  AssertEquals(1, Length(C.SanUri));
  AssertEquals('spiffe://example.org/alice', C.SanUri[0]);
  AssertEquals(1, Length(C.SanEmail));
  AssertEquals('alice@example.org', C.SanEmail[0]);
  AssertTrue('a PEM block', Pos('BEGIN CERTIFICATE', C.Pem) > 0);
  AssertTrue('a validity period', C.NotAfter > C.NotBefore);
  AssertEquals('ccpNone leaves the principal empty', '', C.PrincipalText);
end;

procedure TMtlsContextTest.TestIdentityPrincipalFollowsTheSetting;
var
  X: PX509;
  Dn, Cn: IClientCertificate;
begin
  X := LoadCertificate(StringFromFile(PkiFile('alice.crt')));
  AssertTrue(X <> nil);
  try
    Dn := ClientCertificateFromX509(X, ccpSubjectDn);
    Cn := ClientCertificateFromX509(X, ccpCommonName);
  finally
    X^.Free;
  end;
  AssertEquals(Dn.SubjectDn, Dn.PrincipalText);
  AssertEquals('alice', Cn.PrincipalText);
end;

procedure TMtlsContextTest.TestNilTlsGivesNoIdentity;
begin
  AssertTrue(ReadClientCertificate(nil, ccpNone) = nil);
end;

initialization
  RegisterTest(TMtlsConfigTest);
  RegisterTest(TMtlsContextTest);

finalization
  // the PKI directory is a temporary one of this process
  if GPkiDir <> '' then
    ExecuteProcess('/bin/rm', ['-rf', GPkiDir]);

end.
