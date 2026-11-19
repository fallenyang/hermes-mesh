# 🕸️ Hermes Mesh

> *Your Hermes agents, one shared brain.*

![Version](https://img.shields.io/badge/version-2.0.0-blue)

Hermes Mesh keeps the skills and the durable memory of every [Hermes
Agent](https://github.com/NousResearch/hermes-agent) you run in sync — the laptop,
the desktop, the VPS, the scraper box — so the agent you are talking to knows what
the others learned.

> **This fork runs 2.0.0**, a rewrite of the sync engine in
> [B1Z0N/hermes-mesh](https://github.com/B1Z0N/hermes-mesh) 1.x. The 1.x scripts
> (`sync.sh`, `memory-merge.py`, `setup.sh`, `test.sh`) are still in the tree and
> still work, but they are not the supported path and nothing in the 2.x loop calls
> them. See [Differences from 1.x](#-differences-from-1x).

---

## ⚠️ Why 2.0 exists

1.x keeps **two copies of every file** — the live tree Hermes reads, and a git
worktree — and mirrors them with `rsync --delete`, local wins.

That architecture loses data. A machine whose live tree is older than the hub
pushes the older tree over it, and the conflict detector cannot see it: it only
examines what moved *in the current cycle*, so a worker that fast-forwarded in an
earlier run, or pulled a large batch at once, sees an empty deletion window and
propagates deletions as if they were edits. In one afternoon this removed 584
lines of skills from one hub and 722 from it again, from two different workers.

The memory merge has the same shape. Entries are keyed by content, so a *patch* to
an entry reads as delete + add, and the "never drop an entry" guard re-adds the
superseded text. A 13-entry memory re-inflated to 38 entries / 8.2 kB against a
2,200-character limit inside a single cycle, and the guard reported it as a
healthy sync.

2.0 removes the second copy instead of trying to reconcile it.

---

## 🧠 How it works

Each repo's **worktree *is* the live directory**. There is nothing to mirror:

```
   git remote (bare repos on any host you like)
        │
        ├── hermes-skills.git ──►  $HERMES_HOME/skills      (worktree = live dir)
        ├── hermes-memory.git ──►  $HERMES_HOME/memories    (worktree = live dir)
        └── hermes-state.git  ──►  $HERMES_HOME/mesh-state  (heartbeats)

   every machine runs the same loop, every 15 minutes:
        commit local changes → pull --rebase --autostash → push
```

- **One copy.** A delete is a commit, never a side effect of someone's stale tree.
- **Conflicts are surfaced, not resolved.** A rebase conflict aborts, logs
  `CONFLICT`, and leaves that repo unpushed for the agent or the human to fix. No
  path ever picks a side, and no path ever uses `--force`.
- **No LLM in the loop.** Sync costs nothing and cannot be broken by a model being
  unavailable.
- **Live directories are converted in place** with `git init --separate-git-dir`,
  so migrating an existing machine needs no copying and nothing has to be reconciled.

---

## ✨ What syncs

| Syncs | Stays local |
|---|---|
| `skills/` — the whole agent skill tree | `.env`, `auth.json` |
| `MEMORY.md` / `USER.md` — durable memory and user profile | `state.db`, `sessions/` |
| Heartbeats (`mesh-state`, one branch per machine) | `logs/`, `cron/` |
| | Secrets, OAuth tokens, API keys |

Every worker sees **the same memory** — 2.x has no per-machine filtering.

---

## 🚀 Install

There is **no installer for 2.x yet**: `setup.sh` still installs the 1.x
architecture, so do not run it against a 2.x fleet. Installing a worker is five
steps.

```bash
# 0. back up what you have
tar czf ~/pre-mesh-v2-$(date +%F).tar.gz -C ~/.hermes skills memories

# 1. convert the live dirs into worktrees, in place
mkdir -p ~/.hermes/git
git init -q --separate-git-dir ~/.hermes/git/skills.git -b main -- ~/.hermes/skills
git init -q --separate-git-dir ~/.hermes/git/memory.git -b main -- ~/.hermes/memories

# 2. ignore per-machine bookkeeping, commit, attach the remote, push
cd ~/.hermes/skills
printf '%s\n' .usage.json .curator_state .curator_ledger.jsonl \
  .bundled_manifest .hub/ .locks/ '*.lock' > .gitignore
git add -A && git commit -m "initial skills tree"
git remote add origin <user>@<hub>:/path/to/hermes-skills.git
git push -u origin main

# 3. same for ~/.hermes/memories (ignore *.lock), then clone the state repo
git clone <user>@<hub>:/path/to/hermes-state.git ~/.hermes/mesh-state

# 4. install the loop
install -Dm755 mesh-v2/mesh-sync.sh ~/.hermes/bin/mesh-sync.sh
printf 'MACHINE="%s"\n' "$(hostname)" > ~/.hermes/mesh.conf

# 5. schedule it
( crontab -l 2>/dev/null; \
  echo '*/15 * * * * ~/.hermes/bin/mesh-sync.sh >/dev/null 2>&1' ) | crontab -
```

A bare repo must have `HEAD -> refs/heads/main`
(`git --git-dir=<bare> symbolic-ref HEAD refs/heads/main`), otherwise `git clone`
produces an empty worktree and only the `remote HEAD refers to nonexistent ref`
warning says so.

`mesh-sync.sh` reads `MACHINE` from `~/.hermes/mesh.conf`; everything else comes
from each worktree's own remote.

---

## 💾 Memory model

`MEMORY.md` and `USER.md` are one shared file, identical on every worker. Hermes
caps them at **2,200** and **1,375** characters, so they hold top facts only —
depth belongs in skills, which sync the same way and have no cap. Secrets belong in
neither; they live in the Hermes env file.

---

## 🩺 Liveness

`mesh-state` holds one branch per machine (`state/<hostname>`), force-pushed at most
hourly, so heartbeats can never race or conflict with each other:

```bash
git -C ~/.hermes/mesh-state fetch -q origin
git -C ~/.hermes/mesh-state for-each-ref \
  --format='%(refname:short) %(committerdate:relative)' refs/remotes/origin/state/
```

A branch older than a couple of hours means that machine is not syncing. Under 1.x
this failure ran silently for two weeks on a live machine, which is why heartbeats
exist.

---

## 🔧 Differences from 1.x

| | 1.x | 2.x |
|---|---|---|
| Live files | duplicated, mirrored with `rsync --delete` | are the git worktrees |
| Deletions | propagate from stale trees | are explicit commits |
| Conflicts | local wins; LLM merges memory | abort + report, resolved by hand |
| Force modes | `--force-pull`, `--force-push`, `--squash`, `--resolve-skills` | none |
| Memory merge | `memory-merge.py`, content-keyed, one LLM call per conflict | git's own 3-way merge |
| Machine tags | `⟨machine:X⟩` filtering per host | removed — one shared memory |
| Bookkeeping | tracked, committed every cycle on every machine | gitignored |
| `rsync` | required | **not used** (closes upstream issue #1) |
| Liveness | a log line nobody reads | per-machine heartbeat branches |

---

## 📦 Requirements

- `git`, and SSH access to the hub from every worker (one key per machine).
- Any cron — cronie, cron, or a systemd timer; the loop is a single script.
- No `rsync`, no Python dependency, no LLM calls.

---

## 🔄 Updating and uninstalling

- **Update:** `mesh-sync.sh` is one file — copy a new one over
  `~/.hermes/bin/mesh-sync.sh`. Skills and memory update themselves.
- **Uninstall:** remove the crontab line; to get the old layout back, restore the
  step-0 tarball. Nothing in 2.x deletes anything.

---

## 🧪 Known gaps

- No 2.x installer; install is the manual sequence above.
- `test.sh` and `tests/` cover the 1.x pipeline only.
- Conflicts are manual by design — that is the trade for never losing data.

---

## 🔒 Security note

Memory is shared with **every** machine in the fleet, and its git history is
permanent. Never put API keys, passwords or tokens in `MEMORY.md`, `USER.md` or a
skill: key them in the Hermes env file. If one lands in a synced file, scrub it from
history rather than only deleting the line.

---

## 📄 Licence and credit

MIT © 2026 [B1Z0N](https://github.com/B1Z0N). This fork keeps the original licence
and the full 1.x history; 2.0 is a rewrite of the sync engine, not a different
project.
