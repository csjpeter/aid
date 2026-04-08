#!/bin/bash
# Tiered backup of ~/.claude and ~/.local/share/claude-userdata.
# Retention: hourly (24 h), daily (7 d), weekly (4 w), monthly (12 m).
# Uses rsync --link-dest for space-efficient snapshots.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; PURPLE='\033[0;35m'; NC='\033[0m'
log_title() { echo -e "\n${PURPLE}[TITLE]${NC} $*\n"; }
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Defaults ───────────────────────────────────────────────────────────────────

# Each entry: source_dir:backup_root
BACKUP_TARGETS=(
    "$HOME/.claude:${BACKUP_ROOT:-$HOME/backup/claude}"
    "$HOME/.local/share/claude-userdata:${BACKUP_ROOT_USERDATA:-$HOME/backup/claude-userdata}"
)

HOURLY_KEEP=24
DAILY_KEEP=7
WEEKLY_KEEP=4
MONTHLY_KEEP=12

# ── Help ───────────────────────────────────────────────────────────────────────

print_help_main() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Tiered backup of ~/.claude and ~/.local/share/claude-userdata.
Retention: every hour for 24 h, every day for 7 d,
           every week for 4 w, every month for 12 m.

Commands:
  backup         Create a new backup snapshot and prune old ones
  restore        Restore a backup to ~/.claude (interactive or by name)
  setup-cron     Add an hourly cron job to run 'backup' automatically
  remove-cron    Remove the hourly cron job
  status         Show available backups and disk usage
  help [cmd]     Show this help, or detailed help for a command (default)

Use '$(basename "$0") <command> --help' for the same per-command help.

EOF
}

print_help_backup() {
    cat <<EOF
Usage: $(basename "$0") backup

Create new backup snapshots of ~/.claude and ~/.local/share/claude-userdata.

Backup locations:
  ~/backup/claude/           for ~/.claude
  ~/backup/claude-userdata/  for ~/.local/share/claude-userdata

Tiers (per backup target):
  hourly/    One snapshot per clock-hour, keep 24 (covers 24 h)
  daily/     One snapshot per calendar day, keep 7 (covers 1 week)
  weekly/    One snapshot per ISO week, keep 4 (covers ~1 month)
  monthly/   One snapshot per month, keep 12 (covers 1 year)

Snapshots use rsync --link-dest so only changed files consume new space.
Daily/weekly/monthly backups are hard-linked copies of the hourly snapshot
and require no extra I/O.

Environment:
  BACKUP_ROOT            Override backup root for ~/.claude (default: ~/backup/claude)
  BACKUP_ROOT_USERDATA   Override backup root for claude-userdata (default: ~/backup/claude-userdata)

EOF
}

print_help_restore() {
    cat <<EOF
Usage: $(basename "$0") restore [SNAPSHOT]

Restore a backup snapshot to its original location.

  SNAPSHOT   Tier-qualified name, e.g. hourly/2026-03-23_1400
             If omitted, an interactive list of all targets is shown.

The current directory is renamed to <dir>.bak before restoring.
An existing ~/.claude.bak is removed first.

EOF
}

print_help_setup_cron() {
    cat <<EOF
Usage: $(basename "$0") setup-cron

Add an hourly cron entry that runs '$(basename "$0") backup'.
The entry is added to the current user's crontab.

Cron schedule: 0 * * * *  (top of every hour)

Safe to run multiple times — will not add a duplicate entry.

EOF
}

print_help_remove_cron() {
    cat <<EOF
Usage: $(basename "$0") remove-cron

Remove the hourly cron entry added by setup-cron.
Only removes lines matching this script's backup job.

EOF
}

print_help_status() {
    cat <<EOF
Usage: $(basename "$0") status

Show available backup snapshots and disk usage for each tier.
Also reports whether the cron job is active.

EOF
}

# ── Helpers ────────────────────────────────────────────────────────────────────

# Prune a backup tier directory, keeping the N most recent entries.
prune_dir() {
    local dir="$1"
    local keep="$2"
    [ -d "$dir" ] || return 0
    local entries
    mapfile -t entries < <(ls -1t "$dir" 2>/dev/null)
    local count="${#entries[@]}"
    if (( count > keep )); then
        local i
        for (( i = keep; i < count; i++ )); do
            rm -rf "${dir:?}/${entries[$i]}"
            log_info "Pruned: ${dir##*/}/${entries[$i]}"
        done
    fi
}

# Resolve the absolute path of this script (for cron entry).
script_path() {
    readlink -f "$0"
}

# ── Commands ───────────────────────────────────────────────────────────────────

backup_one_target() {
    local source_dir="$1" backup_root="$2"
    local short_name="${source_dir#"$HOME"/}"

    if [ ! -d "$source_dir" ]; then
        log_warn "Source directory not found: $source_dir — skipping."
        return 0
    fi

    local HOURLY_DIR="$backup_root/hourly"
    local DAILY_DIR="$backup_root/daily"
    local WEEKLY_DIR="$backup_root/weekly"
    local MONTHLY_DIR="$backup_root/monthly"

    mkdir -p "$HOURLY_DIR" "$DAILY_DIR" "$WEEKLY_DIR" "$MONTHLY_DIR"

    local hour_label day_label week_label month_label
    hour_label=$(date '+%Y-%m-%d_%H00')
    day_label=$(date '+%Y-%m-%d')
    week_label=$(date '+%Y-W%V')
    month_label=$(date '+%Y-%m')

    # ── Hourly snapshot ──────────────────────────────────────────────────────

    local hourly_dest="$HOURLY_DIR/$hour_label"
    if [ -d "$hourly_dest" ]; then
        log_info "[$short_name] Hourly snapshot already exists: $hour_label"
    else
        local link_dest_arg=""
        local latest
        latest=$(ls -1t "$HOURLY_DIR" 2>/dev/null | head -1)
        [ -n "$latest" ] && link_dest_arg="--link-dest=$HOURLY_DIR/$latest"

        # shellcheck disable=SC2086
        rsync -a --delete $link_dest_arg "$source_dir/" "$hourly_dest/"
        log_info "[$short_name] Created hourly backup: $hour_label"
    fi

    # ── Promote to daily ─────────────────────────────────────────────────────

    local daily_dest="$DAILY_DIR/$day_label"
    if [ ! -d "$daily_dest" ]; then
        cp -al "$hourly_dest" "$daily_dest"
        log_info "[$short_name] Promoted to daily:   $day_label"
    fi

    # ── Promote to weekly ────────────────────────────────────────────────────

    local weekly_dest="$WEEKLY_DIR/$week_label"
    if [ ! -d "$weekly_dest" ]; then
        cp -al "$hourly_dest" "$weekly_dest"
        log_info "[$short_name] Promoted to weekly:  $week_label"
    fi

    # ── Promote to monthly ───────────────────────────────────────────────────

    local monthly_dest="$MONTHLY_DIR/$month_label"
    if [ ! -d "$monthly_dest" ]; then
        cp -al "$hourly_dest" "$monthly_dest"
        log_info "[$short_name] Promoted to monthly: $month_label"
    fi

    # ── Prune ────────────────────────────────────────────────────────────────

    prune_dir "$HOURLY_DIR"  "$HOURLY_KEEP"
    prune_dir "$DAILY_DIR"   "$DAILY_KEEP"
    prune_dir "$WEEKLY_DIR"  "$WEEKLY_KEEP"
    prune_dir "$MONTHLY_DIR" "$MONTHLY_KEEP"
}

cmd_backup() {
    for target in "${BACKUP_TARGETS[@]}"; do
        local source_dir="${target%%:*}" backup_root="${target#*:}"
        backup_one_target "$source_dir" "$backup_root"
    done
    log_info "Backup complete."
}

cmd_restore() {
    local snapshot="${POSITIONAL[1]:-}"

    # Build list of all snapshots across all targets
    declare -a all_snapshots=()
    declare -a all_source_dirs=()
    declare -a all_backup_roots=()

    if [ -z "$snapshot" ]; then
        echo "Available backups:"
        echo ""
        local i=1
        for target in "${BACKUP_TARGETS[@]}"; do
            local source_dir="${target%%:*}" backup_root="${target#*:}"
            local short_name="${source_dir#"$HOME"/}"
            echo "  ── ~/$short_name ──"
            for tier in hourly daily weekly monthly; do
                local dir="$backup_root/$tier"
                [ -d "$dir" ] || continue
                while IFS= read -r name; do
                    all_snapshots+=("$tier/$name")
                    all_source_dirs+=("$source_dir")
                    all_backup_roots+=("$backup_root")
                    printf "  %3d)  %s/%s\n" "$i" "$tier" "$name"
                    (( i++ ))
                done < <(ls -1t "$dir" 2>/dev/null)
            done
            echo ""
        done

        if [ "${#all_snapshots[@]}" -eq 0 ]; then
            log_error "No backups found."
            exit 1
        fi

        printf "Enter number (1-%d) or q to quit: " "${#all_snapshots[@]}"
        read -r choice
        [[ "$choice" == "q" || "$choice" == "Q" ]] && exit 0

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#all_snapshots[@]} )); then
            log_error "Invalid selection: $choice"
            exit 1
        fi
        local idx=$((choice - 1))
        snapshot="${all_snapshots[$idx]}"
        local restore_source="${all_source_dirs[$idx]}"
        local restore_root="${all_backup_roots[$idx]}"
    else
        # Explicit snapshot given — try to find which target it belongs to
        local restore_source="" restore_root=""
        for target in "${BACKUP_TARGETS[@]}"; do
            local source_dir="${target%%:*}" backup_root="${target#*:}"
            if [ -d "$backup_root/$snapshot" ]; then
                restore_source="$source_dir"
                restore_root="$backup_root"
                break
            fi
        done
        if [ -z "$restore_source" ]; then
            log_error "Snapshot not found: $snapshot"
            exit 1
        fi
    fi

    local src="$restore_root/$snapshot"
    local short_name="${restore_source#"$HOME"/}"

    log_info "Restoring: $snapshot → ~/$short_name"
    if [ -d "$restore_source.bak" ]; then
        rm -rf "$restore_source.bak"
        log_info "Removed old ${restore_source}.bak"
    fi
    if [ -d "$restore_source" ]; then
        mv "$restore_source" "$restore_source.bak"
        log_info "Current ~/$short_name renamed to ~/${short_name}.bak"
    fi
    mkdir -p "$restore_source"
    rsync -a "$src/" "$restore_source/"
    log_info "Restore complete."
}

cmd_setup_cron() {
    local script
    script=$(script_path)
    local cron_entry="0 * * * * $script backup"
    local cron_marker="claude-backup"

    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)

    if echo "$current_crontab" | grep -qF "$script backup"; then
        log_info "Cron job already present — no change needed."
        return 0
    fi

    (
        echo "$current_crontab"
        echo "# $cron_marker — added by $(basename "$0") setup-cron"
        echo "$cron_entry"
    ) | crontab -

    log_info "Cron job added: $cron_entry"
}

cmd_remove_cron() {
    local script
    script=$(script_path)

    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)

    if ! echo "$current_crontab" | grep -qF "$script backup"; then
        log_info "No matching cron entry found — nothing to remove."
        return 0
    fi

    echo "$current_crontab" \
        | grep -vF "$script backup" \
        | grep -v "# claude-backup" \
        | crontab -

    log_info "Cron job removed."
}

cmd_status() {
    echo ""
    local script
    script=$(script_path)

    # Cron status
    if crontab -l 2>/dev/null | grep -qF "$script backup"; then
        log_info "Cron job: active (hourly)"
    else
        log_warn "Cron job: not configured (run setup-cron to enable)"
    fi
    echo ""

    for target in "${BACKUP_TARGETS[@]}"; do
        local source_dir="${target%%:*}" backup_root="${target#*:}"
        local short_name="${source_dir#"$HOME"/}"
        echo "  ── ~/$short_name → $backup_root ──"

        # Per-tier summary
        for tier in hourly daily weekly monthly; do
            local dir="$backup_root/$tier"
            if [ ! -d "$dir" ]; then
                log_info "  $tier:   (no backups yet)"
                continue
            fi
            local count
            count=$(ls -1 "$dir" 2>/dev/null | wc -l)
            local oldest newest size
            oldest=$(ls -1t "$dir" 2>/dev/null | tail -1)
            newest=$(ls -1t "$dir" 2>/dev/null | head -1)
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            printf "${GREEN}[INFO]${NC}  %-8s  %2d snapshot(s)   newest: %-20s  oldest: %-20s  size: %s\n" \
                "$tier" "$count" "${newest:-(none)}" "${oldest:-(none)}" "$size"
        done

        echo ""
        if [ -d "$backup_root" ]; then
            local total_size
            total_size=$(du -sh "$backup_root" 2>/dev/null | cut -f1)
            log_info "Size: $total_size  ($backup_root)"
        else
            log_warn "Backup root does not exist yet: $backup_root"
        fi
        echo ""
    done
}

# ── Option parsing ─────────────────────────────────────────────────────────────

SHOW_HELP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) SHOW_HELP=true ;;
        -*)
            log_error "Unknown option: $1"
            print_help_main >&2
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

# ── Command dispatch ───────────────────────────────────────────────────────────

COMMAND="${POSITIONAL[0]:-help}"
COMMAND_EXPLICIT="${POSITIONAL[0]:+true}"
COMMAND_EXPLICIT="${COMMAND_EXPLICIT:-false}"

if [ "$SHOW_HELP" = "true" ]; then
    case "$COMMAND_EXPLICIT-$COMMAND" in
        true-backup)      print_help_backup ;;
        true-restore)     print_help_restore ;;
        true-setup-cron)  print_help_setup_cron ;;
        true-remove-cron) print_help_remove_cron ;;
        true-status)      print_help_status ;;
        *)                print_help_main ;;
    esac
    exit 0
fi

case "$COMMAND" in
    help)
        case "${POSITIONAL[1]:-}" in
            backup)      print_help_backup ;;
            restore)     print_help_restore ;;
            setup-cron)  print_help_setup_cron ;;
            remove-cron) print_help_remove_cron ;;
            status)      print_help_status ;;
            *)           print_help_main ;;
        esac
        ;;
    backup)      cmd_backup ;;
    restore)     cmd_restore ;;
    setup-cron)  cmd_setup_cron ;;
    remove-cron) cmd_remove_cron ;;
    status)      cmd_status ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_help_main >&2
        exit 1
        ;;
esac
