{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: alpn, tls, openssl
notes:
  - binds the OpenSSL SSL_CTX_set_alpn_select_cb entry point of libssl
  - the callback selects h2 and refuses a client that does not offer it
  - the mORMot2 libssl handle is private, so libssl is loaded a second time
  - the protocol decision is a separate pure function, so a test reaches
    every branch without a TLS handshake
---
}
unit Http2Server.Alpn;

interface

uses
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.lib.openssl11,
  mormot.net.sock;

type
  /// the OpenSSL ALPN select callback type
  // - signature taken from the OpenSSL manual page
  // SSL_CTX_set_alpn_select_cb(3ssl), read 2026-10-07
  // - out_ receives a pointer into the client protocol list, or into a buffer
  // that outlives the handshake; outlen receives its length in bytes
  TAlpnSelectCb = function(ssl: PSSL; out_: PPByte; outlen: PByte;
    in_: PByte; inlen: cardinal; arg: pointer): integer; cdecl;

  /// the SSL_CTX_set_alpn_select_cb() entry point of libssl
  TSslCtxSetAlpnSelectCb = procedure(ctx: PSSL_CTX; cb: TAlpnSelectCb;
    arg: pointer); cdecl;

/// the OpenSSL ALPN select callback that Http2AlpnAttachCtx installs
// - exposed so a test drives the callback directly with a synthetic client
// protocol list, which is where the pointer arithmetic into in_ lives
// - arg points at a TAlpnServerPolicy, or is nil for the h2-only policy
function Http2AlpnSelectCallback(ssl: PSSL; out_: PPByte; outlen: PByte;
  in_: PByte; inlen: cardinal; arg: pointer): integer; cdecl;

/// the ALPN protocol name that the last handshake selected on this SSL
// - returns '' when no protocol was selected
function Http2AlpnSelected(ssl: PSSL): RawUtf8;

/// find the acceptable protocol in a client ALPN list, in wire format
// - the wire format is a vector of 8-bit length-prefixed byte strings,
// as the OpenSSL manual page SSL_CTX_set_alpn_select_cb(3ssl) states
// - returns the offset of the chosen entry inside AClientList, or -1 when
// the list offers no acceptable protocol; a malformed list also returns -1
// - this is the whole decision rule of the ALPN callback, kept free of
// OpenSSL so a test reaches every branch without a handshake
function Http2AlpnSelectOffset(const AClientList: TBytes;
  const AAllowHttp11: boolean): Integer;

/// the name of the protocol that Http2AlpnSelectOffset chose, or ''
function Http2AlpnSelectProtocol(const AClientList: TBytes;
  const AAllowHttp11: boolean): RawUtf8;

/// TRUE when SSL_CTX_set_alpn_select_cb was resolved from libssl
// - loads libssl on the first call, with the same path rules as mORMot2:
// the OPENSSL_LIBPATH environment variable, then the default library names
function Http2AlpnBindingAvailable: boolean;

/// install the h2 select callback on a server SSL_CTX
// - returns FALSE when the SSL_CTX is nil or when the entry point is missing
// - allowHttp11 permits the fallback protocol; the spike keeps it FALSE
function Http2AlpnAttachCtx(ctx: PSSL_CTX; allowHttp11: boolean = false): boolean;

/// install the h2 select callback on the SSL_CTX of a bound TCrtSocket
// - the bound socket holds the server context in its public TLS record, as
// stored by INetTls.AfterBind in the AcceptCert field
function Http2AlpnAttach(const bound: TCrtSocket;
  allowHttp11: boolean = false): boolean;

implementation

const
  ALPN_SELECT_CB_NAME = 'SSL_CTX_set_alpn_select_cb';
  OPENSSL_LIBPATH_NAME = 'OPENSSL_LIBPATH';

type
  /// the protocol policy handed to OpenSSL as the callback argument
  // - the record has a process lifetime, as the manual page requires of the
  // callback argument, and it outlives every handshake
  TAlpnServerPolicy = record
    AllowHttp11: boolean;
  end;

var
  fPolicy: TAlpnServerPolicy;
  fLibSsl: TSynLibrary;
  fSetAlpnSelectCb: TSslCtxSetAlpnSelectCb;

function Http2AlpnSelectOffset(const AClientList: TBytes;
  const AAllowHttp11: boolean): Integer;
var
  p, n: Integer;

  function EntryIs(const AName: RawUtf8): Boolean;
  var
    I: Integer;
  begin
    result := n = length(AName);
    if not result then
      exit;
    for I := 1 to n do
      if AClientList[p + I - 1] <> Ord(AName[I]) then
      begin
        result := false;
        exit;
      end;
  end;

begin
  result := -1;
  p := 0;
  while p < length(AClientList) do
  begin
    // the wire format is a vector of 8-bit length-prefixed byte strings
    n := AClientList[p];
    inc(p);
    if n = 0 then
      exit; // a zero length entry is malformed
    if n > length(AClientList) - p then
      exit; // a truncated entry is malformed
    if EntryIs('h2') then
    begin
      result := p;
      exit;
    end;
    if AAllowHttp11 and
       EntryIs('http/1.1') then
    begin
      result := p;
      exit;
    end;
    inc(p, n);
  end;
end;

function Http2AlpnSelectProtocol(const AClientList: TBytes;
  const AAllowHttp11: boolean): RawUtf8;
var
  offset, n: Integer;
begin
  result := '';
  offset := Http2AlpnSelectOffset(AClientList, AAllowHttp11);
  if offset < 0 then
    exit;
  n := AClientList[offset - 1];
  SetLength(result, n);
  Move(AClientList[offset], result[1], n);
end;

function Http2AlpnSelectCallback(ssl: PSSL; out_: PPByte; outlen: PByte;
  in_: PByte; inlen: cardinal; arg: pointer): integer; cdecl;
var
  client: TBytes;
  offset: Integer;
  policy: ^TAlpnServerPolicy absolute arg;
begin
  // SSL_TLSEXT_ERR_ALERT_FATAL refuses the handshake with a fatal alert
  result := SSL_TLSEXT_ERR_ALERT_FATAL;
  try
    if (out_ = nil) or
       (outlen = nil) or
       (in_ = nil) or
       (inlen = 0) then
      exit;
    out_^ := nil;
    outlen^ := 0;
    SetLength(client, inlen);
    Move(in_^, client[0], inlen);
    offset := Http2AlpnSelectOffset(client,
      (policy <> nil) and policy^.AllowHttp11);
    if offset < 0 then
      exit;
    // the chosen entry lives inside in_, as the manual page permits;
    // offset is the first name octet, and the length octet sits before it
    out_^ := in_ + offset;
    outlen^ := client[offset - 1];
    result := SSL_TLSEXT_ERR_OK;
  except
    // an exception must never cross the OpenSSL callback boundary
    result := SSL_TLSEXT_ERR_ALERT_FATAL;
  end;
end;

function Http2AlpnSelected(ssl: PSSL): RawUtf8;
var
  data: PByte;
  len: cardinal;
begin
  result := '';
  if ssl = nil then
    exit;
  data := nil;
  len := 0;
  SSL_get0_alpn_selected(ssl, @data, @len);
  if (data = nil) or
     (len = 0) then
    exit;
  SetLength(result, len);
  Move(data^, result[1], len);
end;

function Http2AlpnBindingAvailable: boolean;
var
  dir, name1, name3, name4: TFileName;
  err: string;
begin
  result := Assigned(fSetAlpnSelectCb);
  if result then
    exit;
  result := false;
  GlobalLock;
  try
    if Assigned(fSetAlpnSelectCb) then
    begin
      result := true;
      exit;
    end;
    dir := GetSystemEnvString(OPENSSL_LIBPATH_NAME);
    if dir <> '' then
      if DirectoryExists(dir) then
        dir := IncludeTrailingPathDelimiter(dir)
      else
        dir := '';
    name4 := dir + LIB_SSL4;  // OpenSSL 4.x
    name3 := dir + LIB_SSL3;  // OpenSSL 3.x
    name1 := dir + LIB_SSL1;  // OpenSSL 1.1
    fLibSsl := TSynLibrary.Create;
    if not fLibSsl.TryLoadLibrary([name4, name3, name1], nil, @err) then
    begin
      FreeAndNil(fLibSsl);
      exit;
    end;
    if not fLibSsl.Resolve(_PU, ALPN_SELECT_CB_NAME,
             @@fSetAlpnSelectCb, nil, @err) then
    begin
      FreeAndNil(fLibSsl);
      exit;
    end;
    result := Assigned(fSetAlpnSelectCb);
  finally
    GlobalUnLock;
  end;
end;

function Http2AlpnAttachCtx(ctx: PSSL_CTX; allowHttp11: boolean): boolean;
begin
  result := false;
  if ctx = nil then
    exit;
  if not Http2AlpnBindingAvailable then
    exit;
  fPolicy.AllowHttp11 := allowHttp11;
  fSetAlpnSelectCb(ctx, Http2AlpnSelectCallback, @fPolicy);
  result := true;
end;

function Http2AlpnAttach(const bound: TCrtSocket; allowHttp11: boolean): boolean;
begin
  result := false;
  if bound = nil then
    exit;
  result := Http2AlpnAttachCtx(PSSL_CTX(bound.TLS.AcceptCert), allowHttp11);
end;

finalization
  FreeAndNil(fLibSsl);
end.
