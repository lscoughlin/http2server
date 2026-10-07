{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, alpn, tls, test
notes:
  - Tests for the ALPN protocol decision rule of Http2Server.Alpn.
  - The decision rule is a pure function, so the tests need no TLS
    handshake and no network.
  - The wire format under test is the vector of 8-bit length-prefixed byte
    strings that the OpenSSL manual page SSL_CTX_set_alpn_select_cb(3ssl)
    describes.
---
}
/// ALPN protocol selection tests for Http2Server.Alpn
unit Http2Server.Alpn.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2Server.Alpn;

type
  TAlpnSelectTest = class(TTestCase)
  published
    /// a lone h2 entry is chosen
    procedure TestSelectsH2Alone;
    /// h2 wins wherever it sits in the list
    procedure TestSelectsH2FromAMultiEntryList;
    /// h2 wins over a later http/1.1 entry
    procedure TestPrefersH2OverHttp11;
    /// a lone http/1.1 entry is refused when the fallback is off
    procedure TestRefusesHttp11WhenTheFallbackIsOff;
    /// a lone http/1.1 entry is chosen when the fallback is on
    procedure TestAcceptsHttp11WhenTheFallbackIsOn;
    /// a list with no acceptable protocol is refused
    procedure TestRefusesAListWithNoAcceptableProtocol;
    /// a zero length entry is malformed
    procedure TestRefusesAZeroLengthEntry;
    /// a truncated entry is malformed
    procedure TestRefusesATruncatedEntry;
    /// an empty list is refused
    procedure TestRefusesAnEmptyList;
    /// the chosen name matches the entry inside the list
    procedure TestChosenNameMatchesTheEntry;
  end;

implementation

/// encode a protocol list in the wire format
function ProtoList(const ANames: array of string): TBytes;
var
  I, N, P: Integer;
begin
  Result := nil;
  N := 0;
  for I := Low(ANames) to High(ANames) do
    Inc(N, 1 + Length(ANames[I]));
  SetLength(Result, N);
  P := 0;
  for I := Low(ANames) to High(ANames) do
  begin
    Result[P] := Length(ANames[I]);
    Inc(P);
    if Length(ANames[I]) > 0 then
    begin
      Move(ANames[I][1], Result[P], Length(ANames[I]));
      Inc(P, Length(ANames[I]));
    end;
  end;
end;

procedure TAlpnSelectTest.TestSelectsH2Alone;
begin
  AssertEquals('h2 alone is chosen', 'h2',
    Http2AlpnSelectProtocol(ProtoList(['h2']), False));
  AssertTrue('offset is past the length octet',
    Http2AlpnSelectOffset(ProtoList(['h2']), False) = 1);
end;

procedure TAlpnSelectTest.TestSelectsH2FromAMultiEntryList;
var
  List: TBytes;
begin
  List := ProtoList(['http/1.0', 'h2', 'http/1.1']);
  AssertEquals('h2 in the middle wins', 'h2',
    Http2AlpnSelectProtocol(List, False));
  AssertEquals('offset points at the h2 entry', 10,
    Http2AlpnSelectOffset(List, False));
end;

procedure TAlpnSelectTest.TestPrefersH2OverHttp11;
begin
  AssertEquals('a leading h2 wins over a later http/1.1', 'h2',
    Http2AlpnSelectProtocol(ProtoList(['h2', 'http/1.1']), True));
end;

procedure TAlpnSelectTest.TestRefusesHttp11WhenTheFallbackIsOff;
begin
  AssertEquals('http/1.1 is refused with the fallback off', '',
    Http2AlpnSelectProtocol(ProtoList(['http/1.1']), False));
  AssertEquals('the offset is -1', -1,
    Http2AlpnSelectOffset(ProtoList(['http/1.1']), False));
end;

procedure TAlpnSelectTest.TestAcceptsHttp11WhenTheFallbackIsOn;
begin
  AssertEquals('http/1.1 is chosen with the fallback on', 'http/1.1',
    Http2AlpnSelectProtocol(ProtoList(['http/1.1']), True));
end;

procedure TAlpnSelectTest.TestRefusesAListWithNoAcceptableProtocol;
begin
  AssertEquals('spdy/3 is refused', '',
    Http2AlpnSelectProtocol(ProtoList(['spdy/3', 'http/1.0']), True));
end;

procedure TAlpnSelectTest.TestRefusesAZeroLengthEntry;
var
  List: TBytes;
begin
  List := nil;
  SetLength(List, 3);
  List[0] := 0;      // a zero length entry
  List[1] := 2;
  List[2] := Ord('h');
  AssertEquals('a zero length entry is malformed', '',
    Http2AlpnSelectProtocol(List, True));
end;

procedure TAlpnSelectTest.TestRefusesATruncatedEntry;
var
  List: TBytes;
begin
  List := nil;
  SetLength(List, 3);
  List[0] := 8;      // claims eight octets, only two follow
  List[1] := Ord('h');
  List[2] := Ord('2');
  AssertEquals('a truncated entry is malformed', '',
    Http2AlpnSelectProtocol(List, True));
end;

procedure TAlpnSelectTest.TestRefusesAnEmptyList;
begin
  AssertEquals('an empty list is refused', '',
    Http2AlpnSelectProtocol(nil, True));
  AssertEquals('the offset of an empty list is -1', -1,
    Http2AlpnSelectOffset(nil, True));
end;

procedure TAlpnSelectTest.TestChosenNameMatchesTheEntry;
var
  List: TBytes;
begin
  List := ProtoList(['spdy/3', 'h2']);
  AssertEquals('the name is taken from the list itself', 'h2',
    Http2AlpnSelectProtocol(List, False));
  AssertEquals('its offset is the length octet position plus one', 8,
    Http2AlpnSelectOffset(List, False));
end;

initialization
  RegisterTest(TAlpnSelectTest);

end.
