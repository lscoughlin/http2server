{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, live, leak, x509, reference count, ex_data
notes:
  - This unit counts the X509 objects of the process that are alive. OpenSSL
    calls a registered ex_data callback when it creates an X509 and when it
    frees one, so the count needs no change to the code under test.
  - The live run takes the count after a warm-up, runs a few handshakes and
    checks that the count returns to the same value. A reference that the
    identity reader forgot to release keeps one X509 alive per handshake.
  - Only objects created after the install are counted. The run never frees an
    older object in the measured window.
---
}
/// A live count of X509 objects, for the leak check of the identity reader
unit Http2Server.Mtls.Live.Leak;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

/// register the counters with libcrypto; FALSE when the entry point is absent
function InstallX509Counter: Boolean;

/// the X509 objects created and not yet freed since the install
function LiveX509: Integer;

/// the X509 objects created since the install
function CreatedX509: Integer;

implementation

uses
  SysUtils,
  mormot.core.base, mormot.core.os, mormot.lib.openssl11;

type
  TExCallback = procedure(parent, ptr, ad: pointer; idx: Integer;
    argl: PtrInt; argp: pointer); cdecl;
  TGetExNewIndex = function(classIndex: Integer; argl: PtrInt; argp: pointer;
    newFunc, dupFunc: pointer; freeFunc: TExCallback): Integer; cdecl;

const
  // CRYPTO_EX_INDEX_X509 of openssl/crypto.h
  cExIndexX509 = 3;

var
  GLive, GCreated: Integer;
  GLib: TSynLibrary;
  GGetIndex: TGetExNewIndex;

procedure OnNew(parent, ptr, ad: pointer; idx: Integer; argl: PtrInt;
  argp: pointer); cdecl;
begin
  InterlockedIncrement(GLive);
  InterlockedIncrement(GCreated);
end;

procedure OnFree(parent, ptr, ad: pointer; idx: Integer; argl: PtrInt;
  argp: pointer); cdecl;
begin
  InterlockedDecrement(GLive);
end;

function InstallX509Counter: Boolean;
var
  Dir: TFileName;
  Err: string;
begin
  Result := False;
  OpenSslIsAvailable;
  Dir := GetSystemEnvString('OPENSSL_LIBPATH');
  if (Dir <> '') and DirectoryExists(Dir) then
    Dir := IncludeTrailingPathDelimiter(Dir)
  else
    Dir := '';
  GLib := TSynLibrary.Create;
  if not GLib.TryLoadLibrary([Dir + LIB_CRYPTO4, Dir + LIB_CRYPTO3,
           Dir + LIB_CRYPTO1], nil, @Err) then
    Exit;
  if not GLib.Resolve(_PU, 'CRYPTO_get_ex_new_index', @@GGetIndex, nil, @Err) then
    Exit;
  Result := GGetIndex(cExIndexX509, 0, nil, @OnNew, nil, @OnFree) >= 0;
end;

function LiveX509: Integer;
begin
  Result := GLive;
end;

function CreatedX509: Integer;
begin
  Result := GCreated;
end;

end.
