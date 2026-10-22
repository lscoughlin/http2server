{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, http2, protocol selection, preface, cleartext
notes:
  - This unit decides which protocol a cleartext connection speaks, from its
    first octets. It holds no socket.
  - RFC 9113 section 3.4 gives the client connection preface of 24 octets. A
    connection that starts with the whole preface speaks HTTP/2. A connection
    whose first octets are a prefix of the preface waits for more. Any other first
    octets are HTTP/1.1.
---
}
/// Protocol selection for a cleartext connection
unit Http2Server.Http1.Select;

{$mode delphi}{$H+}

interface

type
  TProtocolChoice = (
    /// the octets so far could still be the HTTP/2 preface
    pcNeedMore,
    pcHttp2,
    pcHttp1);

/// the protocol of a cleartext connection after ACount octets
// - the header deadline of the connection bounds the wait for more octets
function SelectCleartextProtocol(const AData; const ACount: Integer): TProtocolChoice;

implementation

uses
  Http2Server.Frames;

function SelectCleartextProtocol(const AData; const ACount: Integer): TProtocolChoice;
var
  P: PByte;
  I, N: Integer;
begin
  if ACount <= 0 then
    Exit(pcNeedMore);
  P := @AData;
  N := ACount;
  if N > ClientPrefaceSize then
    N := ClientPrefaceSize;
  for I := 0 to N - 1 do
    if P[I] <> ClientPreface[I] then
      Exit(pcHttp1);
  if ACount >= ClientPrefaceSize then
    Result := pcHttp2
  else
    Result := pcNeedMore;
end;

end.
