{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, waker, write wake-up, handler thread, detach
notes:
  - This unit holds the write waker of one connection. A handler thread calls
    Signal after it queues output, and the waker calls the method that drains
    the core and writes to the socket.
  - The waker holds a method pointer and no connection class, so this unit does
    not depend on the async server unit.
  - Detach cuts the waker from the connection. A call in flight finishes first,
    and every later call does nothing, so a handler thread never reaches a
    connection that is being freed.
---
}
/// The write waker of an async connection
unit Http2Server.Async.Waker;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs,
  Http2Server.Output;

type
  /// the method that drains the core and writes to the socket
  TWakeProc = procedure of object;

  /// the write waker of one connection
  ///
  /// A handler thread calls Signal after it queues output.  The waker hands the
  /// bytes to the mORMot2 write path, which sends at once when the socket is
  /// ready and subscribes for the write event when it is not.  The connection
  /// carries the edge-triggered flag, so Signal takes effect once per
  /// transition from "no output" to "output".
  TMethodWaker = class(TInterfacedObject, IWriteWaker)
  private
    FWake: TWakeProc;
    FLock: TCriticalSection;
    FInFlight: Integer;
  public
    constructor Create(const AWake: TWakeProc);
    destructor Destroy; override;
    procedure Signal;
    /// cut the waker from the connection
    // - a call that entered before this point finishes (the wait is bounded);
    //   no call starts after it
    procedure Detach;
  end;

implementation

const
  /// the longest wait of Detach for a call in flight, in milliseconds
  cDetachWaitMs = 5000;

constructor TMethodWaker.Create(const AWake: TWakeProc);
begin
  inherited Create;
  FWake := AWake;
  FLock := TCriticalSection.Create;
end;

destructor TMethodWaker.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TMethodWaker.Signal;
var
  Wake: TWakeProc;
begin
  FLock.Acquire;
  try
    Wake := FWake;
    if not Assigned(Wake) then
      exit;
    Inc(FInFlight);
  finally
    FLock.Release;
  end;
  try
    // the first check is the edge-triggered flag inside the core, which keeps
    // one wake-up per transition.  The wake method performs the drain and the
    // mORMot2 write, and it retries once when the write lock went to the IO
    // thread, which is the second check of the wake-up pattern
    Wake();
  finally
    FLock.Acquire;
    try
      Dec(FInFlight);
    finally
      FLock.Release;
    end;
  end;
end;

procedure TMethodWaker.Detach;
var
  Waited: Integer;
  Busy: Boolean;
begin
  FLock.Acquire;
  try
    FWake := nil;
  finally
    FLock.Release;
  end;
  Waited := 0;
  repeat
    FLock.Acquire;
    try
      Busy := FInFlight > 0;
    finally
      FLock.Release;
    end;
    if not Busy then
      exit;
    Sleep(1);
    Inc(Waited);
  until Waited >= cDetachWaitMs;
end;

end.
