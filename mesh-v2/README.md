# mesh-v2 — design notes and migration detail

Install steps live in the [root README](../README.md). This file holds the parts
worth keeping: why the 1.x engine failed, what the migration actually does, how to
verify it, and how to get out.

## Why the 1.x engine failed

Both defects come from the same root cause: **every machine kept two copies of the
same state** (the live tree Hermes reads, and a git worktree) and mirrored them
with `rsync --delete`, local wins.

**Skills.** `sync.sh` exported live → worktree (no `--delete`), then imported
worktree → live (`--delete`), then committed whatever the export produced. A
machine whose live tree was older than the hub therefore wrote the older tree into
the worktree and committed it. Nothing flagged it as a conflict, because the
detector built its "what changed remotely" list from `OLD_HEAD..POST_PULL` — only
the current cycle. A worker that had already fast-forwarded, or pulled a large
batch at once, saw an empty deletion window, and the deletions propagated as edits.
Measured cost in one afternoon: 584 lines, then 722 lines, from two different
workers.

**Memory.** `memory-merge.py` keyed entries by `(machine tag, normalized body)`.
A patch to an entry is therefore a delete of one key plus an add of another, and
the `--ensure-contains` guard (added to stop the merge dropping entries) re-added
the superseded text verbatim. Thirteen consolidated entries re-inflated to
thirty-eight (8.2 kB) against a 2,200-character limit within one cycle, and the
run still reported `HEALTH: OK`.

Adding more guards to a mirror cannot fix a mirror. 2.x deletes it.

## What the migration does

Per machine, in place, with no copying of content:

```bash
tar czf ~/pre-mesh-v2-$(date +%F).tar.gz -C ~/.hermes skills memories
git init --separate-git-dir ~/.hermes/git/skills.git -b main -- ~/.hermes/skills
git init --separate-git-dir ~/.hermes/git/memory.git -b main -- ~/.hermes/memories
```

`--separate-git-dir` leaves a small `.git` **file** in the live directory instead of
a `.git` directory. Hermes and the skill curator tolerate that — verified by
enumerating every skill (`skills_list`) after conversion, and by a full agent turn.

`.gitignore` in the skills repo, so per-machine counters stop being commits:

```
.usage.json
.curator_state
.curator_ledger.jsonl
.bundled_manifest
.hub/
.locks/
*.lock
```

And in the memory repo: `*.lock`.

## Verifying a migration

```bash
git -C ~/.hermes/skills   rev-parse --short HEAD   # same sha on every worker
git -C ~/.hermes/memories rev-parse --short HEAD
md5sum ~/.hermes/memories/MEMORY.md                # identical on every worker
~/.hermes/bin/mesh-sync.sh && tail -3 ~/.hermes/logs/mesh-sync.log
```

Then a round trip, which is the only test that proves both directions:

```bash
echo probe > ~/.hermes/memories/ROUNDTRIP.md
~/.hermes/bin/mesh-sync.sh                      # on machine A
ssh B '~/.hermes/bin/mesh-sync.sh'; ssh B 'md5sum ~/.hermes/memories/ROUNDTRIP.md'
ssh B 'rm ~/.hermes/memories/ROUNDTRIP.md; ~/.hermes/bin/mesh-sync.sh'
~/.hermes/bin/mesh-sync.sh                      # deletion must propagate to A
```

## Operational notes

- **Bare repos need `HEAD -> refs/heads/main`.** Otherwise `git clone` checks out
  nothing and the only signal is `warning: remote HEAD refers to nonexistent ref`;
  the live tree ends up empty and the failure looks like a broken agent.
- **Do not share one heartbeat branch across machines.** A single `main` in the
  state repo makes every worker race; the losers end up detached or wedged in
  `CHERRY_PICK_HEAD`. One branch per machine, force-pushed, cannot conflict.
- **`~/.hermes/state` is Hermes's own runtime directory** (gateway heartbeats).
  Mesh state belongs in `~/.hermes/mesh-state`.
- **Restart the gateway after editing `MEMORY.md` by hand.** A running gateway
  holds memory in memory and will re-materialise its copy over the file on the next
  memory write; the file looks like it "re-inflated by itself".
- **Never carry secrets in the synced files.** A memory repo's history is permanent
  and replicated to every worker; scrub the history, do not just delete the line.

## Rollback

The tarball from the migration restores the previous layout, and the 1.x hub keeps
the full history. Nothing in 2.x is destructive, so rollback is unlinking the cron
line and unpacking a tarball.
