# Repository Guidelines

## Language

All text output uses ASD-STE100 Simplified Technical English.

## Documentation

Documentation is in the `doc/` directory. Documentation is descriptive and
declarative. Documentation never uses the imperative mood. Documentation never
refers to a file in the `plan/` directory.

### Documentation front matter

Each document in `doc/` starts with YAML front matter. The front matter is
standard YAML. It is not wrapped in a comment or in any other markup.

- Line 1 of the file is a line with three hyphens (`---`).
- A second line with three hyphens closes the front matter.
- The `license` key is on line 2. Its value is the SPDX license identifier.
- The `copyright` key holds the copyright holder and the year.
- Additional keys are permitted. The documents use `keywords`, `notes`,
  `scope`, `primary_types`, `db_tables`, `related_docs` and `invariants`.
- The Markdown text starts after the closing line.

```markdown
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: important_thing
notes:
  - this is a note
---

# Title
```

A document cites an RFC by its number and its rfc-editor URL, and states the
date of the check. A document can name the plain-text copy in
`doc/references/`.

### Reference copies

The directory `doc/references/` holds verbatim plain-text copies of the RFCs and
other specifications that the library follows. The file
`doc/references/README.md` lists each copy with its title, its URL and the date
of retrieval. The copies are not documentation in the sense of this section.
The `.txt` copies carry no front matter, and the documentation rules do not
check them. The `.md` files in this directory follow the front matter rule.

## Plans

Plans are in the `plan/` directory. A plan can refer to a document in the
`doc/` directory.

A plan can refer to the reference copies in `doc/references/`. A plan names
the sections that a story must read. Working notes from that reading are in
the `plan/notes/` directory.

## Pascal File Header

Each Pascal file starts with a pasdoc documentation comment. The comment
wraps YAML front matter. The front matter holds a `license` key and a
`copyright` key. The front matter is the same YAML as in a document in
`doc/`. A Pascal file needs the comment wrapper, because the compiler does not
read YAML.

```pascal
{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: important_thing
notes:
  - this is a note
  - this is a note
---
}
unit Example;
```

- The comment is a pasdoc comment. The opening `{**` is on its own line. The
  line with three hyphens that opens the front matter follows on the next
  line. The `license` key follows after that line.
- The `license` value is the SPDX license identifier. The README holds the
  full license name.
- The `copyright` value holds the copyright holder and the year.
- Additional keys are permitted.
- A second line with three hyphens closes the front matter.
- The closing `}` is on its own line, directly after the closing hyphens.
  No blank line is between them.

```pascal
{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: scanner
notes:
  - this implements the string scanner
---
}
unit YamlPuller.Scanner;
```

## Pascal Source

- A Pascal file is less than 1000 lines long. A Pascal file expresses one
  concept, or one related set of concepts.
- A Pascal method is less than 500 lines long. This limit is a soft limit. A
  Pascal method expresses one responsibility.
