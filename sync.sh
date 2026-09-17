#!/usr/bin/env bash
# Two-way sync between a local folder and iCloud Drive (rclone bisync).
# New, changed and deleted files and folders are applied to both sides, except folders in ICLOUD_EXCLUDE_DIRS.
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
# After a failed sync, --watch tries again after this long instead of waiting for POLL_INTERVAL
RETRY_INTERVAL="${ICLOUD_RETRY_INTERVAL:-60}"
# A sync that reads no data for this long is stuck (e.g. on a dead connection) and gets stopped
STALL_SECONDS="${ICLOUD_STALL_SECONDS:-600}"
# Folder names never synced, at any depth: thousands of small, constantly changing files that make every sync slow.
# Empty disables it. Changing it needs a --resync
EXCLUDE_DIRS="${ICLOUD_EXCLUDE_DIRS-.git node_modules target build .gradle .idea .vscode __pycache__ .venv}"
read -ra EXCLUDE_NAMES <<<"$EXCLUDE_DIRS"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/icloud-sync.lock"

EXIT_NEEDS_RESYNC=2
EXIT_NO_ACCESS=3
EXIT_BUSY=4
EXIT_STALLED=5

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

# Runs a command and stops it if it reads nothing (network or disk) for STALL_SECONDS.
# rclone can wait forever on a dead connection while still logging stats, so its output is no sign of progress
run_with_watchdog() {
  "$@" &
  local pid=$! rchar last="" idle=0

  # Background commands ignore Ctrl+C in scripts, so pass it on
  trap "kill -TERM $pid 2>/dev/null; wait $pid || true; exit 130" INT TERM

  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    rchar=$(awk '$1 == "rchar:" { print $2 }' "/proc/$pid/io" 2>/dev/null) || break
    [[ -n "$rchar" ]] || break

    if [[ "$rchar" != "$last" ]]; then
      last=$rchar
      idle=0
    elif (((idle += 5) >= STALL_SECONDS)); then
      echo "Nothing received for ${STALL_SECONDS}s, the connection is probably stuck: stopping the sync" >&2
      kill -TERM "$pid" 2>/dev/null || true
      # Let rclone save its state, but don't wait long: that may need the stuck connection too
      local i
      for i in {1..6}; do
        sleep 5
        kill -0 "$pid" 2>/dev/null || break
      done
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      trap - INT TERM
      return $EXIT_STALLED
    fi
  done

  local status=0
  wait "$pid" || status=$?
  trap - INT TERM
  return $status
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

  # bisync stores the filters file's hash at --resync and refuses to run once it changes
  local filters="$workdir/filters" extra=() name
  if ((${#EXCLUDE_NAMES[@]})); then
    for name in "${EXCLUDE_NAMES[@]}"; do
      printf -- '- %s/**\n' "$name"
    done >"$filters"
    extra+=(--filters-file "$filters")
  else
    rm -f "$filters"
  fi
  if ! $resync && [[ "$(md5sum <"$filters" 2>/dev/null | cut -d' ' -f1)" != "$(cat "$filters.md5" 2>/dev/null)" ]]; then
    echo "The excluded folders (ICLOUD_EXCLUDE_DIRS) changed: run ./sync.sh --resync (deletes nothing)" >&2
    exit $EXIT_NEEDS_RESYNC
  fi
  $resync && [[ ! -f "$filters" ]] && rm -f "$filters.md5"

  # On the first run, a file that differs on both sides keeps the newer version
  $resync && extra+=(--resync-mode newer)

  echo "Syncing $LOCAL_DIR <-> $REMOTE"
  # --ignore-size: iCloud lists iWork files (.pages, .numbers, .key) with a size that doesn't match the download,
  # which bisync treats as "corrupted on transfer" and aborts. Changes are detected by modification time only
  # --bind 0.0.0.0 forces IPv4: over IPv6, connections to iCloud can stall with no error and bisync waits forever
  run_with_watchdog rclone bisync "$LOCAL_DIR" "$REMOTE" \
    --workdir "$workdir" \
    --create-empty-src-dirs \
    --backup-dir1 "$BACKUP_ROOT/$(date +%F-%H%M%S)" \
    --max-delete "$MAX_DELETE" \
    --conflict-resolve newer \
    --conflict-loser num \
    --resilient \
    --ignore-size \
    --recover \
    --bind 0.0.0.0 \
    --timeout 2m \
    --max-lock 2m \
    --stats 1m --stats-one-line \
    -v \
    "${extra[@]}" \
    "$@"
)

regex_escape() { sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1"; }

# Changes inside excluded folders don't start a sync. inotifywait matches the full path, so anchor below LOCAL_DIR
exclude_regex='\.partial$'
for name in "${EXCLUDE_NAMES[@]}"; do
  exclude_regex+="|^$(regex_escape "${LOCAL_DIR%/}")/(.*/)?$(regex_escape "$name")(/|$)"
done
LOCAL_EVENTS=(-r -qq -e close_write,create,delete,move --exclude "$exclude_regex")

# Returns once nothing changed locally for SETTLE_SECONDS
wait_for_settle() {
  echo "Local changes detected"
  while inotifywait "${LOCAL_EVENTS[@]}" -t "$SETTLE_SECONDS" "$LOCAL_DIR"; do :; done
}

# Returns when something changed locally (and then settled) or after the given number of seconds
wait_for_changes() {
  local timeout=$1
  local status=0

  inotifywait "${LOCAL_EVENTS[@]}" -t "$timeout" "$LOCAL_DIR" || status=$?
  case $status in
  0)
    wait_for_settle
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
  local failing=false status wait watcher
  while true; do
    # A sync only sees local changes made before it listed the folder, so watch for changes while it runs.
    # Files the sync itself downloads or deletes count too, which costs one extra sync that finds nothing
    inotifywait "${LOCAL_EVENTS[@]}" "$LOCAL_DIR" &
    watcher=$!

    status=0
    sync_once "$@" || status=$?
    # Retry failures soon, so a sync doesn't wait an hour after the network comes back
    wait=$RETRY_INTERVAL

    case $status in
    0)
      $failing && notify "Sync is working again"
      failing=false
      wait=$POLL_INTERVAL
      ;;
    "$EXIT_NEEDS_RESYNC")
      kill "$watcher" 2>/dev/null || true
      notify "A --resync is needed (first sync not done, or excluded folders changed). Run: ./sync.sh --resync"
      exit $status
      ;;
    "$EXIT_BUSY") ;;
    "$EXIT_NO_ACCESS")
      $failing || notify "Cannot reach iCloud. If the login expired, run: rclone reconnect $REMOTE_NAME"
      failing=true
      ;;
    "$EXIT_STALLED")
      $failing || notify "Sync got stuck (connection not responding) and was stopped. Retrying"
      failing=true
      ;;
    *)
      $failing || notify "Sync failed (exit $status). Check: journalctl --user -u icloud-sync"
      failing=true
      ;;
    esac

    if kill -0 "$watcher" 2>/dev/null; then
      # Still waiting: nothing changed during the sync
      kill "$watcher" 2>/dev/null || true
      wait "$watcher" 2>/dev/null || true
      wait_for_changes "$wait"
    elif wait "$watcher"; then
      wait_for_settle
    else
      wait_for_changes "$wait"
    fi
  done
}

check_setup

if [[ "${1:-}" == "--watch" ]]; then
  shift
  watch_loop "$@"
else
  sync_once "$@"
fi
