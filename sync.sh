#!/usr/bin/env bash
# Two-way sync between a local folder and iCloud Drive (rclone bisync).
# New, changed and deleted files and folders are applied to both sides.
# Local files that are deleted or overwritten are moved to a backup folder; iCloud deletions go to iCloud's trash.
#
# Usage: ./sync.sh [--watch] [extra rclone flags]
#   ./sync.sh --resync --dry-run   preview the first run
#   ./sync.sh --resync             first run: merge both sides, deletes nothing
#   ./sync.sh                      one sync
#   ./sync.sh --watch              keep running: sync on local changes and every POLL_INTERVAL seconds
set -euo pipefail

REMOTE="${ICLOUD_REMOTE:-icloud:}"
LOCAL_DIR="${ICLOUD_LOCAL_DIR:-$HOME/icloud}"
DATA_ROOT="${ICLOUD_DATA_DIR:-$HOME/.local/share/icloud-sync}"
BACKUP_ROOT="${ICLOUD_BACKUP_DIR:-$DATA_ROOT/backup}"
# bisync treats this as a percentage: abort if more than this % of files would be deleted
MAX_DELETE="${ICLOUD_MAX_DELETE:-10}"
# iCloud can't push changes to us, so --watch also syncs on this interval. Listing a large Drive is slow
POLL_INTERVAL="${ICLOUD_POLL_INTERVAL:-3600}"
# After a local change, wait until nothing changed for this long, so a burst of changes becomes one sync
SETTLE_SECONDS="${ICLOUD_SETTLE_SECONDS:-10}"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/icloud-sync.lock"

EXIT_NEEDS_RESYNC=2
EXIT_NO_ACCESS=3
EXIT_BUSY=4

REMOTE_NAME="${REMOTE%%:*}:"

notify() {
  echo "$1" >&2
  notify-send -a "iCloud sync" "iCloud sync" "$1" 2>/dev/null || true
}

check_setup() {
  if ! command -v rclone >/dev/null; then
    echo "rclone not found. Install it: sudo pacman -S rclone" >&2
    exit 1
  fi

  if ! rclone listremotes | grep -qxF "$REMOTE_NAME"; then
    echo "rclone remote \"$REMOTE_NAME\" not found. Create it with: rclone config (type: iclouddrive)" >&2
    exit 1
  fi

  # Backups must live outside the synced folder, or rclone would sync them too
  case "$(realpath -m "$BACKUP_ROOT")/" in
  "$(realpath -m "$LOCAL_DIR")"/*)
    echo "Backup folder must be outside $LOCAL_DIR" >&2
    exit 1
    ;;
  esac

  mkdir -p "$LOCAL_DIR" "$BACKUP_ROOT"
}

# Runs in a subshell so the lock is released when it returns
sync_once() (
  if ! rclone lsd "$REMOTE" --max-depth 1 >/dev/null 2>&1; then
    echo "Cannot access $REMOTE (offline, or the login expired: run rclone reconnect $REMOTE_NAME)" >&2
    exit $EXIT_NO_ACCESS
  fi

  # Never run two syncs at the same time
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Another sync is already running" >&2
    exit $EXIT_BUSY
  fi

  # bisync keeps listings of both sides from the last run; one folder per local/remote pair
  local workdir
  workdir="$DATA_ROOT/bisync/$(printf '%s|%s' "$(realpath -m "$LOCAL_DIR")" "$REMOTE" | sha1sum | cut -c1-12)"
  mkdir -p "$workdir"

  local resync=false arg
  for arg in "$@"; do
    [[ "$arg" == "--resync" || "$arg" == "-1" ]] && resync=true
  done

  if ! $resync && ! compgen -G "$workdir/*.lst" >/dev/null; then
    echo "First run for $LOCAL_DIR <-> $REMOTE: run ./sync.sh --resync (try --resync --dry-run first)" >&2
    exit $EXIT_NEEDS_RESYNC
  fi

  local extra=()
  # On the first run, a file that differs on both sides keeps the newer version
  $resync && extra+=(--resync-mode newer)

  echo "Syncing $LOCAL_DIR <-> $REMOTE"
  rclone bisync "$LOCAL_DIR" "$REMOTE" \
    --workdir "$workdir" \
    --create-empty-src-dirs \
    --backup-dir1 "$BACKUP_ROOT/$(date +%F-%H%M%S)" \
    --max-delete "$MAX_DELETE" \
    --conflict-resolve newer \
    --conflict-loser num \
    --resilient \
    --recover \
    --max-lock 2m \
    --stats 1m --stats-one-line \
    -v \
    "${extra[@]}" \
    "$@"
)

# Returns when something changed locally (and then settled) or after POLL_INTERVAL seconds
wait_for_changes() {
  local events=(-r -qq -e close_write,create,delete,move --exclude '\.partial$')
  local status=0

  inotifywait "${events[@]}" -t "$POLL_INTERVAL" "$LOCAL_DIR" || status=$?
  case $status in
  0)
    echo "Local changes detected"
    while inotifywait "${events[@]}" -t "$SETTLE_SECONDS" "$LOCAL_DIR"; do :; done
    ;;
  2) ;; # timeout: time for the periodic check
  *)
    echo "inotifywait failed (exit $status); retrying in 60s" >&2
    sleep 60
    ;;
  esac
}

watch_loop() {
  if ! command -v inotifywait >/dev/null; then
    echo "inotifywait not found. Install it: sudo pacman -S inotify-tools" >&2
    exit 1
  fi

  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--resync" || "$arg" == "-1" ]]; then
      echo "Run ./sync.sh --resync once on its own before using --watch" >&2
      exit 1
    fi
  done

  # Notify once per problem, not on every retry
  local failing=false status
  while true; do
    status=0
    sync_once "$@" || status=$?

    case $status in
    0)
      $failing && notify "Sync is working again"
      failing=false
      ;;
    "$EXIT_NEEDS_RESYNC")
      notify "First sync not done yet. Run: ./sync.sh --resync"
      exit $status
      ;;
    "$EXIT_BUSY") ;;
    "$EXIT_NO_ACCESS")
      $failing || notify "Cannot reach iCloud. If the login expired, run: rclone reconnect $REMOTE_NAME"
      failing=true
      ;;
    *)
      $failing || notify "Sync failed (exit $status). Check: journalctl --user -u icloud-sync"
      failing=true
      ;;
    esac

    wait_for_changes
  done
}

check_setup

if [[ "${1:-}" == "--watch" ]]; then
  shift
  watch_loop "$@"
else
  sync_once "$@"
fi
