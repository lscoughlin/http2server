{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: rfc 8441, extended connect, settings, validation, protocol, test, fpcunit
notes:
  - This unit tests the pseudo-header :protocol in the request validator and the
    SETTINGS_ENABLE_CONNECT_PROTOCOL setting in the frame codec.
  - RFC 8441 and RFC 9113 were checked on 2026-10-22 at
    https://www.rfc-editor.org/info/rfc8441 and https://www.rfc-editor.org/info/rfc9113.
---
}
/// Tests of the extended CONNECT rules
unit Http2Server.ConnectProtocol.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2Server.Hpack, Http2Server.Frames, Http2Server.RequestValidation;

type
  TConnectProtocolTest = class(TTestCase)
  private
    function Block(const AMethod: string; const AProtocol: string = '';
      const AWithAuthority: Boolean = True): THeaderBlock;
  published
    procedure TestProtocolIsLegalOnlyWithTheSetting;
    procedure TestProtocolNeedsConnect;
    procedure TestProtocolNeedsAuthority;
    procedure TestProtocolTwiceIsMalformed;
    procedure TestEmptyProtocolIsMalformed;
    procedure TestProtocolAfterARegularFieldIsMalformed;
    procedure TestProtocolWithoutPathIsMalformed;
    procedure TestConnectWithoutProtocolKeepsItsBehaviour;
    procedure TestSettingsCarryTheCodeOnlyWhenSet;
    procedure TestSettingsDecodeAcceptsTheCode;
  end;

implementation

function TConnectProtocolTest.Block(const AMethod, AProtocol: string;
  const AWithAuthority: Boolean): THeaderBlock;
var
  N: Integer;

  procedure Add(const AName, AValue: string);
  begin
    SetLength(Result, N + 1);
    Result[N].Name := AName;
    Result[N].Value := AValue;
    Inc(N);
  end;

begin
  Result := nil;
  N := 0;
  Add(':method', AMethod);
  Add(':scheme', 'https');
  Add(':path', '/chat');
  if AWithAuthority then
    Add(':authority', 'example.test');
  if AProtocol <> '' then
    Add(':protocol', AProtocol);
end;

procedure TConnectProtocolTest.TestProtocolIsLegalOnlyWithTheSetting;
begin
  AssertTrue(ValidateRequestHeaders(Block('CONNECT', 'websocket'), False, True).Valid);
  AssertTrue(ValidateRequestHeaders(Block('CONNECT', 'websocket'), False, True).IsExtendedConnect);
  AssertFalse('without the setting', ValidateRequestHeaders(Block('CONNECT', 'websocket'), False, False).Valid);
  AssertFalse('the default is off', ValidateRequestHeaders(Block('CONNECT', 'websocket'), False).Valid);
end;

procedure TConnectProtocolTest.TestProtocolNeedsConnect;
begin
  AssertFalse(ValidateRequestHeaders(Block('GET', 'websocket'), False, True).Valid);
  AssertFalse(ValidateRequestHeaders(Block('POST', 'websocket'), False, True).Valid);
end;

procedure TConnectProtocolTest.TestProtocolNeedsAuthority;
begin
  AssertFalse(ValidateRequestHeaders(Block('CONNECT', 'websocket', False), False, True).Valid);
end;

procedure TConnectProtocolTest.TestProtocolTwiceIsMalformed;
var
  B: THeaderBlock;
begin
  B := Block('CONNECT', 'websocket');
  SetLength(B, Length(B) + 1);
  B[High(B)].Name := ':protocol';
  B[High(B)].Value := 'websocket';
  AssertFalse(ValidateRequestHeaders(B, False, True).Valid);
end;

procedure TConnectProtocolTest.TestEmptyProtocolIsMalformed;
var
  B: THeaderBlock;
begin
  B := Block('CONNECT');
  SetLength(B, Length(B) + 1);
  B[High(B)].Name := ':protocol';
  B[High(B)].Value := '';
  AssertFalse(ValidateRequestHeaders(B, False, True).Valid);
end;

procedure TConnectProtocolTest.TestProtocolAfterARegularFieldIsMalformed;
var
  B: THeaderBlock;
begin
  B := Block('CONNECT');
  SetLength(B, Length(B) + 2);
  B[High(B) - 1].Name := 'sec-websocket-version';
  B[High(B) - 1].Value := '13';
  B[High(B)].Name := ':protocol';
  B[High(B)].Value := 'websocket';
  AssertFalse(ValidateRequestHeaders(B, False, True).Valid);
end;

procedure TConnectProtocolTest.TestProtocolWithoutPathIsMalformed;
var
  B: THeaderBlock;
begin
  B := Block('CONNECT', 'websocket');
  B[2].Name := ':x-removed';
  AssertFalse(ValidateRequestHeaders(B, False, True).Valid);
end;

procedure TConnectProtocolTest.TestConnectWithoutProtocolKeepsItsBehaviour;
begin
  // the decision of 2026-10-22: a CONNECT with :scheme and :path and no :protocol passes
  AssertTrue(ValidateRequestHeaders(Block('CONNECT'), False, True).Valid);
  AssertFalse(ValidateRequestHeaders(Block('CONNECT'), False, True).IsExtendedConnect);
  AssertTrue(ValidateRequestHeaders(Block('CONNECT'), False, False).Valid);
end;

procedure TConnectProtocolTest.TestSettingsCarryTheCodeOnlyWhenSet;
var
  S: TConnectionSettings;
begin
  S := TConnectionSettings.Defaults;
  AssertEquals('six entries by default', 6 * SettingsEntrySize, Length(S.Encode));
  S.EnableConnectProtocol := True;
  AssertEquals('seven entries with the setting', 7 * SettingsEntrySize, Length(S.Encode));
  AssertEquals('the code is 8', 8, S.Encode[6 * SettingsEntrySize + 1]);
  AssertEquals('the value is 1', 1, S.Encode[6 * SettingsEntrySize + 5]);
end;

procedure TConnectProtocolTest.TestSettingsDecodeAcceptsTheCode;
var
  S: TConnectionSettings;
begin
  S := TConnectionSettings.Defaults;
  S.EnableConnectProtocol := True;
  AssertTrue(TConnectionSettings.Decode(S.Encode).EnableConnectProtocol);
  AssertFalse(TConnectionSettings.Decode(TConnectionSettings.Defaults.Encode).EnableConnectProtocol);
end;

initialization
  RegisterTest(TConnectProtocolTest);

end.
