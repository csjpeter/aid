#!/bin/bash
# Switch ~/.claude (and claude-userdata) between the sshfs mount of the home
# machine and a local copy, so Claude keeps working away from home.
#
#   claude-travel.sh status
#   claude-travel.sh go   [--dry-run] [--from-backup]   mount -> local copy
#   claude-travel.sh back [--dry-run]                   local copy -> mount
#
# `go` order (nothing depends on the network after the unmount):
#   1. claude-backup.sh backup --refresh   (mount still alive: fresh local copy)
#   2. claude-share.sh sync-json           (~/.claude.json, newer side wins)
#   3. stop and disable the mount services
#   4. copy the latest local snapshot into the now plain ~/.claude
# With --from-backup steps 1-2 are skipped: the latest existing snapshot is
# used as it is, so it works with no connection to the home machine, e.g. when
# you forgot to switch before leaving.
#
# Safety rules (the home machine may be busy with real work):
#  - the home machine is only ever READ (by the backup refresh, niced by rsync defaults)
#  - `back` never deletes anything there; files it would overwrite are kept
#    in ~/.claude/.travel-backup/<timestamp>/ on the home machine
#  - the local copy is renamed aside on `back`, never deleted
#  - both commands refuse to run while a claude process is running
#  - history.jsonl is never merged by timestamp: the local one is stored
#    next to the original as history.jsonl.travel-<timestamp>
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

HOME_HOST="${CLAUDE_HOME_HOST:-t14}"
TARGETS=(".claude" ".local/share/claude-userdata")
SERVICES=(claude-mount.service claude-userdata-mount.service)
BWLIMIT="${CLAUDE_TRAVEL_BWLIMIT:-20000}"          # KB/s
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backup/claude}"
STAMP=$(date '+%Y%m%d-%H%M%S')
DRY_RUN=false; FROM_BACKUP=false

# Not uploaded to the home machine by `back`: caches that Claude rebuilds.
GO_EXCLUDES=(--exclude=/cache --exclude=/debug --exclude=/shell-snapshots --exclude=/paste-cache --exclude=/.travel-backup)

run() {
    if [ "$DRY_RUN" = true ]; then echo "(dry-run) $*"; else "$@"; fi
}

is_mounted() { findmnt -T "$HOME/$1" -n -o FSTYPE | grep -q '^fuse.sshfs$'; }

home_reachable() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOME_HOST" true; }

refuse_if_claude_running() {
    local pids
    if pids=$(pgrep -x claude); then
        if [ "$DRY_RUN" = true ]; then
            log_warn "Claude is running (pid: $(echo "$pids" | tr '\n' ' ')): a real run would refuse."
            return 0
        fi
        log_error "Claude is running (pid: $(echo "$pids" | tr '\n' ' ')). Quit all sessions first."
        exit 1
    fi
}

cmd_status() {
    local t
    for t in "${TARGETS[@]}"; do
        if is_mounted "$t"; then echo "~/$t: MOUNTED from $HOME_HOST"
        else echo "~/$t: LOCAL ($(du -sh "$HOME/$t" | cut -f1))"; fi
    done
    local s
    for s in "${SERVICES[@]}"; do
        echo "$s: $(systemctl --user is-enabled "$s" || true) / $(systemctl --user is-active "$s" || true)"
    done
    if home_reachable; then echo "$HOME_HOST: reachable"; else echo "$HOME_HOST: NOT reachable"; fi
    ls -d "$HOME"/.claude.travel-* "$HOME"/.local/share/claude-userdata.travel-* || echo "(no aside copies)"
}

snapshot_root() {             # $1 = target path relative to $HOME
    case "$1" in
        .claude) echo "$BACKUP_ROOT" ;;
        *)       echo "${BACKUP_ROOT}-userdata" ;;
    esac
}

fill_check() {                # fail before the unmount if there is nothing to copy
    local root
    root=$(snapshot_root "$1")
    [ -n "$(ls -1r "$root/hourly" | head -1)" ] || { log_error "No snapshot in $root/hourly"; exit 1; }
}

fill_from_backup() {          # $1 = target path relative to $HOME
    local t="$1" root latest
    root=$(snapshot_root "$t")
    latest=$(ls -1r "$root/hourly" | head -1)
    [ -n "$latest" ] || { log_error "No snapshot in $root/hourly"; exit 1; }
    log_info "Using local snapshot $root/hourly/$latest"
    run rsync -a "$root/hourly/$latest/" "$HOME/$t/"
}

cmd_go() {
    local t s here
    here="$(dirname "$(readlink -f "$0")")"
    refuse_if_claude_running
    for t in "${TARGETS[@]}"; do
        is_mounted "$t" || { log_error "~/$t is not a mount: already local?"; exit 1; }
    done
    if [ "$FROM_BACKUP" = false ]; then
        home_reachable || { log_error "$HOME_HOST not reachable. Use --from-backup to use the latest local snapshot as it is."; exit 1; }
        # Any failure here aborts before the unmount: nothing has changed yet.
        run "$here/backup/claude-backup.sh" backup --refresh
        run "$here/claude-share.sh" sync-json
    else
        log_warn "--from-backup: the snapshot is not refreshed, it is as old as the last backup."
    fi
    for t in "${TARGETS[@]}"; do fill_check "$t"; done
    for s in "${SERVICES[@]}"; do run systemctl --user disable --now "$s"; done
    for t in "${TARGETS[@]}"; do
        if [ "$DRY_RUN" = false ] && is_mounted "$t"; then log_error "~/$t is still mounted"; exit 1; fi
        run mkdir -p "$HOME/$t"
        fill_from_backup "$t"
    done
    log_info "Local mode ready. Start Claude as usual."
}

cmd_back() {
    local t s
    refuse_if_claude_running
    home_reachable || { log_error "$HOME_HOST not reachable."; exit 1; }
    for t in "${TARGETS[@]}"; do
        if is_mounted "$t"; then log_error "~/$t is a mount: already in home mode?"; exit 1; fi
    done
    run "$(dirname "$(readlink -f "$0")")/claude-share.sh" sync-json
    for t in "${TARGETS[@]}"; do
        # history.jsonl: keep both sides, merge by hand if ever needed
        if [ -f "$HOME/$t/history.jsonl" ]; then
            run scp -q "$HOME/$t/history.jsonl" "$HOME_HOST:$t/history.jsonl.travel-$STAMP"
        fi
        # update only: never delete, keep what gets overwritten
        run nice -n 19 ionice -c3 rsync -au --bwlimit="$BWLIMIT" \
            --exclude=/history.jsonl "${GO_EXCLUDES[@]}" \
            --backup --backup-dir=".travel-backup/$STAMP" \
            "$HOME/$t/" "$HOME_HOST:$t/"
    done
    # Only after every upload succeeded: move the local copies aside, remount.
    for t in "${TARGETS[@]}"; do
        run mv "$HOME/$t" "$HOME/$t.travel-$STAMP"
        run mkdir -p "$HOME/$t"
    done
    for s in "${SERVICES[@]}"; do run systemctl --user enable --now "$s"; done
    log_info "Home mode restored. Local copies kept: ~/<dir>.travel-$STAMP (delete when no longer needed)."
}

ARGS=()
for a in "$@"; do
    case "$a" in
        --dry-run)     DRY_RUN=true ;;
        --from-backup) FROM_BACKUP=true ;;
        -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
        *)             ARGS+=("$a") ;;
    esac
done

case "${ARGS[0]:-help}" in
    status) cmd_status ;;
    go)     cmd_go ;;
    back)   cmd_back ;;
    help)   "$0" --help ;;
    *)      log_error "Unknown command: ${ARGS[0]}"; exit 1 ;;
esac
