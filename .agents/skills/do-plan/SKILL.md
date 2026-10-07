---
name: do-plan
description: >-
  Generates implementation plans (stories and tasks) from the existing specs
  and codebase. Never edits doc/ or code directly — any documentation update
  a plan calls for becomes a task or story in the plan for do-build to carry
  out. Works read-only, directly in the current checkout (no worktree), and
  writes plan files to .ai/plans/planned/.
---

# Plan Skill

When invoking this skill, your goal is to turn the user's instructions into an **Implementation
Plan**: a set of stories and tasks that `do-build` can execute. This skill is read-only against
`doc/` and the codebase — it never writes either. If the requested change requires new or updated
Reference Documentation, that requirement becomes a task in the plan, not an edit you make here.

There is no worktree for this skill. It produces nothing git-tracked — the plan file lives under
the gitignored `.ai/plans/` — so read specs and code directly in the checkout this session already
has open.

## Implementation Plans

Implementation plans provide actionable tasks for AI/LLM agents to write the code (and, where
called for, the docs).

- **Location**: `.ai/plans/planned/[plan-name].md`
- **Content**: A set of stories and tasks that an AI/LLM agent can use to implement the instructed
  changes. Reference the existing specs under `doc/` that describe current behavior.
- **Documentation-update tasks**: every plan must explicitly check whether the change it describes
  requires new or updated Reference Documentation (`doc/**/*.md`) — a new domain concept, a changed
  invariant, a new component, a behavior change to something `doc/` already describes — not only
  plans that are visibly doc-heavy at a glance. Note in the plan (briefly, in its Background or
  per-story) that this check was made, even when the answer is "none needed," so a reviewer can see
  it was considered rather than skipped. When the check finds doc work is needed, do not write it
  yourself — add it to the plan as a task under the
  story it belongs to, or as its own story if the doc work is large enough to need its own
  breakdown (e.g. a new architecture doc, not a one-paragraph update to an existing one). Word each
  such task so `do-build`'s implementer needs nothing else to act on it:
  - **Tone**: doc prose must be descriptive and explanatory, never imperative — it specifies *what*
    the software is and *how* it works, not instructions to follow.
  - **Rule**: doc content must never reference implementation plans.
  - **Frontmatter**: any touched file over ~120 lines, or any `README.md`, needs the ≤20-line
    frontmatter block from `../../../AGENTS.md` Section 4 (`scope`, `primary_types`, `db_tables`,
    `related_docs`, `invariants`).
  - **Location**: organize according to `../../../doc/README.md`.
- **Rule**: Implementation plans **MAY** (and typically should) reference the specifications
  defined in the Reference Documentation, by path relative to the repo root (`doc/...`, not
  relative to the plan file itself — `.ai/plans/planned/` is a nested directory and a
  plan-file-relative path would resolve wrong).
- **Rule**: Implementation plans **MUST NEVER** link to or reference any file (or entry within a file) under
  `.ai/plans/**` that this run marks consumed (see Workflow steps 0 and 4) — a brainstorm output, a backlog
  entry, or any other existing `.ai/plans/` file used as this plan's source. Copy the relevant decisions,
  constraints, and context out of it into the plan's own prose instead of pointing at it. Consumed sources are
  ephemeral scratch that gets renamed or edited out (step 4) and aren't guaranteed to stick around at that
  path — a plan that leans on one staying in place isn't self-contained.
- **`.ai/plans/` is gitignored.** It never travels with a branch. Nothing here needs a worktree or
  a merge — the plan file is written once, in place, and `do-build` reads it from the same spot.
- **A plan touching a tested product line should name which SIT/UAT suites its Story-level
  tasks are expected to extend**, using
  [sit-uat-suites.md](../../../doc/base/technical/testing/sit-uat-suites.md)'s change-area mapping
  table — that's what `do-build` checks the diff against before merge.

## Workflow

0. **Check whether the prompt is sourced from an existing `.ai/plans/**` file.** If the user's
   instructions name or paste the content of a file anywhere under `.ai/plans/` — a brainstorm
   output (`.ai/plans/brainstorm/`), a backlog entry (`.ai/plans/backlog/`), or any other existing
   plan-adjacent file — remember that file's path; it needs to be marked consumed once the plan
   draft is written (see step 4). When the source is a multi-entry file (most
   `.ai/plans/backlog/*.md` files hold several `##`-headed entries — check with
   `grep -c '^## '`), also note exactly which entry or entries were actually used, since step 4
   treats "this whole file was the source" and "one entry among several was" differently. This
   doesn't apply to a prompt typed fresh in the conversation, only one sourced from an existing
   `.ai/plans/**` file.
1. **Read Specifications First**: read and review the existing Reference Documentation
   (specifications) in `doc/` first. Route-map lookups (`doc/README.md` → section README → file)
   and a direct `mcp__clarity__search` query are complementary, not either/or — fire one targeted
   query per topic even after the route map already names a file, since a table entry doesn't
   cross-link sibling docs (a subsystem's functional doc next to its technical doc is a recurring
   case). Clarity's corpus stops at `doc/**/*.md`, `*.yaml`, and `units|apps/**/*.pas` — config
   files (`.ini`, `docker-compose.yml`) and anything under gitignored `.ai/plans/` need a direct
   read, not a query.
2. **Code Search Second**: only after reading the specifications, search the codebase for context.
   Reach for `ast-grep-nav` first for structural/shape searches, `ctags-nav` for exact symbol-name
   lookups, and the `docs-search` skill / `rg` for text.
3. **Plan and Task**: create or update the **Implementation Plan** at
   `.ai/plans/planned/[plan-name].md`. Break the work down into logical stories and tasks that map
   to the specifications already in `doc/`, with references to the relevant files (repo-root-
   relative paths). Any doc/ work the change requires goes in as its own task(s) or story, per the
   rules above — do not write to `doc/` yourself. If step 0 flagged a `.ai/plans/**` source file
   (or entry), do not link to it — pull the parts of it that still matter (the decision reached,
   the constraints surfaced, the rejected alternatives worth remembering) into this plan's own
   text, in your own words, so the plan reads complete on its own.
4. **Mark the consumed source.** If step 0 found the prompt came from an existing file under
   `.ai/plans/**`, mark it consumed now, in place, so a future `do-plan` (or `brainstorm`) run
   doesn't treat it as still-actionable input:
   - **Whole file consumed** (a brainstorm output, or a backlog/other file where every entry in
     it fed this plan): rename it by prefixing its basename with `planned-`, staying in the same
     directory — `.ai/plans/brainstorm/<name>.md` → `.ai/plans/brainstorm/planned-<name>.md`,
     `.ai/plans/backlog/<name>.md` → `.ai/plans/backlog/planned-<name>.md`, and so on for any
     other `.ai/plans/` subdirectory.
   - **One entry among several consumed** (a multi-entry backlog file where only some `##`
     entries fed this plan): edit the file in place to remove just the consumed entry/entries,
     leaving the rest of the file — and its remaining entries — intact as still-open input for a
     future run. Do not rename a multi-entry file just because one entry was used.
   - Skip this step entirely when the prompt wasn't sourced from an existing `.ai/plans/**` file.

## Review

Plans don't have a test suite to gate them — a human reading them is the check. Do not treat a
plan as ready for `do-build` on your own judgment that the draft looks complete.

1. When the plan is ready, summarize what it contains and point the user at
   `.ai/plans/planned/[plan-name].md` for review.
2. If the user asks for changes, keep iterating on the same plan file.
3. Treat the plan as ready for `do-build` only once the user has explicitly approved. "Looks
   good", "go build it", "approved" (or the equivalent) counts; silence does not.

## Stop conditions

- User has not approved → keep iterating on the plan file, do not report it as ready for `do-build`
