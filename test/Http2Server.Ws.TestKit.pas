{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, test kit, fake channel, session, recording handler, fpcunit
notes:
  - This unit holds the pieces that the session tests share. The fake channel
    behaves like the real ones. A pending channel holds the bytes that are sent,
    Activate releases them in order, Complete drops them.
  - The recording handler writes one line for each callback, with the thread that
    ran it, so a test checks the order and the thread rules.
  - The decoder reads the frames that the server sent, so a test sees messages and
    control frames and not octets.
---
}
/// Shared pieces of the WebSocket session tests
unit Http2Server.Ws.TestKit;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2Server.Errors, Http2Server.Hpack, Http2Server.Seam, Http2Server.Duplex,
  Http2Server.StreamPool, Http2Server.Limits, Http2Server.Observer,
  Http2Server.Ws.Options, Http2Server.Ws.Types, Http2Server.Ws.Frames,
  Http2Server.Ws.Parser, Http2Server.Ws.Reader, Http2Server.Ws.Environment,
  Http2Server.Ws.Session;

type
  /// a channel that records what the session does to it
  TFakeWsChannel = class(TInterfacedObject, IDuplexChannel)
  private
    FLock: TCriticalSection;
    FRegistry: IChannelRegistry;
    FHold: TBytes;
    FState: TChannelState;
  public
    Sent: TBytes;
    Sink: IChannelSink;
    ActivatedStatus: Integer;
    ActivatedHeaders: THeaderBlock;
    CompletedStatus: Integer;
    CompletedHeaders: THeaderBlock;
    CompletedBody: TBytes;
    Credit: Int64;
    CloseMode: TChannelClose;
    ClosedCount: Integer;
    /// when True, Send refuses and queues nothing
    Full: Boolean;
    constructor Create(const ARegistry: IChannelRegistry);
    destructor Destroy; override;
    function Send(const AData: TBytes): TSendResult;
    procedure Close(const AMode: TChannelClose);
    function IsOpen: Boolean;
    function State: TChannelState;
    function QueuedBytes: Int64;
    procedure SetSink(const ASink: IChannelSink);
    procedure ReturnCredit(const ACount: Int64);
    procedure Complete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    procedure Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
    function Registry: IChannelRegistry;
    /// the octets sent so far, a copy
    function SentBytes: TBytes;
    function Activated: Boolean;
    function Completed: Boolean;
    function IsClosed: Boolean;
    function CreditSoFar: Int64;
    /// deliver client frames to the session, as an IO thread does
    procedure Deliver(const AData: TBytes);
    procedure DeliverPeerClosed(const AClean: Boolean);
  end;

  TFakeHandshake = class(TInterfacedObject, IWsHandshake)
  public
    function Activation(const ASubprotocol: string;
      const AExtra: THeaderBlock): TWsActivation;
  end;

  /// what the server sent, decoded
  TWsOutput = record
    /// 'T:text', 'B:hex', 'P:hex' (ping), 'O:hex' (pong), 'C:code:reason'
    Items: TStringList;
    Failed: Boolean;
  end;

  /// the handler of the tests; it records every call
  TRecordingHandler = class(TInterfacedObject, IWsHandler)
  private
    FLock: TCriticalSection;
    FLines: TStringList;
    FThreads: TStringList;
  public
    /// what Init does
    InitResult: TWsInitResult;
    InitSleepMs: Integer;
    InitRaises: Boolean;
    InitSend: TBytes;
    InitSendText: Boolean;
    InitCloses: Boolean;
    InitSetsContext: Boolean;
    /// when True, Message echoes the message
    Echo: Boolean;
    MessageRaises: Boolean;
    /// when set, the first Message call waits on it
    Gate: PRTLEvent;
    OnMessageSleepMs: Integer;
    constructor Create;
    destructor Destroy; override;
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
    procedure Add(const ALine: string);
    function Lines: TStringList;
    function Count: Integer;
    function Line(const AIndex: Integer): string;
    function AllText: string;
    function ThreadOf(const AIndex: Integer): string;
  end;

  /// one server with a pool, a registry and an environment
  TWsRig = class
  private
    FPool: TStreamPool;
    FRegistryObj: TChannelRegistry;
  public
    Registry: IChannelRegistry;
    Env: TWsEnvironment;
    EnvRef: IInterface;
    Events: TStringList;
    EventLock: TCriticalSection;
    property Pool: TStreamPool read FPool;
    constructor Create(const AOptions: TWsOptions; const APoolSize: Integer = 1);
    destructor Destroy; override;
    procedure OnReport(const AEvent: TServerEvent);
    function NewChannel: TFakeWsChannel;
    function EventCount(const AKind: TServerEventKind): Integer;
  end;

/// a client frame, masked
function ClientFrame(const AOpcode: Byte; const AFin: Boolean; const APayload: TBytes;
  const AKey: LongWord = $01020304): TBytes;
function ClientText(const AText: string; const AFin: Boolean = True;
  const AOpcode: Byte = WsOpText): TBytes;
function ClientClose(const ACode: Word; const AReason: string = ''): TBytes;
function Cat(const A, B: TBytes): TBytes;
function BytesOf(const AText: string): TBytes;
function TextOf(const AData: TBytes): string;
function HexOf(const AData: TBytes): string;
/// decode the frames of the server output
function DecodeOutput(const AData: TBytes): TStringList;
type
  TWaitFn = function: Boolean of object;

/// wait until ACondition holds or ATimeoutMs passed; the caller asserts
function WaitUntil(const ACondition: TWaitFn; const ATimeoutMs: Integer = 5000): Boolean;

implementation

{ TFakeWsChannel }

constructor TFakeWsChannel.Create(const ARegistry: IChannelRegistry);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRegistry := ARegistry;
  FState := csPending;
end;

destructor TFakeWsChannel.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TFakeWsChannel.Send(const AData: TBytes): TSendResult;
begin
  FLock.Acquire;
  try
    if FState = csClosed then
      Exit(srClosed);
    if Full then
      Exit(srFull);
    if Length(AData) = 0 then
      Exit(srQueued);
    if FState = csPending then
    begin
      SetLength(FHold, Length(FHold) + Length(AData));
      Move(AData[0], FHold[Length(FHold) - Length(AData)], Length(AData));
    end
    else
    begin
      SetLength(Sent, Length(Sent) + Length(AData));
      Move(AData[0], Sent[Length(Sent) - Length(AData)], Length(AData));
    end;
    Result := srQueued;
  finally
    FLock.Release;
  end;
end;

procedure TFakeWsChannel.Close(const AMode: TChannelClose);
begin
  FLock.Acquire;
  try
    if FState <> csClosed then
    begin
      FState := csClosed;
      CloseMode := AMode;
    end;
    Inc(ClosedCount);
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := FState <> csClosed;
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.State: TChannelState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.QueuedBytes: Int64;
begin
  Result := 0;
end;

procedure TFakeWsChannel.SetSink(const ASink: IChannelSink);
begin
  Sink := ASink;
end;

procedure TFakeWsChannel.ReturnCredit(const ACount: Int64);
begin
  FLock.Acquire;
  try
    Inc(Credit, ACount);
  finally
    FLock.Release;
  end;
end;

procedure TFakeWsChannel.Complete(const AStatus: Integer;
  const AHeaders: THeaderBlock; const ABody: TBytes);
begin
  FLock.Acquire;
  try
    CompletedStatus := AStatus;
    CompletedHeaders := AHeaders;
    CompletedBody := ABody;
    FHold := nil;
    FState := csClosed;
  finally
    FLock.Release;
  end;
end;

procedure TFakeWsChannel.Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
begin
  FLock.Acquire;
  try
    ActivatedStatus := AStatus;
    ActivatedHeaders := AHeaders;
    Sent := FHold;
    FHold := nil;
    FState := csActive;
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.Registry: IChannelRegistry;
begin
  Result := FRegistry;
end;

function TFakeWsChannel.SentBytes: TBytes;
begin
  FLock.Acquire;
  try
    Result := Copy(Sent);
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.Activated: Boolean;
begin
  FLock.Acquire;
  try
    Result := ActivatedStatus <> 0;
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.Completed: Boolean;
begin
  FLock.Acquire;
  try
    Result := CompletedStatus <> 0;
  finally
    FLock.Release;
  end;
end;

function TFakeWsChannel.IsClosed: Boolean;
begin
  Result := not IsOpen;
end;

function TFakeWsChannel.CreditSoFar: Int64;
begin
  FLock.Acquire;
  try
    Result := Credit;
  finally
    FLock.Release;
  end;
end;

procedure TFakeWsChannel.Deliver(const AData: TBytes);
begin
  if Length(AData) > 0 then
    Sink.BytesReceived(AData[0], Length(AData));
end;

procedure TFakeWsChannel.DeliverPeerClosed(const AClean: Boolean);
begin
  Sink.PeerClosed(AClean);
end;

{ TFakeHandshake }

function TFakeHandshake.Activation(const ASubprotocol: string;
  const AExtra: THeaderBlock): TWsActivation;
var
  N: Integer;
begin
  Result := Default(TWsActivation);
  Result.Status := 200;
  Result.Headers := Copy(AExtra);
  if ASubprotocol <> '' then
  begin
    N := Length(Result.Headers);
    SetLength(Result.Headers, N + 1);
    Result.Headers[N].Name := 'sec-websocket-protocol';
    Result.Headers[N].Value := ASubprotocol;
  end;
end;

{ TRecordingHandler }

constructor TRecordingHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
  FThreads := TStringList.Create;
  InitResult := TWsInitResult.Accepted;
end;

destructor TRecordingHandler.Destroy;
begin
  FThreads.Free;
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRecordingHandler.Add(const ALine: string);
begin
  FLock.Acquire;
  try
    FLines.Add(ALine);
    if Http2IsStreamThread then
      FThreads.Add('pool')
    else if Http2IsIoThread then
      FThreads.Add('io')
    else
      FThreads.Add('other');
  finally
    FLock.Release;
  end;
end;

function TRecordingHandler.Lines: TStringList;
begin
  Result := FLines;
end;

function TRecordingHandler.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FLines.Count;
  finally
    FLock.Release;
  end;
end;

function TRecordingHandler.Line(const AIndex: Integer): string;
begin
  FLock.Acquire;
  try
    if AIndex < FLines.Count then
      Result := FLines[AIndex]
    else
      Result := '';
  finally
    FLock.Release;
  end;
end;

function TRecordingHandler.ThreadOf(const AIndex: Integer): string;
begin
  FLock.Acquire;
  try
    if AIndex < FThreads.Count then
      Result := FThreads[AIndex]
    else
      Result := '';
  finally
    FLock.Release;
  end;
end;

function TRecordingHandler.AllText: string;
begin
  FLock.Acquire;
  try
    Result := StringReplace(FLines.Text, #10, '|', [rfReplaceAll]);
  finally
    FLock.Release;
  end;
end;

function TRecordingHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
var
  I: Integer;
  S, Cookie: string;
begin
  S := '';
  for I := 0 to High(AOffered) do
    S := S + AOffered[I] + ',';
  Cookie := '';
  for I := 0 to High(ARequest.Headers) do
    if SameText(ARequest.Headers[I].Name, 'cookie') then
      Cookie := ARequest.Headers[I].Value;
  Add('init ' + ARequest.Path + ' offered=' + S + ' cookie=' + Cookie);
  if InitSleepMs > 0 then
    Sleep(InitSleepMs);
  if InitRaises then
    raise Exception.Create('Init failed');
  if InitSetsContext then
    ASession.SetContext(TInterfacedObject.Create);
  if Length(InitSend) > 0 then
    ASession.Send(InitSend, InitSendText);
  if InitCloses then
    ASession.Close(WsCloseNormal, 'bye from Init');
  Result := InitResult;
end;

procedure TRecordingHandler.Message(const ASession: IWsSession; const AData: TBytes;
  const AText: Boolean);
begin
  if Gate <> nil then
  begin
    RTLEventWaitFor(Gate);
    Gate := nil;
  end;
  if OnMessageSleepMs > 0 then
    Sleep(OnMessageSleepMs);
  if AText then
    Add('msg T ' + TextOf(AData))
  else
    Add('msg B ' + IntToStr(Length(AData)));
  if MessageRaises then
    raise Exception.Create('Message failed');
  if Echo then
    ASession.Send(AData, AText);
end;

procedure TRecordingHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
  Add('pong ' + TextOf(AData));
end;

procedure TRecordingHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  Add('closed ' + IntToStr(ACode) + ' ' + AReason + ' clean=' + BoolToStr(AClean, True));
end;

procedure TRecordingHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
  Add('failed ' + E.Message);
end;

{ TWsRig }

constructor TWsRig.Create(const AOptions: TWsOptions; const APoolSize: Integer);
begin
  inherited Create;
  Events := TStringList.Create;
  EventLock := TCriticalSection.Create;
  FPool := TStreamPool.Create(APoolSize);
  FRegistryObj := TChannelRegistry.Create(100000, 262144, 65536);
  FRegistryObj.SourceProvider := FPool.NewSource;
  Registry := FRegistryObj;
  Env := TWsEnvironment.Create(AOptions, TMonotonicClock.Create, OnReport);
  EnvRef := Env;
  FRegistryObj.Environment := EnvRef;
end;

destructor TWsRig.Destroy;
begin
  Env.Stop;
  FRegistryObj.SourceProvider := nil;
  FPool.Free;
  FRegistryObj.Environment := nil;
  EnvRef := nil;
  Registry := nil;
  EventLock.Free;
  Events.Free;
  inherited Destroy;
end;

procedure TWsRig.OnReport(const AEvent: TServerEvent);
const
  Names: array[TServerEventKind] of string = ('', '', '', '', '', '', '', '', '', '',
    'handler-exception', '', '', 'ws-opened', 'ws-rejected', 'ws-closed', 'ws-failed',
    'ws-bucket', 'tls-handshake-failed');
begin
  EventLock.Acquire;
  try
    Events.Add(Names[AEvent.Kind] + ':' + IntToStr(AEvent.WsCode));
  finally
    EventLock.Release;
  end;
end;

function TWsRig.NewChannel: TFakeWsChannel;
var
  Ch: IDuplexChannel;
begin
  Result := TFakeWsChannel.Create(Registry);
  Ch := Result;
  // the registry counts a detached channel and lists it, as the real ones do
  Registry.TryAcquire;
  Registry.Add(Ch);
end;

function TWsRig.EventCount(const AKind: TServerEventKind): Integer;
const
  Names: array[TServerEventKind] of string = ('', '', '', '', '', '', '', '', '', '',
    'handler-exception', '', '', 'ws-opened', 'ws-rejected', 'ws-closed', 'ws-failed',
    'ws-bucket', 'tls-handshake-failed');
var
  I: Integer;
begin
  Result := 0;
  EventLock.Acquire;
  try
    for I := 0 to Events.Count - 1 do
      if Pos(Names[AKind] + ':', Events[I]) = 1 then
        Inc(Result);
  finally
    EventLock.Release;
  end;
end;

{ helpers }

function Cat(const A, B: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

function BytesOf(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

function HexOf(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AData) do
    Result := Result + IntToHex(AData[I], 2);
end;

function ClientFrame(const AOpcode: Byte; const AFin: Boolean; const APayload: TBytes;
  const AKey: LongWord): TBytes;
begin
  Result := WsEncodeFrame(AOpcode, AFin, APayload, True, WsMaskKeyFromLongWord(AKey));
end;

function ClientText(const AText: string; const AFin: Boolean; const AOpcode: Byte): TBytes;
begin
  Result := ClientFrame(AOpcode, AFin, BytesOf(AText));
end;

function ClientClose(const ACode: Word; const AReason: string): TBytes;
begin
  Result := ClientFrame(WsOpClose, True, WsBuildClosePayload(ACode, RawByteString(AReason)));
end;

type
  TDecodeSink = class(TInterfacedObject, IWsReaderSink)
  public
    Items: TStringList;
    procedure Message(const AText: Boolean; const AData: TBytes);
    procedure Control(const AOpcode: Byte; const AData: TBytes);
  end;

procedure TDecodeSink.Message(const AText: Boolean; const AData: TBytes);
begin
  if AText then
    Items.Add('T:' + TextOf(AData))
  else
    Items.Add('B:' + HexOf(AData));
end;

procedure TDecodeSink.Control(const AOpcode: Byte; const AData: TBytes);
var
  Code: Integer;
  Reason: RawByteString;
begin
  case AOpcode of
    WsOpPing: Items.Add('P:' + HexOf(AData));
    WsOpPong: Items.Add('O:' + HexOf(AData));
    WsOpClose:
      begin
        WsParseClosePayload(AData, Code, Reason);
        Items.Add('C:' + IntToStr(Code) + ':' + string(Reason));
      end;
  end;
end;

function DecodeOutput(const AData: TBytes): TStringList;
var
  Limits: TWsLimits;
  Reader: TWsReader;
  Sink: TDecodeSink;
  Ref: IWsReaderSink;
begin
  Result := TStringList.Create;
  Limits.MaxFrameSize := 1 shl 24;
  Limits.MaxMessageSize := 1 shl 26;
  Limits.MaxFragments := 1000000;
  Reader := TWsReader.Create(Limits, {ARequireMasked=}False);
  Sink := TDecodeSink.Create;
  Sink.Items := Result;
  Ref := Sink;
  try
    if Length(AData) > 0 then
      if not Reader.Feed(AData[0], Length(AData), Ref) then
        Result.Add('DECODE-FAILED:' + IntToStr(Reader.Failure.Code));
  finally
    Reader.Free;
  end;
end;

function WaitUntil(const ACondition: TWaitFn; const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if ACondition() then
      Exit(True);
    Sleep(2);
  until GetTickCount64 >= Deadline;
  Result := ACondition();
end;

end.
