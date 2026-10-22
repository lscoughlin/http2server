{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, origin, policy, rfc 6454, test vectors, fpcunit
notes:
  - This unit tests the origin policy with the vectors V1 to V81 of the research
    notes, grouped by the context of the server (scheme and authority).
  - The tolerant choices apply. A value in upper case is lowered before the compare,
    and an explicit default port equals the same origin without a port.
---
}
/// Unit tests for Http2Server.Ws.Origin and Http2Server.Ws.Options
unit Http2Server.Ws.Origin.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2Server.Ws.Origin, Http2Server.Ws.Options;

type
  TWsOriginTest = class(TTestCase)
  private
    procedure Expect(const AName: string; const AAccept: Boolean;
      const AScheme, AAuthority: string; const AValues: array of string;
      const APolicy: TWsOriginPolicy = opSameOrAbsent);
    function Check(const AScheme, AAuthority: string;
      const AValues: array of string): TWsOriginVerdict;
  published
    procedure TestContextA;
    procedure TestContextB;
    procedure TestContextC;
    procedure TestContextD;
    procedure TestContextE;
    procedure TestContextF;
    procedure TestAllowListPolicies;
    procedure TestAnyAndNonePassEverything;
    procedure TestRefusalStatuses;
    procedure TestOptionsDefaults;
    procedure TestOptionsValidation;
  end;

implementation

function Values(const A: array of string): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function TWsOriginTest.Check(const AScheme, AAuthority: string;
  const AValues: array of string): TWsOriginVerdict;
begin
  Result := WsCheckOrigin(opSameOrAbsent, nil, AScheme, AAuthority, Values(AValues));
end;

procedure TWsOriginTest.Expect(const AName: string; const AAccept: Boolean;
  const AScheme, AAuthority: string; const AValues: array of string;
  const APolicy: TWsOriginPolicy);
var
  V: TWsOriginVerdict;
begin
  V := WsCheckOrigin(APolicy, nil, AScheme, AAuthority, Values(AValues));
  AssertEquals(AName + ' (' + V.Reason + ')', AAccept, V.Accept);
end;

procedure TWsOriginTest.TestContextA;
const
  H = 'app.example.com';
begin
  Expect('V1', True, 'https', H, []);
  Expect('V2', True, 'https', H, ['https://app.example.com']);
  Expect('V3', True, 'https', H, ['https://app.example.com:443']);
  Expect('V4', True, 'https', H, ['HTTPS://APP.EXAMPLE.COM']);
  Expect('V5', True, 'https', H, ['https://App.Example.com']);
  Expect('V6', False, 'https', H, ['http://app.example.com']);
  Expect('V7', False, 'https', H, ['https://app.example.com:8443']);
  Expect('V8', False, 'https', H, ['https://example.com']);
  Expect('V9', False, 'https', H, ['https://www.app.example.com']);
  Expect('V10', False, 'https', H, ['https://app.example.com.evil.test']);
  Expect('V11', False, 'https', H, ['https://evil.test']);
  Expect('V12', False, 'https', H, ['https://evil.test/app.example.com']);
  Expect('V13', False, 'https', H, ['https://app.example.com/']);
  Expect('V14', False, 'https', H, ['https://app.example.com/path']);
  Expect('V15', False, 'https', H, ['https://app.example.com?x=1']);
  Expect('V16', False, 'https', H, ['https://user@app.example.com']);
  Expect('V17', False, 'https', H, ['null']);
  Expect('V18', False, 'https', H, ['NULL']);
  Expect('V19', False, 'https', H, ['']);
  Expect('V20', True, 'https', H, ['https://app.example.com https://app.example.com']);
  Expect('V21', False, 'https', H, ['https://app.example.com https://evil.test']);
  Expect('V22', False, 'https', H, ['https://evil.test https://app.example.com']);
  Expect('V23', False, 'https', H, ['https://app.example.com,https://evil.test']);
  Expect('V24', False, 'https', H, ['https://app.example.com  https://app.example.com']);
  Expect('V25', False, 'https', H, ['null https://app.example.com']);
  Expect('V26', True, 'https', H, [' https://app.example.com ']);
  Expect('V26 tab', True, 'https', H, [#9'https://app.example.com'#9]);
  Expect('V27', False, 'https', H, ['app.example.com']);
  Expect('V28', False, 'https', H, ['//app.example.com']);
  Expect('V29', False, 'https', H, ['https://']);
  Expect('V30', False, 'https', H, ['https://app.example.com:']);
  Expect('V31', False, 'https', H, ['https://app.example.com:0443']);
  Expect('V32', False, 'https', H, ['https://app.example.com:99999']);
  Expect('V33', False, 'https', H, ['https://app.example.com', 'https://app.example.com']);
  Expect('V34', False, 'https', H, ['chrome-extension://abcdef']);
  Expect('V35', False, 'https', H, ['file://']);
  Expect('V36', False, 'https', H, ['https://app'#$C3#$A9'.example.com']);
  Expect('V37', False, 'https', H, ['https://xn--app-example.com']);
  Expect('a fragment', False, 'https', H, ['https://app.example.com#x']);
  Expect('a backslash', False, 'https', H, ['https://app.example.com\evil']);
end;

procedure TWsOriginTest.TestContextB;
begin
  Expect('V40', True, 'https', 'app.example.com:8443', ['https://app.example.com:8443']);
  Expect('V41', False, 'https', 'app.example.com:8443', ['https://app.example.com']);
  Expect('V42', False, 'https', 'app.example.com:8443', ['https://app.example.com:443']);
end;

procedure TWsOriginTest.TestContextC;
begin
  Expect('V50', True, 'http', 'localhost:8080', ['http://localhost:8080']);
  Expect('V51', False, 'http', 'localhost:8080', ['https://localhost:8080']);
  Expect('V52', False, 'http', 'localhost:8080', ['http://localhost']);
  Expect('V53', False, 'http', 'localhost:8080', ['http://127.0.0.1:8080']);
  Expect('V54', True, 'http', 'localhost:8080', ['http://LOCALHOST:8080']);
end;

procedure TWsOriginTest.TestContextD;
begin
  Expect('V60', True, 'http', 'example.com', ['http://example.com']);
  Expect('V61', True, 'http', 'example.com', ['http://example.com:80']);
  Expect('V62', False, 'http', 'example.com', ['https://example.com:80']);
end;

procedure TWsOriginTest.TestContextE;
begin
  Expect('V70', True, 'https', '[::1]:8443', ['https://[::1]:8443']);
  Expect('V71', False, 'https', '[::1]:8443', ['https://[0:0:0:0:0:0:0:1]:8443']);
end;

procedure TWsOriginTest.TestContextF;
begin
  Expect('V80 empty host', False, 'https', '', ['https://app.example.com']);
  Expect('V80 bad host', False, 'https', 'a b', ['https://app.example.com']);
  // no Origin: accepted whatever the host
  Expect('no origin, no host', True, 'https', '', []);
end;

procedure TWsOriginTest.TestAllowListPolicies;
var
  Allowed: TArray<string>;
  V: TWsOriginVerdict;
begin
  Allowed := Values(['https://partner.example.org', 'http://localhost:3000']);
  V := WsCheckOrigin(opAllowList, Allowed, 'https', 'app.example.com', Values(['https://partner.example.org']));
  AssertTrue('an allow-list hit', V.Accept);
  V := WsCheckOrigin(opAllowList, Allowed, 'https', 'app.example.com', Values(['https://app.example.com']));
  AssertTrue('the origin of the server passes too', V.Accept);
  V := WsCheckOrigin(opAllowList, Allowed, 'https', 'app.example.com', Values(['https://evil.test']));
  AssertFalse('a miss', V.Accept);
  AssertEquals(403, V.Status);
  V := WsCheckOrigin(opAllowListOnly, Allowed, 'https', 'app.example.com', Values(['https://app.example.com']));
  AssertFalse('the origin of the server needs a list entry', V.Accept);
  V := WsCheckOrigin(opAllowListOnly, Allowed, 'https', 'app.example.com', Values(['http://LOCALHOST:3000']));
  AssertTrue('case does not matter in the list', V.Accept);
  V := WsCheckOrigin(opAllowListOnly, Allowed, 'https', 'app.example.com', nil);
  AssertTrue('an absent origin passes', V.Accept);
  V := WsCheckOrigin(opAllowList, Allowed, 'https', '', Values(['https://partner.example.org']));
  AssertTrue('the list needs no host of the server', V.Accept);
end;

procedure TWsOriginTest.TestAnyAndNonePassEverything;
begin
  Expect('any', True, 'https', 'a', ['https://evil.test'], opAny);
  Expect('any with garbage', True, 'https', 'a', ['not an origin'], opAny);
  Expect('none', True, 'https', 'a', ['null'], opNone);
end;

procedure TWsOriginTest.TestRefusalStatuses;
begin
  AssertEquals('a foreign origin is 403', 403,
    Check('https', 'a.example', ['https://b.example']).Status);
  AssertEquals('a malformed value is 400', 400,
    Check('https', 'a.example', ['https://a.example/x']).Status);
  AssertEquals('null is 403', 403, Check('https', 'a.example', ['null']).Status);
  AssertEquals('two fields are 400', 400,
    Check('https', 'a.example', ['https://a.example', 'https://a.example']).Status);
end;

procedure TWsOriginTest.TestOptionsDefaults;
var
  O: TWsOptions;
begin
  O := TWsOptions.Create;
  AssertEquals(Int64(1048576), O.MaxMessageSize);
  AssertEquals(Int64(65536), O.MaxFrameSize);
  AssertEquals(16, O.QueuedMessages);
  AssertEquals(30000, O.PingIntervalMs);
  AssertEquals(10000, O.PongTimeoutMs);
  AssertEquals(5000, O.CloseTimeoutMs);
  AssertEquals(10000, O.InitTimeoutMs);
  AssertTrue(O.OriginPolicy = opSameOrAbsent);
end;

procedure TWsOriginTest.TestOptionsValidation;
var
  O: TWsOptions;
  P: TArray<string>;

  function Count(const AOptions: TWsOptions): Integer;
  var
    L: TArray<string>;
  begin
    L := nil;
    AOptions.Problems(L);
    Result := Length(L);
  end;

begin
  O := TWsOptions.Create;
  AssertEquals('the defaults are valid', 0, Count(O));
  AssertEquals(1, Count(O.WithMaxMessageSize(0)));
  AssertEquals(1, Count(O.WithQueuedMessages(0)));
  AssertEquals(1, Count(O.WithPingIntervalMs(-1)));
  AssertEquals('the ping can be off', 0, Count(O.WithPingIntervalMs(0)));
  AssertEquals(1, Count(O.WithPongTimeoutMs(0)));
  AssertEquals('a bad allow-list entry', 1, Count(O.WithAllowedOrigins(Values(['example.com']))));
  AssertEquals('allow-list only needs an entry', 1, Count(O.WithOriginPolicy(opAllowListOnly)));
  AssertEquals(0, Count(O.WithOriginPolicy(opAllowListOnly).WithAllowedOrigins(Values(['https://a.example']))));
  AssertEquals('a subprotocol that is not a token', 1, Count(O.WithSubprotocols(Values(['a b']))));
  AssertEquals(0, Count(O.WithSubprotocols(Values(['chat', 'v1.json']))));
  P := nil;
  O.WithMaxMessageSize(0).WithFrameSize(0).Problems(P);
  AssertEquals('several problems are all reported', 2, Length(P));
end;

initialization
  RegisterTest(TWsOriginTest);

end.
