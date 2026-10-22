{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, test kit, parser, capture, fpcunit
notes:
  - This unit runs bytes through the HTTP/1.1 parser and the guard and returns a
    one-line transcript of what the sink saw. It holds no socket.
  - A byte stream is fed whole, one octet at a time and in random pieces. The three
    transcripts must be equal, which is the property that a resumable parser
    needs.
---
}
/// A capture sink and a feeding helper for the HTTP/1.1 parser tests
unit Http2Server.Http1.TestKit;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Http1.Limits, Http2Server.Http1.Guard, Http2Server.Http1.Parser;

type
  /// records the events of the parser as text
  TH1Capture = class(TInterfacedObject, IH1ParserSink)
  private
    FLines: TStringList;
    FBody: string;
    FParser: TH1Parser;
    FAutoNext: Boolean;
  public
    constructor Create(const AAutoNext: Boolean);
    destructor Destroy; override;
    procedure Attach(const AParser: TH1Parser);
    procedure HeadComplete(const AHead: TH1Head);
    procedure BodyBytes(const AData; const ACount: Integer);
    procedure BodyEnd;
    procedure Rejected(const AVerdict: TH1Verdict);
    function Text: string;
  end;

  TH1Mode = (fmWhole, fmOctets, fmRandom);

/// run AInput through a new parser and answer the transcript
// - AAutoNext starts the next request after each complete one, as a connection
//   that keeps alive does
function H1Run(const AInput: string; const ALimits: THttp11Limits;
  const AMode: TH1Mode; const AAutoNext: Boolean = True): string;

/// run in all three modes and fail the test when the transcripts differ
function H1RunAll(const AInput: string; const ALimits: THttp11Limits;
  const AAutoNext: Boolean = True): string;

/// the transcript has a rejection with this status
function H1Rejected(const ATranscript: string; const AStatus: Integer): Boolean;

implementation

constructor TH1Capture.Create(const AAutoNext: Boolean);
begin
  inherited Create;
  FLines := TStringList.Create;
  FAutoNext := AAutoNext;
end;

destructor TH1Capture.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

procedure TH1Capture.Attach(const AParser: TH1Parser);
begin
  FParser := AParser;
end;

procedure TH1Capture.HeadComplete(const AHead: TH1Head);
const
  F: array[TH1Framing] of string = ('none', 'length', 'chunked');
var
  S: string;
begin
  S := 'H ' + AHead.Line.Method + ' ' + AHead.Line.Target + ' auth=' +
    AHead.Authority + ' fr=' + F[AHead.Framing] + ' len=' +
    IntToStr(AHead.ContentLength) + ' v1.' + IntToStr(AHead.Line.Minor);
  if AHead.KeepAlive then
    S := S + ' keep'
  else
    S := S + ' close';
  if AHead.Expect100 then
    S := S + ' e100';
  if AHead.WebSocketUpgrade then
    S := S + ' ws';
  FLines.Add(S);
  FBody := '';
end;

procedure TH1Capture.BodyBytes(const AData; const ACount: Integer);
var
  S: string;
begin
  SetString(S, PChar(@AData), ACount);
  FBody := FBody + S;
end;

procedure TH1Capture.BodyEnd;
begin
  FLines.Add('B ' + FBody);
  FLines.Add('E');
  FBody := '';
  if FAutoNext and (FParser <> nil) then
    FParser.NextRequest;
end;

procedure TH1Capture.Rejected(const AVerdict: TH1Verdict);
begin
  FLines.Add('R ' + IntToStr(AVerdict.Status));
end;

function TH1Capture.Text: string;
begin
  // a partial body is part of the transcript
  if FBody <> '' then
    Result := FLines.Text + 'partial ' + FBody
  else
    Result := FLines.Text;
end;

function H1Run(const AInput: string; const ALimits: THttp11Limits;
  const AMode: TH1Mode; const AAutoNext: Boolean): string;
var
  Sink: TH1Capture;
  Ref: IH1ParserSink;
  Parser: TH1Parser;
  At, N: Integer;
begin
  Sink := TH1Capture.Create(AAutoNext);
  Ref := Sink;
  Parser := TH1Parser.Create(ALimits, Ref);
  try
    Sink.Attach(Parser);
    At := 1;
    while At <= Length(AInput) do
    begin
      case AMode of
        fmWhole: N := Length(AInput);
        fmOctets: N := 1;
      else
        N := 1 + Random(9);
      end;
      if At + N - 1 > Length(AInput) then
        N := Length(AInput) - At + 1;
      Parser.Feed(AInput[At], N);
      Inc(At, N);
    end;
    Result := Sink.Text;
    Sink.Attach(nil);
  finally
    Parser.Free;
  end;
end;

function H1RunAll(const AInput: string; const ALimits: THttp11Limits;
  const AAutoNext: Boolean): string;
var
  Octets, Random_: string;
  I: Integer;
begin
  Result := H1Run(AInput, ALimits, fmWhole, AAutoNext);
  Octets := H1Run(AInput, ALimits, fmOctets, AAutoNext);
  if Octets <> Result then
    raise EAssertionFailedError.Create('octet-wise feeding differs. whole: ' +
      Result + ' octets: ' + Octets);
  RandSeed := 4242;
  for I := 1 to 8 do
  begin
    Random_ := H1Run(AInput, ALimits, fmRandom, AAutoNext);
    if Random_ <> Result then
      raise EAssertionFailedError.Create('random feeding differs. whole: ' +
        Result + ' random: ' + Random_);
  end;
end;

function H1Rejected(const ATranscript: string; const AStatus: Integer): Boolean;
begin
  Result := Pos('R ' + IntToStr(AStatus) + #10, ATranscript) > 0;
end;

end.
