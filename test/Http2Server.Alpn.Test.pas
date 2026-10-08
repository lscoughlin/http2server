{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, alpn, tls, test
notes:
  - Tests for the ALPN protocol decision rule of Http2Server.Alpn.
  - The decision rule is a pure function, so most tests need no TLS
    handshake and no network.
  - The callback tests drive the OpenSSL callback directly, because the
    pointer it reports into the client list is where the wire format is
    easiest to get wrong.
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
    /// the callback reports a pointer at the name octets, not the length
    procedure TestCallbackPointsAtTheNameOctets;
    /// the callback reports the length of the chosen name
    procedure TestCallbackReportsTheNameLength;
    /// the callback refuses a list with no acceptable protocol
    procedure TestCallbackRefusesAnUnacceptableList;
    /// the callback survives a nil protocol list
    procedure TestCallbackRefusesANilList;
  end;

implementation

const
  SSL_TLSEXT_ERR_OK = 0;
  SSL_TLSEXT_ERR_ALERT_FATAL = 2;

type
  /// the policy record the callback reads from its argument
  TAlpnTestPolicy = record
    AllowHttp11: Boolean;
  end;

var
  /// a policy that permits the http/1.1 fallback
  FallbackPolicy: TAlpnTestPolicy;

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
  AssertTrue('offset points past the length octet',
    Http2AlpnSelectOffset(ProtoList(['h2']), False) = 1);
end;

procedure TAlpnSelectTest.TestSelectsH2FromAMultiEntryList;
var
  List: TBytes;
begin
  List := ProtoList(['http/1.0', 'h2', 'http/1.1']);
  AssertEquals('h2 in the middle wins', 'h2',
    Http2AlpnSelectProtocol(List, False));
  AssertEquals('the offset is the position of the first name octet', 10,
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
  AssertEquals('the offset of a refused list is -1', -1,
    Http2AlpnSelectOffset(ProtoList(['http/1.1']), False));
end;

procedure TAlpnSelectTest.TestAcceptsHttp11WhenTheFallbackIsOn;
begin
  AssertEquals('http/1.1 is chosen with the fallback on', 'http/1.1',
    Http2AlpnSelectProtocol(ProtoList(['http/1.1']), True));
end;

procedure TAlpnSelectTest.TestRefusesAListWithNoAcceptableProtocol;
begin
  AssertEquals('spdy/3 is refused even with the fallback on', '',
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
  AssertEquals('the offset is the position of the first name octet', 8,
    Http2AlpnSelectOffset(List, False));
end;

procedure TAlpnSelectTest.TestCallbackPointsAtTheNameOctets;
var
  List: TBytes;
  Out_: PByte;
  OutLen: Byte;
  Res: Integer;
begin
  List := ProtoList(['spdy/3', 'h2']);
  Out_ := nil;
  OutLen := 0;
  Res := Http2AlpnSelectCallback(nil, @Out_, @OutLen, @List[0], Length(List), nil);
  AssertEquals('the callback accepts the list', SSL_TLSEXT_ERR_OK, Res);
  AssertEquals('the reported length is the name length', 2, OutLen);
  AssertEquals('the reported pointer starts at the first name octet',
    Ord('h'), Out_^);
  AssertEquals('the next octet follows it', Ord('2'), (Out_ + 1)^);
end;

procedure TAlpnSelectTest.TestCallbackReportsTheNameLength;
var
  List: TBytes;
  Out_: PByte;
  OutLen: Byte;
begin
  List := ProtoList(['http/1.0', 'http/1.1']);
  Out_ := nil;
  OutLen := 0;
  AssertEquals('the h2-only policy refuses the list',
    SSL_TLSEXT_ERR_ALERT_FATAL,
    Http2AlpnSelectCallback(nil, @Out_, @OutLen, @List[0], Length(List), nil));
  Out_ := nil;
  OutLen := 0;
  AssertEquals('the fallback policy accepts http/1.1',
    SSL_TLSEXT_ERR_OK,
    Http2AlpnSelectCallback(nil, @Out_, @OutLen, @List[0], Length(List),
      @FallbackPolicy));
  AssertEquals('the reported length is the full name', 8, OutLen);
  AssertEquals('the reported pointer starts at the first name octet',
    Ord('h'), Out_^);
end;

procedure TAlpnSelectTest.TestCallbackRefusesAnUnacceptableList;
var
  List: TBytes;
  Out_: PByte;
  OutLen: Byte;
begin
  List := ProtoList(['spdy/3']);
  Out_ := nil;
  OutLen := 0;
  AssertEquals('spdy/3 is refused with a fatal alert',
    SSL_TLSEXT_ERR_ALERT_FATAL,
    Http2AlpnSelectCallback(nil, @Out_, @OutLen, @List[0], Length(List), nil));
  AssertTrue('no protocol is reported', Out_ = nil);
  AssertEquals('the reported length is zero', 0, OutLen);
end;

procedure TAlpnSelectTest.TestCallbackRefusesANilList;
var
  Out_: PByte;
  OutLen: Byte;
begin
  Out_ := nil;
  OutLen := 0;
  AssertEquals('a nil list is refused with a fatal alert',
    SSL_TLSEXT_ERR_ALERT_FATAL,
    Http2AlpnSelectCallback(nil, @Out_, @OutLen, nil, 0, nil));
end;

initialization
  FallbackPolicy.AllowHttp11 := True;
  RegisterTest(TAlpnSelectTest);

end.
