{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, waker, write wake-up, handler thread
notes:
  - This unit holds the write waker of one connection. A handler thread calls
    Signal after it queues output, and the waker calls the method that drains
    the core and writes to the socket.
  - The waker holds a method pointer and no connection class, so this unit does
    not depend on the async server unit.
---
}
/// The write waker of an async connection
unit Http2Server.Async.Waker;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
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
  public
    constructor Create(const AWake: TWakeProc);
    procedure Signal;
  end;

implementation

constructor TMethodWaker.Create(const AWake: TWakeProc);
begin
  inherited Create;
  FWake := AWake;
end;

procedure TMethodWaker.Signal;
begin
  if not Assigned(FWake) then
    exit;
  // the first check is the edge-triggered flag inside the core, which keeps
  // one wake-up per transition.  The wake method performs the drain and the
  // mORMot2 write, and it retries once when the write lock went to the IO
  // thread, which is the second check of the wake-up pattern
  FWake();
end;

end.
