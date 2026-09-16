# icloud-sync-for-linux

Two-way sync between iCloud Drive and a local folder on Linux. It's a single script, `sync.sh`, built on [rclone bisync](https://rclone.org/bisync/) and [rclone's iCloud Drive backend](https://rclone.org/iclouddrive/).

New, changed and deleted files and folders are applied to both sides. With `--watch` the script keeps running: it syncs when local files change and every hour to pick up changes made in iCloud.

## Setup

1. Install the tools: `sudo pacman -S rclone inotify-tools libnotify` (rclone must be ≥ 1.69)
2. Create the remote: `rclone config` → new remote named `icloud`, type `iclouddrive`. Use your normal Apple ID password (app-specific passwords are rejected) and approve the 2FA prompt.
   - If Advanced Data Protection is on, enable *Settings → Apple Account → iCloud → Access iCloud Data on the Web* on your iPhone.
3. Check it works: `rclone lsd icloud:`

## First run

bisync has to merge both sides once before normal runs work:

```sh
./sync.sh --resync --dry-run    # preview
tmux new -s icloud ./sync.sh --resync
```

`--resync` copies anything missing to the other side and **deletes nothing**. If a file differs on the two sides, the newer version wins. With a large Drive this can take hours or days. If it's interrupted, run it again; files already copied are skipped.

## Usage

```sh
./sync.sh              # one sync
./sync.sh --dry-run    # preview one sync
./sync.sh --watch      # keep running: sync on local changes and every hour
```

Any extra arguments are passed to rclone.

### Run in the background (systemd user service)

```sh
systemctl --user link "$PWD/icloud-sync.service"
systemctl --user enable --now icloud-sync
journalctl --user -u icloud-sync -f    # logs
```

The service starts when you log in and restarts if it crashes. If the repository isn't at `~/sources/codegik/icloud-sync-for-linux`, edit `ExecStart` in `icloud-sync.service`.

### When the login expires

Apple requires your password and 2FA, so logging in again can't be automated. rclone keeps the session for up to 30 days. When it expires:

1. You get a desktop notification: *Cannot reach iCloud. If the login expired, run: rclone reconnect icloud:*
2. Run `rclone reconnect icloud:` and approve the 2FA prompt.
3. The service keeps running. The next sync works, and you get a *Sync is working again* notification.

The same notification appears when you're offline. It's shown once per problem, not on every retry.

## Settings

Environment variables. For the service, add `Environment=NAME=value` lines to the unit file.

| Variable | Default | |
|---|---|---|
| `ICLOUD_REMOTE` | `icloud:` | rclone remote, optionally with a folder (`icloud:Documents`) |
| `ICLOUD_LOCAL_DIR` | `~/icloud` | local folder |
| `ICLOUD_DATA_DIR` | `~/.local/share/icloud-sync` | sync state and backups |
| `ICLOUD_BACKUP_DIR` | `$ICLOUD_DATA_DIR/backup` | where replaced or deleted local files go |
| `ICLOUD_MAX_DELETE` | `10` | abort if more than this **percent** of files would be deleted |
| `ICLOUD_POLL_INTERVAL` | `3600` | seconds between checks for iCloud changes (`--watch`) |
| `ICLOUD_SETTLE_SECONDS` | `10` | quiet period after local changes before syncing (`--watch`) |

## Safety

- Local files that a sync deletes or overwrites are moved to `~/.local/share/icloud-sync/backup/<timestamp>/`. Files deleted in iCloud go to iCloud's *Recently Deleted*.
- A sync stops if it would delete more than `ICLOUD_MAX_DELETE` percent of files. If the deletions are intended, run `./sync.sh --force` once.
- If a file changed on both sides, the newer one wins and the other is kept alongside it, renamed with a `conflict1` suffix.
- Only one sync runs at a time. A manual `./sync.sh` while the service is syncing exits right away.
- Interrupted runs recover on the next run without needing another `--resync`.

## Known limits

- Every sync lists both sides completely, which is slow for a large Drive. Changes made in iCloud show up at the next hourly check.
- Local edits made while a sync is running aren't picked up until the next sync.
- The rclone iCloud backend is experimental. iCloud has no file hashes, so changes are detected by size and modification time.
