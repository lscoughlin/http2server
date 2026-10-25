{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, seam, handler, request, response, adapter
notes:
  - This unit holds the handler-side request and response adapters. Each one
    wraps one TServerStream and implements the seam interfaces.
  - The handler pool builds a fresh pair for each dispatch.
---
}
/// The handler-side request and response of one stream
// - the adapters move bytes only and convert no text encoding, as the seam
//   requires
unit Http2Server.StreamAdapters;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes,
  Http2Server.Errors,
  Http2Server.Hpack,
  Http2Server.Headers,
  Http2Server.Seam,
  Http2Server.ClientCert,
  Http2Server.AccessLog,
  Http2Server.ResponseWriter,
  Http2Server.Waiter,
  Http2Server.Stream,
  Http2Server.Duplex,
  Http2Server.StreamChannel;

type
  /// what an upgrade needs to know of an HTTP/2 request: the :protocol pseudo-header
  IH2ConnectRequest = interface
    ['{7E1F0C11-00C6-4A11-9C72-000000000F06}']
    /// the value of :protocol, or an empty text for a request that has none
    function Protocol: string;
  end;

  /// what an upgrade needs from an HTTP/2 response: the WebSocket environment
  IH2Upgradable = interface
    ['{7E1F0C11-00C7-4A11-9C72-000000000F07}']
    function WsEnvironment: IInterface;
  end;

  /// the report of a detach: the stream, and True when the registry refused it
  TDetachNotify = procedure(const AStream: TServerStream;
    const ARefused: Boolean) of object;

  /// The request as one handler sees it, backed by one TServerStream.
  ///
  /// The adapter is byte-oriented, as the seam requires.  The pseudo-headers
  /// come from the decoded request block of the stream.
  TServerStreamRequest = class(TInterfacedObject, IServerRequest, IH2ConnectRequest)
  private
    FStream: TServerStream;
    FPrincipal: string;
    function PseudoValue(const AName: string): string;
  public
    constructor Create(const AStream: TServerStream);
    function GetPrincipal: string;
    procedure SetPrincipal(const AValue: string);
    function GetClientCertificate: IClientCertificate;
    function Method: string;
    function Scheme: string;
    function Authority: string;
    function Path: string;
    function Headers: THeaderBlock;
    function Read(var ABuffer; const ACount: Integer): Integer;
    function ReadChunk(out AChunk: TBytes): Boolean;
    function BodyIsComplete: Boolean;
    function IsCancelled: Boolean;
    function StreamId: LongWord;
    function Protocol: string;
  end;

  /// The response as one handler writes it, backed by one TServerStream.
  ///
  /// SendHeaders holds the response block for the IO side, which owns the
  /// HPACK encoder.  A body writer is pulled when the handler calls Finish.
  TServerStreamResponse = class(TInterfacedObject, IServerResponse, IH2Upgradable,
    IAccessLogProbe)
  private
    FStatus: Integer;
    FBodyOctets: Int64;
    FStream: TServerStream;
    FBodyWriter: IBodyWriter;
    FHeadersSent: Boolean;
    FRegistry: IChannelRegistry;
    FDetached: Boolean;
    FOnDetach: TDetachNotify;
    procedure CheckNotDetached;
  public
    /// ARegistry limits and lists the detached streams of the server; a nil
    /// registry detaches without a limit
    constructor Create(const AStream: TServerStream;
      const ARegistry: IChannelRegistry = nil);
    procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure Write(const AData: TBytes); overload;
    procedure Write(const ABuffer; const ACount: Integer); overload;
    procedure SetBodyWriter(const AWriter: IBodyWriter);
    procedure Finish;
    procedure RegisterCancelHook(const AHook: TCancelHook);
    function IsCancelled: Boolean;
    function StreamId: LongWord;
    function Detach: IDuplexChannel;
    function WsEnvironment: IInterface;
    // IAccessLogProbe
    function LoggedStatus: Integer;
    function LoggedBodyOctets: Int64;
    function LoggedRemoteAddress: string;
    function LoggedProtocol: string;
    /// the report of a detach, for the observer of the server
    property OnDetach: TDetachNotify read FOnDetach write FOnDetach;
    /// true once the handler detached the stream
    property Detached: Boolean read FDetached;
    /// true once the handler sent the response headers
    property HeadersSent: Boolean read FHeadersSent;
  end;

implementation

{ TServerStreamRequest }

constructor TServerStreamRequest.Create(const AStream: TServerStream);
begin
  inherited Create;
  FStream := AStream;
  // the certificate belongs to the connection; its principal text is empty
  // unless the caller asked for one
  if (AStream <> nil) and (AStream.ClientCertificate <> nil) then
    FPrincipal := AStream.ClientCertificate.PrincipalText;
end;

function TServerStreamRequest.GetClientCertificate: IClientCertificate;
begin
  Result := nil;
  if FStream <> nil then
    Result := FStream.ClientCertificate;
end;

function TServerStreamRequest.GetPrincipal: string;
begin
  Result := FPrincipal;
end;

procedure TServerStreamRequest.SetPrincipal(const AValue: string);
begin
  FPrincipal := AValue;
end;

function TServerStreamRequest.PseudoValue(const AName: string): string;
var
  H: THeaderBlock;
  I: Integer;
begin
  Result := '';
  H := FStream.RemoteHeaders;
  for I := 0 to High(H) do
    if H[I].Name = AName then
      Exit(H[I].Value);
end;

function TServerStreamRequest.Method: string;
begin
  Result := PseudoValue(HeaderMethod);
end;

function TServerStreamRequest.Scheme: string;
begin
  Result := PseudoValue(HeaderScheme);
end;

function TServerStreamRequest.Authority: string;
begin
  Result := PseudoValue(HeaderAuthority);
end;

function TServerStreamRequest.Path: string;
begin
  Result := PseudoValue(HeaderPath);
end;

function TServerStreamRequest.Headers: THeaderBlock;
var
  H: THeaderBlock;
  I, N: Integer;
begin
  Result := nil;
  H := FStream.RemoteHeaders;
  SetLength(Result, Length(H));
  N := 0;
  for I := 0 to High(H) do
    if (Length(H[I].Name) = 0) or (H[I].Name[1] <> ':') then
    begin
      Result[N] := H[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

function TServerStreamRequest.Read(var ABuffer;
  const ACount: Integer): Integer;
begin
  Result := FStream.Read(ABuffer, ACount);
end;

function TServerStreamRequest.ReadChunk(out AChunk: TBytes): Boolean;
begin
  Result := FStream.ReadChunk(AChunk);
end;

function TServerStreamRequest.BodyIsComplete: Boolean;
begin
  Result := FStream.BodyIsComplete;
end;

function TServerStreamRequest.IsCancelled: Boolean;
begin
  Result := FStream.IsCancelled;
end;

function TServerStreamRequest.StreamId: LongWord;
begin
  Result := FStream.StreamId;
end;

function TServerStreamRequest.Protocol: string;
begin
  Result := PseudoValue(':protocol');
end;

{ TServerStreamResponse }

function TServerStreamResponse.WsEnvironment: IInterface;
begin
  if FRegistry = nil then
    Result := nil
  else
    Result := FRegistry.WsEnvironment;
end;

constructor TServerStreamResponse.Create(const AStream: TServerStream;
  const ARegistry: IChannelRegistry);
begin
  inherited Create;
  FStream := AStream;
  FRegistry := ARegistry;
end;

procedure TServerStreamResponse.CheckNotDetached;
begin
  if FDetached then
    raise EHttpError.Create(
      'the response is detached: use the channel that Detach returned');
end;

function TServerStreamResponse.Detach: IDuplexChannel;
begin
  CheckNotDetached;
  // before SendHeaders the channel is pending: no response has left yet
  try
    Result := THttp2StreamChannel.Attach(FStream, FRegistry, not FHeadersSent);
  except
    on EDetachRefused do
    begin
      if Assigned(FOnDetach) then
        FOnDetach(FStream, True);
      raise;
    end;
  end;
  FDetached := True;
  if Assigned(FOnDetach) then
    FOnDetach(FStream, False);
end;

procedure TServerStreamResponse.SendHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
var
  Prepared: THeaderBlock;
begin
  CheckNotDetached;
  // a refused header block leaves no trace: the state changes after the check
  CheckResponseHeaders(AHeaders);
  Prepared := WithDate(PrepareH2ResponseHeaders(AHeaders), AStatus);
  FHeadersSent := True;
  // an interim status (1xx) is not the final status
  if AStatus >= 200 then
    FStatus := AStatus;
  FStream.QueueResponseHeaders(AStatus, Prepared, AEndStream);
end;

procedure TServerStreamResponse.Write(const AData: TBytes);
begin
  CheckNotDetached;
  FStream.Write(AData);
  Inc(FBodyOctets, Length(AData));
end;

procedure TServerStreamResponse.Write(const ABuffer; const ACount: Integer);
begin
  CheckNotDetached;
  FStream.Write(ABuffer, ACount);
  if ACount > 0 then
    Inc(FBodyOctets, ACount);
end;

procedure TServerStreamResponse.SetBodyWriter(const AWriter: IBodyWriter);
begin
  CheckNotDetached;
  FBodyWriter := AWriter;
end;

procedure TServerStreamResponse.Finish;
var
  Chunk: TBytes;
begin
  CheckNotDetached;
  if FBodyWriter <> nil then
    while FBodyWriter.NextChunk(Chunk) do
    begin
      FStream.Write(Chunk);
      Inc(FBodyOctets, Length(Chunk));
    end;
  FStream.RequestFinish;
end;

function TServerStreamResponse.LoggedStatus: Integer;
begin
  Result := FStatus;
end;

function TServerStreamResponse.LoggedBodyOctets: Int64;
begin
  Result := FBodyOctets;
end;

function TServerStreamResponse.LoggedRemoteAddress: string;
begin
  Result := FStream.RemoteAddress;
end;

function TServerStreamResponse.LoggedProtocol: string;
begin
  Result := 'HTTP/2.0';
end;

procedure TServerStreamResponse.RegisterCancelHook(const AHook: TCancelHook);
var
  W: IStreamWaiter;
begin
  W := FStream.Waiter;
  // the default waiter is a TBlockingWaiter and holds the hook slot; another
  // IStreamWaiter has no hook slot
  if W is TBlockingWaiter then
    (W as TBlockingWaiter).RegisterHook(AHook);
end;

function TServerStreamResponse.IsCancelled: Boolean;
begin
  Result := FStream.IsCancelled;
end;

function TServerStreamResponse.StreamId: LongWord;
begin
  Result := FStream.StreamId;
end;

end.
