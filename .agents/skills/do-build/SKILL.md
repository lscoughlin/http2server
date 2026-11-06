---
name: do-build
description: >-
  Implements planned work in an isolated git worktree with a team of agents,
  then merges locally to main and deletes the worktree. Use whenever the user
  says do-build, /do-build, implement a plan, execute plan/, build in a
  worktree, land planned work on main, or asks to use a team of agents to
  implement plans and drop the worktree when done.
---

# do-build

Turn a plan into code on `main` without touching the current checkout. One
worktree, a team of agents inside it, local merge, then the worktree goes away.

This is the implementation counterpart of `do-plan`. `do-plan` writes plans to
`plan/[plan-name].md` (and `plan/stories/`) — including, as ordinary tasks or
stories, any Reference Documentation (`doc/**/*.md`) the plan calls for;
`do-plan` never writes `doc/` itself. This skill executes those plans (or an
inline plan), writing both code and any called-for docs, and lands them. As
tasks land — reviewed and tested, not merely attempted — it checks them off
(`- [ ]` → `- [x]`) in the plan file itself, so `plan/` stays an accurate,
resumable progress record for the whole run.

Text that the build writes (code comments, docs, commit messages) follows
`AGENTS.md`: ASD-STE100 Simplified Technical English.

## Goal

Invoking this skill is an explicit request for a long-running job that ends
with the work on `main` and the worktree gone. If the session offers a goal
tool (`CreateGoal` and `UpdateGoal`), call `CreateGoal` before creating the
worktree, with an objective in this shape (fill in the resolved plan names or
the user's prompt), keep it `active` until `main` has the work and the worktree
is gone, and call `UpdateGoal` with `complete` only then:

```
Use a team of agents to implement the following plans in a worktree. When complete, merge to main and drop the worktree.

<resolved plans or prompt>
```

If no goal tool exists, say so once and carry on: the checkboxes in the plan
file are the progress record. If you stop short (conflict, red tests, hook
approval), say what is left.

## Resolve the plan

1. If the user names a plan (path, filename, or slug), read it from `plan/`.
   A name like `more_config_opts` is `plan/more_config_opts.md`. A full path
   such as `plan/more_config_opts.md` is used as given.
2. If they name several plans, implement all of them in **one** worktree.
3. If they do not name a file, the rest of the message *is* the plan. Still
   skim `plan/` (and `plan/README.md`) when the prompt clearly points at an
   existing plan or story.
4. Read the plan(s) and every spec they link (usually under `doc/`) before
   writing code. The plan is the task list; the specs are the source of truth.
5. Check the plan's own preconditions before any worktree work. A plan can
   depend on other work being on `main` first (for example a "Parallel work"
   or "Depends on" section). If a precondition is not met, stop and report
   it; do not start the build.
6. A plan whose Status section says it is not approved is not ready. Stop and
   ask, unless the user's invocation of this skill names the plan (that counts
   as approval).

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
git -C "$PRIMARY" worktree add -b build/<slug> "$PRIMARY.build-<slug>" main
```

The path `<primary>.build-<slug>` (for example
`http2server.build-more-config-opts`) matches what Worktrunk makes.

**Before creating,** run `git worktree list` and `git branch --list 'build/*'`.
If a worktree or branch of that name already exists, look at it (`git log
main..build/<slug>`, `git status` in it). Reuse it only if it holds this
plan's work. A leftover with no commits, or a branch that another builder
uses, is not yours to delete: ask the user before you remove or reuse it.

**Third-party sources:** the library builds against `third_party/mORMot2`.
After the worktree exists, check that `$WORKTREE/third_party/mORMot2/src`
exists. If it does not, link it from the primary checkout:

```bash
ln -sfn "$PRIMARY/third_party/mORMot2" "$WORKTREE/third_party/mORMot2"
```

Compiled output goes to `bin/` inside the worktree (it is ignored by git).
Never point a worktree build at the `bin/` of the primary checkout.

Every agent prompt must include the **absolute** worktree path and branch
name, and must say that all edits stay there.

## Team of agents

You are the coordinator. You do not implement the whole plan yourself when
it splits cleanly. You partition, dispatch, review, and land.

1. Split the plan into workstreams by **file/package ownership**, not by
   story number alone. Parallel agents on one worktree will clobber each
   other if they touch the same files.
2. Launch independent workstreams in the same turn with the `Agent` tool
   (`general-purpose`). Sequential stories that share files wait. Many plans
   in this repo touch the same few files (`Config.pas`, `Async.pas`,
   `Connection.Core.pas`); treat those as one owner at a time.
3. Keep the concurrent set small (about four implementers). More parallelism
   only helps when the partitions are truly disjoint.
4. After a wave finishes, review the worktree diff yourself, run the relevant
   `task` targets **in the worktree**, and either dispatch a fix wave or
   continue.

Each implementer prompt includes:

- Absolute worktree path and branch
- The story/tasks they own, plus links to the specs
- The exclusive paths they may edit
- `AGENTS.md` constraints: ASD-STE100 text, a Pascal file under 1000 lines
  and one concept, a method under 500 lines (soft), the pasdoc header with
  front matter on every Pascal file, and the build through `make` / `task`
  (not raw `fpc` calls)
- For any task that writes or updates Reference Documentation (`doc/**/*.md`):
  doc prose is descriptive and explanatory, never imperative, and must never
  reference this or any other implementation plan (nothing under `plan/`);
  every document in `doc/` starts with the YAML front matter that `AGENTS.md`
  (section Documentation front matter) defines (`license` on line 2,
  `copyright`, and optional keys such as `keywords`, `scope`, `primary_types`,
  `related_docs`, `invariants`); a new document gets a row in `doc/README.md`;
  an RFC is cited by number with its rfc-editor URL and the date of the check
- Commit on the feature branch when their story is done — landing on `main`
  is the user's request, so feature-branch commits are in scope
- Report back the exact task IDs (e.g. `Task 2.1`, `Task 2.3`) finished,
  separately from any they skipped, deferred, or only partially did — this
  is what you check off against next, so a vague "done" is not enough
- Do **not** merge, push, touch `main`, or remove the worktree
- Do **not** edit the plan file under `plan/` — it lives in the primary
  checkout, not the worktree (`plan/` is gitignored), and checking off tasks
  is your job after review, not theirs on self-report

Use `explore` only to answer a locating question — and within that, reach
for `ast-grep-nav` first for structural/shape searches, `ctags-nav` for
exact symbol-name lookups, and `rg` for plain text. Use `p-debug` if a
FreePascal test crashes or leaks. Do not send implementers off to
re-plan; `do-plan` already did that.

After a wave's diff review and tests pass (the same review this section
already asks for), open the plan file(s) in the **primary checkout**'s
`plan/` — not the worktree; `plan/` is gitignored and never travels with the
branch — and mark that wave's finished tasks `- [x]`. Check off
only what you have personally verified (diff read, tests run), never
straight from an implementer's report. Leave anything stopped-short,
skipped, or deferred unchecked; a short inline note next to it (why, and
what's left) is worth more to whoever resumes than silence. Do this after
every wave, not just once at the end, so a mid-run stop still leaves the
plan file telling the truth about what actually landed.

## Verify before merge

Merge only when the worktree is green enough to land:

Run each check in the worktree:

- `make test` (the fpcunit suite) and `make examples`. The plan can name
  narrower or extra checks (a live TLS run, `make tls-live`, `make mtls-live`);
  run those it names. Report the test count and compare it with the count
  before the change.
- `task docs:check` after any wave that touched `doc/**/*.md` or a Pascal
  header. Fix whatever it reports (front matter, imperative mood, a reference
  to `plan/`, broken links) in the worktree before moving on. Do not merge a
  doc change that fails it.
- When a story changes wire behaviour (frames, GOAWAY, flow control, TLS), also
  run `task validate` (`h2spec` and the abuse tool) and compare the numbers
  with `doc/verification/validation.md`. A drop blocks the merge. If a tool is
  not installed on the host, say so in the report; do not skip it silently.
- Check that no Pascal file passes 999 lines: `wc -l src/*.pas test/*.pas`.
  A file over the limit blocks the merge, also when it was over before and the
  change made it longer.
- No leftover build output in the diff (`git status` shows only intended
  files; `bin/` is ignored).
- A change to a user-visible setting is not done until the factory
  documentation (`doc/design/configuration.md`) and the validation rules agree
  with the code.

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
(below) if this run warrants them, close out the plan file (see "Plan file
lifecycle" below), then `UpdateGoal` → `complete` if a goal tool is in use.

Commit messages follow the style of `git log` (a conventional prefix such as
`feat(config):`, `fix(h2):` or `docs(tls):`, then the story numbers) and the
attribution lines that the session gives for commits. Do not tag, and do not
change `VERSION` or `http2server.lpk`, unless the plan or the user asks.

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

The plan file stays in `plan/` after the land (see "Plan file lifecycle"
below), with its unchecked tasks still unchecked and a note next to each. Even
so, every unchecked task and every newly discovered, unaddressed bug or gap
**must** get an entry here, so a future `do-plan` run finds it as input and
none of it is silently dropped.

Write (or update) `.ai/plans/backlog/<plan-slug>.md` in the **primary
checkout**, same gitignored-directory rule as the plan and AAR files. Use
the same `<plan-slug>` as the AAR and link the two files to each other. Add
an entry for each of:

- **Unfinished plan items** — every unchecked `- [ ]` task, quoted or
  paraphrased, with why it wasn't done (deliberately deferred, superseded,
  blocked).
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

In this repo `plan/` is the project record: finished plans stay there with a
status (`plan/hardening.md` and `plan/README.md` are the model). So a plan file
is **not deleted** after a land.

After a successful land:

1. Open the plan file in the primary checkout. Make its Status section say
   that the plan landed, with the date and the landing commit, and which tasks
   were deferred (each deferred task stays `- [ ]` with a note, and has an
   entry in the backlog file).
2. Add or update the story list and status rows in `plan/README.md`, in the
   style of the rows that are there. If another builder is working on
   `plan/README.md` at the same time (check `git status` and the worktree
   list), leave it and tell the user.
3. Do not edit `doc/` for this: the documents never refer to `plan/`.

State in your report to the user which plan file was updated, alongside the
usual land summary.

## Stop conditions

- Plan file missing or specs the plan depends on are absent → stop and say
  what to generate with `do-plan` first
- A precondition of the plan is not met (for example work that must be on
  `main` first), or the plan is not approved → stop and report
- Cannot create the worktree → stop; do not implement on `main`
- Merge or tests blocked → leave the worktree, write the after-action report
  and backlog file above before reporting back (this always qualifies as
  something unfinished), and say the path/branch and what failed
- A required external tool is missing (`h2spec`, `openssl`, a FreePascal unit
  directory) → report which check could not run; never report that check as
  passed

## Example

User: `do-build plan/more_config_opts.md`

1. Read `plan/more_config_opts.md`, its Status and its preconditions, and the
   `doc/design/` documents it lists. Stop if a precondition is not met.
2. If a goal tool exists, `CreateGoal` with the objective above and that plan.
3. `wt switch --create build/more-config-opts --base main --no-cd`
4. Check that `third_party/mORMot2` is present in the worktree.
5. Dispatch agents for stories that touch disjoint files; run stories that
   share `Config.pas`, `Async.pas` or `Connection.Core.pas` one after the other.
6. After each wave: read the diff, run `make test`, `make examples` and
   `task docs:check` in the worktree, then check off the finished tasks in
   `plan/more_config_opts.md` (primary checkout).
7. Run `task validate` when a story changed wire behaviour.
8. `wt merge main`
9. If anything was left unchecked or a blocker had to be worked around, write
   `.ai/plans/analysis/AAR-more-config-opts.md` and
   `.ai/plans/backlog/more-config-opts.md`.
10. Update the Status of `plan/more_config_opts.md` and the rows of
    `plan/README.md`.
11. `UpdateGoal` complete, if a goal tool is in use.
