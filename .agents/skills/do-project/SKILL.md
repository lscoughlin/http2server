---
name: do-project
description: >-
  Research and viability-exploration skill for a major feature or initiative in
  the tdbank codebase — a new market, a new product line, a new architectural
  domain — for when the question is "could/should we build this at all" and
  answering it takes gathering reference documentation and checking claims
  against the outside world across more than one session, not one quick
  exchange. Runs a dialectic cycle like `brainstorm` (thesis, antithesis,
  synthesis, then Socratic rounds), but every claim sourced from outside this
  repo is checked against an external, authoritative source — logged as
  Claim/Source/Retrieved/Verdict in a sources ledger — before it is written
  down as fact; no claim about a third-party library, vendor API, spec,
  regulation, or industry practice goes into a project file from recall
  alone. Calls the `advisor` tool before committing to any verdict that
  closes out the project. Use whenever the user says do-project,
  /do-project, "is X viable", "could we build/support X market/product",
  "let's explore doing X", "research whether we could build X", or hands you
  a converged `brainstorm` output that turns out to need sustained research
  rather than a direct plan. Not for a single fuzzy question that resolves
  in one sitting (`brainstorm`) and not for something already concrete
  enough to break into stories (`do-plan`). Everything this skill writes
  lives under one project's own directory, `.ai/plans/projects/<slug>/` — a
  README, a viability record, a sources ledger, per-topic research files,
  and (once the shape is clear) a gap ledger or design summary — built up
  and resumed across many sessions; it never edits `doc/`, code, another
  project's directory, or anything outside its own project directory, and
  hands off to `do-plan` only once the user explicitly approves.
---

# Do-Project Skill

`brainstorm` resolves a fuzzy question into one prompt in a single sitting. `do-plan` turns an
already-concrete ask into stories and tasks. Neither is built for the question this skill answers:
**is a major feature or initiative even viable, and what would building it actually require** —
"could tdbank's engine support Islamic profit-sharing deposits," "is a five-country BNPL launch
viable," "what would Japan market entry actually require." That's this skill: hold the question
open across however many sessions it takes, grounded in the codebase, `doc/`, and the outside
world in equal measure, building a durable, self-contained record of the investigation in the
open, until the project reaches a verdict (viable, not viable, or explicitly parked).

**If the question resolves in one sitting with no real research burden**, use `brainstorm`
instead — running this skill's full verification discipline over something that was never in
doubt just slows the user down. This skill earns its keep on genuinely open feasibility
questions about **major** features: something that would touch multiple apps/units, introduce a
new dependency or architectural pattern, or carry real cost/risk if wrong.

This skill never creates a worktree and never edits a file that already exists outside
`.ai/plans/projects/` — no `doc/`, no code, no other project's directory, no `.ai/plans/planned/`
or `.ai/plans/brainstorm/` files (except the one move described in Section 1). The only thing it
ever writes to is one project's own directory under the primary checkout's
`.ai/plans/projects/<slug>/` (see Section 2 for why "primary checkout" matters here). A project
directory is expected to grow over many separate conversations — read what's already there before
adding to it; do not restart a project's reasoning from scratch just because this is a new
session.

## 1. Relationship to `brainstorm` and `do-plan`

- **If the request is already scoped enough for `do-plan`** — a clear ask with a bounded surface
  `do-plan` could start specifying right now — say so and point at `do-plan`. Don't manufacture a
  research project for its own sake.
- **If the request is still fuzzy** — the user doesn't yet know what they're asking for — that's
  `brainstorm`'s job. Point at it instead.
- **This skill sits between them**: the ask is clear (a real market, a real product idea, a real
  architectural question) but answering it needs verified external research, a codebase gap
  analysis, or both, spread across more work than one sitting can hold. A project this skill
  starts may itself hand off to `do-plan` once it converges (Section 8) — that hand-off is this
  skill's own exit, not something it does mid-stream.
- A `brainstorm` output can seed a project directly: if `.ai/plans/brainstorm/<slug>.md` converged
  on something bigger than `do-plan` can act on as-is, **move** that file (not copy) into the new
  `.ai/plans/projects/<slug>/<slug>.md`, unchanged. It becomes the project's seed material — cited
  in the README's Index as "the original brainstorm output," never rewritten. Nothing is left
  behind at the old path.

## 2. Starting or resuming a project

`.ai/plans/` is gitignored and per-worktree — a worktree's copy is separate, empty, and vanishes
when the worktree is dropped. Resolve the primary checkout the same way `brainstorm` and
`do-build` do, before reading or writing anything:

```bash
PRIMARY="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
```

Work under `$PRIMARY/.ai/plans/projects/<slug>/`, never a bare relative path — `<slug>` is a short
kebab-case slug of the feature or initiative (this repo's convention, e.g. `rate-shopping-engine`,
`multi-region-ledger`, `asia-bnpl`).

- **New project**: create the directory and start from the layout in "Directory layout" below.
- **Existing project**: if the user names a project that already has a directory, or the topic
  clearly continues one, this is a resume, not a fresh start. List
  `$PRIMARY/.ai/plans/projects/` first if it's unclear whether one already exists, then:
  1. Read `README.md` in full — its Status line and "Where this stands" (still exploring) or "How
     this converged" (already has a verdict) section say exactly where the project left off.
  2. Read `viability.md`'s most recent rounds and `open-issues.md`/`open-items.md` (if present) in
     full — the next round should visibly build on the last one, not repeat it.
  3. Continue the round numbering from where it stopped. Never renumber or delete a past round.
  Do not start a second directory for the same initiative.

### Directory layout

Every project's core files, present from the start:

```
.ai/plans/projects/<slug>/
├── README.md        # status, problem statement, index of the files below
├── viability.md      # the dialectic: thesis/antithesis/synthesis + Socratic rounds, open questions
├── sources.md         # verification log: every external claim, its source, its verdict
└── research/          # one file per topic investigated, internal or external
    └── <topic-slug>.md
```

- **`README.md`** — the entry point. Problem statement (what feature/initiative, why it's being
  considered), current **status** (Section 6), and a short index linking `viability.md`,
  `sources.md`, and every other file in the directory. Keep this current — it's what a future
  session (or the user, cold) reads first.
- **`viability.md`** — the running dialectic record (Section 5). Append each round; don't rewrite
  history away, since a later round explicitly building on an earlier one is part of the record.
- **`sources.md`** — the verification log for external claims (Section 3). May stay a near-empty
  stub, with a note saying why, if every finding so far is internal to the repo.
- **`research/<topic-slug>.md`** — reference material gathered on one topic, written so it stands
  alone (a future reader shouldn't need the conversation to make sense of it). Cite sources inline
  for external claims; a claim about this repo cites a `path:line` instead. Give each file its own
  "Open questions" subsection once it accumulates any.

Additional files appear as a project grows — not every project needs every one:

| File | When it appears |
| --- | --- |
| `research/pdfs/` or `pdfs/` | Archived copies of primary source documents actually fetched and read. Pick one location per project and stay consistent; give it its own `README.md` indexing what's there and why. |
| `open-issues.md` / `open-items.md` | Once open questions outgrow a couple of bullets in the README — see Section 5. |
| A gap ledger or design summary, named for its topic (`<slug>-in-<region>.md`, `design-summary.md`) | Once the shape of the answer is clear enough to write down — see Section 5's closing note. |
| `datamodel/<name>.yaml` | Only for a new-domain-concept project proposing a schema — written in the same DSL as `doc/base/datamodel/*.yaml` (see `doc/base/datamodel/rules.md`). |

Write to these files continuously through the conversation as findings land — this is a reference
corpus being built up, not a single report assembled at the end the way `brainstorm`'s output is.

## 3. External sourcing discipline

Every claim in this project that comes from outside this repository gets one entry in
`sources.md`, in this exact shape:

```
**Claim**: <the specific factual claim, precise enough to be falsifiable>
**Source**: <full citation — publisher, document title, date, section/¶ if applicable>
**Retrieved**: <date>, via `<url>` (how it was fetched, and which pages/sections were actually
read). Archived locally at [`pdfs/<file>`](pdfs/<file>) if a document was fetched.
**Verdict**: **Verified**/**Partially verified**/**Unverified**/**Contradicted**. <why>
---
```

Add a **Corroborating source** block under the same claim when a second, independent source backs
or complicates the first — note explicitly whether it confirms the exact figure or only the
general mechanism. Entries are separated by `---` and ordered to match the research file(s) they
support; note that grouping at the top of `sources.md`.

- **Verdict vocabulary is exactly these four words** — do not invent a fifth. **Verified** means a
  primary source was read directly and confirms the claim as stated. **Partially verified** means
  the mechanism is Verified but a specific figure or detail inside it is not — say precisely which
  part is which. **Unverified** means a claim is currently resting on a secondary source (a search
  summary, a blocked fetch) with no primary source read yet, or nothing confirming or denying it
  was found at all — log it honestly rather than upgrading it or dropping it silently; don't let it
  quietly read as settled fact elsewhere in the project. **Contradicted** means two sources
  disagree — record both, keep both entries, and say which one this project relies on and why;
  resolving the conflict (or deciding it doesn't matter) is itself part of the dialectic, not
  something to smooth over before the user sees it.
- **A claim sourced entirely inside this repository does not need a `sources.md` entry** — it's
  verified by direct file read or `rg`, cited `path:line` in the research file itself. Internal
  claims don't need external verification — the file itself is the ground truth — but do note when
  a doc claim and the code disagree; that disagreement is a finding in its own right. Say once, at
  the top of `sources.md`, that internal claims are cited in-line instead, so the omission reads as
  a rule, not a gap.
- Prefer a primary source (the regulator's own text, the standard-setter's own document, a vendor's
  or bank's own published page, a library's own source/changelog) over a secondary summary every
  time one is reachable. If the user has stated a sourcing preference (e.g. a native-language
  regulatory text over an English secondary summary), follow it and say so.
- If a fetch is blocked (a WAF, a 403, a paywall), say so plainly in `sources.md` as Unverified —
  don't quietly fall back to a weaker source without flagging the substitution. `Claude in Chrome`
  is a legitimate fallback for a document that 403s a direct fetch.
- **Never silently edit a claim that turns out wrong.** Strike it through in place
  (`~~wrong claim~~`) and add a note of what corrected it and when — the same discipline
  `viability.md` uses for corrections (Section 5). A reader should be able to see that something
  changed, not just the corrected version.

## 4. Internal research discipline

Same order `do-plan` and `brainstorm` use: read `doc/` first (`mcp__clarity__search`, `index:
"docs"`, per topic, even when the route map in `doc/README.md` already names a file — fire a
direct query anyway, since a table entry doesn't cross-link a paired doc), then the codebase
(`ast-grep-nav` for structural/shape searches, `ctags-nav`/`readtags` for exact symbol lookups,
`rg` for everything else). One extra rule specific to this skill: **prefer a direct source-code
read over `doc/` prose whenever a finding will drive a verdict.** `doc/` can lag the code; a
gap-ledger row or a viability round built on a doc description that doesn't match the actual
implementation is worse than one that took longer to confirm directly. Say explicitly when a
finding is source-code-grounded versus doc-sourced, the same way a project's own gap-ledger passes
do.

## 5. The viability dialectic

`viability.md` starts `# Viability dialectic` and holds every round, numbered, in the order they
happened — never renumbered, never deleted, corrections struck through in place per Section 3's
discipline.

- **Round 1 is always thesis → antithesis → synthesis**, exactly like `brainstorm`'s round
  structure, under `### Thesis: ...` / `### Antithesis: ...` / `### Synthesis: ...` subheadings.
  Thesis: this is viable, grounded in the research so far. Antithesis: argue it yourself — the
  cost, the risk, the constraint that breaks it, the simpler alternative nobody's checked.
  Synthesis: reconcile into a sharper claim about viability (or a sharper open question). Put all
  three in front of the user in one turn.
- **Later rounds take whichever shape moves the verdict forward fastest**, headed
  `## Round N — <short label of what happened>`:
  - Another thesis/antithesis/synthesis pass, narrower than round 1's, whenever a round is
    genuinely contesting the framing.
  - A **Socratic round** — ask the single question that would most change the viability verdict: a
    cost nobody's estimated, a dependency nobody's checked, a constraint that's assumed but
    unconfirmed. Let the answer visibly feed the next round rather than sitting unused.
  - A plain **decision** (`### Decision`), a literature check against real-world practice, or a
    naming choice, when that's what the work actually needs — don't force the three-part
    thesis/antithesis/synthesis shape onto a round that's just recording a finding.
  Don't collapse several rounds into one message because the direction seems obvious — the point
  is the user pushing back on a specific claim, and research that surfaces a hard external
  constraint (a verified "no, that API can't do that") should become the next antithesis
  immediately, not wait for a scheduled round. Append each round to `viability.md` as it happens —
  do not hold rounds in the conversation only and write them up after the fact.
- **Call the `advisor` tool at least once before committing to any verdict that closes out a
  project or a major sub-question**, and log that round explicitly, e.g.
  `## Round N (advisor review, before a verdict)`. Treat its critique with the same weight the
  `advisor` tool's own guidance calls for — if it finds something the dialectic mismodeled, the
  next round should visibly correct course, not defend the prior framing.
- State verdicts in plain words as they're reached — `viable`, `not viable`, a scope decision, a
  question closed — so a reader scanning round headers and decision lines gets the shape of the
  argument without reading every word.
- Move an open question out of `viability.md` and into `open-issues.md`/`open-items.md` once open
  questions start accumulating (more than a couple of live threads) — organize that file by
  priority tiers (`## P1 — ...`, `## P2 — ...`) plus a closing `## Out of scope by explicit
  decision (not open — recorded so it isn't re-litigated)` section for anything the user has
  explicitly ruled out. That last section matters: it stops a future round from reopening a
  question that's actually settled.
- Once the shape of the answer is clear, write it down separately from the round-by-round history
  — a reader shouldn't have to replay the whole dialectic to know the current state:
  - For a **market or product-fit question**: a gap ledger (Config vs. New build) against the
    relevant existing engine, named for its topic at the project root.
  - For a **new domain-concept question**: a `design-summary.md` — "the design as it currently
    stands, in one page, no dialectic history" — optionally with `datamodel/*.yaml` for a proposed
    schema, and a concern-specific cross-reference doc (e.g. `compliance-integration.md`) when one
    cross-cutting theme keeps recurring across rounds and research and deserves one place that
    answers it fully.
  - Either way, name the single highest-uncertainty design decision or open regulatory question
    explicitly, worth carrying into a future `do-plan` pass verbatim.

## 6. Convergence and the README status lifecycle

A human confirms the verdict; the sense that research "looks complete" isn't the check. Ask
directly if it's unclear which outcome the conversation has reached. `README.md`'s `## Status:
...` line, first under the title, is the source of truth for which one:

- **`exploring`** — the dialectic is still running with no verdict yet.
- **`viable`** — the dialectic and the verified research converge on "this can be built," with the
  real costs/risks named, not hidden.
- **`not viable`** — a verified external fact or an internal constraint rules it out. Record
  exactly which finding did it and why it's disqualifying, not just "seems hard." This is a real,
  useful outcome — it stops future sessions from re-asking the same question.
- **`parked`** — genuinely still open, but the user wants to stop for now. Record what's resolved
  and what isn't, so resuming later doesn't start from zero.
- **`handed-off`** — `do-plan` has already produced plans from this project (Section 8). Keep the
  prior status alongside it, e.g. "(Prior status: **viable** — see ... below.)", so the verdict
  reasoning stays visible after hand-off.

The rest of `README.md`:

- `## Problem statement` — the real question, plainly stated, corrected in place (not silently) if
  a later round finds the framing was wrong.
- `## Index` — one bullet per file in the directory, each annotated with what it holds and why it
  matters, kept current every time a file is added.
- While `exploring`: `## Where this stands` — current state, what the last round found, what the
  next round should tackle. This section gets replaced, not appended to, each time it's updated.
- Once converged: `## The <verdict> verdict, in one page` (the argument's conclusion, dense enough
  to stand alone) and `## How this converged` (the shape of the argument — which alternatives were
  considered and ruled out, and what changed the project's mind, if anything did).
- `## Handoff` — see Section 8.

A project directory is a durable reference corpus, not disposable scratch — unlike `brainstorm`'s
single prompt file, don't rename or delete it once the verdict lands, at `viable`/`not
viable`/`parked` or afterward.

## 7. Cross-project integration

A project frequently surfaces things that aren't its own scope:

- **An unrelated codebase defect found along the way** (a real bug, not a gap this project is
  meant to fill): don't work around it silently. Surface it to the user, and only file it to
  `.ai/plans/backlog/<slug>.md` on the user's explicit direction — never on your own initiative.
  Once filed, note it in this project (`open-issues.md` or the relevant round) and treat it as
  assumed-fixed going forward; if it's later confirmed landed, say so and cite the commit.
- **Work another initiative already covers**: if a gap this project found is already addressed by
  an in-progress `.ai/plans/planned/*.md` plan, cross-reference that plan by path instead of
  re-describing the work or double-counting it as this project's own gap.
- **A tangential idea that deserves its own investigation**: note it as future work "for its own
  `do-project`," not as scope creep on the current one — same discipline a project uses to keep
  its own problem statement from drifting.

## 8. Handoff to `do-plan`

Same approval gate `brainstorm` uses: this skill's own judgment that a project "looks done" is not
the check. Convergence means the verdict section and "How this converged" have stopped changing
between sessions and the user agrees the project is ready to hand off — ask directly if unclear.

If the verdict is **viable** and, once approved:

- Point `do-plan` at the project directory (the **absolute path** under the primary checkout,
  `$PRIMARY/.ai/plans/projects/<slug>/`, starting from `README.md`), not a single file — `do-plan`
  needs the whole corpus (design docs, sources, research), not just the verdict. Tell it to pull
  the settled decisions, constraints, and verified findings into its own plan text — the same way
  `do-plan` already treats a `brainstorm` output, except the source here is a directory, not one
  file.
- The project directory's own files are **not consumed** — they stay in place as the reference
  corpus the plan(s) were written from, unlike a `brainstorm` output. Only the README's Status line
  changes, to `handed-off`, with a line noting which plan file(s) `do-plan` produced. The research
  underneath stays exactly where it is.
- Do not auto-invoke `do-plan` without asking, even once a verdict looks final — the user may want
  to sit with the verdict first, and some projects (an explicit, recorded decision) are meant to
  stop here rather than become a build.

## Stop conditions

- User's answers keep reopening viability with no narrowing after several rounds → say so, ask
  whether to keep going, narrow scope, or park it.
- An external source directly contradicts the working thesis → raise it as the next antithesis (or
  Socratic round) immediately, and log it in `sources.md` as **Contradicted**, don't wait for the
  next scheduled round.
- A claim central to the thesis can't be verified after a real search attempt, or a blocked source
  would materially change the verdict if it turned out to contradict what's already found → log it
  **Unverified** in `sources.md`, flag it in `open-issues.md` if one exists, and say so plainly;
  don't let the dialectic proceed as if it were settled.
- User says to stop or move on before a verdict → leave the directory exactly as it stands,
  `Status: exploring`; do not force a synthesis just to close the session.
- User has not approved hand-off → keep the project's status as its verdict, not `handed-off`, and
  do not invoke `do-plan`.
