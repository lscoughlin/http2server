{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, licence, spdx, headers
notes:
  - This unit checks the licence of the tree. A Pascal file header holds
    the chosen SPDX expression, and no placeholder survives.
  - The test reads the files from the repository root, so it runs from the
    working directory of the test runner.
---
}
/// Licence header checks for the repository
unit Http2Server.Licence.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}

interface

uses
  SysUtils, Classes, fpcunit, testregistry;

type
  /// the licence expression of the library
  TLicenceTest = class(TTestCase)
  private
    function RepoRoot: string;
    function ReadHead(const APath: string; const ALines: Integer): string;
    procedure CollectFiles(const ADir, AMask: string; const AInto: TStrings);
  published
    procedure TestEveryPassFileNamesTheLicence;
    procedure TestNoPlaceholderLicenceSurvives;
    procedure TestLicenceAndNoticeExist;
    procedure TestNoticeNamesTheExpression;
  end;

implementation

const
  LicenceExpression = 'LGPL-2.1-only WITH Independent-modules-exception';

function TLicenceTest.RepoRoot: string;
var
  Dir: string;
  Depth: Integer;
begin
  // the test runner runs from the repository root; walk upward if it does not
  Dir := GetCurrentDir;
  for Depth := 0 to 4 do
  begin
    if FileExists(IncludeTrailingPathDelimiter(Dir) + 'LICENSE') then
      Exit(Dir);
    Dir := ExcludeTrailingPathDelimiter(ExtractFileDir(Dir));
  end;
  Result := GetCurrentDir;
end;

function TLicenceTest.ReadHead(const APath: string;
  const ALines: Integer): string;
var
  Lines: TStringList;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    while Lines.Count > ALines do
      Lines.Delete(Lines.Count - 1);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TLicenceTest.CollectFiles(const ADir, AMask: string;
  const AInto: TStrings);
var
  Search: TSearchRec;
  Path: string;
  Mask: string;
begin
  // every entry is enumerated, then filtered, so a subdirectory is visited
  // whatever the mask is
  Mask := AMask;
  if (Mask = '') or (Mask[1] = '.') then
  begin
    if Mask = '*' then
      Mask := ''
    else if Mask = '*.md' then
      Mask := '.md';
  end;
  if Mask = '*' then
    Mask := '';
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, Search) = 0 then
  begin
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      Path := IncludeTrailingPathDelimiter(ADir) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
        CollectFiles(Path, AMask, AInto)
      else if (AMask = '*') or
              (ExtractFileExt(Search.Name) = Copy(AMask, 2, Length(AMask) - 1)) then
        AInto.Add(Path);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;

procedure TLicenceTest.TestEveryPassFileNamesTheLicence;
var
  Files: TStringList;
  I: Integer;
  Head: string;
begin
  Files := TStringList.Create;
  try
    CollectFiles(RepoRoot + '/src', '*.pas', Files);
    CollectFiles(RepoRoot + '/test', '*.pas', Files);
    CollectFiles(RepoRoot + '/examples', '*.pas', Files);
    AssertTrue('the search finds the Pascal files', Files.Count >= 40);
    for I := 0 to Files.Count - 1 do
    begin
      Head := ReadHead(Files[I], 5);
      AssertTrue(Files[I] + ' names the licence expression',
        Pos('license: ' + LicenceExpression, Head) > 0);
      AssertTrue(Files[I] + ' names the copyright holder',
        Pos('copyright: Copyright 2026 Liam Seamus Coughlin', Head) > 0);
    end;
  finally
    Files.Free;
  end;
end;

procedure TLicenceTest.TestNoPlaceholderLicenceSurvives;
var
  Files: TStringList;
  I: Integer;
  Text: TStringList;
  Placeholder: string;
begin
  // the placeholder is built at run time, so this unit holds no literal copy
  Placeholder := 'TBD' + '-LICENCE';
  Files := TStringList.Create;
  Text := TStringList.Create;
  try
    CollectFiles(RepoRoot + '/src', '*.pas', Files);
    CollectFiles(RepoRoot + '/test', '*.pas', Files);
    CollectFiles(RepoRoot + '/examples', '*.pas', Files);
    CollectFiles(RepoRoot + '/doc', '*.md', Files);
    for I := 0 to Files.Count - 1 do
    begin
      Text.LoadFromFile(Files[I]);
      AssertTrue(Files[I] + ' holds no placeholder licence',
        Pos(Placeholder, Text.Text) = 0);
    end;
  finally
    Text.Free;
    Files.Free;
  end;
end;

procedure TLicenceTest.TestLicenceAndNoticeExist;
begin
  AssertTrue('LICENSE exists', FileExists(RepoRoot + '/LICENSE'));
  AssertTrue('NOTICE exists', FileExists(RepoRoot + '/NOTICE'));
  AssertTrue('the LICENSE holds the LGPL text',
    Pos('GNU LESSER GENERAL PUBLIC LICENSE',
      ReadHead(RepoRoot + '/LICENSE', 400)) > 0);
  AssertTrue('the LICENSE holds the Free Pascal linking exception',
    Pos('Free Pascal linking exception',
      ReadHead(RepoRoot + '/LICENSE', 400)) > 0);
end;

procedure TLicenceTest.TestNoticeNamesTheExpression;
var
  Notice: TStringList;
begin
  Notice := TStringList.Create;
  try
    Notice.LoadFromFile(RepoRoot + '/NOTICE');
    AssertTrue('the NOTICE names the SPDX expression',
      Pos('LGPL-2.1-only WITH Independent-modules-exception',
        Notice.Text) > 0);
    AssertTrue('the NOTICE names mORMot2',
      Pos('mORMot2', Notice.Text) > 0);
    AssertTrue('the NOTICE names OpenSSL',
      Pos('OpenSSL', Notice.Text) > 0);
    AssertTrue('the NOTICE names the copied protocol units',
      Pos('copied protocol units', Notice.Text) > 0);
  finally
    Notice.Free;
  end;
end;

initialization
  RegisterTest(TLicenceTest);
end.
