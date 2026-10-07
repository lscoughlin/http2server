---
name: do-build
description: >-
  Implements planned work in an isolated git worktree with a team of agents,
  then merges locally to main and deletes the worktree. Use whenever the user
  says do-build, /do-build, implement a plan, execute .ai/plans, build in a
  worktree, land planned work on main, or asks to use a team of agents to
  implement plans and drop the worktree when done. Invoking this skill is an
  explicit request to create a Cursor goal for that landing.
---

# do-build

Turn a plan into code on `main` without touching the current checkout. One
worktree, a team of agents inside it, local merge, then the worktree goes away.

This is the implementation counterpart of `do-plan`. `do-plan` writes plans to
`.ai/plans/planned/*.md` — including, as ordinary tasks or stories, any
Reference Documentation (`doc/**/*.md`) the plan calls for; `do-plan` never
writes `doc/` itself. This skill executes those plans (or an inline plan),
writing both code and any called-for docs, and lands them. As tasks land —
reviewed and tested, not merely attempted — it checks them off (`- [ ]` →
`- [x]`) in the plan file itself, so `.ai/plans/planned/*.md` stays an
accurate, resumable progress record for the whole run.

## Goal

Invoking this skill **is** an explicit request for a long-running goal. Call
`CreateGoal` immediately — before creating the worktree — with an objective in
this shape (fill in the resolved plan names or the user's prompt):

```
Use a team of agents to implement the following plans in a worktree. When complete, merge to main and drop the worktree.

<resolved plans or prompt>
```

Keep the goal `active` until `main` has the work and the worktree is gone.
Call `UpdateGoal` with `complete` only then. If you stop short (conflict,
red tests, hook approval), leave the goal active and say what is left.

## Resolve the plan

1. If the user names a plan (path, filename, or slug), read it from
   `.ai/plans/planned/`. A name like `introduce-rate-balance` is
   `.ai/plans/planned/introduce-rate-balance.md`.
2. If they name several plans, implement all of them in **one** worktree.
3. If they do not name a file, the rest of the message *is* the plan. Still
   skim `.ai/plans/planned/` when the prompt clearly points at an existing
   story.
4. Read the plan(s) and every spec they link (usually under `doc/`) before
   writing code. The plan is the task list; the specs are the source of truth.

Do not start implementation from memory of a plan you have not opened.

## Worktree

All implementation happens on a new branch in a new worktree, branched from
`main`. Do not edit the checkout this session started in. Do not use Task
`isolation: "worktree"` or `best-of-n-runner` — those create extra throwaway
trees. This skill owns exactly one tree.

**Branch name:** `build/<slug>` from the plan filename, or a short slug of the
inline prompt. Multiple plans: `build/<first-slug>` plus a brief extra if
needed.

**Create (prefer Worktrunk):**

```bash
command -v wt
# if wt exists:
wt switch --create build/<slug> --base main --no-cd
```

`--no-cd` matters: this session cannot consume Worktrunk's shell-integration
cd. Resolve the path with `wt list` or `git worktree list` after create.

**Fallback (no `wt`):**

```bash
PRIMARY="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
git -C "$PRIMARY" worktree add -b build/<slug> "$PRIMARY/../tdbank-build-<slug>" main
```

**`.vendor`:** the vendor tree is gitignored and lives only in the primary
checkout. After the worktree exists:

```bash
PRIMARY="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
if [ ! -e "$PRIMARY/.vendor" ]; then
  (cd "$PRIMARY" && task vendor)
fi
ln -sfn "$PRIMARY/.vendor" "$WORKTREE/.vendor"
```

Every agent prompt must include the **absolute** worktree path and branch
name, and must say that all edits stay there.

## Team of agents

You are the coordinator. You do not implement the whole plan yourself when
it splits cleanly. You partition, dispatch, review, and land.

1. Split the plan into workstreams by **file/package ownership**, not by
   story number alone. Parallel agents on one worktree will clobber each
   other if they touch the same files.
2. Launch independent workstreams in the same turn with `Task`
   (`generalPurpose`). Sequential stories that share files wait.
3. Keep the concurrent set small (about four implementers). More parallelism
   only helps when the partitions are truly disjoint.
4. After a wave finishes, review the worktree diff yourself, run the relevant
   `task` targets **in the worktree**, and either dispatch a fix wave or
   continue.

Each implementer prompt includes:

- Absolute worktree path and branch
- The story/tasks they own, plus links to the specs
- The exclusive paths they may edit
- `AGENTS.md` constraints (architecture, `task` not raw `fpc`, identity,
  naming)
- For any task that writes or updates Reference Documentation (`doc/**/*.md`):
  doc prose is descriptive and explanatory, never imperative, and must never
  reference this or any other implementation plan; files over ~120 lines and
  every `README.md` need the frontmatter block from `AGENTS.md` Section 4
  (`scope`, `primary_types`, `db_tables`, `related_docs`, `invariants`);
  organize per `doc/README.md`
- Commit on the feature branch when their story is done — landing on `main`
  is the user's request, so feature-branch commits are in scope
- Report back the exact task IDs (e.g. `Task 2.1`, `Task 2.3`) finished,
  separately from any they skipped, deferred, or only partially did — this
  is what you check off against next, so a vague "done" is not enough
- Do **not** merge, push, touch `main`, or remove the worktree
- Do **not** edit `.ai/plans/planned/*.md` themselves — it lives in the
  primary checkout, not the worktree, and checking off tasks is your job
  after review, not theirs on self-report

Use `explore` only to answer a locating question — and within that, reach
for `ast-grep-nav` first for structural/shape searches, `ctags-nav` for
exact symbol-name lookups, and `rg` for plain text. Use `p-debug` if a
FreePascal test crashes or leaks. Do not send implementers off to
re-plan; `do-plan` already did that.

After a wave's diff review and tests pass (the same review this section
already asks for), open the plan file(s) in the **primary checkout**'s
`.ai/plans/planned/` — not the worktree; plans are gitignored and never
travel with the branch — and mark that wave's finished tasks `- [x]`. Check off
only what you have personally verified (diff read, tests run), never
straight from an implementer's report. Leave anything stopped-short,
skipped, or deferred unchecked; a short inline note next to it (why, and
what's left) is worth more to whoever resumes than silence. Do this after
every wave, not just once at the end, so a mid-run stop still leaves the
plan file telling the truth about what actually landed.

## Verify before merge

Merge only when the worktree is green enough to land:

- Relevant `task` tests/builds from the worktree (smallest package
  `*:test` that covers the change; wider if the plan spans apps)
- No leftover debug/profile objects if a debug rebuild was used
  (`task <pkg>:clean` first)
- UI changes: exercise the flow, not just a screenshot
- Check the diff's changed paths against
  [sit-uat-suites.md](../../../doc/base/technical/testing/sit-uat-suites.md)'s
  change-area mapping table and run the matching SIT/UAT suite(s) in the
  worktree alongside the tests/builds above — a change under more than one
  path prefix runs the union of the matching rows. This in-worktree run is
  always the **Integration-level** execution of the matching suite(s): a
  local host process, with the auth shim or no auth. The merge gate never
  requires a Kubernetes cluster or a real OAuth2 login. If the mapped
  suite(s) also include a real-OAuth2 path (per sit-uat-suites.md — for
  example `zitadel-auth.http` or the opt-in `zitadel-login` UAT spec), a
  true SIT/UAT-level run against a deployed environment is a separate,
  follow-up verification outside this gate. This step does not perform
  that run.
- If any wave touched `doc/**/*.md`, run `task docs:build` in the worktree
  after that wave's diff review. Fix whatever it reports (broken links,
  malformed frontmatter, any other build error) in the worktree before
  moving on — do not merge a doc change that fails `docs:build`.

If tests fail, fix them in the worktree. Do not merge red. Do not merge
an empty branch — drop the worktree instead and report that nothing
changed.

Before merging, do a last pass over the plan file(s): every task you are
about to land should already be checked off from the wave-by-wave updates
above. Anything still `- [ ]` at this point either did not actually land
(fix that first) or was deliberately deferred (say so when you report the
land, so it is not mistaken for forgotten).

## Land on main and drop the tree

Local merge only. Do not push. Do not open a PR unless the user asks.

**Worktrunk** (from the worktree; default squash + remove):

```bash
wt merge main
```

If hooks need approval (`Cannot prompt for approval in non-interactive
environment`), stop and ask the user to run `wt config approvals add`.
Do not pass `--yes` to bypass that for them.

**Git fallback** (run from the primary checkout, which holds `main`):

```bash
git -C "$PRIMARY" merge --squash build/<slug>
git -C "$PRIMARY" commit -m "$(cat <<'EOF'
<why this plan landed>

EOF
)"
git worktree remove "$WORKTREE"
git -C "$PRIMARY" branch -d build/<slug>
```

If `main`'s working tree is dirty and the merge cannot proceed, leave the
build worktree in place and report that. Same if the merge conflicts: do
not force it; say what collided.

After a successful land, confirm with `git worktree list` / `wt list` that
the build tree is gone, write the after-action report and backlog file
(below) if this run warrants them, remove the plan file (see "Plan file
lifecycle" below — this always happens once the AAR and backlog steps are
done), then `UpdateGoal` → `complete`.

## After-action report

Before reporting back to the user — whether the run lands cleanly, lands
with loose ends, or stops short — check whether it leaves anything
unfinished: unchecked `- [ ]` items in the plan file(s), a scope decision
the user made mid-run that narrowed or reshaped the original ask, a bug or
gap discovered along the way that was knowingly left unfixed, or a blocker
(merge conflict, red test, dirty `main`) that had to be diagnosed and
worked around. If none of that applies — the plan landed and every task is
checked off clean — skip this section (and the Backlog section below)
entirely; do not write an AAR for a run with nothing to report. The plan
file still gets deleted (see "Plan file lifecycle" below) — skipping the
AAR and backlog only means there was nothing left for them to hold.

Otherwise, write `.ai/plans/analysis/AAR-<plan-slug>.md` in the **primary
checkout** (same gitignored-directory rule as the plan files themselves —
never inside the worktree, which may already be gone by this point).
`<plan-slug>` matches the branch slug used for this run (`build/<slug>`);
for a multi-plan run, use the first plan's slug. If an AAR for that slug
already exists from an earlier session on this plan, update it rather than
starting over — treat it the same way the plan file's checkboxes are
treated: an accurate, cumulative record, not a per-run diary.

The AAR covers only the **outcome** of this run — a summary of the work
done, not follow-up work; that goes to the Backlog section below, kept
cleanly out of the AAR. Cover, in whatever subset applies:

- **What shipped** — a short per-story summary and the landing commit.
- **Scope decisions made mid-run** — anywhere the user's feedback during
  the build narrowed, relaxed, or reshaped a requirement from how the plan
  or its source spec originally stated it, so the gap between "what was
  asked" and "what shipped" is explicit rather than silently absorbed.
- **Blockers and how they resolved** — a merge conflict with work that
  landed on `main` mid-run, a flaky/pre-existing test failure judged
  unrelated, anything that needed diagnosis before the run could proceed.
  State what collided and how it was reconciled, not just that it happened.
- **Backlog spawned** — a link to `.ai/plans/backlog/<plan-slug>.md` (below)
  when this run wrote or updated one, so a reader lands on the follow-up
  list from here.

Write it in the analyst's own voice, plainly, the way this section's items
are meant to be read by whoever picks up the remaining work next — not a
transcript of tool calls. Then reference the AAR path when reporting back
to the user, alongside the usual land summary.

## Backlog

Everything the AAR deliberately excludes — unfinished plan items and newly
discovered problems — goes here instead, so the outcome record and the
follow-up list never get mixed together in one file.

The plan file is always deleted once this run finishes landing (see "Plan
file lifecycle" below), so this file — not the plan's checkboxes — becomes
the sole durable record of anything left undone. Every unchecked task and
every newly discovered, unaddressed bug or gap **must** get an entry here
before the plan file goes; none of it may be silently dropped.

Write (or update) `.ai/plans/backlog/<plan-slug>.md` in the **primary
checkout**, same gitignored-directory rule as the plan and AAR files. Use
the same `<plan-slug>` as the AAR and link the two files to each other. Add
an entry for each of:

- **Unfinished plan items** — every unchecked `- [ ]` task, quoted or
  paraphrased, with why it wasn't done (deliberately deferred, superseded,
  blocked) — this is what "Plan file lifecycle" below requires before the
  plan file can be deleted.
- **Gaps or bugs found but not fixed** — anything discovered while
  implementing that's out of this plan's scope (a pre-existing bug in
  adjacent code, a missing capability a future plan will need to add). Say
  why it wasn't fixed here, not just that it exists.
- **New issues surfaced during the build** — anything else worth a future
  `do-plan` or `brainstorm` picking up that isn't already one of the above.

Word each entry so a future `do-plan` (or `brainstorm`) run can act on it
without reopening this run's transcript — what's wrong or missing, and
enough context (file paths, the relevant spec) to start from. This file is
candidate input for planning, not a status report — write it that way.

## Plan file lifecycle

A plan file's job is to stay a resumable, truthful worklist only while the
work it describes is in flight. Once a run lands on `main`, the plan file's
job is over — every task in it is either checked off, or its remainder has
already moved to the backlog file (mandatory, per the Backlog section
above). Either way nothing is left for the plan file uniquely to hold, so
after a successful land it is **always** deleted.

After the after-action-report and backlog steps above (whether or not they
produced anything), delete the plan file(s) from the primary checkout's
`.ai/plans/planned/`. Do this only after confirming — from the wave-by-wave
checkoffs and the last pass before merge — that every unchecked task has a
corresponding backlog entry; if you find one that doesn't, add it to the
backlog first.

Deleting the plan file does not delete its AAR or its backlog file —
`.ai/plans/analysis/AAR-<slug>.md` and `.ai/plans/backlog/<slug>.md` stay as
the durable record of what happened and what's left, and are what the next
`do-plan` or `do-build` run resumes from instead of the plan file.

State in your report to the user that the plan file was removed, alongside
the usual land summary.

## Stop conditions

- Plan file missing or specs the plan depends on are absent → stop and say
  what to generate with `do-plan` first
- Cannot create the worktree → stop; do not implement on `main`
- Merge or tests blocked → leave the worktree, keep the goal active, write
  the after-action report and backlog file above before reporting back
  (this always qualifies as something unfinished), and say the path/branch
  and what failed

## Example

User: `do-build introduce-rate-balance`

1. `CreateGoal` with the objective above and that plan name
2. Read `.ai/plans/planned/introduce-rate-balance.md` and the `doc/` specs
   it lists
3. `wt switch --create build/introduce-rate-balance --base main --no-cd`
4. Symlink `.vendor`
5. Dispatch deposit-side and loan-side agents only if their file sets do
   not overlap; otherwise one after the other
6. Run the deposits/loans tests in the worktree
7. Check off the finished tasks in
   `.ai/plans/planned/introduce-rate-balance.md` (primary checkout)
8. `wt merge main`
9. If anything was left unchecked or a blocker had to be worked around,
   write `.ai/plans/analysis/AAR-introduce-rate-balance.md` and
   `.ai/plans/backlog/introduce-rate-balance.md`
10. Remove `.ai/plans/planned/introduce-rate-balance.md` — its remainder,
    if any, is now in the backlog file
11. `UpdateGoal` complete
