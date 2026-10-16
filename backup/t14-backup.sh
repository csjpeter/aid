#!/bin/bash
# Backup of ~/ai-projects content that lives only on t14 (no GitHub remote).
#
#  - repo <path>   : bare mirror under $BACKUP_ROOT/repos/ (git objects only,
#                    never pruned, so rewritten history stays recoverable)
#  - files <path>  : rsync snapshot under $BACKUP_ROOT/files/<tier>/<label>
#                    (daily 7, weekly 4, monthly 12; hardlinked via --link-dest)
#
# The list of paths lives in a config file, not in this script.
# Config: ${T14_BACKUP_CONF:-~/.config/aid-backup/t14.conf}
#   host <ssh host>            (default: t14)
#   base <remote dir>          (default: ai-projects, relative to remote $HOME)
#   repo <path under base>
#   files <path under base>
#   # comment
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; PURPLE='\033[0;35m'; NC='\033[0m'
log_title() { echo -e "\n${PURPLE}[TITLE]${NC} $*\n"; }
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

BACKUP_ROOT="${T14_BACKUP_ROOT:-$HOME/backup/t14}"
CONF="${T14_BACKUP_CONF:-$HOME/.config/aid-backup/t14.conf}"
DAILY_KEEP=7; WEEKLY_KEEP=4; MONTHLY_KEEP=12
DRY_RUN=false

HOST="t14"; BASE="ai-projects"
REPOS=(); FILES=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] <command>

Commands:
  backup   Mirror the listed repos and snapshot the listed folders from t14
  status   Show what is backed up and how old the last runs are

Options:
  --dry-run   Show what would be done (rsync -n, no git fetch/clone)
  --help      This help

Config: $CONF
Target: $BACKUP_ROOT
EOF
}

load_conf() {
    [ -r "$CONF" ] || { log_error "Config not readable: $CONF"; exit 1; }
    local key val
    while read -r key val; do
        case "$key" in
            ''|'#'*) ;;
            host)  HOST="$val" ;;
            base)  BASE="$val" ;;
            repo)  REPOS+=("$val") ;;
            files) FILES+=("$val") ;;
            *)     log_error "Unknown config key '$key' in $CONF"; exit 1 ;;
        esac
    done < "$CONF"
}

# Keep the N newest entries of a tier directory; delete the rest.
prune_dir() {
    local dir="$1" keep="$2" entries i
    case "$dir" in "$BACKUP_ROOT"/files/*) ;; *) log_error "unsafe path: $dir"; exit 1 ;; esac
    [ -d "$dir" ] || return 0
    mapfile -t entries < <(ls -1r "$dir")
    for (( i = keep; i < ${#entries[@]}; i++ )); do
        ( cd "$dir" && rm -rf "${entries[$i]:?}" )
        log_info "Pruned: ${dir##*/}/${entries[$i]}"
    done
}

backup_repo() {
    local path="$1" name dest
    name="${path//\//__}"
    dest="$BACKUP_ROOT/repos/$name.git"
    local dirty
    dirty=$(ssh -o BatchMode=yes "$HOST" "git -C '$BASE/$path' status --porcelain | wc -l")
    [ "$dirty" -eq 0 ] || log_warn "[$path] $dirty uncommitted change(s) on $HOST: not part of the backup (git objects only)"

    if [ "$DRY_RUN" = true ]; then
        log_info "[$path] (dry-run) would mirror $HOST:$BASE/$path -> $dest"
        return 0
    fi
    mkdir -p "$BACKUP_ROOT/repos"
    if [ ! -d "$dest" ]; then
        git clone --mirror "ssh://$HOST/~/$BASE/$path" "$dest"
        git -C "$dest" config gc.auto 0
        git -C "$dest" config gc.pruneExpire never
        log_info "[$path] Cloned mirror."
    else
        git -C "$dest" fetch --no-prune --tags origin '+refs/*:refs/*'
        log_info "[$path] Mirror updated."
    fi
}

backup_files() {
    local path="$1" root="$BACKUP_ROOT/files/${1//\//__}"
    local day week month latest link=()
    day=$(date '+%Y-%m-%d'); week=$(date '+%Y-W%V'); month=$(date '+%Y-%m')

    if [ "$DRY_RUN" = true ]; then
        rsync -a -n --stats "$HOST:$BASE/$path/" "$root/daily/$day/" | grep -E "Number of (regular )?files|Total transferred"
        return 0
    fi
    mkdir -p "$root/daily" "$root/weekly" "$root/monthly"
    if [ -d "$root/daily/$day" ]; then
        log_info "[$path] Daily snapshot already exists: $day (refreshing)"
    else
        latest=$(ls -1r "$root/daily" | head -1)
        [ -n "$latest" ] && link=(--link-dest="$root/daily/$latest")
    fi
    rsync -a --delete "${link[@]}" "$HOST:$BASE/$path/" "$root/daily/$day/"
    log_info "[$path] Daily snapshot: $day"
    [ -d "$root/weekly/$week" ]   || { cp -al "$root/daily/$day" "$root/weekly/$week";   log_info "[$path] Promoted to weekly:  $week"; }
    [ -d "$root/monthly/$month" ] || { cp -al "$root/daily/$day" "$root/monthly/$month"; log_info "[$path] Promoted to monthly: $month"; }
    prune_dir "$root/daily"   "$DAILY_KEEP"
    prune_dir "$root/weekly"  "$WEEKLY_KEEP"
    prune_dir "$root/monthly" "$MONTHLY_KEEP"
}

cmd_backup() {
    load_conf
    log_title "t14 backup ($HOST:$BASE -> $BACKUP_ROOT)"
    local failed=0 p
    for p in "${REPOS[@]}"; do backup_repo "$p" || { log_error "[$p] failed"; failed=$((failed + 1)); }; done
    for p in "${FILES[@]}"; do backup_files "$p" || { log_error "[$p] failed"; failed=$((failed + 1)); }; done
    log_info "Done. Failed: $failed"
    return "$failed"
}

cmd_status() {
    load_conf
    log_title "t14 backup status ($BACKUP_ROOT)"
    local p name latest
    for p in "${REPOS[@]}"; do
        name="${p//\//__}"
        if [ -d "$BACKUP_ROOT/repos/$name.git" ]; then
            echo "repo  $p: $(git -C "$BACKUP_ROOT/repos/$name.git" log -1 --format='%h %cd' --date=short --all)  $(du -sh "$BACKUP_ROOT/repos/$name.git" | cut -f1)"
        else
            echo "repo  $p: MISSING"
        fi
    done
    for p in "${FILES[@]}"; do
        name="${p//\//__}"
        latest=$(ls -1r "$BACKUP_ROOT/files/$name/daily" | head -1) || latest=""
        echo "files $p: ${latest:-MISSING}"
    done
}

ARGS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) usage; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done
case "${ARGS[0]:-help}" in
    backup) cmd_backup ;;
    status) cmd_status ;;
    help)   usage ;;
    *)      log_error "Unknown command: ${ARGS[0]}"; usage >&2; exit 1 ;;
esac
