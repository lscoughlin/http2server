{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, identity, tls, x509
notes:
  - This unit holds the identity of a verified client certificate. The record
    is immutable once built, so one reference is shared by every stream of a
    connection and by a WebSocket session without a lock.
  - The reader takes the certificate from the SSL object of one connection and
    never from the shared TNetTlsContext record.
---
}
/// The identity of a verified TLS client certificate
unit Http2Server.ClientCert;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils,
  mormot.core.base, mormot.net.sock, mormot.lib.openssl11,
  Http2Server.Mtls.Types;

type
  /// the identity of a client certificate; read-only
  IClientCertificate = interface
    ['{7E1F0C11-00E1-4A11-9C72-000000002001}']
    function GetSubjectDn: string;
    function GetIssuerDn: string;
    function GetCommonName: string;
    function GetSerialHex: string;
    function GetSha256: string;
    function GetSanDns: TArray<string>;
    function GetSanUri: TArray<string>;
    function GetSanEmail: TArray<string>;
    function GetNotBefore: TDateTime;
    function GetNotAfter: TDateTime;
    function GetPem: string;
    function GetPrincipalText: string;
    /// the subject distinguished name as text
    property SubjectDn: string read GetSubjectDn;
    /// the issuer distinguished name as text
    property IssuerDn: string read GetIssuerDn;
    /// the first common name of the subject, or empty
    property CommonName: string read GetCommonName;
    /// the serial number in upper-case hexadecimal
    property SerialHex: string read GetSerialHex;
    /// the SHA-256 fingerprint of the certificate in lower-case hexadecimal
    property Sha256: string read GetSha256;
    /// the DNS names of the subject alternative name extension
    property SanDns: TArray<string> read GetSanDns;
    /// the URI names of the subject alternative name extension
    property SanUri: TArray<string> read GetSanUri;
    /// the e-mail names of the subject alternative name extension
    property SanEmail: TArray<string> read GetSanEmail;
    /// the start of the validity period, in UTC
    property NotBefore: TDateTime read GetNotBefore;
    /// the end of the validity period, in UTC
    property NotAfter: TDateTime read GetNotAfter;
    /// the leaf certificate in PEM form
    property Pem: string read GetPem;
    /// the text that the principal setting made of this certificate
    property PrincipalText: string read GetPrincipalText;
  end;

  /// what the connection events use to give an exchange its client certificate
  IClientCertificateSink = interface
    ['{7E1F0C11-00E2-4A11-9C72-000000002002}']
    procedure SetClientCertificate(const AValue: IClientCertificate);
  end;

  /// the plain values of a client certificate
  TClientCertificateData = record
    SubjectDn, IssuerDn, CommonName, SerialHex, Sha256, Pem: string;
    SanDns, SanUri, SanEmail: TArray<string>;
    NotBefore, NotAfter: TDateTime;
    PrincipalText: string;
  end;

/// the identity object of plain values
function NewClientCertificate(
  const AData: TClientCertificateData): IClientCertificate;

/// the identity of a loaded X509 certificate; the caller keeps its reference
function ClientCertificateFromX509(const AX509: PX509;
  const APrincipal: TClientCertPrincipal): IClientCertificate;

/// the identity of the peer of one finished TLS handshake
// - answers nil when there is no TLS instance, no peer certificate, or when
//   the chain did not verify (SSL_get_verify_result is not X509_V_OK)
function ReadClientCertificate(const ATls: INetTls;
  const APrincipal: TClientCertPrincipal): IClientCertificate;

implementation

type
  TClientCertificateImpl = class(TInterfacedObject, IClientCertificate)
  private
    FData: TClientCertificateData;
  public
    constructor Create(const AData: TClientCertificateData);
    function GetSubjectDn: string;
    function GetIssuerDn: string;
    function GetCommonName: string;
    function GetSerialHex: string;
    function GetSha256: string;
    function GetSanDns: TArray<string>;
    function GetSanUri: TArray<string>;
    function GetSanEmail: TArray<string>;
    function GetNotBefore: TDateTime;
    function GetNotAfter: TDateTime;
    function GetPem: string;
    function GetPrincipalText: string;
  end;

constructor TClientCertificateImpl.Create(const AData: TClientCertificateData);
begin
  inherited Create;
  FData := AData;
end;

function TClientCertificateImpl.GetSubjectDn: string;
begin
  Result := FData.SubjectDn;
end;

function TClientCertificateImpl.GetIssuerDn: string;
begin
  Result := FData.IssuerDn;
end;

function TClientCertificateImpl.GetCommonName: string;
begin
  Result := FData.CommonName;
end;

function TClientCertificateImpl.GetSerialHex: string;
begin
  Result := FData.SerialHex;
end;

function TClientCertificateImpl.GetSha256: string;
begin
  Result := FData.Sha256;
end;

function TClientCertificateImpl.GetSanDns: TArray<string>;
begin
  Result := Copy(FData.SanDns);
end;

function TClientCertificateImpl.GetSanUri: TArray<string>;
begin
  Result := Copy(FData.SanUri);
end;

function TClientCertificateImpl.GetSanEmail: TArray<string>;
begin
  Result := Copy(FData.SanEmail);
end;

function TClientCertificateImpl.GetNotBefore: TDateTime;
begin
  Result := FData.NotBefore;
end;

function TClientCertificateImpl.GetNotAfter: TDateTime;
begin
  Result := FData.NotAfter;
end;

function TClientCertificateImpl.GetPem: string;
begin
  Result := FData.Pem;
end;

function TClientCertificateImpl.GetPrincipalText: string;
begin
  Result := FData.PrincipalText;
end;

function NewClientCertificate(
  const AData: TClientCertificateData): IClientCertificate;
begin
  Result := TClientCertificateImpl.Create(AData);
end;

/// split the general names of a SAN list by their type prefix
procedure SplitSan(const ANames: TRawUtf8DynArray;
  out ADns, AUri, AEmail: TArray<string>);
var
  i: Integer;
  Name: string;

  procedure Add(var AList: TArray<string>; const AValue: string);
  begin
    SetLength(AList, Length(AList) + 1);
    AList[High(AList)] := AValue;
  end;

begin
  ADns := nil;
  AUri := nil;
  AEmail := nil;
  for i := 0 to High(ANames) do
  begin
    Name := string(ANames[i]);
    if Copy(Name, 1, 4) = 'DNS:' then
      Add(ADns, Copy(Name, 5, MaxInt))
    else if Copy(Name, 1, 4) = 'URI:' then
      Add(AUri, Copy(Name, 5, MaxInt))
    else if Copy(Name, 1, 6) = 'email:' then
      Add(AEmail, Copy(Name, 7, MaxInt));
    // any other entry is dropped: mORMot2 splits the text of an address name
    // (IP Address:...) at the blank, and the record keeps no address field
  end;
end;

function ClientCertificateFromX509(const AX509: PX509;
  const APrincipal: TClientCertPrincipal): IClientCertificate;
var
  D: TClientCertificateData;
  One: PX509DynArray;
begin
  Result := nil;
  if AX509 = nil then
    Exit;
  D.SubjectDn := string(AX509^.SubjectName);
  D.IssuerDn := string(AX509^.IssuerName);
  D.CommonName := string(AX509^.GetSubject('CN'));
  D.SerialHex := UpperCase(StringReplace(string(AX509^.SerialNumber), ':', '',
    [rfReplaceAll]));
  D.Sha256 := LowerCase(string(AX509^.FingerPrint(EVP_sha256)));
  SplitSan(AX509^.SubjectAlternativeNames(False), D.SanDns, D.SanUri,
    D.SanEmail);
  D.NotBefore := AX509^.NotBefore;
  D.NotAfter := AX509^.NotAfter;
  SetLength(One, 1);
  One[0] := AX509;
  D.Pem := string(PX509DynArrayToPem(One));
  D.PrincipalText := PrincipalTextFor(APrincipal, D.SubjectDn, D.CommonName);
  Result := NewClientCertificate(D);
end;

function ReadClientCertificate(const ATls: INetTls;
  const APrincipal: TClientCertPrincipal): IClientCertificate;
var
  Ssl: PSSL;
  Peer: PX509;
begin
  Result := nil;
  if ATls = nil then
    Exit;
  Ssl := PSSL(ATls.GetRawTls);
  if Ssl = nil then
    Exit;
  Peer := Ssl^.PeerCertificate;     // takes a reference; Free releases it
  if Peer = nil then
    Exit;
  try
    // OpenSSL ends a handshake whose chain failed, so a connection that got
    // here verified. The check is one call and keeps the rule explicit
    if SSL_get_verify_result(Ssl) <> 0 then
      Exit;
    Result := ClientCertificateFromX509(Peer, APrincipal);
  finally
    Peer^.Free;
  end;
end;

end.
