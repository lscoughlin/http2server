{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, limits, factory, validation, protocol selection, test, fpcunit
notes:
  - This unit tests the HTTP/1.1 settings of the factory, the cleartext protocol
    selection, and the two promises about limits. Two servers in one process keep
    their own limits, and the library never writes the process-wide variables of
    mORMot2.
---
}
/// Tests of the HTTP/1.1 settings and the protocol selection
unit Http2Server.Http1.Config.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  mormot.net.http,
  Http2Server, Http2Server.Http1.Limits, Http2Server.Http1.Select,
  Http2Server.Frames, Http2Server.Http1.RawClient;

type
  THttp1ConfigTest = class(TTestCase)
  private
    function ProblemsOf(const AFactory: THttp2ServerFactory): string;
  published
    procedure TestDefaults;
    procedure TestFallbackIsOnByDefaultAndTheSetterChangesACopy;
    procedure TestLimitsAreValidated;
    procedure TestLimitsAboveTheMormotCeilingAreRefused;
    procedure TestSelectorChoosesByTheFirstOctets;
    procedure TestTwoServersKeepTheirOwnLimits;
    procedure TestTheMormotVariablesAreNeverWritten;
  end;

implementation

function THttp1ConfigTest.ProblemsOf(const AFactory: THttp2ServerFactory): string;
var
  P: TArray<string>;
  I: Integer;
begin
  Result := '';
  AFactory.Validate(P);
  for I := 0 to High(P) do
    Result := Result + P[I] + '; ';
end;

procedure THttp1ConfigTest.TestDefaults;
var
  L: THttp11Limits;
begin
  L := THttp2ServerFactory.Create.Http11;
  AssertEquals(8192, L.MaxRequestLine);
  AssertEquals(8192, L.MaxHeaderLine);
  AssertEquals(100, L.MaxHeaderCount);
  AssertEquals(65536, L.MaxHeaderOctets);
  AssertEquals(1048576, L.MaxChunkSize);
  AssertEquals(1024, L.MaxChunkExtension);
  AssertEquals(4096, L.MaxTrailerOctets);
  AssertEquals(Int64(16777216), L.MaxBodySize);
  AssertEquals(65536, L.MaxPipelinedOctets);
  AssertEquals(30000, L.BodyDeadlineMs);
end;

procedure THttp1ConfigTest.TestFallbackIsOnByDefaultAndTheSetterChangesACopy;
var
  A, B: THttp2ServerFactory;
begin
  A := THttp2ServerFactory.Create;
  AssertTrue('the fallback is on by default', A.Http11Fallback);
  B := A.WithHttp11Fallback(False);
  AssertFalse(B.Http11Fallback);
  AssertTrue('the original is unchanged', A.Http11Fallback);
end;

procedure THttp1ConfigTest.TestLimitsAreValidated;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create;
  AssertEquals('the default limits add no problem', 0, Pos('HTTP/1.1', ProblemsOf(F)));
  AssertTrue(Pos('request line', ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxRequestLine(0)))) > 0);
  AssertTrue(Pos('header count', ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxHeaderCount(0)))) > 0);
  AssertTrue(Pos('chunk size', ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxChunkSize(0)))) > 0);
  AssertTrue(Pos('trailer', ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxTrailerOctets(0)))) > 0);
  AssertTrue(Pos('body limit', ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxBodySize(-1)))) > 0);
  AssertTrue(Pos('body deadline', ProblemsOf(F.WithHttp11Limits(F.Http11.WithBodyDeadlineMs(-1)))) > 0);
end;

procedure THttp1ConfigTest.TestLimitsAboveTheMormotCeilingAreRefused;
var
  F: THttp2ServerFactory;
  Text: string;
begin
  F := THttp2ServerFactory.Create;
  Text := ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxHeaderLine(MaxHttpHeaderLineSize + 1)));
  AssertTrue(Text, Pos('MaxHttpHeaderLineSize', Text) > 0);
  Text := ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxChunkSize(MaxHttpChunkSize + 1)));
  AssertTrue(Text, Pos('MaxHttpChunkSize', Text) > 0);
  // a limit at the ceiling is fine
  Text := ProblemsOf(F.WithHttp11Limits(F.Http11.WithMaxHeaderLine(MaxHttpHeaderLineSize)));
  AssertEquals('', Pos('MaxHttpHeaderLineSize', Text), 0);
end;

procedure THttp1ConfigTest.TestSelectorChoosesByTheFirstOctets;
var
  Preface: array[0..ClientPrefaceSize - 1] of Byte;
  Bad: AnsiString;
begin
  Move(ClientPreface[0], Preface[0], ClientPrefaceSize);
  AssertTrue('the whole preface is HTTP/2', SelectCleartextProtocol(Preface[0], ClientPrefaceSize) = pcHttp2);
  AssertTrue('a longer buffer that starts with it is HTTP/2',
    SelectCleartextProtocol(Preface[0], ClientPrefaceSize) = pcHttp2);
  AssertTrue('a prefix of the preface waits', SelectCleartextProtocol(Preface[0], 10) = pcNeedMore);
  AssertTrue('one octet waits', SelectCleartextProtocol(Preface[0], 1) = pcNeedMore);
  AssertTrue('no octet waits', SelectCleartextProtocol(Preface[0], 0) = pcNeedMore);
  Bad := 'GET / HTTP/1.1';
  AssertTrue('a request line is HTTP/1.1', SelectCleartextProtocol(Bad[1], Length(Bad)) = pcHttp1);
  Bad := 'P';
  AssertTrue('P could be PRI, so the choice waits', SelectCleartextProtocol(Bad[1], 1) = pcNeedMore);
  Bad := 'POST / HTTP/1.1';
  AssertTrue('POST differs from PRI at the second octet', SelectCleartextProtocol(Bad[1], Length(Bad)) = pcHttp1);
  Bad := 'PRI * HTTP/2.0'#13#10'Host: a'#13#10#13#10;
  AssertTrue('a PRI line with no SM is HTTP/1.1 and meets the 505 rule',
    SelectCleartextProtocol(Bad[1], Length(Bad)) = pcHttp1);
  Bad := #22#3#1;
  AssertTrue('TLS handshake octets on a cleartext listener', SelectCleartextProtocol(Bad[1], 3) = pcHttp1);
end;

procedure THttp1ConfigTest.TestTwoServersKeepTheirOwnLimits;
var
  H: TTestHandler;
  HR: IHttp2Handler;
  Tight, Wide: IHttp2Server;
  A, B: TRawHttp;
  R: TRawResponse;
  Req: string;
begin
  H := TTestHandler.Create;
  HR := H;
  Tight := LiveFactory(HR).WithHttp11Limits(THttp11Limits.Create.WithMaxHeaderLine(100)).Build;
  Wide := LiveFactory(HR).Build;
  Tight.Start;
  Wide.Start;
  A := TRawHttp.Create(Tight.Port);
  B := TRawHttp.Create(Wide.Port);
  try
    Req := 'GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'X-A: ' + StringOfChar('a', 300) + CRLF + CRLF;
    A.Send(Req);
    AssertTrue(A.ReadResponse(False, ResponseMs, R));
    AssertEquals('the tight server refuses a 300-octet line', 431, R.Status);
    B.Send(Req);
    AssertTrue(B.ReadResponse(False, ResponseMs, R));
    AssertEquals('the wide server accepts it', 200, R.Status);
  finally
    A.Free;
    B.Free;
    Tight.Stop;
    Wide.Stop;
  end;
end;

procedure THttp1ConfigTest.TestTheMormotVariablesAreNeverWritten;
var
  Line, Chunk, Mem: Integer;
  H: TTestHandler;
  HR: IHttp2Handler;
  S: IHttp2Server;
  C: TRawHttp;
  R: TRawResponse;
begin
  Line := MaxHttpHeaderLineSize;
  Chunk := MaxHttpChunkSize;
  Mem := MaxHttpInMemSize;
  H := TTestHandler.Create;
  HR := H;
  S := LiveFactory(HR).WithHttp11Limits(THttp11Limits.Create.WithMaxHeaderLine(200)).Build;
  S.Start;
  C := TRawHttp.Create(S.Port);
  try
    C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue(C.ReadResponse(False, ResponseMs, R));
    AssertEquals(Line, MaxHttpHeaderLineSize);
    AssertEquals(Chunk, MaxHttpChunkSize);
    AssertEquals(Mem, MaxHttpInMemSize);
  finally
    C.Free;
    S.Stop;
  end;
  AssertEquals('after Stop too', Line, MaxHttpHeaderLineSize);
end;

initialization
  RegisterTest(THttp1ConfigTest);

end.
