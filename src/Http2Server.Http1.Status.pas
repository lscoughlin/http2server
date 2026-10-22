{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, status line, reason phrase
notes:
  - This unit holds the reason phrases of the HTTP/1.1 status line (RFC 9112
    section 4). A code that is not in the table gets an empty phrase, and the
    status line keeps the space after the code.
---
}
/// Reason phrases of the HTTP/1.1 status line
unit Http2Server.Http1.Status;

{$mode delphi}{$H+}

interface

/// the reason phrase of AStatus, or an empty text for an unknown code
function Http1ReasonPhrase(const AStatus: Integer): string;

/// the status line with its CRLF, for example 'HTTP/1.1 200 OK'#13#10
// - an unknown code gives 'HTTP/1.1 299 '#13#10, with the space kept
function Http1StatusLine(const AStatus: Integer;
  const AMinor: Integer = 1): string;

implementation

uses
  SysUtils;

function Http1ReasonPhrase(const AStatus: Integer): string;
begin
  case AStatus of
    100: Result := 'Continue';
    101: Result := 'Switching Protocols';
    200: Result := 'OK';
    201: Result := 'Created';
    202: Result := 'Accepted';
    203: Result := 'Non-Authoritative Information';
    204: Result := 'No Content';
    205: Result := 'Reset Content';
    206: Result := 'Partial Content';
    300: Result := 'Multiple Choices';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    406: Result := 'Not Acceptable';
    408: Result := 'Request Timeout';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    411: Result := 'Length Required';
    412: Result := 'Precondition Failed';
    413: Result := 'Content Too Large';
    414: Result := 'URI Too Long';
    415: Result := 'Unsupported Media Type';
    416: Result := 'Range Not Satisfiable';
    417: Result := 'Expectation Failed';
    426: Result := 'Upgrade Required';
    429: Result := 'Too Many Requests';
    431: Result := 'Request Header Fields Too Large';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
    505: Result := 'HTTP Version Not Supported';
  else
    Result := '';
  end;
end;

function Http1StatusLine(const AStatus, AMinor: Integer): string;
begin
  Result := 'HTTP/1.' + IntToStr(AMinor) + ' ' + IntToStr(AStatus) + ' ' +
    Http1ReasonPhrase(AStatus) + #13#10;
end;

end.
