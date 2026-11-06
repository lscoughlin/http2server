{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls, protocol, version, test, fpcunit
notes:
  - Tests for the accepted TLS version range of the server.
  - The factory range reaches the TLS policy, and the policy reaches the
    server context in ApplyTls.
  - The live tests drive real handshakes with the openssl command against a
    loopback server, and they skip with a clear message when the command or
    the loopback certificate is absent.
---
}
/// TLS protocol range tests for BuildTlsPolicy and ApplyTls
unit Http2Server.TlsProtocols.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, process, fpcunit, testregistry,
  mormot.core.base,
  mormot.net.sock,
  mormot.lib.openssl11,
  Http2Server.Config, Http2Server.Config.Tls, Http2Server.Seam,
  Http2Server.Tls, Http2Server.Async, Http2Server.Async.Options;

type
  /// the pure mapping tests of the protocol range
  TTlsProtocolMappingTest = class(TTestCase)
  published
    procedure TestFactoryMapsProtocolRange;
  end;

  /// a handler that does nothing, only to satisfy the factory wiring
  TTlsNullHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the live handshake tests of the protocol range
  TTlsProtocolLiveTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    function StartServer(const AMin, AMax: TTlsVersion): Integer;
    procedure StopServer;
    /// the output of one s_client handshake with the pinned version
    function Handshake(const APort: Integer; const AFlag: string): string;
    /// one range case: the pinned client connects or fails as AExpectOk says
    procedure RunCase(const AMin, AMax: TTlsVersion; const AFlag,
      AProto: string; const AExpectOk: Boolean);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestTls12ClientAcrossRanges;
    procedure TestTls13ClientAcrossRanges;
  end;

implementation

const
  /// the loopback certificate and key of the test suite
  cTlsCertFile = 'test/certs/localhost.crt';
  cTlsKeyFile = 'test/certs/localhost.key';

{ TTlsProtocolMappingTest }

procedure TTlsProtocolMappingTest.TestFactoryMapsProtocolRange;
var
  Factory: THttp2ServerFactory;
  Policy: TTlsPolicy;
begin
  Factory := THttp2ServerFactory.Create
    .WithHandler(TTlsNullHandler.Create)
    .WithClearTextAllowed(False)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile(cTlsCertFile)
      .WithMinTlsVersion(tvTls13)
      .WithMaxTlsVersion(tvTls13));
  Policy := BuildTlsPolicy(Factory);
  AssertEquals('the minimum reaches the policy', TLS1_3_VERSION,
    Policy.MinProtocol);
  AssertEquals('the maximum reaches the policy', TLS1_3_VERSION,
    Policy.MaxProtocol);
  Factory := THttp2ServerFactory.Create
    .WithHandler(TTlsNullHandler.Create)
    .WithClearTextAllowed(False)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile(cTlsCertFile));
  Policy := BuildTlsPolicy(Factory);
  AssertEquals('the default minimum is TLS 1.2', TLS1_2_VERSION,
    Policy.MinProtocol);
  AssertEquals('the default maximum is TLS 1.3', TLS1_3_VERSION,
    Policy.MaxProtocol);
end;

{ TTlsNullHandler }

procedure TTlsNullHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  // the live tests stop at the handshake; no request ever arrives
end;

{ TTlsProtocolLiveTest }

procedure TTlsProtocolLiveTest.SetUp;
begin
  inherited SetUp;
  if ExeSearch('openssl') = '' then
    Ignore('the openssl command is absent, so no handshake runs');
  if not FileExists(cTlsCertFile) or not FileExists(cTlsKeyFile) then
    Ignore('the loopback certificate is absent, so no handshake runs');
  FServer := nil;
end;

procedure TTlsProtocolLiveTest.TearDown;
begin
  StopServer;
  inherited TearDown;
end;

function TTlsProtocolLiveTest.StartServer(const AMin,
  AMax: TTlsVersion): Integer;
var
  Factory: THttp2ServerFactory;
begin
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(False)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile(cTlsCertFile)
      .WithKeyFile(cTlsKeyFile)
      .WithMinTlsVersion(AMin)
      .WithMaxTlsVersion(AMax))
    .WithHandler(TTlsNullHandler.Create)
    .WithHandlerThreads(2)
    .WithIOThreads(2);
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
  Result := FServer.BoundPort;
end;

procedure TTlsProtocolLiveTest.StopServer;
begin
  FreeAndNil(FServer);
end;

function TTlsProtocolLiveTest.Handshake(const APort: Integer;
  const AFlag: string): string;
var
  P: TProcess;
  Mem: TMemoryStream;
  Quit: RawByteString;
  Deadline: QWord;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  Result := '';
  P := TProcess.Create(nil);
  Mem := TMemoryStream.Create;
  try
    P.Executable := ExeSearch('openssl');
    P.Parameters.Add('s_client');
    P.Parameters.Add('-connect');
    P.Parameters.Add('127.0.0.1:' + IntToStr(APort));
    P.Parameters.Add(AFlag);
    P.Parameters.Add('-alpn');
    P.Parameters.Add('h2');
    P.Options := [poUsePipes];
    P.Execute;
    // one Q ends the session after the handshake, so the command exits
    Quit := 'Q' + #10;
    P.Input.Write(Quit[1], Length(Quit));
    P.CloseInput;
    Deadline := GetTickCount64 + 15000;
    while P.Running and (GetTickCount64 < Deadline) do
      Sleep(10);
    if P.Running then
    begin
      P.Terminate(1);
      Fail('the openssl command did not end within 15 s');
    end;
    // the session summary goes to stdout and the alerts to stderr
    while P.Output.NumBytesAvailable > 0 do
    begin
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N <= 0 then
        Break;
      Mem.Write(Buf, N);
    end;
    while P.StdErr.NumBytesAvailable > 0 do
    begin
      N := P.StdErr.Read(Buf, SizeOf(Buf));
      if N <= 0 then
        Break;
      Mem.Write(Buf, N);
    end;
    SetLength(Result, Mem.Size);
    if Mem.Size > 0 then
      Move(Mem.Memory^, Result[1], Mem.Size);
  finally
    Mem.Free;
    P.Free;
  end;
end;

procedure TTlsProtocolLiveTest.RunCase(const AMin, AMax: TTlsVersion;
  const AFlag, AProto: string; const AExpectOk: Boolean);
var
  Port: Integer;
  Out: string;
  Tag: string;
begin
  if AMin = tvTls12 then
    Tag := '1.2'
  else
    Tag := '1.3';
  if AMax = tvTls12 then
    Tag := Tag + '-1.2'
  else
    Tag := Tag + '-1.3';
  Tag := 'range ' + Tag + ', client ' + AFlag + ': ';
  Port := StartServer(AMin, AMax);
  try
    Out := Handshake(Port, AFlag);
    if AExpectOk then
    begin
      // OpenSSL 4.1 pads the label for TLS 1.2 ("Protocol  :") but not for
      // TLS 1.3 ("Protocol:"), so both forms count
      AssertTrue(Tag + 'the handshake selects ' + AProto + #10 + Out,
        (Pos('Protocol  : ' + AProto, Out) > 0) or
        (Pos('Protocol: ' + AProto, Out) > 0));
      AssertTrue(Tag + 'h2 is negotiated' + #10 + Out,
        Pos('ALPN protocol: h2', Out) > 0);
    end
    else
      AssertTrue(Tag + 'the handshake fails' + #10 + Out,
        Pos('Cipher is (NONE)', Out) > 0);
  finally
    StopServer;
  end;
end;

procedure TTlsProtocolLiveTest.TestTls12ClientAcrossRanges;
begin
  RunCase(tvTls12, tvTls13, '-tls1_2', 'TLSv1.2', True);
  RunCase(tvTls12, tvTls12, '-tls1_2', 'TLSv1.2', True);
  RunCase(tvTls13, tvTls13, '-tls1_2', '', False);
end;

procedure TTlsProtocolLiveTest.TestTls13ClientAcrossRanges;
begin
  RunCase(tvTls12, tvTls13, '-tls1_3', 'TLSv1.3', True);
  RunCase(tvTls13, tvTls13, '-tls1_3', 'TLSv1.3', True);
  RunCase(tvTls12, tvTls12, '-tls1_3', '', False);
end;

initialization
  RegisterTest(TTlsProtocolMappingTest);
  RegisterTest(TTlsProtocolLiveTest);

end.
