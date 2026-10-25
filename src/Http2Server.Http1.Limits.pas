{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, limits, request line, header, chunk, trailer, body, pipelining
notes:
  - This unit holds the limits of the HTTP/1.1 request parser as a record of the
    server builder. The limits are never process-wide globals.
  - The parser of mORMot2 has its own ceilings in the variables
    MaxHttpHeaderLineSize and MaxHttpChunkSize. The server never writes them.
    A limit of this record can be lower than the variable but not higher, and
    Problems reports a limit above the variable.
---
}
/// The limits of the HTTP/1.1 request parser
unit Http2Server.Http1.Limits;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// the limits of one HTTP/1.1 connection, set on the server builder
  THttp11Limits = record
  private
    FMaxRequestLine: Integer;
    FMaxHeaderLine: Integer;
    FMaxHeaderCount: Integer;
    FMaxHeaderOctets: Integer;
    FMaxChunkSize: Integer;
    FMaxChunkExtension: Integer;
    FMaxTrailerOctets: Integer;
    FMaxBodySize: Int64;
    FMaxPipelinedOctets: Integer;
    FBodyDeadlineMs: Integer;
    FBodyTotalMs: Integer;
  public
    /// the defaults of the limits
    class function Create: THttp11Limits; static;
    /// the greatest length of the request line, in octets
    function WithMaxRequestLine(const AValue: Integer): THttp11Limits;
    /// the greatest length of one header line, in octets
    function WithMaxHeaderLine(const AValue: Integer): THttp11Limits;
    /// the greatest number of header lines
    function WithMaxHeaderCount(const AValue: Integer): THttp11Limits;
    /// the greatest size of the whole header section, in octets
    function WithMaxHeaderOctets(const AValue: Integer): THttp11Limits;
    /// the greatest chunk of a chunked body, in octets
    function WithMaxChunkSize(const AValue: Integer): THttp11Limits;
    /// the greatest length of the extension on a chunk-size line, in octets
    function WithMaxChunkExtension(const AValue: Integer): THttp11Limits;
    /// the greatest size of the trailer section, in octets
    function WithMaxTrailerOctets(const AValue: Integer): THttp11Limits;
    /// the greatest request body, in octets
    function WithMaxBodySize(const AValue: Int64): THttp11Limits;
    /// the greatest number of octets of the next requests that the server holds
    function WithMaxPipelinedOctets(const AValue: Integer): THttp11Limits;
    /// the greatest wait between two reads of a request body, in milliseconds
    function WithBodyDeadlineMs(const AValue: Integer): THttp11Limits;
    /// the greatest time from the request head to the end of its body, in
    /// milliseconds; 0 turns the limit off
    // - a peer that sends one octet before each idle deadline passes the idle
    //   limit, so this limit bounds the time a handler waits for a body
    function WithBodyTotalMs(const AValue: Integer): THttp11Limits;

    /// add one text to AProblems for each limit that is not usable
    procedure Problems(var AProblems: TArray<string>);

    property MaxRequestLine: Integer read FMaxRequestLine;
    property MaxHeaderLine: Integer read FMaxHeaderLine;
    property MaxHeaderCount: Integer read FMaxHeaderCount;
    property MaxHeaderOctets: Integer read FMaxHeaderOctets;
    property MaxChunkSize: Integer read FMaxChunkSize;
    property MaxChunkExtension: Integer read FMaxChunkExtension;
    property MaxTrailerOctets: Integer read FMaxTrailerOctets;
    property MaxBodySize: Int64 read FMaxBodySize;
    property MaxPipelinedOctets: Integer read FMaxPipelinedOctets;
    property BodyDeadlineMs: Integer read FBodyDeadlineMs;
    property BodyTotalMs: Integer read FBodyTotalMs;
  end;

implementation

uses
  mormot.net.http;

class function THttp11Limits.Create: THttp11Limits;
begin
  // RFC 9112 section 3 recommends support for a request line of at least 8000
  // octets, and 8192 is the usual bound
  Result.FMaxRequestLine := 8192;
  Result.FMaxHeaderLine := 8192;
  Result.FMaxHeaderCount := 100;
  Result.FMaxHeaderOctets := 65536;
  Result.FMaxChunkSize := 1048576;
  Result.FMaxChunkExtension := 1024;
  Result.FMaxTrailerOctets := 4096;
  // the exchange buffers the body until the handler reads it, with no
  // backpressure on the socket, so the body limit is the bound of the memory of
  // one request
  Result.FMaxBodySize := 16777216;
  Result.FMaxPipelinedOctets := 65536;
  Result.FBodyDeadlineMs := 30000;
  Result.FBodyTotalMs := 300000;
end;

function THttp11Limits.WithMaxRequestLine(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxRequestLine := AValue;
end;

function THttp11Limits.WithMaxHeaderLine(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxHeaderLine := AValue;
end;

function THttp11Limits.WithMaxHeaderCount(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxHeaderCount := AValue;
end;

function THttp11Limits.WithMaxHeaderOctets(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxHeaderOctets := AValue;
end;

function THttp11Limits.WithMaxChunkSize(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxChunkSize := AValue;
end;

function THttp11Limits.WithMaxChunkExtension(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxChunkExtension := AValue;
end;

function THttp11Limits.WithMaxTrailerOctets(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxTrailerOctets := AValue;
end;

function THttp11Limits.WithMaxBodySize(const AValue: Int64): THttp11Limits;
begin
  Result := Self;
  Result.FMaxBodySize := AValue;
end;

function THttp11Limits.WithMaxPipelinedOctets(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FMaxPipelinedOctets := AValue;
end;

function THttp11Limits.WithBodyDeadlineMs(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FBodyDeadlineMs := AValue;
end;

function THttp11Limits.WithBodyTotalMs(const AValue: Integer): THttp11Limits;
begin
  Result := Self;
  Result.FBodyTotalMs := AValue;
end;

procedure THttp11Limits.Problems(var AProblems: TArray<string>);

  procedure Add(const AText: string);
  begin
    SetLength(AProblems, Length(AProblems) + 1);
    AProblems[High(AProblems)] := AText;
  end;

begin
  if FMaxRequestLine < 1 then
    Add('the HTTP/1.1 request line limit is below 1');
  if FMaxHeaderLine < 1 then
    Add('the HTTP/1.1 header line limit is below 1');
  if FMaxHeaderCount < 1 then
    Add('the HTTP/1.1 header count limit is below 1');
  if FMaxHeaderOctets < 1 then
    Add('the HTTP/1.1 header section limit is below 1');
  if FMaxChunkSize < 1 then
    Add('the HTTP/1.1 chunk size limit is below 1');
  if FMaxChunkExtension < 1 then
    Add('the HTTP/1.1 chunk extension limit is below 1');
  if FMaxTrailerOctets < 1 then
    Add('the HTTP/1.1 trailer limit is below 1');
  if FMaxBodySize < 0 then
    Add('the HTTP/1.1 body limit is below 0');
  if FMaxPipelinedOctets < 0 then
    Add('the HTTP/1.1 pipelined octet limit is below 0');
  if FBodyDeadlineMs < 0 then
    Add('the HTTP/1.1 body deadline is below 0');
  if FBodyTotalMs < 0 then
    Add('the HTTP/1.1 total body time is below 0');
  // the parser of mORMot2 enforces its own ceilings; a higher limit here
  // could never take effect
  if FMaxRequestLine > MaxHttpHeaderLineSize then
    Add('the HTTP/1.1 request line limit is above MaxHttpHeaderLineSize of mORMot2');
  if FMaxHeaderLine > MaxHttpHeaderLineSize then
    Add('the HTTP/1.1 header line limit is above MaxHttpHeaderLineSize of mORMot2');
  if FMaxChunkSize > MaxHttpChunkSize then
    Add('the HTTP/1.1 chunk size limit is above MaxHttpChunkSize of mORMot2');
end;

end.
