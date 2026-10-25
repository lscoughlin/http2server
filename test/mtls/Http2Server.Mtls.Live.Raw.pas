{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, live, raw client, http2, http1, extended connect, tls socket
notes:
  - This unit holds two small raw clients for the live mutual TLS validation.
    They use the TLS socket of the sibling client at ../http2client, which can
    offer an ALPN list and present a client certificate.
  - The HTTP/2 client opens the extended CONNECT stream of RFC 8441, because the
    sibling client speaks WebSocket over HTTP/1.1 only. It builds frames with the
    codec of this library.
  - A refusal shows as a failed dial, a failed read or a closed socket before
    the response headers. TLS 1.3 reports a rejected client certificate on the
    first read and not on connect, so the clients treat both the same way.
---
}
/// Raw TLS clients for the live mutual TLS validation
unit Http2Server.Mtls.Live.Raw;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  mormot.core.base, mormot.core.os,
  Http2.Tls, Http2.ClientCert,
  Http2Server.Hpack, Http2Server.Frames, Http2Server.Ws.Frames;

type
  /// the outcome of one raw request
  TRawResult = record
    /// no response headers arrived: the dial, the handshake or the read failed
    Refused: Boolean;
    Status: string;
    Body: string;
  end;

  /// a raw HTTP/2 client over TLS
  TRawH2 = class
  private
    FSock: IHttp2Socket;
    FEnc, FDec: THpackCodec;
    FClosed: Boolean;
    FNextStream: LongWord;
    FStream: LongWord;
    FStatus: string;
    FBody: string;
    FHeadersSeen, FEnded: Boolean;
    procedure Send(const AFrame: TFrame);
    function ReadExact(var ABuffer; const ACount: Integer): Boolean;
    function Pump: Boolean;
    procedure Take(const AFrame: TFrame);
    function Wait(const AUntilEnded: Boolean): Boolean;
    function OpenStream(const AFields: THeaderBlock; const AEnd: Boolean): LongWord;
  public
    /// dial and send the preface; raises when the dial fails
    constructor Create(const APort: Integer; const AIdentity: IClientIdentity);
    destructor Destroy; override;
    function Get(const APath: string): TRawResult;
    /// open the extended CONNECT stream; the result holds the status
    function OpenWebSocket(const APath: string): TRawResult;
    procedure SendWsText(const AText: string);
  end;

/// one HTTP/1.1 GET over TLS that offers only http/1.1
function RawHttp1Get(const APort: Integer; const AIdentity: IClientIdentity;
  const APath: string): TRawResult;

implementation

const
  cReadMs = 3000;
  cWaitMs = 5000;

function FrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

function Field(const AFields: THeaderBlock; const AName: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(AFields) do
    if AFields[i].Name = AName then
      Exit(AFields[i].Value);
end;

{ TRawH2 }

constructor TRawH2.Create(const APort: Integer; const AIdentity: IClientIdentity);
var
  Wire: TBytes;
  Settings: TBytes;
  N: Integer;
begin
  inherited Create;
  FEnc := THpackCodec.Create;
  FDec := THpackCodec.Create;
  FNextStream := 1;
  FSock := TTlsSocket.DialWithAlpn('127.0.0.1', APort,
    AlpnProtocolList(['h2']), True, cReadMs, '', '', 0, AIdentity);
  FSock.ReadTimeoutMs := cReadMs;
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Settings := FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults));
  SetLength(Wire, ClientPrefaceSize + Length(Settings));
  Move(Settings[0], Wire[ClientPrefaceSize], Length(Settings));
  N := FSock.Write(Wire[0], Length(Wire));
  if GetEnvironmentVariable('MTLS_DEBUG') <> '' then
    WriteLn(StdErr, '  preface write ', N, ' of ', Length(Wire));
end;

destructor TRawH2.Destroy;
begin
  try
    if FSock <> nil then
      FSock.Close;
  except
    // the peer may have closed the socket already
  end;
  FDec.Free;
  FEnc.Free;
  inherited Destroy;
end;

procedure TRawH2.Send(const AFrame: TFrame);
var
  Wire: TBytes;
begin
  Wire := FrameBytes(AFrame);
  try
    FSock.Write(Wire[0], Length(Wire));
  except
    FClosed := True;
  end;
end;

procedure TRawH2.Take(const AFrame: TFrame);
var
  Fields: THeaderBlock;
  Text: string;
begin
  if GetEnvironmentVariable('MTLS_DEBUG') <> '' then
    WriteLn(StdErr, '  frame type ', Ord(AFrame.Header.FrameType), ' stream ',
      AFrame.Header.StreamId, ' len ', Length(AFrame.Payload));
  case AFrame.Header.FrameType of
    ftSettings:
      if not AFrame.IsAck then
        Send(BuildSettingsAck);
    ftHeaders:
      if AFrame.Header.StreamId = FStream then
      begin
        Fields := FDec.Decode(ExtractHeaderBlock(AFrame));
        if not FHeadersSeen then
          FStatus := Field(Fields, ':status');
        FHeadersSeen := True;
        if AFrame.IsEndStream then
          FEnded := True;
      end;
    ftData:
      if AFrame.Header.StreamId = FStream then
      begin
        SetLength(Text, Length(AFrame.Payload));
        if Length(AFrame.Payload) > 0 then
          Move(AFrame.Payload[0], Text[1], Length(AFrame.Payload));
        FBody := FBody + Text;
        if AFrame.IsEndStream then
          FEnded := True;
      end;
    ftRstStream:
      if AFrame.Header.StreamId = FStream then
        FEnded := True;
  end;
end;

function TRawH2.ReadExact(var ABuffer; const ACount: Integer): Boolean;
var
  P: PByte;
  Done, N: Integer;
begin
  // the TLS socket of the sibling client reads up to the count it is given and
  // waits for the rest, so a frame is read as its header, then its payload
  Result := False;
  P := @ABuffer;
  Done := 0;
  try
    while Done < ACount do
    begin
      N := FSock.Read(P[Done], ACount - Done);
      if N <= 0 then
        Exit;
      Inc(Done, N);
    end;
    Result := True;
  except
    on E: Exception do
      if GetEnvironmentVariable('MTLS_DEBUG') <> '' then
        WriteLn(StdErr, '  read: ', E.ClassName, ': ', E.Message);
  end;
end;

function TRawH2.Pump: Boolean;
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  Frame: TFrame;
begin
  Result := False;
  if FClosed then
    Exit;
  SetLength(HeaderBytes, FrameHeaderSize);
  if not ReadExact(HeaderBytes[0], FrameHeaderSize) then
  begin
    FClosed := True;
    Exit;
  end;
  Header := TFrameHeader.ReadFrom(HeaderBytes);
  Frame.Header := Header;
  SetLength(Frame.Payload, Header.Length);
  if (Header.Length > 0) and not ReadExact(Frame.Payload[0], Header.Length) then
  begin
    FClosed := True;
    Exit;
  end;
  Take(Frame);
  Result := True;
end;

function TRawH2.Wait(const AUntilEnded: Boolean): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + cWaitMs;
  while GetTickCount64 < Deadline do
  begin
    if AUntilEnded then
    begin
      if FEnded then
        Exit(True);
    end
    else if FHeadersSeen then
      Exit(True);
    if not Pump then
      Break;
  end;
  Result := FHeadersSeen;
end;

function TRawH2.OpenStream(const AFields: THeaderBlock;
  const AEnd: Boolean): LongWord;
begin
  Result := FNextStream;
  Inc(FNextStream, 2);
  FStream := Result;
  FStatus := '';
  FBody := '';
  FHeadersSeen := False;
  FEnded := False;
  Send(BuildHeadersFrame(Result, FEnc.Encode(AFields), True, AEnd));
end;

function TRawH2.Get(const APath: string): TRawResult;
var
  F: THeaderBlock;

  procedure Add(const AIndex: Integer; const AName, AValue: string);
  begin
    F[AIndex].Name := AName;
    F[AIndex].Value := AValue;
  end;

begin
  SetLength(F, 4);
  Add(0, ':method', 'GET');
  Add(1, ':scheme', 'https');
  Add(2, ':path', APath);
  Add(3, ':authority', 'localhost');
  OpenStream(F, True);
  Wait(True);
  Result.Refused := not FHeadersSeen;
  Result.Status := FStatus;
  Result.Body := FBody;
end;

function TRawH2.OpenWebSocket(const APath: string): TRawResult;
var
  F: THeaderBlock;

  procedure Add(const AIndex: Integer; const AName, AValue: string);
  begin
    F[AIndex].Name := AName;
    F[AIndex].Value := AValue;
  end;

begin
  // the server sends SETTINGS_ENABLE_CONNECT_PROTOCOL first. Read it before
  // the CONNECT request, so the request never races the setting
  Pump;
  SetLength(F, 6);
  Add(0, ':method', 'CONNECT');
  Add(1, ':scheme', 'https');
  Add(2, ':path', APath);
  Add(3, ':authority', 'localhost');
  Add(4, ':protocol', 'websocket');
  Add(5, 'sec-websocket-version', '13');
  OpenStream(F, False);
  Wait(False);
  Result.Refused := not FHeadersSeen;
  Result.Status := FStatus;
  if not FHeadersSeen then
    if FClosed then
      Result.Status := '(closed)'
    else
      Result.Status := '(timeout)';
  Result.Body := '';
end;

procedure TRawH2.SendWsText(const AText: string);
var
  Data, Wire: TBytes;
begin
  SetLength(Data, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Data[0], Length(AText));
  Wire := WsEncodeFrame($1, True, Data, True, WsMaskKeyFromLongWord($0A0B0C0D));
  Send(BuildDataFrame(FStream, Wire, False));
end;

{ HTTP/1.1 }

function RawHttp1Get(const APort: Integer; const AIdentity: IClientIdentity;
  const APath: string): TRawResult;
var
  Sock: IHttp2Socket;
  Req: RawByteString;
  Buf: array[0..4095] of Byte;
  Reply: RawByteString;
  N, P: Integer;
  Line: string;
begin
  Result.Refused := True;
  Result.Status := '';
  Result.Body := '';
  try
    Sock := TTlsSocket.DialWithAlpn('127.0.0.1', APort,
      AlpnProtocolList(['http/1.1']), True, cReadMs, '', '', 0, AIdentity);
    Sock.ReadTimeoutMs := cReadMs;
    Req := 'GET ' + RawByteString(APath) + ' HTTP/1.1'#13#10 +
      'Host: localhost'#13#10'Connection: close'#13#10#13#10;
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
  except
    // a read that fails after some bytes still leaves those bytes in Reply
  end;
  P := Pos(#13#10#13#10, string(Reply));
  if P = 0 then
    Exit;
  Line := Copy(string(Reply), 1, Pos(#13#10, string(Reply)) - 1);   // HTTP/1.1 200 OK
  Result.Status := Copy(Line, 10, 3);
  Result.Body := Copy(string(Reply), P + 4, MaxInt);
  Result.Refused := False;
  try
    Sock.Close;
  except
  end;
end;

end.
