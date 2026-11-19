#!/usr/bin/env bash
# Hermes Mesh v2 — single-copy git sync.
# ~/.hermes/skills and ~/.hermes/memories are git worktrees: the live files ARE
# the repo. No rsync, no force, no merge engine. A conflict stops that repo for
# this cycle and is reported; nothing is ever resolved by picking a side.
set -uo pipefail

HERMES="${HERMES_HOME:-$HOME/.hermes}"
LOG="$HERMES/logs/mesh-sync.log"
CONF="$HERMES/mesh.conf"
MACHINE="${MACHINE:-$(hostname)}"
[ -f "$CONF" ] && . "$CONF"
mkdir -p "$(dirname "$LOG")"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
HEALTH="OK"
CONFLICT_REPOS=""

commit_local() {   # repo-dir
    local d="$1"
    [ -d "$d" ] || return 0
    if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
        git -C "$d" add -A
        if git -C "$d" -c user.name="Hermes Mesh" -c user.email="mesh@localhost" \
             commit -q -m "$MACHINE: $(date '+%F %T')" 2>>"$LOG"; then
            log "$(basename "$d"): committed local changes"
        fi
    fi
}

pull_rebase() {    # repo-dir -> 0 ok, 1 conflict, 2 network/other
    local d="$1" i
    # Never start from a half-finished rebase/cherry-pick left by an earlier run.
    git -C "$d" rebase --abort 2>/dev/null || true
    git -C "$d" cherry-pick --abort 2>/dev/null || true
    for i in 1 2 3; do
        if git -C "$d" pull --rebase --autostash -q origin main 2>>"$LOG"; then
            return 0
        fi
        if git -C "$d" status --porcelain=v1 2>/dev/null | grep -qE '^(UU|AA|DD|AU|UA|DU|UD) '; then
            git -C "$d" rebase --abort 2>/dev/null
            return 1
        fi
        sleep $((i * 5))
    done
    git -C "$d" rebase --abort 2>/dev/null
    return 2
}

push_retry() {     # repo-dir -> 0 pushed, 1 failed
    local d="$1" i
    for i in 1 2 3; do
        if git -C "$d" push -q origin main 2>>"$LOG"; then return 0; fi
        git -C "$d" pull --rebase --autostash -q origin main 2>>"$LOG" || true
        sleep $((i * 5))
    done
    return 1
}

for NAME in skills memories; do
    D="$HERMES/$NAME"
    if [ ! -e "$D/.git" ]; then
        log "$NAME: not a git worktree — skipped"
        HEALTH="WARN"; continue
    fi
    commit_local "$D"
    pull_rebase "$D"; RC=$?
    case $RC in
        1) log "$NAME: CONFLICT — left for resolution, not pushed"
           HEALTH="CONFLICT"; CONFLICT_REPOS="$CONFLICT_REPOS $NAME"; continue ;;
        2) log "$NAME: pull failed after 3 attempts"
           HEALTH="WARN"; continue ;;
    esac
    if push_retry "$D"; then
        log "$NAME: pushed $(git -C "$D" rev-parse --short HEAD)"
    else
        log "$NAME: push failed after 3 attempts"
        HEALTH="WARN"
    fi
done

# Hourly heartbeat into the state repo. Each machine owns one branch and one
# file, so heartbeats can never race or conflict with each other.
STATE="$HERMES/mesh-state"
if [ -e "$STATE/.git" ] && [ "$(date +%M)" -lt 5 ]; then
    MB="state/$(hostname)"
    git -C "$STATE" rebase --abort 2>/dev/null || true
    git -C "$STATE" cherry-pick --abort 2>/dev/null || true
    HEAD_SHA=$(git -C "$HERMES/skills" rev-parse --short HEAD 2>/dev/null || echo none)
    git -C "$STATE" checkout -q -B "$MB" 2>/dev/null || true
    printf '{"machine":"%s","hostname":"%s","ts":"%s","skills":"%s","health":"%s"}\n' \
        "$MACHINE" "$(hostname)" "$(date -Iseconds)" "$HEAD_SHA" "$HEALTH" \
        >"$STATE/$(hostname).json"
    git -C "$STATE" add -A
    git -C "$STATE" -c user.name="Hermes Mesh" -c user.email="mesh@localhost" \
        commit -q -m "$MACHINE heartbeat $(date '+%F %T')" 2>/dev/null || true
    if git -C "$STATE" push -q --force origin "$MB" 2>>"$LOG"; then
        log "state: heartbeat pushed to $MB"
    else
        log "state: heartbeat push failed"
    fi
fi

log "HEALTH: ${HEALTH}${CONFLICT_REPOS:+ conflicts:$CONFLICT_REPOS}"
[ "$HEALTH" = "CONFLICT" ] && exit 1
exit 0
