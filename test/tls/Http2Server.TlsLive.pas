{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, alpn, live, validation, http2client, fallback
notes:
  - This program starts two servers with TLS on loopback in one process, one
    with the HTTP/1.1 fallback and one without it. It drives both with the TLS
    socket of the sibling client at ../http2client, which offers any ALPN list.
  - It checks the select rule of RFC 7301 in a real handshake. The server picks
    h2 wherever the client lists it. It serves http/1.1 only when the fallback
    is on. It refuses an unknown protocol with a fatal alert. A client without
    an ALPN extension gets HTTP/1.1 when the fallback is on.
  - The program is a validation run and puts no load on the server.
  - The first argument is the directory of the test PKI, made by
    tools/certs/make_mtls_pki.sh. The exit code is 0 when every check passed.
---
}
/// Live validation of the ALPN policy against the sibling client
program Http2Server.TlsLive;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Http2Server, Http2.Tls,
  Http2Server.Mtls.Live.Raw;

type
  /// answers 200 and the text ok on every path
  TOkHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the result of one dial
  TDial = record
    /// the handshake failed
    Refused: Boolean;
    /// the protocol that the server selected; empty when it selected none
    Selected: string;
    /// the first line of the answer to a request on the connection
    Line: string;
  end;

var
  Pki: string;
  Passed, Failed: Integer;

procedure TOkHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
begin
  SetLength(Body, 2);
  Body[0] := Ord('o');
  Body[1] := Ord('k');
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

procedure Check(const AName: string; const ACondition: Boolean;
  const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(Passed);
    WriteLn('ok   ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

function Build(const AFallback: Boolean; const AHandler: IHttp2Handler): IHttp2Server;
begin
  Result := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(False)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile(Pki + '/server.crt')
      .WithKeyFile(Pki + '/server.key'))
    .WithHttp11Fallback(AFallback)
    .WithHandler(AHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500)
    .Build(nil);
  Result.Start;
end;

/// dial with an ALPN offer and send an HTTP/1.1 request when http/1.1 was chosen
// - an empty offer sends no ALPN extension
function Dial(const APort: Integer; const AOffer: array of string): TDial;
var
  Sock: IHttp2Socket;
  Req: RawByteString;
  Buf: array[0..1023] of Byte;
  N: Integer;
  Reply: RawByteString;
begin
  Result.Refused := True;
  Result.Selected := '';
  Result.Line := '';
  try
    Sock := TTlsSocket.DialWithAlpn('127.0.0.1', APort, AlpnProtocolList(AOffer),
      True, 3000);
    Sock.ReadTimeoutMs := 3000;
    Result.Selected := TTlsSocket(Sock as TObject).SelectedProtocol;
    if Result.Selected <> 'h2' then
    begin
      Req := 'GET / HTTP/1.1'#13#10'Host: localhost'#13#10'Connection: close'#13#10#13#10;
      Sock.Write(Req[1], Length(Req));
      Reply := '';
      repeat
        N := Sock.Read(Buf, SizeOf(Buf));
        if N > 0 then
        begin
          SetLength(Reply, Length(Reply) + N);
          Move(Buf[0], Reply[Length(Reply) - N + 1], N);
        end;
      until N <= 0;
      Result.Line := Copy(string(Reply), 1, Pos(#13#10, string(Reply)) - 1);
    end;
    Result.Refused := False;
    try
      Sock.Close;
    except
    end;
  except
    // a failed handshake leaves Refused set
  end;
end;

procedure RunPolicy(const AName: string; const APort: Integer;
  const AFallback: Boolean);
var
  D: TDial;
  H2: TRawH2;
  W: TRawResult;
begin
  WriteLn('-- ', AName);
  D := Dial(APort, ['h2']);
  Check(AName + ': an offer of h2 selects h2', (not D.Refused) and (D.Selected = 'h2'),
    D.Selected);
  D := Dial(APort, ['http/1.1', 'h2']);
  Check(AName + ': h2 wins when the client lists it second',
    (not D.Refused) and (D.Selected = 'h2'), D.Selected);
  D := Dial(APort, ['spdy/3', 'h2']);
  Check(AName + ': h2 wins after an unknown name', (not D.Refused) and (D.Selected = 'h2'),
    D.Selected);
  D := Dial(APort, ['spdy/3']);
  Check(AName + ': an unknown protocol is refused in the handshake', D.Refused,
    D.Selected + ' ' + D.Line);
  D := Dial(APort, ['http/1.1']);
  if AFallback then
    Check(AName + ': http/1.1 is served', (not D.Refused) and (D.Selected = 'http/1.1') and
      (D.Line = 'HTTP/1.1 200 OK'), D.Selected + ' ' + D.Line)
  else
    Check(AName + ': http/1.1 is refused', D.Refused, D.Selected + ' ' + D.Line);
  D := Dial(APort, []);
  if AFallback then
    Check(AName + ': no ALPN extension is served as HTTP/1.1',
      (not D.Refused) and (D.Selected = '') and (D.Line = 'HTTP/1.1 200 OK'),
      D.Selected + ' ' + D.Line)
  else
    // the handshake finishes without an ALPN extension, and the server closes
    // the connection after it, so no answer comes back
    Check(AName + ': no ALPN extension gets no answer', D.Refused or (D.Line = ''),
      D.Selected + ' ' + D.Line);
  H2 := TRawH2.Create(APort, nil);
  try
    W := H2.Get('/');
    Check(AName + ': a request over h2 is answered', (not W.Refused) and
      (W.Status = '200') and (W.Body = 'ok'), W.Status + ' ' + W.Body);
  finally
    H2.Free;
  end;
end;

var
  HandlerRef: IHttp2Handler;
  WithFallback, WithoutFallback: IHttp2Server;

begin
  Pki := ParamStr(1);
  if (Pki = '') or not FileExists(Pki + '/server.crt') then
  begin
    WriteLn(StdErr, 'usage: Http2Server.TlsLive <pki-directory>');
    Halt(2);
  end;
  HandlerRef := TOkHandler.Create;
  // two servers at once: each keeps its own policy
  WithFallback := Build(True, HandlerRef);
  WithoutFallback := Build(False, HandlerRef);
  try
    RunPolicy('fallback on', WithFallback.Port, True);
    RunPolicy('fallback off', WithoutFallback.Port, False);
    // the first server still follows its own policy after the second ran
    RunPolicy('fallback on, again', WithFallback.Port, True);
  finally
    WithFallback.Stop;
    WithoutFallback.Stop;
  end;
  WriteLn;
  WriteLn('passed ', Passed, ', failed ', Failed);
  if Failed > 0 then
    Halt(1);
end.
