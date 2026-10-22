{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream, host, callbacks, wake-up, refusal
notes:
  - This unit holds the two callback interfaces that a stream uses to reach its
    connection. The connection core implements them.
  - The interfaces live apart from the stream, because they are the contract
    between the stream buffers and the connection, a separate concept.
---
}
/// The connection callbacks of one stream
unit Http2Server.StreamHost;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs,
  Http2Server.Errors;

type
  /// The IO side of the connection, as one stream needs it.
  ///
  /// TServerStream calls WindowUpdatePending when a handler read has consumed
  /// inbound bytes.  The connection sums the pending credit of a stream and
  /// emits one WINDOW_UPDATE, so the wait interface of a handler carries no
  /// flow-control knowledge.
  ///
  /// TServerStream calls OutputPending when a handler write has added bytes
  /// to the outbound buffer.  The connection then asks its write waker to
  /// signal the IO thread, so output that appears while no client byte is in
  /// flight still reaches the socket.
  IStreamHost = interface
    ['{7E1F0C11-0006-4A11-9C72-000000000506}']
    /// the handler consumed AIncrement inbound bytes of AStreamId
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    /// a handler added outbound bytes to AStreamId
    procedure OutputPending(const AStreamId: LongWord);
  end;

  /// The connection side of a refusal.
  ///
  /// The handler pool runs on its own threads, so a refusal cannot touch the
  /// outbound queue directly.  Refuse marks the stream and then calls this
  /// host method, and the connection queues the RST_STREAM under its own
  /// lock, which is the same lock the IO thread holds while it flushes.
  IRefusalHost = interface
    ['{7E1F0C11-0007-4A11-9C72-000000000507}']
    /// the local side refused AStreamId and owes the peer an RST_STREAM
    procedure QueueRefusal(const AStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode);
  end;

  /// The connection lock, with a reference count.
  ///
  /// The core and every stream hold a reference. A detached stream can outlive
  /// its core, and a stream takes this lock in every buffer operation, so the
  /// lock lives until the last holder lets it go.
  TConnectionLock = class(TInterfacedObject)
  private
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    property Lock: TCriticalSection read FLock;
  end;

implementation

{ TConnectionLock }

constructor TConnectionLock.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TConnectionLock.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

end.
