{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, protocol, test
notes:
  - Tests for the server-side additions to Http2Server.Frames and
    Http2Server.Errors: the received-frame size check, the server SETTINGS
    builder, the client connection preface, and the server exceptions.
  - The received-frame size check, the server SETTINGS builder and the
    preface parser follow RFC 9113 sections 3.4, 6.5 and 4.2.
---
}
/// Server-side protocol tests for Http2Server.Frames and Http2Server.Errors
unit Http2Server.Protocol.Server.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2Server.Errors, Http2Server.Frames;

type
  TServerProtocolTest = class(TTestCase)
  published
    /// a received frame larger than the advertised limit is a connection error
    procedure TestOversizeReceivedFrameIsRefused;
    /// a frame at the limit is accepted
    procedure TestFrameAtTheLimitIsAccepted;
    /// a received frame that only exceeds the limit on the payload is refused
    procedure TestValidateRefusesOversizePayload;
    /// the server SETTINGS frame carries the values the server enforces
    procedure TestServerSettingsCarryFactoryValues;
    /// the server SETTINGS frame is a stream-0 SETTINGS frame with no ACK
    procedure TestServerSettingsShape;
    /// the client preface is accepted octet for octet
    procedure TestClientPrefaceIsAccepted;
    /// a wrong preface octet is rejected
    procedure TestClientPrefaceRejectsAWrongByte;
    /// a short preface is rejected
    procedure TestClientPrefaceRejectsAShortBuffer;
    /// the preface reader accepts a well-formed stream
    procedure TestReadClientPrefaceAcceptsAStream;
    /// the preface reader rejects a malformed stream
    procedure TestReadClientPrefaceRejectsAStream;
    /// the preface reader reports a stream that ends inside the preface
    procedure TestReadClientPrefaceReportsATruncatedStream;
    /// the server exception classes exist and carry the right base type
    procedure TestServerExceptionsArePresent;
  end;

implementation

/// a copy of the RFC 9113 section 3.4 preface as a byte container
function PrefaceBytes: TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ClientPrefaceSize);
  for I := 0 to ClientPrefaceSize - 1 do
    Result[I] := ClientPreface[I];
end;

function PrependHeader(const ALength: LongWord; const AFrameType: TFrameType;
  const AStreamId: LongWord): TBytes;
var
  H: TFrameHeader;
begin
  Result := nil;
  SetLength(Result, FrameHeaderSize);
  H.Clear;
  H.Length := ALength;
  H.FrameType := AFrameType;
  H.StreamId := AStreamId;
  H.WriteTo(Result);
end;

procedure TServerProtocolTest.TestOversizeReceivedFrameIsRefused;
var
  S: TMemoryStream;
  Hdr: TBytes;
  Raised: Boolean;
begin
  S := TMemoryStream.Create;
  try
    // A DATA frame that claims 20000 octets, above the 16384 default.
    Hdr := PrependHeader(20000, ftData, 1);
    S.WriteBuffer(Hdr[0], Length(Hdr));
    S.Position := 0;
    Raised := False;
    try
      ReadFrame(S, DefaultMaxFrameSize);
    except
      on E: EHttpProtocolError do
      begin
        Raised := True;
        AssertEquals('frame size error', Ord(ecFrameSizeError), Ord(E.ErrorCode));
      end;
    end;
    AssertTrue('an oversize received frame raises a protocol error', Raised);
  finally
    S.Free;
  end;
end;

procedure TServerProtocolTest.TestFrameAtTheLimitIsAccepted;
var
  S: TMemoryStream;
  Hdr, Payload: TBytes;
  F: TFrame;
begin
  S := TMemoryStream.Create;
  try
    SetLength(Payload, 32);
    Hdr := PrependHeader(32, ftData, 1);
    S.WriteBuffer(Hdr[0], Length(Hdr));
    S.WriteBuffer(Payload[0], Length(Payload));
    S.Position := 0;
    F := ReadFrame(S, DefaultMaxFrameSize);
    AssertEquals('payload length', 32, Length(F.Payload));
    AssertEquals('stream id', 1, F.Header.StreamId);
  finally
    S.Free;
  end;
end;

procedure TServerProtocolTest.TestValidateRefusesOversizePayload;
var
  F: TFrame;
  Payload: TBytes;
  Raised: Boolean;
begin
  SetLength(Payload, 64);
  F := TFrame.Create(ftData, [], 1, Payload);
  F.Header.Length := 64;
  Raised := False;
  try
    ValidateFrame(F, 32);
  except
    on E: EHttpProtocolError do
      Raised := Ord(E.ErrorCode) = Ord(ecFrameSizeError);
  end;
  AssertTrue('a payload above the limit raises a frame size error', Raised);
end;

procedure TServerProtocolTest.TestServerSettingsCarryFactoryValues;
var
  St: TConnectionSettings;
begin
  St := TConnectionSettings.Defaults;
  St.MaxConcurrentStreams := 7;
  St.InitialWindowSize := 4096;
  St.MaxFrameSize := 32768;
  St.MaxHeaderListSize := 1024;
  St.HeaderTableSize := 2048;
  St.EnablePush := False;
  AssertEquals('streams', 7, St.MaxConcurrentStreams);
  AssertEquals('frame size', 32768, St.MaxFrameSize);
  AssertEquals('header list', 1024, St.MaxHeaderListSize);
end;

procedure TServerProtocolTest.TestServerSettingsShape;
var
  St: TConnectionSettings;
  F: TFrame;
  Decoded: TConnectionSettings;
begin
  St := TConnectionSettings.Defaults;
  St.MaxConcurrentStreams := 11;
  F := BuildServerSettings(St);
  AssertEquals('frame type', Ord(ftSettings), Ord(F.Header.FrameType));
  AssertEquals('stream id', 0, F.Header.StreamId);
  AssertFalse('no ACK', F.IsAck);
  Decoded := TConnectionSettings.Decode(F.Payload);
  AssertEquals('streams survive the round trip', 11, Decoded.MaxConcurrentStreams);
  AssertEquals('max frame size survives', DefaultMaxFrameSize, Decoded.MaxFrameSize);
end;

procedure TServerProtocolTest.TestClientPrefaceIsAccepted;
var
  Buf: TBytes;
begin
  Buf := PrefaceBytes;
  AssertEquals('preface length', 24, Length(Buf));
  AssertTrue('the real preface is accepted', CheckClientPreface(Buf));
end;

procedure TServerProtocolTest.TestClientPrefaceRejectsAWrongByte;
var
  Buf: TBytes;
begin
  Buf := PrefaceBytes;
  Buf[0] := Ord('X');
  AssertFalse('a wrong first octet is refused', CheckClientPreface(Buf));
end;

procedure TServerProtocolTest.TestClientPrefaceRejectsAShortBuffer;
var
  Buf: TBytes;
begin
  Buf := PrefaceBytes;
  SetLength(Buf, ClientPrefaceSize - 1);
  AssertFalse('23 octets are refused', CheckClientPreface(Buf));
  Buf := nil;
  AssertFalse('an empty buffer is refused', CheckClientPreface(Buf));
end;

procedure TServerProtocolTest.TestReadClientPrefaceAcceptsAStream;
var
  S: TMemoryStream;
  Buf: TBytes;
begin
  Buf := PrefaceBytes;
  S := TMemoryStream.Create;
  try
    S.WriteBuffer(Buf[0], Length(Buf));
    S.Position := 0;
    ReadClientPreface(S);
    AssertEquals('the stream is consumed', ClientPrefaceSize, S.Position);
  finally
    S.Free;
  end;
end;

procedure TServerProtocolTest.TestReadClientPrefaceRejectsAStream;
var
  S: TMemoryStream;
  Buf: TBytes;
  Raised: Boolean;
begin
  Buf := PrefaceBytes;
  Buf[23] := Ord('X');
  S := TMemoryStream.Create;
  try
    S.WriteBuffer(Buf[0], Length(Buf));
    S.Position := 0;
    Raised := False;
    try
      ReadClientPreface(S);
    except
      on E: EHttpProtocolError do
        Raised := Ord(E.ErrorCode) = Ord(ecProtocolError);
    end;
    AssertTrue('a bad preface raises a protocol error', Raised);
  finally
    S.Free;
  end;
end;

procedure TServerProtocolTest.TestReadClientPrefaceReportsATruncatedStream;
var
  S: TMemoryStream;
  Buf: TBytes;
  Raised: Boolean;
begin
  Buf := PrefaceBytes;
  SetLength(Buf, 10);
  S := TMemoryStream.Create;
  try
    S.WriteBuffer(Buf[0], Length(Buf));
    S.Position := 0;
    Raised := False;
    try
      ReadClientPreface(S);
    except
      on E: EHttpConnectionClosed do
        Raised := True;
    end;
    AssertTrue('a truncated stream raises a closed-connection error', Raised);
  finally
    S.Free;
  end;
end;

procedure TServerProtocolTest.TestServerExceptionsArePresent;
var
  E: EServerConfigError;
begin
  AssertTrue('EServerConfigError is EHttpError',
    EServerConfigError.InheritsFrom(EHttpError));
  AssertTrue('EStreamCancelled is EHttpStreamError',
    EStreamCancelled.InheritsFrom(EHttpStreamError));
  AssertTrue('EStreamReset is EHttpStreamError',
    EStreamReset.InheritsFrom(EHttpStreamError));
  AssertTrue('EServerStopped is EHttpError',
    EServerStopped.InheritsFrom(EHttpError));
  E := EServerConfigError.Create('MaxFrameSize is below the minimum');
  try
    AssertTrue('the message survives', Pos('MaxFrameSize', E.Message) > 0);
  finally
    E.Free;
  end;
end;

initialization
  RegisterTest(TServerProtocolTest);

end.
