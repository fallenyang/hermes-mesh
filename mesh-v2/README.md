# Mesh v2 — one copy, git only

The 1.x design keeps **two copies of every file** — the live tree Hermes reads
(`$HERMES_HOME/skills`, `$HERMES_HOME/memories`) and a git worktree — and mirrors
them with `rsync --delete`, local wins.

That architecture loses data. Any worker whose live tree is older than the hub
pushes the older tree over it, and the conflict detector cannot see it: it only
examines what moved *in the current cycle*, so a machine that fast-forwarded in an
earlier run, or pulled a large batch at once, sees an empty deletion window and
propagates the deletions as if they were edits. In the field this cost 584 lines
of skills on one machine and 722 on another within one afternoon, from two
different workers. The memory merge has a matching failure: entries are keyed by
content, so a patch is read as delete+add, and the "never drop an entry" guard
re-adds the superseded text — a 13-entry memory re-inflated to 38 entries / 8.2 kB
(3.7x the 2,200-char limit) within one cycle.

v2 removes the second copy instead of trying to reconcile it.

## Layout

Each repo's **worktree is the live directory**:

```
$HERMES_HOME/skills      git worktree -> hermes-skills.git
$HERMES_HOME/memories    git worktree -> hermes-memory.git
$HERMES_HOME/mesh-state  git worktree -> hermes-state.git   (heartbeats)
$HERMES_HOME/git/        separate git dirs (keeps .git out of the skills tree)
$HERMES_HOME/bin/mesh-sync.sh
$HERMES_HOME/mesh.conf   MACHINE="<name>"
```

`git init --separate-git-dir` converts an existing live directory in place, so no
copying of content is required and nothing has to be reconciled. Hermes and the
curator tolerate the `.git` *file* this leaves in the skills tree — verified by
enumerating every skill after conversion.

## What the sync does

Per repo: commit local changes, `pull --rebase --autostash`, push. Three attempts
each with backoff.

- No `rsync`, no `--force-pull`, `--force-push`, `--squash`, `--resolve-skills`.
- No LLM in the loop; `memory-merge.py` is not used.
- A rebase conflict aborts, logs `CONFLICT`, and leaves that repo unpushed. It
  never picks a side.
- Deletions are commits, so they propagate like any other change.
- Per-machine bookkeeping (`skills/.usage.json`, `.curator_state`,
  `.curator_ledger.jsonl`, `.bundled_manifest`, `.hub/`, `.locks/`, `*.lock`) is
  gitignored. It used to be tracked and committed every cycle on every machine.

## Memory model

One shared `MEMORY.md` / `USER.md`, identical bytes on every worker, no
`⟨machine:⟩` filtering. Hermes caps them at 2,200 / 1,375 chars, so they hold the
top facts only; deep detail belongs in skills, which sync the same way and have no
cap. Secrets never belong in either file.

## Heartbeats

`hermes-state.git` holds one branch per machine (`state/<hostname>`) force-pushed
at most hourly, so heartbeats cannot race or conflict. A machine whose branch is
more than ~2 hours old is not syncing.

## Install on a worker

```bash
# 1. back up, then convert the live dirs in place
tar czf ~/pre-v2-$(date +%F).tar.gz -C ~/.hermes skills memories
git init -q --separate-git-dir ~/.hermes/git/skills.git -b main -- ~/.hermes/skills
git init -q --separate-git-dir ~/.hermes/git/memory.git -b main -- ~/.hermes/memories
# 2. add .gitignore (see the list above), commit, add origin, push
# 3. install mesh-sync.sh + mesh.conf, one cron line
```

A bare repo must have `HEAD -> refs/heads/main`, or `git clone` produces an empty
worktree with only `warning: remote HEAD refers to nonexistent ref`.

```
*/15 * * * * ~/.hermes/bin/mesh-sync.sh >/dev/null 2>&1
```

## Rollback

The tarball from step 1 restores the old layout, and the 1.x hub keeps the full
history. Nothing in this design is destructive.
