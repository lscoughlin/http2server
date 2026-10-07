{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, facade
notes:
  - This unit is the public facade of the HTTP/2 server library.
  - The facade re-exports the public units of the library.
  - The library is a placeholder until the server units exist.
---
}
/// Public facade of the HTTP/2 server library
// - this unit is the entry point of the library; a caller adds only this
//   unit to the uses clause
// - the server surface is not built yet, so the unit declares no type and
//   no routine; the unit exists so that the build line and the test runner
//   link a real library unit from the first day
unit Http2Server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

implementation

end.
