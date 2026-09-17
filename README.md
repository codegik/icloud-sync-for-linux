# icloud-sync-for-linux

Two-way sync between iCloud Drive and a local folder on Linux. It's a single script, `sync.sh`, built on [rclone bisync](https://rclone.org/bisync/) and [rclone's iCloud Drive backend](https://rclone.org/iclouddrive/).

New, changed and deleted files and folders are applied to both sides. With `--watch` the script keeps running: it syncs when local files change and every hour (configurable) to pick up changes made in iCloud.

## Install

Works on any Linux with systemd: Arch (including Omarchy), Debian/Ubuntu, Fedora, openSUSE… Nothing is installed system-wide except missing packages, and the installer asks before using sudo.

```sh
git clone https://github.com/codegik/icloud-sync-for-linux.git
cd icloud-sync-for-linux
./install.sh
```

or, without cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/codegik/icloud-sync-for-linux/master/install.sh | bash
```

The installer:

1. Checks for rclone ≥ 1.69, inotify-tools and libnotify, and offers to install what's missing. If your distro's rclone is too old, it offers [rclone's official installer](https://rclone.org/install/).
2. Asks for the local folder, the part of iCloud Drive to sync, how often to check iCloud and the deletion safety limit.
3. Connects rclone to iCloud if needed. Use your normal Apple ID password (app-specific passwords are rejected) and approve the 2FA prompt. If Advanced Data Protection is on, first enable *Settings → Apple Account → iCloud → Access iCloud Data on the Web* on your iPhone.
4. Installs `~/.local/bin/icloud-sync`, the settings file `~/.config/icloud-sync/config` and a systemd user service.

Run it again to update or change settings (your current answers are the defaults). `./install.sh --uninstall` removes the program and the service. Your files, settings and backups stay.

## First run

bisync has to merge both sides once before normal runs work:

```sh
icloud-sync --resync --dry-run    # preview
tmux new -s icloud icloud-sync --resync    # or, without tmux: systemd-run --user --collect --unit icloud-sync-resync ~/.local/bin/icloud-sync --resync
systemctl --user enable --now icloud-sync    # afterwards: keep syncing in the background
```

`--resync` copies anything missing to the other side and **deletes nothing**. If a file differs on the two sides, the newer version wins. With a large Drive this can take hours or days. If it's interrupted, run it again; files already copied are skipped.

## Usage

```sh
icloud-sync              # one sync
icloud-sync --dry-run    # preview one sync
icloud-sync --watch      # keep running: sync on local changes and on the configured interval
journalctl --user -u icloud-sync -f    # logs of the background service
```

Any extra arguments are passed to rclone. The service starts when you log in and restarts if it crashes.

Without installing, `./sync.sh` in the repository works the same way but ignores the settings file. Configure it with the environment variables below.

### When the login expires

Apple requires your password and 2FA, so logging in again can't be automated. rclone keeps the session for up to 30 days. When it expires:

1. You get a desktop notification: *Cannot reach iCloud. If the login expired, run: rclone reconnect icloud:*
2. Run `rclone reconnect icloud:` and approve the 2FA prompt.
3. The service keeps running. The next sync works, and you get a *Sync is working again* notification.

The same notification appears when you're offline. It's shown once per problem, not on every retry.

## Settings

Set in `~/.config/icloud-sync/config` (re-run `./install.sh`, or edit it and run `systemctl --user restart icloud-sync`). Environment variables with the same names take precedence.

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
- A sync stops if it would delete more than `ICLOUD_MAX_DELETE` percent of files. If the deletions are intended, run `icloud-sync --force` once.
- If a file changed on both sides, the newer one wins and the other is kept alongside it, renamed with a `conflict1` suffix.
- Only one sync runs at a time. A manual `icloud-sync` while the service is syncing exits right away.
- Interrupted runs recover on the next run without needing another `--resync`.

## Known limits

- Every sync lists both sides completely, which is slow for a large Drive. Changes made in iCloud show up at the next hourly check.
- Local edits made while a sync is running aren't picked up until the next sync.
- The rclone iCloud backend is experimental. iCloud has no file hashes, and it reports the wrong size for iWork files (Pages, Numbers, Keynote), so changes are detected by modification time only.
