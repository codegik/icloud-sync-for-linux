#!/usr/bin/env bash
# Installs icloud-sync for the current user (no root needed, except to install missing packages).
#
# Usage:
#   ./install.sh               install or update, from a clone of the repository
#   ./install.sh --uninstall   remove the program and the service (keeps settings, sync state and backups)
#   curl -fsSL https://raw.githubusercontent.com/codegik/icloud-sync-for-linux/master/install.sh | bash
set -euo pipefail

RAW_URL="${ICLOUD_SYNC_RAW_URL:-https://raw.githubusercontent.com/codegik/icloud-sync-for-linux/master}"
MIN_RCLONE="1.69"

BIN="$HOME/.local/bin/icloud-sync"
LIB_DIR="$HOME/.local/lib/icloud-sync"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/icloud-sync"
CONFIG="$CONFIG_DIR/config"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/icloud-sync.service"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

# Prompts read from the terminal, so they also work when this script is piped from curl
ask() { # ask "question" default -> REPLY
  local answer
  read -r -p "$1 [$2]: " answer </dev/tty
  REPLY="${answer:-$2}"
}

confirm() { # confirm "question" y|n
  local answer hint="[y/N]"
  [[ "$2" == y ]] && hint="[Y/n]"
  read -r -p "$1 $hint " answer </dev/tty
  answer="${answer:-$2}"
  [[ "$answer" == [yY]* ]]
}

# Writes to a temporary file and renames it, so a copy that is currently running is never modified
install_file() { # install_file mode source destination
  mkdir -p "$(dirname "$3")"
  local tmp
  tmp="$(mktemp "$3.XXXXXX")"
  cat "$2" >"$tmp"
  chmod "$1" "$tmp"
  mv -f "$tmp" "$3"
}

has_systemd_user() {
  command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1
}

uninstall() {
  if has_systemd_user; then
    systemctl --user disable --now icloud-sync 2>/dev/null || true
  fi
  rm -f "$UNIT" "$BIN"
  rm -rf "$LIB_DIR"
  has_systemd_user && systemctl --user daemon-reload
  say "icloud-sync removed"
  echo "Left in place: your synced folder, settings ($CONFIG_DIR) and sync state/backups (see ICLOUD_DATA_DIR, default ~/.local/share/icloud-sync)."
}

# --- Dependencies ------------------------------------------------------------

detect_package_manager() {
  local pm
  for pm in pacman apt-get dnf zypper; do
    command -v "$pm" >/dev/null && echo "$pm" && return
  done
}

package_for() { # package_for package-manager command
  case "$2" in
  notify-send)
    case "$1" in
    apt-get) echo libnotify-bin ;;
    zypper) echo libnotify-tools ;;
    *) echo libnotify ;;
    esac
    ;;
  inotifywait) echo inotify-tools ;;
  *) echo "$2" ;;
  esac
}

install_packages() { # install_packages package-manager packages...
  local pm="$1"
  shift
  case "$pm" in
  pacman) sudo pacman -S --needed "$@" ;;
  apt-get) sudo apt-get update && sudo apt-get install -y "$@" ;;
  dnf) sudo dnf install -y "$@" ;;
  zypper) sudo zypper install -y "$@" ;;
  esac
}

rclone_version_ok() {
  command -v rclone >/dev/null || return 1
  local version
  version="$(rclone version 2>/dev/null | head -1 | sed -n 's/^rclone v\([0-9][0-9.]*\).*/\1/p')"
  [[ -n "$version" ]] && [[ "$(printf '%s\n%s\n' "$MIN_RCLONE" "$version" | sort -V | head -1)" == "$MIN_RCLONE" ]]
}

check_dependencies() {
  say "Checking dependencies"

  local cmd missing_core=()
  for cmd in flock sha1sum realpath curl; do
    command -v "$cmd" >/dev/null || missing_core+=("$cmd")
  done

  local pm
  pm="$(detect_package_manager)"

  local packages=()
  command -v inotifywait >/dev/null || packages+=("$(package_for "$pm" inotifywait)")
  command -v notify-send >/dev/null || packages+=("$(package_for "$pm" notify-send)")

  local rclone_via_script=false
  if ! rclone_version_ok; then
    if command -v rclone >/dev/null; then
      echo "rclone is too old ($(rclone version | head -1)); version $MIN_RCLONE or newer is needed."
    fi
    if [[ "$pm" == pacman ]]; then
      packages+=(rclone)
    else
      # Debian/Ubuntu and others often ship an rclone without the iCloud backend
      rclone_via_script=true
      command -v unzip >/dev/null || packages+=(unzip)
    fi
  fi

  if ((${#missing_core[@]})); then
    for cmd in "${missing_core[@]}"; do
      case "$cmd" in
      flock) packages+=(util-linux) ;;
      sha1sum | realpath) packages+=(coreutils) ;;
      *) packages+=("$cmd") ;;
      esac
    done
  fi

  if ((${#packages[@]})) || $rclone_via_script; then
    if [[ -z "$pm" ]]; then
      warn "Couldn't detect your package manager. Install these yourself and run the installer again:"
      warn "  rclone >= $MIN_RCLONE (https://rclone.org/install/), inotify-tools, libnotify (notify-send)"
      exit 1
    fi

    if ((${#packages[@]})); then
      echo "Missing packages: ${packages[*]}"
      if confirm "Install them with sudo $pm?" y; then
        # The package manager's own prompts must read the terminal, not the script piped from curl
        if ! install_packages "$pm" "${packages[@]}" </dev/tty; then
          if [[ "$pm" == pacman ]]; then
            # Usually an outdated package database; Arch doesn't support installing without upgrading
            die "Installing failed. Update the system first (sudo pacman -Syu$([[ -d $HOME/.local/share/omarchy ]] && echo ", or omarchy-update on Omarchy")) and run the installer again."
          fi
          die "Installing failed. Install ${packages[*]} yourself and run the installer again."
        fi
      else
        die "Install them and run the installer again."
      fi
    fi

    if $rclone_via_script; then
      echo "rclone $MIN_RCLONE or newer is needed. It can be installed with rclone's official installer (https://rclone.org/install.sh)."
      if confirm "Run it with sudo?" y; then
        # Exit code 3 means the latest version is already installed
        curl -fsSL https://rclone.org/install.sh | sudo bash || [[ $? -eq 3 ]]
      else
        die "Install rclone >= $MIN_RCLONE and run the installer again."
      fi
    fi
  fi

  rclone_version_ok || die "rclone >= $MIN_RCLONE is still missing."
  echo "All dependencies are installed."
}

# --- iCloud login ------------------------------------------------------------

setup_remote() { # setup_remote name
  if rclone listremotes | grep -qxF "$1:"; then
    echo "rclone remote \"$1:\" already exists."
  else
    say "Connecting to iCloud"
    cat <<EOF
rclone's setup will start now. Answer it like this:
  n (new remote)  ->  name: $1  ->  storage: iclouddrive
  Apple ID: your email   password: your normal Apple ID password (app-specific passwords don't work)
  Then approve the sign-in on your Apple device and type the 6-digit code.
  Leave everything else at its default, and quit with q when done.
If Advanced Data Protection is on, first enable on your iPhone:
  Settings -> Apple Account -> iCloud -> Access iCloud Data on the Web
EOF
    confirm "Start rclone config now?" y || die "Create the remote with: rclone config, then run the installer again."
    rclone config </dev/tty
    rclone listremotes | grep -qxF "$1:" || die "No remote named \"$1\" was created. Run the installer again."
  fi

  echo "Checking access to iCloud Drive..."
  rclone lsd "$1:" --max-depth 1 >/dev/null ||
    die "Cannot list iCloud Drive. If the login expired, run: rclone reconnect $1:"
  echo "iCloud Drive is reachable."
}

# --- Settings ------------------------------------------------------------------

expand_path() {
  case "$1" in
  "~") echo "$HOME" ;;
  "~/"*) echo "$HOME/${1#"~/"}" ;;
  *) echo "$1" ;;
  esac
}

configure() {
  # Current settings are the defaults when re-running the installer
  if [[ -f "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    . "$CONFIG"
  fi

  local remote="${ICLOUD_REMOTE:-icloud:}"
  local remote_name="${remote%%:*}" remote_path="${remote#*:}"

  say "Settings"
  ask "Local folder to sync" "${ICLOUD_LOCAL_DIR:-$HOME/icloud}"
  LOCAL_DIR="$(realpath -m "$(expand_path "$REPLY")")"
  ask "rclone remote name" "$remote_name"
  remote_name="$REPLY"
  ask "Folder inside iCloud Drive to sync (empty = whole Drive)" "${remote_path:-}"
  remote_path="$REPLY"
  REMOTE="$remote_name:$remote_path"
  ask "Check iCloud for changes every N minutes" "$((${ICLOUD_POLL_INTERVAL:-3600} / 60))"
  [[ "$REPLY" =~ ^[1-9][0-9]*$ ]] || die "Not a number of minutes: $REPLY"
  local poll=$((REPLY * 60))
  ask "Stop a sync if it would delete more than this percent of files" "${ICLOUD_MAX_DELETE:-10}"
  [[ "$REPLY" =~ ^[0-9]+$ ]] && ((REPLY <= 100)) || die "Not a percentage: $REPLY"
  local max_delete="$REPLY"

  DATA_DIR="${ICLOUD_DATA_DIR:-$HOME/.local/share/icloud-sync}"

  setup_remote "$remote_name"

  mkdir -p "$CONFIG_DIR"
  [[ -f "$CONFIG" ]] && cp "$CONFIG" "$CONFIG.bak"
  {
    echo "# icloud-sync settings, written by install.sh. Re-run the installer or edit by hand."
    echo "# Variables set in the environment take precedence over this file."
    printf 'ICLOUD_LOCAL_DIR=%q\n' "$LOCAL_DIR"
    printf 'ICLOUD_REMOTE=%q\n' "$REMOTE"
    printf 'ICLOUD_POLL_INTERVAL=%q\n' "$poll"
    printf 'ICLOUD_MAX_DELETE=%q\n' "$max_delete"
    printf 'ICLOUD_DATA_DIR=%q\n' "$DATA_DIR"
    echo "# ICLOUD_BACKUP_DIR=\"\$ICLOUD_DATA_DIR/backup\"   where replaced or deleted local files go"
    echo "# ICLOUD_SETTLE_SECONDS=10                      quiet period after local changes before syncing"
  } >"$CONFIG"
  echo "Saved $CONFIG"
}

# --- Files -----------------------------------------------------------------------

fetch_sources() {
  SRC_DIR=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "$dir/sync.sh" && -f "$dir/icloud-sync.service" ]] && SRC_DIR="$dir"
  fi

  if [[ -z "$SRC_DIR" ]]; then
    SRC_DIR="$(mktemp -d)"
    trap 'rm -rf "$SRC_DIR"' EXIT
    echo "Downloading from $RAW_URL"
    curl -fsSL "$RAW_URL/sync.sh" -o "$SRC_DIR/sync.sh"
    curl -fsSL "$RAW_URL/icloud-sync.service" -o "$SRC_DIR/icloud-sync.service"
  fi
}

install_files() {
  say "Installing"
  install_file 755 "$SRC_DIR/sync.sh" "$LIB_DIR/sync.sh"

  local wrapper
  wrapper="$(mktemp)"
  cat >"$wrapper" <<'EOF'
#!/usr/bin/env bash
# Installed by icloud-sync-for-linux's install.sh: loads the settings file, then runs sync.sh
set -euo pipefail

# Fixed paths, so the service finds the same files as your shell even if its environment differs
default_config=@CONFIG@
lib_dir=@LIB_DIR@

config="${ICLOUD_SYNC_CONFIG:-$default_config}"
if [[ -f "$config" ]]; then
  # Variables already set in the environment take precedence over the file
  saved=()
  for name in $(compgen -v ICLOUD_); do saved+=("$name=${!name}"); done
  set -a
  # shellcheck source=/dev/null
  . "$config"
  set +a
  for pair in "${saved[@]}"; do export "$pair"; done
fi

exec "$lib_dir/sync.sh" "$@"
EOF
  local content
  content="$(<"$wrapper")"
  content="${content//@CONFIG@/"$(printf '%q' "$CONFIG")"}"
  content="${content//@LIB_DIR@/"$(printf '%q' "$LIB_DIR")"}"
  printf '%s\n' "$content" >"$wrapper"
  install_file 755 "$wrapper" "$BIN"
  rm -f "$wrapper"
  echo "Installed $BIN"

  case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin is not in your PATH. Add it, or run $BIN directly." ;;
  esac
}

# Same check sync.sh does: bisync keeps listings per local/remote pair after the first --resync
first_sync_done() {
  local key
  key="$(printf '%s|%s' "$LOCAL_DIR" "$REMOTE" | sha1sum | cut -c1-12)"
  compgen -G "$DATA_DIR/bisync/$key/*.lst" >/dev/null
}

setup_service() {
  if ! has_systemd_user; then
    warn "systemd user services aren't available. To sync in the background, start 'icloud-sync --watch' when you log in."
    return
  fi

  install_file 644 "$SRC_DIR/icloud-sync.service" "$UNIT"
  systemctl --user daemon-reload
  echo "Installed $UNIT"

  if ! first_sync_done; then
    # tmux isn't installed everywhere; systemd-run also keeps the first sync running after the terminal closes
    local run_first="systemd-run --user --collect --unit icloud-sync-resync $(printf '%q' "$BIN") --resync
  journalctl --user -u icloud-sync-resync -f    # follow its progress"
    command -v tmux >/dev/null && run_first="tmux new -s icloud $(printf '%q' "$BIN") --resync"

    say "Almost done: run the first sync"
    cat <<EOF
The first sync merges both sides, copies anything missing and deletes nothing.
With a large Drive it can take hours; if it's interrupted, just run it again.
Wait for it to finish before starting the background service.

  icloud-sync --resync --dry-run    # preview
  $run_first
  systemctl --user enable --now icloud-sync    # when it's done: keep syncing in the background
EOF
    return
  fi

  if confirm "Start the background sync service now (and on every login)?" y; then
    systemctl --user enable icloud-sync
    systemctl --user restart icloud-sync
    echo "Running. Logs: journalctl --user -u icloud-sync -f"
  fi
}

main() {
  case "${1:-}" in
  --uninstall)
    uninstall
    return
    ;;
  "") ;;
  *) die "Usage: install.sh [--uninstall]" ;;
  esac

  [[ -r /dev/tty ]] || die "The installer asks questions and needs a terminal."
  [[ $EUID -ne 0 ]] || die "Run the installer as your normal user, not root."

  check_dependencies
  fetch_sources
  configure
  install_files
  setup_service

  say "icloud-sync is installed"
  echo "Settings: $CONFIG (re-run the installer to change them)"
}

main "$@"
