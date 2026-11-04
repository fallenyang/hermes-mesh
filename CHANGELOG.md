# Changelog

## 1.1.0 — 2026-11-03

Hardening release. Every fix below was found in a live three-machine mesh and
each one has a regression test that fails against 1.0.2.

### Fixed — memory safety
- **Local memory could be silently deleted.** The three-way merge used the
  pre-pull `HEAD` as its merge base. As soon as a rebase had rewritten local
  history, entries that existed only on that machine looked like *remote
  deletions* and were dropped without a warning. The merge base is now the true
  `git merge-base` of local and remote, captured before any pull.
- **New `--ensure-contains` guard.** After merging, any entry present in live
  memory but missing from the merged result is restored verbatim and reported
  as `memory-drop-prevented`. A sync can no longer remove a fact the machine
  already knew.
- If the guard itself cannot run, live memory is left untouched
  (`memory-guard-failed`) instead of being overwritten from an unverified merge.

### Fixed — sync loops
- **Failed rebases looped forever.** `git rebase --abort` ran *after*
  `git reset --hard origin/BRANCH`; the abort restores the branch to its
  pre-rebase tip, which silently undid the reset. HEAD stayed on the diverged
  commit and every subsequent cycle replayed the same failing rebase. Abort now
  runs first, then the reset.
- **`sync.sh --dry-run` crashed.** The cleanup path referenced `$EXCLUDE_FILE`
  before it was assigned and `set -u` turned that into `unbound variable`, so
  the documented safe preview exited 1 whenever both skills directories
  existed.

### Fixed — scheduling
- **Silent no-op scheduler on systems without cron.** `setup.sh` installed a
  crontab as long as the `crontab` binary existed, without checking that a cron
  daemon was running. On Arch/CachyOS the job never fired and the log simply
  stopped. A crontab binary is no longer treated as proof: the installer
  detects a running daemon (`cron` / `crond` / `cronie`, or the process) and
  falls back to a **systemd user timer** (`OnUnitActiveSec`, `Persistent=true`),
  warning when lingering is disabled. Override with
  `HERMES_MESH_SCHEDULER=cron|systemd|auto`.
- `uninstall.sh` removes the systemd timer units as well.

### Fixed — installation
- **`bash setup.sh < answers` installed a different version than the one it was
  running.** Any non-TTY stdin was treated as `curl | bash` and re-cloned the
  scripts from GitHub, so automation and CI seeded worktrees from upstream
  instead of the working tree. setup.sh now prefers the scripts beside itself
  and only clones when there is no script file on disk. Pin explicitly with
  `HERMES_MESH_SOURCE_DIR`.

### Fixed — observability
- Skill drift after import is now detected and reported (`skill-drift:N`) with
  the offending paths, instead of logging `HEALTH: OK` over a diverging tree.

### Tests
- 48 → 61 assertions. New coverage for the dry-run crash, failed-rebase memory
  preservation, the merge guard, and the systemd timer fallback.
- The harness mocks `systemctl`/`loginctl`, pins `HERMES_MESH_SOURCE_DIR`, and
  isolates `HOME` and the sync lock (`HERMES_MESH_LOCK`) per test — results no
  longer depend on whether the host runs cron, and a test run can no longer
  write to the operator's real sync log or block their scheduled cycle.

## 1.0.2 — 2026-06-27

### Added
- `sync.sh --resolve-skills` flag — auto-resolves skill conflicts by keeping local versions (suppresses warnings, logs resolution count). Pair with `--force-pull` on other machines.

### Fixed
- `setup.sh` now exports actual memory content during bootstrap — if `MEMORY.md` or `USER.md` already have real data, they're copied into the worktree instead of being replaced with empty placeholders. Prevents memory loss on first sync.

## 1.0.1 — 2026-06-06

### Fixes (peer review)
- LLM fallback now writes `warn("llm-fallback")` to the health log summary instead of only stderr
- Added `-c` (checksum) to all 5 rsync calls — prevents spurious commits from timestamp-only diffs
- Added GitHub Actions CI: shellcheck + test suite on every push
- Added git version tags (v1.0.1)
- Added `curl | bash` integrity note to setup.sh

## 1.0.0 — 2026-06-06

Initial stable release.

### Features
- One-liner interactive setup (`curl | bash`)
- Coordinator + worker architecture with bare Git repo hub
- Three-way `§`-delimited memory merge with machine-tag awareness
- LLM fallback for conflicting edits on the same entry
- Skills rsync with conflict detection and non-blocking warnings
- Auto-tagging: new memory entries default to `⟨machine:NAME⟩` unless global
- `sync.sh --force-push` / `--force-pull` for one-sided conflict resolution
- `sync.sh --squash` to periodically collapse history noise
- `update.sh` with full-rebase or scripts-only modes
- `uninstall.sh` that reads from config and preserves user data
- `test.sh` — 42 tests covering setup, merge, sync, uninstall, edge cases
- macOS (launchd) and Linux (cron) scheduler support
- `§` delimiter escaping: `\§` for literal section signs in memory entries

### Fixes since pre-release
- `prompt()` helper deduplicates 9 identical prompt blocks
- `expand_path()` replaces unsafe `eval echo` tilde expansion
- `validate_interval()` rejects negative, zero, and out-of-range sync intervals
- `seed_worktree()` function extracts 50-line monolithic block
- `SCRIPT_DIR` computed at top, cloned from GitHub when piped
- TTY detection handles CI/non-interactive environments gracefully
- Uninstall derives worktree path from `config.toml` directory
- Memory merge: local deletions now propagate correctly (removed broken first-sync heuristic)
- All `read` calls use `-r` for safety, all prompts use `echo -n` + `read` instead of `read -p`
