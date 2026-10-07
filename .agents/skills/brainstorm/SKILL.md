---
name: brainstorm
description: >-
  Conversational discovery skill for when the user knows roughly what they
  want but hasn't yet turned it into something `do-plan` could act on. Works
  the problem together over a dialectic cycle — propose a framing, argue the
  counter-case, ask probing questions, revise — grounded in research across
  doc/, the codebase, and the web, until a single ready-to-plan prompt falls
  out. Use whenever the user says brainstorm, /brainstorm, "let's think
  through this before we plan it", "I'm not sure what I actually want here",
  or is describing a problem/idea that's still fuzzy — open questions,
  competing options, no clear shape yet — rather than a request already
  well-formed enough to spec out directly (that case belongs to `do-plan`
  itself, not this skill). Like `do-plan`, this skill never opens a worktree;
  unlike `do-plan`, it never even writes a plan — it only writes one file
  under `.ai/plans/brainstorm/` and never touches an existing repo file.
---

# Brainstorm Skill

`do-plan` is good at turning a clear ask into a plan — including any doc
updates it calls for, captured as tasks for `do-build` to carry out. It's not
built for the step before that — when the user has a direction but not yet a
request, and getting from one to the other takes back-and-forth, not a
one-shot answer. That's this skill: sit in the fuzzy part of the problem with
the user, grounded in what actually exists, until a single well-formed prompt
falls out. Then hand that prompt to `do-plan`.

**If the request is already well-formed enough for `do-plan` to act on
directly** — a clear ask with a scope `do-plan` could start specifying right
now — say so and point at `do-plan` instead of manufacturing a dialectic for
its own sake. This skill earns its keep on the fuzzy cases; running thesis/
antithesis rounds over something that was already clear just delays the
user.

This skill never creates a worktree and never edits a file that already
exists in the repo — no `doc/`, no code, no `.ai/plans/planned/`
implementation plans. The only thing it ever writes is one new file under the
primary checkout's `.ai/plans/brainstorm/` (see Section 4 for why "primary
checkout" matters here). Everything else stays read-only, in the checkout
this session already has open.

## 1. Ground the conversation in research, not just opinion

Before proposing framings, find out what's actually true. Pull in whichever
of these are relevant to the topic — not all three on every brainstorm, just
the ones that would change what you'd say:

- **Existing docs** (`doc/**`) — same habit as `do-plan`'s "read specs
  first". Fire one direct `mcp__clarity__search` query per topic even when
  `doc/README.md`'s route map already names the file to read — a table entry
  points at one doc, not its siblings, and a single targeted query routinely
  surfaces a paired doc the table doesn't cross-link (a subsystem's
  functional doc next to its technical doc is a recurring case; do this
  before grepping by hand). Its corpus stops at `doc/**/*.md`, `*.yaml`, and
  `units|apps/**/*.pas` — it has no reach into `.ini`/YAML-manifest config,
  `docker-compose.yml`, or anything under gitignored `.ai/plans/`; once the
  question turns to what a config or script actually does today, fall
  through to direct reads instead of re-querying. If the system already
  documents an answer, the brainstorm should start from that, not
  rediscover it.
- **The codebase** — same habit as `do-plan`'s "code search second". Use the
  `ast-grep-nav` skill first for structural/shape searches (a pattern, not a
  name), `ctags-nav` / `readtags` for exact symbol-name lookups, and `rg` for
  everything else. Check what's actually implemented, since docs can lag.
- **External web research** — `WebSearch`/`WebFetch` for prior art, standards,
  or approaches outside this codebase. Reach for this when the problem space
  is unfamiliar or the user is asking "how do other systems handle this."

Do this research continuously through the conversation, not only at the
start — a good antithesis or a good probing question often sends you back to
check something you assumed.

## 2. The dialectic cycle

The goal of each round is to move the framing, not to perform a debate. Two
modes, alternating:

- **Thesis → antithesis → synthesis.** Propose a concrete framing of the
  problem, grounded in whatever research supports it (thesis). Then argue
  the counter-case yourself — what's wrong with that framing, what it
  ignores, what breaks it (antithesis). Then reconcile the two into a
  sharper version (synthesis). Put all three in front of the user in one
  turn and let them react to the synthesis, not just rubber-stamp it.
- **Socratic questioning.** Instead of proposing a position, ask the
  question that would most narrow things down — an unstated assumption, a
  constraint nobody's named yet, an edge case that would change the answer.
  Let the user's response do the narrowing.

**Round 1 is always thesis → antithesis → synthesis** — the user needs
something concrete to react to before questions about it are worth asking.
From round 2 on, alternate between the two modes. If a Socratic round
surfaces something that reopens the framing, the next thesis/antithesis
round should visibly incorporate it — the point of alternating is that each
mode corrects the blind spot of the other, so let them actually talk to each
other across rounds, not run in parallel.

Keep each round short enough that the user can respond to it — this is a
conversation, not a report. Don't collapse multiple rounds into one message
because you think you already know where it's heading; the value is in the
user pushing back on a specific claim, and they can't do that if the claim
was buried three rounds ago in a wall of text.

## 3. Convergence

Don't decide on your own that the framing is done — same principle as
`do-plan`'s approval gate: a human confirms, your own sense that it "looks
settled" isn't the check. Convergence looks like the last couple of rounds
producing small refinements instead of new directions, *and* the user saying
something to that effect ("yeah, that's it", "that's the shape of it",
"let's write that up"). Ask directly if it's unclear: "Does this feel like
the right shape to write up, or is there another angle worth pushing on?"

## 4. Write the prompt

Once converged, write **one new file** at
`.ai/plans/brainstorm/<slug>.md`, where `<slug>` is a short slug of the topic
(this repo's convention, e.g. `rate-balance-cutover`, `channel-fallback`).

`.ai/plans/` is gitignored, and `do-build` handles it by always resolving the
**primary checkout** and reading/writing plan files there — never inside a
worktree, since a worktree's `.ai/plans/` is a separate, empty, untracked
directory that vanishes when the tree is dropped. This skill never opens a
worktree itself, but if it's invoked from a session that already has one
open (mid `do-build` run), the same trap applies. So resolve the primary
checkout the same way `do-build` does before writing:

```bash
PRIMARY="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
```

and write to `$PRIMARY/.ai/plans/brainstorm/<slug>.md`, not a bare relative
path. Before writing, check whether that path already exists — if this
conversation is a continuation of an earlier brainstorm on the same topic,
keep revising that same file instead of creating a second one for the same
idea.

The file is written **for `do-plan` to read as its instructions**, so shape
it as a prompt, not as meeting notes:

- **What's being asked for** — the request in its converged form, stated
  plainly enough that `do-plan` could act on it without rejoining this
  conversation.
- **Why** — the reasoning that survived the dialectic: which alternatives
  were considered and ruled out, and on what grounds. This is what stops
  `do-plan` (or a human reviewing its output) from re-litigating a question
  this conversation already settled.
- **Grounding** — pointers to the specific `doc/`, code, or external sources
  the conversation relied on, so `do-plan` starts from the same footing
  instead of re-deriving it.
- **Open edges** — anything explicitly left unresolved and why (scope
  deliberately cut, genuinely still undecided) — distinct from things that
  were settled. `do-plan` should be able to tell the two apart at a glance.

If further discussion changes the framing after this file is written, edit
that same file in place rather than starting a new one — it's a draft under
revision, not a log of the conversation's history.

## 5. Hand off

Show the user the written prompt (or point at the file) and ask how they
want to proceed:

- Invoke the `do-plan` skill now, pointing it at the **absolute path**
  `$PRIMARY/.ai/plans/brainstorm/<slug>.md` and telling it to read that file
  as its instructions — a path handoff, not pasting the file's content into
  the invocation, since inline content risks losing something in the copy.
  Or,
- Leave it written for the user to feed into `do-plan` themselves later.

Do not auto-invoke `do-plan` without asking — the user may want to sit with
the written prompt first, same way `do-plan` itself waits for approval
before treating its plan as ready for `do-build`.

## Stop conditions

- User's answers keep reopening the framing with no sign of narrowing after
  several rounds → say so plainly rather than forcing a synthesis; ask
  whether to keep going, narrow the scope, or park it
- Research surfaces a hard constraint that invalidates the direction so far
  → raise it immediately as the next antithesis, don't wait for the next
  scheduled round
- User says to stop or move on before convergence → do not write the file;
  the brainstorm can resume later from wherever it left off
