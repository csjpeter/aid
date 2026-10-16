# Backup model

All backup tooling lives in `backup/`. One entry point: `backup/aid-backup`.

## What is protected, where it goes

| What | Tool | Target (`~/backup/`) | Retention |
|---|---|---|---|
| GitHub repos (own account) | `github-sync.sh` | `github/<repo>` (live mirror) | none: fetch only, never prunes |
| `~/.claude`, `~/.local/share/claude-userdata` | `claude-backup.sh` | `claude/`, `claude-userdata/` | hourly 24, daily 7, weekly 4, monthly 12 |
| t14-only git repos (no GitHub remote) | `t14-backup.sh` | `t14/repos/<path>.git` (bare mirror) | none: objects never pruned |
| t14 folders that are not git repos | `t14-backup.sh` | `t14/files/<path>/{daily,weekly,monthly}` | daily 7, weekly 4, monthly 12 |

The t14 lists live in `~/.config/aid-backup/t14.conf` (example:
`backup/t14.conf.example`), not in the script.

## Schedule (crontab)

```
0 * * * *   aid-backup claude   hourly
30 3 * * *  aid-backup t14      daily
45 3 * * *  aid-backup github   daily
```

Output of all three goes to `~/aid-backup.log`. `aid-backup status` shows the
state of every backup; `aid-backup all` runs every step and reports each failure.

## Guarantees

- `github-sync.sh` never deletes a local branch, tag or commit; a force push
  on the remote is saved as a `backup/<timestamp>/...` tag; only fast-forward
  merges happen. (If the remote history was rewritten on purpose, e.g. to
  remove a private name, align the clone by hand with `reset --hard`.)
- A t14 repo mirror holds the committed state only. `t14-backup.sh` warns when
  the working tree has uncommitted changes: commit them on t14 to include them.
- Snapshots are ordered **by name**, never by mtime (rsync keeps the source
  mtime, so a fresh snapshot of an unchanged source would look the oldest).
- Everything is on the same machine (gulliver) as the sources of the t14
  copies are on t14: gulliver and t14 back each other up. There is no off-site copy.

## Restore

- Claude config: `claude-backup.sh restore [SNAPSHOT]` (the current directory is
  kept as `<dir>.bak`).
- t14 repo: `git clone ~/backup/t14/repos/<name>.git <dest>`.
- t14 folder: copy back from `~/backup/t14/files/<name>/daily/<date>/`.
- GitHub repo: it is a normal clone in `~/backup/github/<repo>`.

## Working away from home: `claude-travel.sh`

`~/.claude` on gulliver is normally an sshfs mount of t14's `~/.claude`.
`claude-travel.sh go` switches to a local copy in this order, so nothing
depends on the network after the unmount:

1. `claude-backup.sh backup --refresh`: fresh local snapshot (mount still alive)
2. `claude-share.sh sync-json`: `~/.claude.json`, the newer side wins
3. stop and disable the two mount services
4. copy the latest local snapshot into the now plain `~/.claude`

`go --from-backup` skips steps 1-2 and uses the latest existing snapshot as it
is: usable with no connection to t14 (for example if you forgot to switch
before leaving). `back` merges the local changes up to t14 without deleting
anything there (overwritten files go to `~/.claude/.travel-backup/<stamp>/`,
`history.jsonl` is stored beside the original, not merged), moves the local
copies aside as `<dir>.travel-<stamp>` and restores the mounts. Both refuse to
run while a `claude` process runs. `--dry-run` prints the steps. The real switch
has not been exercised yet because the first test needs a Claude-free moment.
