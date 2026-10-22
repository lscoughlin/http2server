{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, raw client, test kit, socket, chunked, fpcunit
notes:
  - This unit holds a small HTTP/1.1 client over a raw socket and a handler that
    the live tests share. The client sends exactly the octets that a test gives
    it, so a test can send a request that a normal client library refuses.
  - The waits are bounded polls of the socket and never a fixed sleep that decides
    a result.
---
}
/// A raw HTTP/1.1 client and a test handler for the live tests
unit Http2Server.Http1.RawClient;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  mormot.core.base, mormot.net.sock,
  Http2Server, Http2Server.Errors;

type
  /// one parsed response
  TRawResponse = record
    Status: Integer;
    /// the status line and the header lines as received, with CRLF
    Head: string;
    Body: string;
    /// the response had a Transfer-Encoding: chunked body
    Chunked: Boolean;
    /// the connection ended with the response
    Closed: Boolean;
    function Header(const AName: string): string;
  end;

  TRawHttp = class
  private
    FSock: TCrtSocket;
    FBuf: RawByteString;
    FClosed: Boolean;
    function Pump(const AWaitMs: Integer): Boolean;
    function TakeUntil(const AMarker: string; const ATimeoutMs: Integer;
      out AText: string): Boolean;
    function TakeBytes(const ACount, ATimeoutMs: Integer; out AText: string): Boolean;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    procedure Send(const AText: RawByteString);
    /// read one final response; a 100 Continue before it is skipped and counted
    function ReadResponse(const AHeadOnly: Boolean; const ATimeoutMs: Integer;
      out AResponse: TRawResponse): Boolean;
    /// read the status line and the header lines only
    function ReadHead(const ATimeoutMs: Integer; out AResponse: TRawResponse): Boolean;
    /// read one chunk of a chunked body; ALast is true for the last chunk
    function ReadChunk(const ATimeoutMs: Integer; out AData: string;
      out ALast: Boolean): Boolean;
    /// read an interim 1xx response head
    function ReadInterim(const ATimeoutMs: Integer; out AHead: string): Boolean;
    /// true once the peer closed the connection within ATimeoutMs
    function WaitClosed(const ATimeoutMs: Integer): Boolean;
    /// the octets that arrive within ATimeoutMs
    function ReadSome(const ATimeoutMs: Integer): string;
    property Closed: Boolean read FClosed;
  end;

  /// the handler of the live tests; the path selects the behaviour
  TTestHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FLock: TCriticalSection;
    FCalls: Integer;
    FSlowMs: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    function Calls: Integer;
    property SlowMs: Integer read FSlowMs write FSlowMs;
  end;

function LiveFactory(const AHandler: IHttp2Handler): THttp2ServerFactory;

const
  CRLF = #13#10;
  ResponseMs = 5000;

implementation

function LiveFactory(const AHandler: IHttp2Handler): THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(AHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500);
end;

{ TRawResponse }

function TRawResponse.Header(const AName: string): string;
var
  Lines: TStringList;
  I, P: Integer;
  Line: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(Head, CRLF, #10, [rfReplaceAll]);
    for I := 1 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      P := Pos(':', Line);
      if (P > 0) and SameText(Copy(Line, 1, P - 1), AName) then
        Exit(Trim(Copy(Line, P + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
end;

{ TRawHttp }

constructor TRawHttp.Create(const APort: Integer);
begin
  inherited Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, ResponseMs);
end;

destructor TRawHttp.Destroy;
begin
  FSock.Free;
  inherited Destroy;
end;

procedure TRawHttp.Send(const AText: RawByteString);
begin
  // SockSend appends a CRLF; SockSendFlush with a body sends the octets as given
  FSock.SockSendFlush(AText);
end;

function TRawHttp.Pump(const AWaitMs: Integer): Boolean;
var
  Pending: TCrtSocketPending;
  Chunk: RawByteString;
begin
  Result := False;
  if FClosed then
    Exit;
  Pending := FSock.SockReceivePending(0);
  if Pending in [cspSocketError, cspSocketClosed] then
  begin
    FClosed := True;
    Exit;
  end;
  // receive only when data waits; a receive with no data blocks until the
  // socket timeout. SockReceivePending does not wait, so the caller's loop
  // sleeps and runs against a real clock
  if not (Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket]) then
  begin
    Sleep(AWaitMs div 4 + 1);
    Exit;
  end;
  Chunk := FSock.SockReceiveString;
  if Chunk <> '' then
  begin
    FBuf := FBuf + Chunk;
    Result := True;
  end
  else
    FClosed := True;   // readable and empty: the peer closed
end;

function TRawHttp.TakeUntil(const AMarker: string; const ATimeoutMs: Integer;
  out AText: string): Boolean;
var
  P: Integer;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  AText := '';
  repeat
    P := Pos(AMarker, FBuf);
    if P > 0 then
    begin
      AText := Copy(FBuf, 1, P + Length(AMarker) - 1);
      Delete(FBuf, 1, P + Length(AMarker) - 1);
      Exit(True);
    end;
    if FClosed then
      Exit(False);
    Pump(20);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function TRawHttp.TakeBytes(const ACount, ATimeoutMs: Integer; out AText: string): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  AText := '';
  while Length(FBuf) < ACount do
  begin
    if FClosed or (GetTickCount64 >= Deadline) then
      Exit(False);
    Pump(20);
  end;
  AText := Copy(FBuf, 1, ACount);
  Delete(FBuf, 1, ACount);
  Result := True;
end;

function TRawHttp.ReadInterim(const ATimeoutMs: Integer; out AHead: string): Boolean;
begin
  Result := TakeUntil(CRLF + CRLF, ATimeoutMs, AHead);
end;

function TRawHttp.ReadResponse(const AHeadOnly: Boolean; const ATimeoutMs: Integer;
  out AResponse: TRawResponse): Boolean;
var
  Head, Line, SizeLine, Piece, Rest: string;
  Len, Size: Integer;
  Deadline: QWord;
begin
  Result := False;
  AResponse := Default(TRawResponse);
  repeat
    if not TakeUntil(CRLF + CRLF, ATimeoutMs, Head) then
      Exit;
    AResponse.Status := StrToIntDef(Copy(Head, 10, 3), 0);
  until AResponse.Status <> 100;
  AResponse.Head := Head;
  Line := AResponse.Header('transfer-encoding');
  AResponse.Chunked := SameText(Line, 'chunked');
  if AHeadOnly or (AResponse.Status = 204) or (AResponse.Status = 304) then
    Exit(True);
  if AResponse.Chunked then
  begin
    repeat
      if not TakeUntil(CRLF, ATimeoutMs, SizeLine) then
        Exit;
      Size := StrToIntDef('$' + Trim(SizeLine), -1);
      if Size < 0 then
        Exit;
      if not TakeBytes(Size + 2, ATimeoutMs, Piece) then
        Exit;
      AResponse.Body := AResponse.Body + Copy(Piece, 1, Size);
    until Size = 0;
    Exit(True);
  end;
  Line := AResponse.Header('content-length');
  if Line <> '' then
  begin
    Len := StrToIntDef(Line, 0);
    if not TakeBytes(Len, ATimeoutMs, Piece) then
      Exit;
    AResponse.Body := Piece;
    Exit(True);
  end;
  // no length: the body ends when the connection closes
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (not FClosed) and (GetTickCount64 < Deadline) do
    Pump(20);
  Rest := FBuf;
  FBuf := '';
  AResponse.Body := Rest;
  AResponse.Closed := FClosed;
  Result := FClosed;
end;

function TRawHttp.ReadHead(const ATimeoutMs: Integer;
  out AResponse: TRawResponse): Boolean;
var
  Head: string;
begin
  AResponse := Default(TRawResponse);
  Result := TakeUntil(CRLF + CRLF, ATimeoutMs, Head);
  if not Result then
    Exit;
  AResponse.Head := Head;
  AResponse.Status := StrToIntDef(Copy(Head, 10, 3), 0);
  AResponse.Chunked := SameText(AResponse.Header('transfer-encoding'), 'chunked');
end;

function TRawHttp.ReadChunk(const ATimeoutMs: Integer; out AData: string;
  out ALast: Boolean): Boolean;
var
  SizeLine, Piece: string;
  Size: Integer;
begin
  Result := False;
  AData := '';
  ALast := False;
  if not TakeUntil(CRLF, ATimeoutMs, SizeLine) then
    Exit;
  Size := StrToIntDef('$' + Trim(SizeLine), -1);
  if Size < 0 then
    Exit;
  if not TakeBytes(Size + 2, ATimeoutMs, Piece) then
    Exit;
  AData := Copy(Piece, 1, Size);
  ALast := Size = 0;
  Result := True;
end;

function TRawHttp.WaitClosed(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (not FClosed) and (GetTickCount64 < Deadline) do
    Pump(20);
  Result := FClosed;
end;

function TRawHttp.ReadSome(const ATimeoutMs: Integer): string;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (GetTickCount64 < Deadline) and not FClosed do
    Pump(20);
  Result := FBuf;
  FBuf := '';
end;

{ TTestHandler }

constructor TTestHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSlowMs := 300;
end;

destructor TTestHandler.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TTestHandler.Calls: Integer;
begin
  FLock.Acquire;
  try
    Result := FCalls;
  finally
    FLock.Release;
  end;
end;

procedure TTestHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Path: string;
  H: THeaderBlock;
  Body, Part: TBytes;
  Buf: array[0..4095] of Byte;
  N, I: Integer;

  function Bytes(const AText: string): TBytes;
  begin
    Result := nil;
    SetLength(Result, Length(AText));
    if Length(AText) > 0 then
      Move(AText[1], Result[0], Length(AText));
  end;

  function Len(const AValue: Integer): THeaderBlock;
  begin
    Result := nil;
    SetLength(Result, 1);
    Result[0].Name := 'content-length';
    Result[0].Value := IntToStr(AValue);
  end;

begin
  FLock.Acquire;
  try
    Inc(FCalls);
  finally
    FLock.Release;
  end;
  Path := ARequest.Path;
  if Path = '/hello' then
  begin
    AResponse.SendHeaders(200, Len(5), False);
    AResponse.Write(Bytes('hello'));
    AResponse.Finish;
  end
  else if Path = '/chunked' then
  begin
    AResponse.SendHeaders(200, nil, False);
    AResponse.Write(Bytes('one'));
    AResponse.Write(Bytes('two'));
    AResponse.Write(Bytes('three'));
    AResponse.Finish;
  end
  else if (Path = '/echo') or (Path = '/expect') then
  begin
    Body := nil;
    repeat
      N := ARequest.Read(Buf[0], SizeOf(Buf));
      if N > 0 then
      begin
        I := Length(Body);
        SetLength(Body, I + N);
        Move(Buf[0], Body[I], N);
      end;
    until N = 0;
    AResponse.SendHeaders(200, Len(Length(Body)), False);
    AResponse.Write(Body);
    AResponse.Finish;
  end
  else if Path = '/ignore-body' then
  begin
    // answers without reading the body
    AResponse.SendHeaders(200, Len(2), False);
    AResponse.Write(Bytes('ok'));
    AResponse.Finish;
  end
  else if Path = '/nocontent' then
  begin
    AResponse.SendHeaders(204, nil, True);
  end
  else if Path = '/notmodified' then
  begin
    AResponse.SendHeaders(304, Len(5), True);
  end
  else if Path = '/raise' then
    raise Exception.Create('the handler failed before the headers')
  else if Path = '/raise-late' then
  begin
    AResponse.SendHeaders(200, nil, False);
    AResponse.Write(Bytes('partial'));
    raise Exception.Create('the handler failed after the headers');
  end
  else if Path = '/slow' then
  begin
    Sleep(FSlowMs);
    AResponse.SendHeaders(200, Len(4), False);
    AResponse.Write(Bytes('slow'));
    AResponse.Finish;
  end
  else if Path = '/big' then
  begin
    SetLength(Part, 65536);
    FillChar(Part[0], Length(Part), Ord('x'));
    AResponse.SendHeaders(200, Len(16 * 65536), False);
    for I := 1 to 16 do
      AResponse.Write(Part);
    AResponse.Finish;
  end
  else if Path = '/own-date' then
  begin
    SetLength(H, 2);
    H[0].Name := 'date';
    H[0].Value := 'Mon, 01 Jan 2001 00:00:00 GMT';
    H[1].Name := 'content-length';
    H[1].Value := '0';
    AResponse.SendHeaders(200, H, True);
  end
  else if Path = '/bad-header' then
  begin
    SetLength(H, 1);
    H[0].Name := 'x-evil';
    H[0].Value := 'a' + CRLF + 'set-cookie: pwned';
    AResponse.SendHeaders(200, H, True);
  end
  else if Pos('/info', Path) = 1 then
  begin
    // the fields and parts of the request as the handler sees them
    Part := Bytes(ARequest.Method + ' ' + ARequest.Scheme + ' ' + ARequest.Authority +
      ' ' + ARequest.Path);
    AResponse.SendHeaders(200, Len(Length(Part)), False);
    AResponse.Write(Part);
    AResponse.Finish;
  end
  else
  begin
    AResponse.SendHeaders(404, Len(0), True);
  end;
end;

end.
