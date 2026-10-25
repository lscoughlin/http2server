{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: access log, common log format, principal, basic auth, test, fpcunit
notes:
  - This unit tests the Common Log Format text, the Basic user helper, and the
    records that a running server gives to the writer over HTTP/1.1 and HTTP/2.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Tests of the access log
unit Http2Server.AccessLog.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2Server, Http2Server.Server.Test, Http2Server.Http1.RawClient;

type
  /// keeps every record that it receives
  TRecordingWriter = class(TInterfacedObject, IAccessLogWriter)
  private
    FLock: TCriticalSection;
    FRecords: TList<TAccessLogRecord>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Write(const ARecord: TAccessLogRecord);
    function Count: Integer;
    function At(const AIndex: Integer): TAccessLogRecord;
    /// wait until ACount records exist
    function WaitFor(const ACount, ATimeoutMs: Integer): Boolean;
  end;

  /// answers 'hello'; the path /who sets a principal first
  TLoggedHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  TAccessLogFormatTest = class(TTestCase)
  private
    function Sample: TAccessLogRecord;
  published
    procedure TestCommonLogLine;
    procedure TestEmptyFieldsAreDashes;
    procedure TestNegativeOffset;
    procedure TestRequestLineEscapes;
    procedure TestPrincipalWithASpaceIsEscaped;
    procedure TestBasicUser;
    procedure TestBasicUserWithoutColon;
    procedure TestBasicUserRejectsOtherInput;
  end;

  TAccessLogLiveTest = class(TTestCase)
  published
    procedure TestHttp1RecordCarriesTheRequestAndResponse;
    procedure TestExplicitPrincipalWinsOverBasic;
    procedure TestHttp2Record;
    procedure TestNilWriterServesWithoutLogging;
    procedure TestHttp1QueueRefusalIsLogged;
    procedure TestHttp2RefusalWithRstStreamIsLoggedWithoutStatus;
    procedure TestHttp2Refusal503IsLogged;
  end;

implementation

function Headers1(const AName, AValue: string): THeaderBlock;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Name := AName;
  Result[0].Value := AValue;
end;

{ TRecordingWriter }

constructor TRecordingWriter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRecords := TList<TAccessLogRecord>.Create;
end;

destructor TRecordingWriter.Destroy;
begin
  FRecords.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRecordingWriter.Write(const ARecord: TAccessLogRecord);
begin
  FLock.Acquire;
  try
    FRecords.Add(ARecord);
  finally
    FLock.Release;
  end;
end;

function TRecordingWriter.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FRecords.Count;
  finally
    FLock.Release;
  end;
end;

function TRecordingWriter.At(const AIndex: Integer): TAccessLogRecord;
begin
  FLock.Acquire;
  try
    Result := FRecords[AIndex];
  finally
    FLock.Release;
  end;
end;

function TRecordingWriter.WaitFor(const ACount, ATimeoutMs: Integer): Boolean;
var
  Stop: QWord;
begin
  Stop := GetTickCount64 + QWord(ATimeoutMs);
  while (Count < ACount) and (GetTickCount64 < Stop) do
    Sleep(5);
  Result := Count >= ACount;
end;

{ TLoggedHandler }

procedure TLoggedHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
begin
  if ARequest.Path = '/who' then
    ARequest.Principal := 'oauth|sub-42';
  Body := TBytes.Create(Ord('h'), Ord('e'), Ord('l'), Ord('l'), Ord('o'));
  AResponse.SendHeaders(200, Headers1('content-length', '5'), False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

{ TAccessLogFormatTest }

function TAccessLogFormatTest.Sample: TAccessLogRecord;
begin
  Result := Default(TAccessLogRecord);
  Result.RemoteAddress := '127.0.0.1';
  Result.Principal := 'frank';
  Result.StartTime := EncodeDate(2000, 10, 10) + EncodeTime(13, 55, 36, 0);
  Result.UtcOffsetMinutes := -420;
  Result.Method := 'GET';
  Result.Target := '/apache_pb.gif';
  Result.Protocol := 'HTTP/1.0';
  Result.Status := 200;
  Result.BodyOctets := 2326;
end;

procedure TAccessLogFormatTest.TestCommonLogLine;
begin
  // the example line of the Apache documentation
  AssertEquals(
    '127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.0" 200 2326',
    FormatCommonLog(Sample));
end;

procedure TAccessLogFormatTest.TestEmptyFieldsAreDashes;
var
  R: TAccessLogRecord;
begin
  R := Sample;
  R.RemoteAddress := '';
  R.Principal := '';
  R.Status := 0;
  R.BodyOctets := 0;
  AssertEquals('- - - [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.0" - -',
    FormatCommonLog(R));
end;

procedure TAccessLogFormatTest.TestNegativeOffset;
var
  R: TAccessLogRecord;
begin
  R := Sample;
  R.UtcOffsetMinutes := 330;
  AssertTrue('the offset is east positive',
    Pos(' +0530] ', FormatCommonLog(R)) > 0);
end;

procedure TAccessLogFormatTest.TestRequestLineEscapes;
var
  R: TAccessLogRecord;
begin
  R := Sample;
  R.Target := '/a"b\c'#13#10'd';
  AssertTrue('"GET /a\x22b\x5cc\x0d\x0ad HTTP/1.0" 200',
    Pos('"GET /a\x22b\x5cc\x0d\x0ad HTTP/1.0" 200', FormatCommonLog(R)) > 0);
end;

procedure TAccessLogFormatTest.TestPrincipalWithASpaceIsEscaped;
var
  R: TAccessLogRecord;
begin
  R := Sample;
  R.Principal := 'a b';
  AssertEquals('127.0.0.1 - a\x20b [', Copy(FormatCommonLog(R), 1, 20));
end;

procedure TAccessLogFormatTest.TestBasicUser;
begin
  // dXNlcjpwYXNzd29yZA== is user:password
  AssertEquals('user',
    BasicAuthUser(Headers1('authorization', 'Basic dXNlcjpwYXNzd29yZA==')));
  AssertEquals('the scheme name has no case', 'user',
    BasicAuthUser(Headers1('Authorization', 'bAsIc dXNlcjpwYXNzd29yZA==')));
end;

procedure TAccessLogFormatTest.TestBasicUserWithoutColon;
begin
  // dXNlcg== is user
  AssertEquals('user', BasicAuthUser(Headers1('authorization', 'Basic dXNlcg==')));
end;

procedure TAccessLogFormatTest.TestBasicUserRejectsOtherInput;
begin
  AssertEquals('', BasicAuthUser(nil));
  AssertEquals('', BasicAuthUser(Headers1('authorization', 'Bearer abc.def')));
  AssertEquals('', BasicAuthUser(Headers1('authorization', 'Basic')));
  AssertEquals('', BasicAuthUser(Headers1('authorization', 'Basic !!!notbase64')));
  AssertEquals('', BasicAuthUser(Headers1('accept', 'Basic dXNlcg==')));
end;

{ TAccessLogLiveTest }

procedure TAccessLogLiveTest.TestHttp1RecordCarriesTheRequestAndResponse;
var
  Writer: TRecordingWriter;
  WriterRef: IAccessLogWriter;
  Server: IHttp2Server;
  C: TRawHttp;
  R: TRawResponse;
  Rec: TAccessLogRecord;
begin
  Writer := TRecordingWriter.Create;
  WriterRef := Writer;
  Server := LiveFactory(TLoggedHandler.Create)
    .WithAccessLogWriter(WriterRef).Build;
  Server.Start;
  try
    C := TRawHttp.Create(Server.Port);
    try
      C.Send('GET /hello?x=1 HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
        'User-Agent: probe/1' + CRLF +
        'Authorization: Basic dXNlcjpwYXNzd29yZA==' + CRLF + CRLF);
      AssertTrue(C.ReadResponse(False, ResponseMs, R));
    finally
      C.Free;
    end;
    AssertTrue('one record', Writer.WaitFor(1, ResponseMs));
    Rec := Writer.At(0);
    AssertEquals('127.0.0.1', Rec.RemoteAddress);
    AssertEquals('the unverified Basic name is the fallback', 'user', Rec.Principal);
    AssertEquals('GET', Rec.Method);
    AssertEquals('/hello?x=1', Rec.Target);
    AssertEquals('HTTP/1.1', Rec.Protocol);
    AssertEquals(200, Rec.Status);
    AssertEquals(5, Rec.BodyOctets);
    AssertEquals('probe/1', Rec.UserAgent);
  finally
    Server.Stop;
  end;
end;

procedure TAccessLogLiveTest.TestExplicitPrincipalWinsOverBasic;
var
  Writer: TRecordingWriter;
  WriterRef: IAccessLogWriter;
  Server: IHttp2Server;
  C: TRawHttp;
  R: TRawResponse;
begin
  Writer := TRecordingWriter.Create;
  WriterRef := Writer;
  Server := LiveFactory(TLoggedHandler.Create)
    .WithAccessLogWriter(WriterRef).Build;
  Server.Start;
  try
    C := TRawHttp.Create(Server.Port);
    try
      C.Send('GET /who HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
        'Authorization: Basic dXNlcjpwYXNzd29yZA==' + CRLF + CRLF);
      AssertTrue(C.ReadResponse(False, ResponseMs, R));
    finally
      C.Free;
    end;
    AssertTrue('one record', Writer.WaitFor(1, ResponseMs));
    AssertEquals('oauth|sub-42', Writer.At(0).Principal);
  finally
    Server.Stop;
  end;
end;

procedure TAccessLogLiveTest.TestHttp2Record;
var
  Writer: TRecordingWriter;
  WriterRef: IAccessLogWriter;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Body: TBytes;
  Rec: TAccessLogRecord;
begin
  Writer := TRecordingWriter.Create;
  WriterRef := Writer;
  Server := LiveFactory(TLoggedHandler.Create)
    .WithAccessLogWriter(WriterRef).Build;
  Server.Start;
  try
    Client := TLifecycleClient.Create(Server.Port);
    try
      Client.SendGet(1, '/who');
      AssertTrue(Client.WaitForResponse(1, ResponseMs, Body));
    finally
      Client.Free;
    end;
    AssertTrue('one record', Writer.WaitFor(1, ResponseMs));
    Rec := Writer.At(0);
    AssertEquals('127.0.0.1', Rec.RemoteAddress);
    AssertEquals('oauth|sub-42', Rec.Principal);
    AssertEquals('HTTP/2.0', Rec.Protocol);
    AssertEquals('/who', Rec.Target);
    AssertEquals(200, Rec.Status);
    AssertEquals(5, Rec.BodyOctets);
    AssertEquals(1, Integer(Rec.StreamId));
  finally
    Server.Stop;
  end;
end;

procedure TAccessLogLiveTest.TestNilWriterServesWithoutLogging;
var
  Server: IHttp2Server;
  C: TRawHttp;
  R: TRawResponse;
begin
  AssertTrue('the default is no writer',
    THttp2ServerFactory.Create.AccessLogWriter = nil);
  Server := LiveFactory(TLoggedHandler.Create).WithAccessLogWriter(nil).Build;
  Server.Start;
  try
    C := TRawHttp.Create(Server.Port);
    try
      C.Send('GET /hello HTTP/1.1' + CRLF + 'Host: localhost' + CRLF + CRLF);
      AssertTrue(C.ReadResponse(False, ResponseMs, R));
      AssertEquals(200, R.Status);
    finally
      C.Free;
    end;
  finally
    Server.Stop;
  end;
end;

procedure TAccessLogLiveTest.TestHttp1QueueRefusalIsLogged;
var
  Writer: TRecordingWriter;
  WriterRef: IAccessLogWriter;
  Server: IHttp2Server;
  C: TRawHttp;
  R: TRawResponse;
  Rec: TAccessLogRecord;
begin
  Writer := TRecordingWriter.Create;
  WriterRef := Writer;
  // depth 0 refuses every request at once
  Server := LiveFactory(TLoggedHandler.Create)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .WithAccessLogWriter(WriterRef).Build;
  Server.Start;
  try
    C := TRawHttp.Create(Server.Port);
    try
      C.Send('GET /refused HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
        'Authorization: Basic dXNlcjpwYXNzd29yZA==' + CRLF + CRLF);
      AssertTrue(C.ReadResponse(False, ResponseMs, R));
      AssertEquals(503, R.Status);
    finally
      C.Free;
    end;
    AssertTrue('one record', Writer.WaitFor(1, ResponseMs));
    Rec := Writer.At(0);
    AssertEquals(503, Rec.Status);
    AssertEquals('GET', Rec.Method);
    AssertEquals('/refused', Rec.Target);
    AssertEquals('HTTP/1.1', Rec.Protocol);
    AssertEquals('127.0.0.1', Rec.RemoteAddress);
    AssertEquals('user', Rec.Principal);
    AssertEquals(0, Rec.BodyOctets);
  finally
    Server.Stop;
  end;
end;

procedure TAccessLogLiveTest.TestHttp2RefusalWithRstStreamIsLoggedWithoutStatus;
var
  Writer: TRecordingWriter;
  WriterRef: IAccessLogWriter;
  Server: IHttp2Server;
  Client: TLifecycleClient;
  Code: THttp2ErrorCode;
  Rec: TAccessLogRecord;
begin
  Writer := TRecordingWriter.Create;
  WriterRef := Writer;
  Server := LiveFactory(TLoggedHandler.Create)
    .WithQueue(TQueueOptions.Create.WithDepth(0))
    .WithAccessLogWriter(WriterRef).Build;
  Server.Start;
  try
    Client := TLifecycleClient.Create(Server.Port);
    try
      Client.SendGet(1, '/refused');
      AssertTrue(Client.WaitForReset(1, ResponseMs, Code));
    finally
      Client.Free;
    end;
    AssertTrue('one record', Writer.WaitFor(1, ResponseMs));
    Rec := Writer.At(0);
    AssertEquals('no response went out', 0, Rec.Status);
    AssertEquals('/refused', Rec.Target);
    AssertEquals('HTTP/2.0', Rec.Protocol);
    AssertEquals('127.0.0.1', Rec.RemoteAddress);
    AssertEquals(1, Integer(Rec.StreamId));
  finally
    Server.Stop;
  end;
end;

procedure TAccessLogLiveTest.TestHttp2Refusal503IsLogged;
var
  Writer: TRecordingWriter;
  WriterRef: IAccessLogWriter;
  Server: IHttp2Server;
  Client: TLifecycleClient;
begin
  Writer := TRecordingWriter.Create;
  WriterRef := Writer;
  Server := LiveFactory(TLoggedHandler.Create)
    .WithQueue(TQueueOptions.Create.WithDepth(0).WithRefusalMode(rmHttp503))
    .WithAccessLogWriter(WriterRef).Build;
  Server.Start;
  try
    Client := TLifecycleClient.Create(Server.Port);
    try
      Client.SendGet(1, '/refused');
      // the 503 has headers only, so no DATA frame arrives; the record is the proof
      AssertTrue('one record', Writer.WaitFor(1, ResponseMs));
    finally
      Client.Free;
    end;
    AssertEquals(503, Writer.At(0).Status);
    AssertEquals('/refused', Writer.At(0).Target);
  finally
    Server.Stop;
  end;
end;

initialization
  RegisterTest(TAccessLogFormatTest);
  RegisterTest(TAccessLogLiveTest);
end.
