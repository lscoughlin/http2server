{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: facade, public api, aliases
notes:
  - This unit names the Http2Server unit alone among the server units. It
    compiles only when the facade exports every type and constant that the
    methods of the factory and the observer events need.
---
}
unit Http2Server.Facade.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2Server;

type
  TFacadeClock = class(TInterfacedObject, IMonotonicClock)
  public
    function NowMs: QWord;
  end;

  TFacadeHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  TFacadeTest = class(TTestCase)
  published
    procedure TestEveryWithMethodIsReachableThroughTheFacade;
    procedure TestErrorCodesAndLimitKindsAreExported;
  end;

implementation

function TFacadeClock.NowMs: QWord;
begin
  Result := GetTickCount64;
end;

procedure TFacadeHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
end;

procedure TFacadeTest.TestEveryWithMethodIsReachableThroughTheFacade;
var
  Limits: THttp11Limits;
  Clock: IMonotonicClock;
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  Limits := THttp11Limits.Create;
  Clock := TFacadeClock.Create;
  F := THttp2ServerFactory.Create
    .WithHandler(TFacadeHandler.Create)
    .WithClearTextAllowed(True)
    .WithHttp11Limits(Limits)
    .WithClock(Clock)
    .WithQueue(TQueueOptions.Create.WithRefusalMode(rmHttp503))
    .WithTls(TTlsServerOptions.Create);
  AssertTrue('SRV-14: the factory validates: ' + F.ProblemText, F.Validate(Problems));
end;

procedure TFacadeTest.TestErrorCodesAndLimitKindsAreExported;
var
  Event: TServerEvent;
  Code: THttp2ErrorCode;
  Kind: TLimitKind;
begin
  Code := ecNoError;
  Kind := lkReset;
  Event.Kind := seBucketTripped;
  Event.LimitKind := lkPing;
  Event.ErrorCode := ecEnhanceYourCalm;
  AssertTrue(Ord(Event.LimitKind) > Ord(Kind));
  AssertTrue(Ord(Event.ErrorCode) > Ord(Code));
  AssertEquals('EHttpTimeout is a facade type', 'EHttpTimeout', EHttpTimeout.ClassName);
  AssertEquals('EStreamCancelled is a facade type', 'EStreamCancelled',
    EStreamCancelled.ClassName);
end;

initialization
  RegisterTest(TFacadeTest);

end.
