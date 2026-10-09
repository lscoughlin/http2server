{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, content-encoding
notes:
  - Covers the gzip and deflate codecs, the accept-encoding chooser, the
    header lookup of a request block, and the coding body writer.
---
}
unit Http2Server.Encoding.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Hpack, Http2Server.Seam, Http2Server.Encoding;

type
  TEncodingTest = class(TTestCase)
  private
    function BytesOf(const AText: string): TBytes;
    function TextOf(const AData: TBytes): string;
    function Compressible: TBytes;
    function BlockOf(const AName, AValue: string): THeaderBlock;
  published
    // the codecs
    procedure TestGzipRoundTrip;
    procedure TestGzipHeaderIsTheGzipContainer;
    procedure TestDeflateRoundTrip;
    procedure TestDeflateHeaderIsZlib;
    procedure TestRawDeflateRoundTrip;
    procedure TestDeflateDecompressAcceptsRawDeflate;
    procedure TestGzipCompressesRepetitiveInput;
    // CompressFor
    procedure TestCompressForIdentityReturnsTheInput;
    procedure TestCompressForGzipProducesAGzipContainer;
    procedure TestCompressForDeflateProducesAZlibContainer;
    // the chooser
    procedure TestNegotiateAbsentIsIdentity;
    procedure TestNegotiateGzipAndDeflatePrefersGzip;
    procedure TestNegotiateUnknownIsIdentity;
    procedure TestNegotiateGzipRefusedFallsToDeflate;
    procedure TestNegotiateWildcardSelectsGzip;
    procedure TestNegotiateQualityZeroOnBothIsIdentity;
    procedure TestNegotiateHigherQualityWins;
    // the header lookup
    procedure TestHeaderValueOfFindsTheName;
    procedure TestHeaderValueOfIsCaseInsensitive;
    procedure TestHeaderValueOfAbsentIsEmpty;
    procedure TestHeaderValueOfTakesTheFirst;
    // the body writer
    procedure TestCompressingWriterEmitsAGzipBody;
    procedure TestCompressingWriterEmitsADeflateBody;
    procedure TestCompressingWriterIsEmptyAware;
  end;

  /// a body writer over a fixed list of chunks
  TChunkWriter = class(TInterfacedObject, IBodyWriter)
  private
    FChunks: TArray<TBytes>;
    FNext: Integer;
  public
    constructor Create(const AChunks: array of TBytes);
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

procedure RegisterTests;

implementation

{ TChunkWriter }

constructor TChunkWriter.Create(const AChunks: array of TBytes);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FChunks, Length(AChunks));
  for I := 0 to High(AChunks) do
    FChunks[I] := Copy(AChunks[I], 0, Length(AChunks[I]));
  FNext := 0;
end;

function TChunkWriter.NextChunk(out ABuffer: TBytes): Boolean;
begin
  SetLength(ABuffer, 0);
  if FNext > High(FChunks) then
    Exit(False);
  ABuffer := FChunks[FNext];
  Inc(FNext);
  Result := True;
end;

{ TEncodingTest }

function TEncodingTest.BytesOf(const AText: string): TBytes;
begin
  Result := TEncoding.ANSI.GetBytes(AText);
end;

function TEncodingTest.TextOf(const AData: TBytes): string;
begin
  Result := TEncoding.ANSI.GetString(AData);
end;

function TEncodingTest.Compressible: TBytes;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 1 to 400 do
    S := S + 'the quick brown fox jumps over the lazy dog. ';
  Result := BytesOf(S);
end;

function TEncodingTest.BlockOf(const AName, AValue: string): THeaderBlock;
begin
  SetLength(Result, 1);
  Result[0].Name := AName;
  Result[0].Value := AValue;
  Result[0].Sensitive := False;
end;

procedure TEncodingTest.TestGzipRoundTrip;
var
  Data, Blob: TBytes;
begin
  Data := Compressible;
  Blob := GzipCompress(Data);
  AssertEquals('the round trip returns the input text', TextOf(Data),
    TextOf(GzipDecompress(Blob)));
end;

procedure TEncodingTest.TestGzipHeaderIsTheGzipContainer;
var
  Blob: TBytes;
begin
  Blob := GzipCompress(BytesOf('hello'));
  AssertEquals('the gzip signature byte 1', $1F, Blob[0]);
  AssertEquals('the gzip signature byte 2', $8B, Blob[1]);
  AssertEquals('the gzip compression method byte', 8, Blob[2]);
end;

procedure TEncodingTest.TestDeflateRoundTrip;
var
  Data, Blob: TBytes;
begin
  Data := Compressible;
  Blob := DeflateCompress(Data);
  AssertEquals('the round trip returns the input text', TextOf(Data),
    TextOf(DeflateDecompress(Blob)));
end;

procedure TEncodingTest.TestDeflateHeaderIsZlib;
var
  Blob: TBytes;
begin
  Blob := DeflateCompress(BytesOf('hello'));
  AssertEquals('the zlib method nibble', 8, Blob[0] and $0F);
  AssertEquals('the zlib header check bits', 0,
    (((Blob[0] shl 8) + Blob[1]) mod 31));
end;

procedure TEncodingTest.TestRawDeflateRoundTrip;
var
  Data, Blob: TBytes;
begin
  Data := Compressible;
  Blob := RawDeflateCompress(Data);
  AssertEquals('a bare deflate stream decodes', TextOf(Data),
    TextOf(DeflateDecompress(Blob)));
end;

procedure TEncodingTest.TestDeflateDecompressAcceptsRawDeflate;
var
  Raw: TBytes;
begin
  Raw := RawDeflateCompress(BytesOf('no zlib wrapper'));
  AssertEquals('a bare deflate stream is decoded', 'no zlib wrapper',
    TextOf(DeflateDecompress(Raw)));
end;

procedure TEncodingTest.TestGzipCompressesRepetitiveInput;
var
  Data, Blob: TBytes;
begin
  Data := Compressible;
  Blob := GzipCompress(Data);
  AssertTrue('repetitive input compresses',
    Length(Blob) < Length(Data) div 2);
end;

procedure TEncodingTest.TestCompressForIdentityReturnsTheInput;
var
  Data, Out32: TBytes;
begin
  Data := BytesOf('unchanged');
  Out32 := CompressFor(ceIdentity, Data);
  AssertEquals('identity returns the same bytes', 'unchanged', TextOf(Out32));
end;

procedure TEncodingTest.TestCompressForGzipProducesAGzipContainer;
var
  Blob: TBytes;
begin
  Blob := CompressFor(ceGzip, BytesOf('coded'));
  AssertEquals('the gzip signature byte 1', $1F, Blob[0]);
  AssertEquals('the body decodes', 'coded', TextOf(GzipDecompress(Blob)));
end;

procedure TEncodingTest.TestCompressForDeflateProducesAZlibContainer;
var
  Blob: TBytes;
begin
  Blob := CompressFor(ceDeflate, BytesOf('coded'));
  AssertEquals('the zlib method nibble', 8, Blob[0] and $0F);
  AssertEquals('the body decodes', 'coded', TextOf(DeflateDecompress(Blob)));
end;

procedure TEncodingTest.TestNegotiateAbsentIsIdentity;
begin
  AssertEquals('an absent header is identity', Ord(ceIdentity),
    Ord(NegotiateEncoding('')));
  AssertEquals('a blank header is identity', Ord(ceIdentity),
    Ord(NegotiateEncoding('  ')));
end;

procedure TEncodingTest.TestNegotiateGzipAndDeflatePrefersGzip;
begin
  AssertEquals('gzip wins at equal quality', Ord(ceGzip),
    Ord(NegotiateEncoding('gzip, deflate')));
end;

procedure TEncodingTest.TestNegotiateUnknownIsIdentity;
begin
  AssertEquals('an unoffered coding is never chosen', Ord(ceIdentity),
    Ord(NegotiateEncoding('br')));
end;

procedure TEncodingTest.TestNegotiateGzipRefusedFallsToDeflate;
begin
  AssertEquals('a refused gzip falls to deflate', Ord(ceDeflate),
    Ord(NegotiateEncoding('gzip;q=0, deflate')));
end;

procedure TEncodingTest.TestNegotiateWildcardSelectsGzip;
begin
  AssertEquals('a wildcard selects gzip', Ord(ceGzip),
    Ord(NegotiateEncoding('*')));
end;

procedure TEncodingTest.TestNegotiateQualityZeroOnBothIsIdentity;
begin
  AssertEquals('both refused is identity', Ord(ceIdentity),
    Ord(NegotiateEncoding('gzip;q=0, deflate;q=0')));
end;

procedure TEncodingTest.TestNegotiateHigherQualityWins;
begin
  AssertEquals('a higher-quality deflate wins', Ord(ceDeflate),
    Ord(NegotiateEncoding('gzip;q=0.5, deflate;q=0.9')));
  AssertEquals('a higher-quality gzip wins', Ord(ceGzip),
    Ord(NegotiateEncoding('gzip;q=0.9, deflate;q=0.5')));
end;

procedure TEncodingTest.TestHeaderValueOfFindsTheName;
begin
  AssertEquals('the value is found', 'gzip',
    HeaderValueOf(BlockOf('accept-encoding', 'gzip'), 'accept-encoding'));
end;

procedure TEncodingTest.TestHeaderValueOfIsCaseInsensitive;
begin
  AssertEquals('the name is compared without case', 'gzip',
    HeaderValueOf(BlockOf('Accept-Encoding', 'gzip'), 'accept-encoding'));
end;

procedure TEncodingTest.TestHeaderValueOfAbsentIsEmpty;
begin
  AssertEquals('an absent name is empty', '',
    HeaderValueOf(BlockOf('accept', 'text/plain'), 'accept-encoding'));
end;

procedure TEncodingTest.TestHeaderValueOfTakesTheFirst;
var
  Block: THeaderBlock;
begin
  SetLength(Block, 2);
  Block[0].Name := 'accept-encoding';
  Block[0].Value := 'gzip';
  Block[1].Name := 'accept-encoding';
  Block[1].Value := 'deflate';
  AssertEquals('the first value wins', 'gzip',
    HeaderValueOf(Block, 'accept-encoding'));
end;

function DrainWriter(const AWriter: IBodyWriter): TBytes;
var
  Chunk: TBytes;
begin
  SetLength(Result, 0);
  while AWriter.NextChunk(Chunk) do
  begin
    SetLength(Result, Length(Result) + Length(Chunk));
    if Length(Chunk) > 0 then
      Move(Chunk[0], Result[Length(Result) - Length(Chunk)], Length(Chunk));
  end;
end;

procedure TEncodingTest.TestCompressingWriterEmitsAGzipBody;
var
  Inner: IBodyWriter;
  Writer: IBodyWriter;
  Out32: TBytes;
begin
  Inner := TChunkWriter.Create([BytesOf('first '), BytesOf('second')]);
  Writer := TCompressingBodyWriter.Create(Inner, ceGzip);
  Out32 := DrainWriter(Writer);
  AssertEquals('the coded body carries the gzip signature', $1F, Out32[0]);
  AssertEquals('the coded body decodes', 'first second',
    TextOf(GzipDecompress(Out32)));
  // the gzip trail carries the input size (ISIZE, RFC 1952 section 2.3.1),
  // so this proves the footer reached the peer when the inner writer was
  // exhausted, not merely that the deflate stream inflates
  AssertEquals('the gzip trailer holds the input size', 12,
    Out32[Length(Out32) - 4] or (Out32[Length(Out32) - 3] shl 8));
end;

procedure TEncodingTest.TestCompressingWriterEmitsADeflateBody;
var
  Inner: IBodyWriter;
  Writer: IBodyWriter;
  Out32: TBytes;
begin
  Inner := TChunkWriter.Create([BytesOf('first '), BytesOf('second')]);
  Writer := TCompressingBodyWriter.Create(Inner, ceDeflate);
  Out32 := DrainWriter(Writer);
  AssertEquals('the coded body carries a zlib header', 8, Out32[0] and $0F);
  AssertEquals('the coded body decodes', 'first second',
    TextOf(DeflateDecompress(Out32)));
end;

procedure TEncodingTest.TestCompressingWriterIsEmptyAware;
var
  Inner: IBodyWriter;
  Writer: IBodyWriter;
  Out32: TBytes;
begin
  Inner := TChunkWriter.Create([]);
  Writer := TCompressingBodyWriter.Create(Inner, ceGzip);
  Out32 := DrainWriter(Writer);
  // an empty gzip stream is still a valid container (header + footer)
  AssertTrue('an empty body still produces a gzip container',
    Length(Out32) >= 18);
  AssertEquals('an empty coded body decodes to nothing', 0,
    Length(GzipDecompress(Out32)));
end;

procedure RegisterTests;
begin
  RegisterTest(TEncodingTest);
end;

initialization
  RegisterTests;

end.
