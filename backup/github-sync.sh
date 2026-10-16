#!/usr/bin/env bash
# GitHub repók biztonságos szinkronizálása
#
# Garanciák:
#  - Soha nem töröl helyi branchet, taget vagy commit objektumot
#  - Ha a remote-on commitok eltűnnek (force push), biztonsági tag menti az elveszett állást
#  - Csak fast-forward merge történik; eltérő history esetén a helyi branch érintetlen marad
#  - --no-prune: törölt remote branchek helyi nyomkövetője megmarad
#
# Használat:
#   ./github-sync.sh [--dir <könyvtár>] [--user <github_felhasználó>] [--org <org>] [--help]
#
# Környezeti változók (opcionális):
#   GITHUB_REPOS_DIR  – célkönyvtár (alap: ~/backup/github)
#   GITHUB_SYNC_USER  – GitHub felhasználónév (alap: bejelentkezett gh user)

set -euo pipefail

# --- Alapértékek ---
REPOS_DIR="${GITHUB_REPOS_DIR:-$HOME/backup/github}"
GH_TARGET=""   # üres = saját repók, egyébként org neve
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE=""    # beállítása a mkdir után

# --- Argumentum feldolgozás ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)   REPOS_DIR="$2"; shift 2 ;;
        --user)  GH_TARGET="$2"; shift 2 ;;
        --org)   GH_TARGET="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Ismeretlen opció: $1" >&2; exit 1 ;;
    esac
done

# --- Segédfüggvények ---
log() {
    local msg="[$TIMESTAMP] $*"
    printf '%s\n' "$msg" | tee -a "$LOG_FILE"
}

warn() {
    log "FIGYELEM: $*"
}

err() {
    log "HIBA: $*"
}

# Visszatérési érték: 0 = ok, 1 = hiba (hogy a számlálók rendben legyenek)
# $1 = owner/repo  $2 = opcionális célkönyvtár (alap: $REPOS_DIR/<repo>)
sync_repo() {
    local full_name="$1"
    local repo_name="${full_name##*/}"
    local repo_dir="${2:-$REPOS_DIR/$repo_name}"

    echo ""
    echo "--- $full_name ---"

    # Ha a könyvtár létezik de nem git repo, kihagyjuk
    if [[ -d "$repo_dir" ]] && [[ ! -d "$repo_dir/.git" ]]; then
        err "[$repo_name] Könyvtár létezik de nem git repo: $repo_dir – kihagyva."
        return 1
    fi

    # ── 1. Klónozás ha még nincs ──────────────────────────────────────────────
    if [[ ! -d "$repo_dir/.git" ]]; then
        log "[$repo_name] Klónozás..."
        if ! gh repo clone "$full_name" "$repo_dir"; then
            err "[$repo_name] Klónozás sikertelen."
            return 1
        fi
        log "[$repo_name] Klónozás kész."
        return 0
    fi

    # ── 2. Remote tracking ref-ek jelenlegi állapotának rögzítése ────────────
    declare -A old_remote_refs=()
    while IFS=' ' read -r sha ref; do
        old_remote_refs["$ref"]="$sha"
    done < <(git -C "$repo_dir" for-each-ref \
                 --format='%(objectname) %(refname)' 'refs/remotes/')

    # ── 3. Fetch – soha nem prune-ol ─────────────────────────────────────────
    log "[$repo_name] Fetch..."
    if ! git -C "$repo_dir" fetch --all --tags --no-prune 2>&1 | sed 's/^/  /'; then
        warn "[$repo_name] Fetch sikertelen, kihagyva."
        return 1
    fi

    # ── 4. Force push / átírt history detektálása ────────────────────────────
    while IFS=' ' read -r new_sha ref; do
        local old_sha="${old_remote_refs[$ref]:-}"
        [[ -z "$old_sha" ]] && continue          # új ref, nem volt korábban
        [[ "$old_sha" == "$new_sha" ]] && continue  # nem változott

        # Ha az old SHA nem őse az új SHA-nak → history átírás
        if ! git -C "$repo_dir" merge-base --is-ancestor "$old_sha" "$new_sha"; then
            local short_ref="${ref#refs/remotes/}"
            warn "[$repo_name] Force push / átírt history: $short_ref"
            warn "[$repo_name]   Eltűnt állás: ${old_sha:0:12}  Új csúcs: ${new_sha:0:12}"

            local backup_tag="backup/${TIMESTAMP}/${short_ref//\//-}"
            if git -C "$repo_dir" tag "$backup_tag" "$old_sha"; then
                log "[$repo_name] Biztonsági tag mentve: $backup_tag  (régi remote csúcs megőrizve)"
            else
                warn "[$repo_name] Nem sikerült biztonsági tag-et létrehozni: $backup_tag"
            fi
        fi
    done < <(git -C "$repo_dir" for-each-ref \
                 --format='%(objectname) %(refname)' 'refs/remotes/')

    # ── 5. Jelenlegi branch fast-forward frissítése ───────────────────────────
    local current_branch
    current_branch=$(git -C "$repo_dir" branch --show-current)

    if [[ -z "$current_branch" ]]; then
        log "[$repo_name] Detached HEAD – branch frissítés kihagyva."
        return 0
    fi

    local remote_ref="refs/remotes/origin/$current_branch"

    if ! git -C "$repo_dir" rev-parse --verify --quiet "$remote_ref" >/dev/null; then
        log "[$repo_name] Nincs origin/$current_branch tracking ref – branch érintetlen."
        return 0
    fi

    local local_sha remote_sha
    local_sha=$(git -C "$repo_dir" rev-parse HEAD)
    remote_sha=$(git -C "$repo_dir" rev-parse "$remote_ref")

    if [[ "$local_sha" == "$remote_sha" ]]; then
        log "[$repo_name] Naprakész: $current_branch"
    elif git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$remote_sha"; then
        # Helyi branch a remote mögött van → fast-forward biztonságos
        git -C "$repo_dir" merge --ff-only "$remote_ref" 2>&1 | sed 's/^/  /'
        log "[$repo_name] Fast-forward OK: $current_branch"
    elif git -C "$repo_dir" merge-base --is-ancestor "$remote_sha" "$local_sha"; then
        # Helyi branch előrébb van → rendben, nem csinálunk semmit
        log "[$repo_name] Helyi branch előrébb van (helyi commitok léteznek): $current_branch"
    else
        # Valódi eltérés (pl. force push utáni local változások)
        warn "[$repo_name] Eltérő history! Helyi branch változatlan: $current_branch"
        warn "[$repo_name]   Kézi egyeztetés szükséges (git merge / git rebase)."
    fi

    return 0
}

# GitHub remote URL-ből owner/repo kinyerése
# Kezeli: git@github.com:owner/repo.git és https://github.com/owner/repo[.git]
parse_github_full_name() {
    local url="$1"
    local result
    result=$(printf '%s' "$url" \
        | sed -E 's|^git@github\.com:([^/]+/[^/]+?)\.git$|\1|
                  s|^https?://github\.com/([^/]+/[^/]+?)\.git$|\1|
                  s|^https?://github\.com/([^/]+/[^/]+?)$|\1|')
    # Ha a sed nem változtatott rajta, nem GitHub URL
    if [[ "$result" == "$url" ]]; then
        echo ""
    else
        echo "$result"
    fi
}

# $REPOS_DIR-ban lévő, már meglévő git repók felderítése
# $1: a gh repo list alapján már ismert owner/repo-k szóközzel elválasztott listája (kizáráshoz)
# Kimenet: "full_name<TAB>repo_dir" sorok (csak az újak)
discover_local_repos() {
    local known_names_str="$1"
    local dir repo_dir_name origin_url full_name

    [[ -d "$REPOS_DIR" ]] || return 0

    for dir in "$REPOS_DIR"/*/; do
        [[ -d "$dir/.git" ]] || continue
        repo_dir_name=$(basename "$dir")

        # Kihagyjuk ha a könyvtárnév már szerepel a gh listában
        if printf '%s\n' $known_names_str | grep -qxF "$repo_dir_name"; then
            continue
        fi

        if ! origin_url=$(git -C "$dir" config --get remote.origin.url); then origin_url=""; fi
        if [[ -z "$origin_url" ]]; then
            warn "[helyi/$repo_dir_name] Nincs origin remote – kihagyva."
            continue
        fi

        full_name=$(parse_github_full_name "$origin_url")
        if [[ -z "$full_name" ]]; then
            warn "[helyi/$repo_dir_name] Nem GitHub remote: $origin_url – kihagyva."
            continue
        fi

        log "[helyi/$repo_dir_name] Felderített repó: $full_name  ($dir)"
        printf '%s\t%s\n' "$full_name" "$dir"
    done
}

# ── Főprogram ─────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$REPOS_DIR"
    LOG_FILE="$REPOS_DIR/.sync-${TIMESTAMP}.log"
    touch "$LOG_FILE"

    local gh_user
    gh_user=$(gh api user --jq .login)

    if [[ -z "$GH_TARGET" ]]; then
        GH_TARGET="$gh_user"
    fi

    log "GitHub szinkronizálás indul: $GH_TARGET → $REPOS_DIR"
    log "Log: $LOG_FILE"

    local repo_list
    repo_list=$(gh repo list "$GH_TARGET" \
        --limit 1000 \
        --json nameWithOwner \
        --jq '.[].nameWithOwner')

    if [[ -z "$repo_list" ]]; then
        log "Nem található egyetlen repó sem: $GH_TARGET"
        repo_list=""
    fi

    # Ismert repo-nevek (csak a rövid nevek, könyvtárnév-egyeztetéshez)
    local known_short_names=""
    while IFS= read -r full_name; do
        local short="${full_name##*/}"
        known_short_names="$known_short_names $short"
    done <<< "${repo_list:-}"

    local total=0 ok=0 failed=0

    # ── gh repo list alapján ──────────────────────────────────────────────────
    if [[ -n "$repo_list" ]]; then
        log "GitHub lista feldolgozása ($GH_TARGET)..."
        while IFS= read -r full_name; do
            total=$((total + 1))
            if sync_repo "$full_name"; then
                ok=$((ok + 1))
            else
                failed=$((failed + 1))
            fi
        done <<< "$repo_list"
    fi

    # ── Helyi könyvtárban már meglévő, listán nem szereplő repók ─────────────
    echo ""
    log "Helyi repók felderítése: $REPOS_DIR ..."
    local discovered
    discovered=$(discover_local_repos "$known_short_names")

    if [[ -n "$discovered" ]]; then
        while IFS=$'\t' read -r full_name repo_dir; do
            total=$((total + 1))
            if sync_repo "$full_name" "$repo_dir"; then
                ok=$((ok + 1))
            else
                failed=$((failed + 1))
            fi
        done <<< "$discovered"
    else
        log "Nincs gh listán kívüli helyi repó."
    fi

    echo ""
    log "════════════════════════════════════════"
    log "Kész! Összesen: $total  |  Sikeres: $ok  |  Hibás: $failed"
    log "Log fájl: $LOG_FILE"
    [[ $failed -gt 0 ]] && log "Hibás repók részleteiért lásd a log fájlt."

    return $failed
}

main "$@"
