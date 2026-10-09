{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, content-encoding, gzip
notes:
  - Copied from the sibling HTTP/2 client project, source file
    Http2.Encoding.pas.  The unit name and every uses reference are renamed
    into the Http2Server namespace.  The parts that need a client response
    object are dropped, and TCompressingBodyWriter is added for the server
    body-writer seam.
  - The codecs use the zlib bindings that Free Pascal ships with the
    compiler (paszlib/zstream), so the unit adds no third-party dependency.
---
}
/// Content coding (gzip and deflate) for response bodies
// - the server never codes a body on its own. A handler that wants a coded
//   response reads `accept-encoding` from the request, calls
//   NegotiateEncoding, and writes the coded bytes itself, or hands
//   TCompressingBodyWriter to IServerResponse.SetBodyWriter.
// - coding is never applied when the peer did not offer it: an absent or
//   empty `accept-encoding` yields ceIdentity, which is the answer
//   NegotiateEncoding gives.
unit Http2Server.Encoding;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes,
  Http2Server.Hpack, Http2Server.Seam, zstream;

type
  /// the content codings this server can produce
  TContentEncoding = (
    /// no coding; the body is already plain
    ceIdentity,
    /// the gzip container of RFC 1952
    ceGzip,
    /// the zlib container of RFC 1950
    ceDeflate
  );

/// the coding named by an `accept-encoding` value, in the RFC 9110 section
/// 12.5.3 quality-value grammar
// - an absent or empty value yields ceIdentity. `gzip;q=0` rejects gzip, `*`
//   covers every coding, and a coding the peer did not offer is never
//   chosen. When two codings are acceptable, the greater quality wins, and
//   an equal quality breaks toward gzip: every `deflate` reader in the field
//   tolerates gzip, and gzip carries an integrity check.
function NegotiateEncoding(const AAcceptEncoding: string): TContentEncoding;

/// the coding named by a `content-encoding` value, or ceIdentity
// - the value is a list; the first coding this server understands wins,
//   because a chain it does not know cannot be produced
function ParseContentEncoding(const AValue: string): TContentEncoding;

/// the token to put in `content-encoding` for ACoding ('' for identity)
function EncodingToken(const ACoding: TContentEncoding): string;

/// true when the coding codes the body rather than passing it through
function IsEncoded(const ACoding: TContentEncoding): Boolean;

/// compress AData into a gzip container
function GzipCompress(const AData: TBytes): TBytes;
/// compress AData into a zlib container
function DeflateCompress(const AData: TBytes): TBytes;
/// compress AData into a bare deflate stream (no zlib header)
function RawDeflateCompress(const AData: TBytes): TBytes;

/// decompress a gzip container
function GzipDecompress(const AData: TBytes): TBytes;
/// decompress a deflate body, zlib-wrapped or bare
// - many clients send a bare deflate stream under the name `deflate`, so the
//   container is detected from the first two bytes rather than assumed
function DeflateDecompress(const AData: TBytes): TBytes;

/// compact AData for ACoding, or return AData when the coding is identity
function CompressFor(const ACoding: TContentEncoding;
  const AData: TBytes): TBytes;

/// the first value of AName in AHeaders, or '' when the name is absent
// - header names are compared without case, as RFC 9113 section 8.2 requires
function HeaderValueOf(const AHeaders: THeaderBlock;
  const AName: string): string;

type
  /// a body writer that codes every chunk of another body writer
  ///
  /// The writer is the server's opt-in path for a coded response: build it
  /// over the handler's own writer and hand it to SetBodyWriter. The gzip
  /// container is closed when the inner writer is exhausted, so the footer
  /// reaches the peer before the response ends. `content-length` must not be
  /// sent with a coded body, because the coded size is unknown before the
  /// stream ends; HTTP/2 delimits the body by END_STREAM.
  TCompressingBodyWriter = class(TInterfacedObject, IBodyWriter)
  private
    FInner: IBodyWriter;
    FCoding: TContentEncoding;
    FSink: TMemoryStream;
    FCoder: TStream;
    FDone: Boolean;
    FStarted: Boolean;
    procedure StartCoder;
    /// the bytes the coder produced since the last take
    function Take: TBytes;
  public
    constructor Create(const AInner: IBodyWriter;
      const ACoding: TContentEncoding);
    destructor Destroy; override;
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

implementation

function ContainsToken(const AList, AToken: string): Boolean;
var
  P, Start: Integer;
  Item, Name: string;
begin
  Result := False;
  Start := 1;
  for P := 1 to Length(AList) + 1 do
  begin
    if (P > Length(AList)) or (AList[P] = ',') then
    begin
      Item := Trim(Copy(AList, Start, P - Start));
      Start := P + 1;
      if Item <> '' then
      begin
        if Pos(';', Item) > 0 then
          Name := Trim(Copy(Item, 1, Pos(';', Item) - 1))
        else
          Name := Item;
        if SameText(Name, AToken) then
          Exit(True);
      end;
    end;
  end;
end;

function ParseContentEncoding(const AValue: string): TContentEncoding;
var
  P, Start: Integer;
  Item, Name: string;
begin
  Result := ceIdentity;
  Start := 1;
  for P := 1 to Length(AValue) + 1 do
  begin
    if (P > Length(AValue)) or (AValue[P] = ',') then
    begin
      Item := Trim(Copy(AValue, Start, P - Start));
      Start := P + 1;
      if Item <> '' then
      begin
        if Pos(';', Item) > 0 then
          Name := Trim(Copy(Item, 1, Pos(';', Item) - 1))
        else
          Name := Item;
        if SameText(Name, 'gzip') or SameText(Name, 'x-gzip') then
          Exit(ceGzip);
        if SameText(Name, 'deflate') then
          Exit(ceDeflate);
      end;
    end;
  end;
end;

function NegotiateEncoding(const AAcceptEncoding: string): TContentEncoding;
var
  P, Start, Semi: Integer;
  Item, Name, Params: string;
  QGzip, QDeflate, QStar, Q: Single;
  HasGzip, HasDeflate, HasStar: Boolean;

  function ParseQuality(const AParams: string): Single;
  var
    Seg: string;
    SStart, SP, Eq: Integer;
  begin
    Result := 1.0;
    SStart := 1;
    for SP := 1 to Length(AParams) + 1 do
    begin
      if (SP > Length(AParams)) or (AParams[SP] = ';') then
      begin
        Seg := Trim(Copy(AParams, SStart, SP - SStart));
        SStart := SP + 1;
        Eq := Pos('=', Seg);
        if (Eq > 0) and SameText(Trim(Copy(Seg, 1, Eq - 1)), 'q') then
        begin
          Result := StrToFloatDef(Trim(Copy(Seg, Eq + 1, MaxInt)), 1.0);
          if Result < 0 then
            Result := 0;
          if Result > 1 then
            Result := 1;
        end;
      end;
    end;
  end;

begin
  Result := ceIdentity;
  if Trim(AAcceptEncoding) = '' then
    Exit;

  QGzip := -1;
  QDeflate := -1;
  QStar := -1;
  HasGzip := False;
  HasDeflate := False;
  HasStar := False;

  // A coding with no quality parameter counts as q=1, and a repeated name
  // keeps the greatest of its qualities, which is what the grammar allows
  // and what a real client sends.
  Start := 1;
  for P := 1 to Length(AAcceptEncoding) + 1 do
  begin
    if (P > Length(AAcceptEncoding)) or (AAcceptEncoding[P] = ',') then
    begin
      Item := Trim(Copy(AAcceptEncoding, Start, P - Start));
      Start := P + 1;
      if Item <> '' then
      begin
        Semi := Pos(';', Item);
        if Semi > 0 then
        begin
          Name := Trim(Copy(Item, 1, Semi - 1));
          Params := Copy(Item, Semi + 1, MaxInt);
        end
        else
        begin
          Name := Item;
          Params := '';
        end;
        Q := ParseQuality(Params);
        if SameText(Name, 'gzip') or SameText(Name, 'x-gzip') then
        begin
          if Q > QGzip then
            QGzip := Q;
          HasGzip := True;
        end
        else if SameText(Name, 'deflate') then
        begin
          if Q > QDeflate then
            QDeflate := Q;
          HasDeflate := True;
        end
        else if Name = '*' then
        begin
          if Q > QStar then
            QStar := Q;
          HasStar := True;
        end;
      end;
    end;
  end;

  if HasGzip and (QGzip > 0) and ((not HasDeflate) or (QGzip >= QDeflate)) then
    Exit(ceGzip);
  if HasDeflate and (QDeflate > 0) then
    Exit(ceDeflate);
  // A wildcard stands in for a coding the peer did not name, so gzip is the
  // answer when it is acceptable. gzip is preferred over deflate because
  // every `deflate` reader in the field tolerates it and it is a container
  // with an integrity check.
  if HasStar and (QStar > 0) then
    Exit(ceGzip);
  Result := ceIdentity;
end;

function EncodingToken(const ACoding: TContentEncoding): string;
begin
  case ACoding of
    ceGzip: Result := 'gzip';
    ceDeflate: Result := 'deflate';
  else
    Result := '';
  end;
end;

function IsEncoded(const ACoding: TContentEncoding): Boolean;
begin
  Result := ACoding <> ceIdentity;
end;

function HeaderValueOf(const AHeaders: THeaderBlock;
  const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Name, AName) then
      Exit(AHeaders[I].Value);
end;

function CompressInto(const AData: TBytes; const ALevel: TCompressionLevel;
  const AGzip, ASkipHeader: Boolean): TBytes;
var
  Dest: TMemoryStream;
  C: TStream;
begin
  SetLength(Result, 0);
  Dest := TMemoryStream.Create;
  try
    if AGzip then
      C := TGZipCompressionStream.Create(ALevel, Dest)
    else
      C := TCompressionStream.Create(ALevel, Dest, ASkipHeader);
    try
      if Length(AData) > 0 then
        C.Write(AData[0], Length(AData));
    finally
      // the destructor flushes the final block and writes the gzip footer
      C.Free;
    end;
    SetLength(Result, Dest.Size);
    if Dest.Size > 0 then
    begin
      Dest.Position := 0;
      Dest.ReadBuffer(Result[0], Dest.Size);
    end;
  finally
    Dest.Free;
  end;
end;

function GzipCompress(const AData: TBytes): TBytes;
begin
  Result := CompressInto(AData, clDefault, True, False);
end;

function DeflateCompress(const AData: TBytes): TBytes;
begin
  Result := CompressInto(AData, clDefault, False, False);
end;

function RawDeflateCompress(const AData: TBytes): TBytes;
begin
  Result := CompressInto(AData, clDefault, False, True);
end;

function InflateAll(const AData: TBytes; const AGzip, ASkipHeader: Boolean)
  : TBytes;
var
  Src, Dst: TMemoryStream;
  D: TStream;
  Buf: array[0..16383] of Byte;
  N: LongInt;
begin
  SetLength(Result, 0);
  Src := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    if Length(AData) > 0 then
      Src.Write(AData[0], Length(AData));
    Src.Position := 0;
    if AGzip then
      D := TGZipDecompressionStream.Create(Src)
    else
      D := TDecompressionStream.Create(Src, ASkipHeader);
    try
      repeat
        N := D.Read(Buf[0], SizeOf(Buf));
        if N > 0 then
          Dst.Write(Buf[0], N);
      until N <= 0;
    finally
      D.Free;
    end;
    SetLength(Result, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Result[0], Dst.Size);
    end;
  finally
    Dst.Free;
    Src.Free;
  end;
end;

function GzipDecompress(const AData: TBytes): TBytes;
begin
  Result := InflateAll(AData, True, False);
end;

function LooksZlib(const AData: TBytes): Boolean;
var
  CMF, FLG: Integer;
begin
  Result := False;
  if Length(AData) < 2 then
    Exit;
  CMF := AData[0];
  FLG := AData[1];
  // RFC 1950 section 2.2: the low nibble is the method (8 = deflate) and the
  // two header bytes are a multiple of 31
  Result := ((CMF and $0F) = 8) and (((CMF shl 8) + FLG) mod 31 = 0);
end;

function DeflateDecompress(const AData: TBytes): TBytes;
begin
  if LooksZlib(AData) then
    Result := InflateAll(AData, False, False)
  else
    Result := InflateAll(AData, False, True);
end;

function CompressFor(const ACoding: TContentEncoding;
  const AData: TBytes): TBytes;
begin
  case ACoding of
    ceGzip: Result := GzipCompress(AData);
    ceDeflate: Result := DeflateCompress(AData);
  else
    Result := AData;
  end;
end;

{ TCompressingBodyWriter }

constructor TCompressingBodyWriter.Create(const AInner: IBodyWriter;
  const ACoding: TContentEncoding);
begin
  inherited Create;
  FInner := AInner;
  FCoding := ACoding;
  FSink := TMemoryStream.Create;
  FDone := False;
  FStarted := False;
end;

destructor TCompressingBodyWriter.Destroy;
begin
  FCoder.Free;
  FSink.Free;
  inherited Destroy;
end;

procedure TCompressingBodyWriter.StartCoder;
begin
  if FStarted then
    Exit;
  FStarted := True;
  if FCoding = ceGzip then
    FCoder := TGZipCompressionStream.Create(clDefault, FSink)
  else
    FCoder := TCompressionStream.Create(clDefault, FSink);
end;

function TCompressingBodyWriter.Take: TBytes;
var
  N: Int64;
begin
  SetLength(Result, 0);
  // the coder advances the position to the end as it writes, so the bytes
  // present are read from the start of the sink
  N := FSink.Size;
  if N <= 0 then
    Exit;
  FSink.Position := 0;
  SetLength(Result, N);
  FSink.ReadBuffer(Result[0], N);
  // the sink is drained, so it can start over
  FSink.Size := 0;
  FSink.Position := 0;
end;

function TCompressingBodyWriter.NextChunk(out ABuffer: TBytes): Boolean;
var
  Inner: TBytes;
begin
  SetLength(ABuffer, 0);
  if FDone then
    Exit(False);
  StartCoder;
  while True do
  begin
    if not FInner.NextChunk(Inner) then
    begin
      // the inner writer is exhausted: close the container so the footer
      // reaches the peer, then emit whatever is left
      FCoder.Free;
      FCoder := nil;
      FDone := True;
      ABuffer := Take;
      Exit(Length(ABuffer) > 0);
    end;
    if Length(Inner) > 0 then
      FCoder.Write(Inner[0], Length(Inner));
    ABuffer := Take;
    if Length(ABuffer) > 0 then
      Exit(True);
  end;
end;

end.
