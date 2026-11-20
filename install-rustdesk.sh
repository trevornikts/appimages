#!/usr/bin/env bash

set -euo pipefail

CURL=(curl -fsSL --retry 8 --retry-delay 3 --retry-all-errors)
MIRROR="${RUSTDESK_BASE_URL:-}"
VERSION=""

if [ "$(id -u)" -eq 0 ]; then
  MODE=root
  CRED_FILE=/root/rustdesk-credentials.txt
  DEFAULT_LOG=/var/log/rustdesk-install.log
else
  MODE=user
  CRED_FILE="$HOME/rustdesk-credentials.txt"
  DEFAULT_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/rustdesk-install.log"
fi

# Log file: a plain, readable document (644). Falls back to a temp file if the default location
# is not writable.
LOG="${RUSTDESK_LOG:-$DEFAULT_LOG}"
if ! { mkdir -p "$(dirname "$LOG")" && : >> "$LOG"; } 2>/dev/null; then
  LOG="$(mktemp "${TMPDIR:-/tmp}/rustdesk-install.XXXXXX.log")"
fi
chmod 644 "$LOG" 2>/dev/null || true

step() { echo "==> $*"; }

verify_sum() {
  local file="$1" name="$2" sums want
  sums="$(curl -fsSL --max-time 30 "${MIRROR%/}/SHA256SUMS" 2>/dev/null)" || {
    echo "WARNING: ${MIRROR%/}/SHA256SUMS not found, checksum verification skipped." >&2; return 0; }
  want="$(printf '%s\n' "$sums" | awk -v n="$name" '$2==n || $2=="*" n {print $1; exit}')"
  [ -n "$want" ] || { echo "WARNING: no entry for $name in SHA256SUMS, checksum verification skipped." >&2; return 0; }
  [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$want" ] || { echo "Checksum mismatch for $name!" >&2; exit 1; }
  echo "Checksum of $name verified."
}

github_version() {
  local v="${RUSTDESK_VERSION:-}" json
  if [ -z "$v" ]; then
    json="$("${CURL[@]}" https://api.github.com/repos/rustdesk/rustdesk/releases/latest)"
    v="$(printf '%s\n' "$json" | sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p' | head -n1)"
  fi
  [ -n "$v" ] || { echo "Could not determine the RustDesk version." >&2; return 1; }
  printf '%s\n' "$v"
}

# download <output file> <file name on your server> <GitHub asset suffix>
download() {
  local out="$1" mirror_name="$2" gh_suffix="$3" url
  if [ -n "$MIRROR" ]; then
    VERSION="(from ${MIRROR%/})"
    url="${MIRROR%/}/$mirror_name"
    echo "Downloading $url"
    "${CURL[@]}" -o "$out" "$url"
    verify_sum "$out" "$mirror_name"
  else
    VERSION="$(github_version)"
    url="https://github.com/rustdesk/rustdesk/releases/download/${VERSION}/rustdesk-${VERSION}-${gh_suffix}"
    echo "Downloading $url"
    "${CURL[@]}" -o "$out" "$url"
  fi
}

install_root() {
  step "Checking machine-id"
  # RustDesk takes the machine uuid from /var/lib/dbus/machine-id. If that file is empty, the ID
  # is never registered and the password is encrypted with a key derived from an empty uuid.
  [ -s /etc/machine-id ] || systemd-machine-id-setup
  if [ ! -s /var/lib/dbus/machine-id ]; then
    mkdir -p /var/lib/dbus
    ln -sf /etc/machine-id /var/lib/dbus/machine-id
    echo "/var/lib/dbus/machine-id was empty, linked it to /etc/machine-id."
  fi

  local arch
  case "$(dpkg --print-architecture)" in
    amd64) arch=x86_64 ;;
    arm64) arch=aarch64 ;;
    *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac

  if ! command -v curl >/dev/null || [ ! -d /etc/ssl/certs ]; then
    step "Installing curl and ca-certificates"
    apt-get -o Acquire::Retries=10 update
    apt-get -o Acquire::Retries=10 install -y curl ca-certificates
  fi

  step "Downloading the RustDesk package"
  DEB="$(mktemp --suffix=.deb)"   # global on purpose: the EXIT trap runs after this function returns
  trap 'rm -f "$DEB"' EXIT
  download "$DEB" "rustdesk-${arch}.deb" "${arch}.deb"

  step "Installing the package"
  apt-get -o Acquire::Retries=10 install -y "$DEB"

  step "Starting the rustdesk service"
  systemctl enable --now rustdesk

  local password="${RUSTDESK_PASSWORD:-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')}"

  step "Getting the RustDesk ID"
  local rd_id="" i
  for i in $(seq 1 30); do
    rd_id="$(rustdesk --get-id 2>/dev/null | tail -n1 | tr -d '[:space:]')" || true
    [[ "$rd_id" =~ ^[0-9]+$ ]] && break
    rd_id=""
    sleep 2
  done
  [ -n "$rd_id" ] || { echo "Could not get the RustDesk ID (check: systemctl status rustdesk)." >&2; return 1; }

  step "Setting the permanent password"
  local cfg=/root/.config/rustdesk/RustDesk.toml before now set_ok=""
  before="$(sed -n "s/^password = //p" "$cfg" 2>/dev/null | head -n1 || true)"
  for i in $(seq 1 30); do
    rustdesk --password "$password" >/dev/null 2>&1 || true
    now="$(sed -n "s/^password = //p" "$cfg" 2>/dev/null | head -n1 || true)"
    if [ -n "$now" ] && [ "$now" != "''" ] && [ "$now" != "$before" ]; then set_ok=1; break; fi
    sleep 2
  done
  [ -n "$set_ok" ] || { echo "Could not store the permanent password (check: systemctl status rustdesk)." >&2; return 1; }

  # The public server can assign a new ID right after the first registration; read it again.
  sleep 10
  local id2
  id2="$(rustdesk --get-id 2>/dev/null | tail -n1 | tr -d '[:space:]')" || true
  if [[ "$id2" =~ ^[0-9]+$ ]] && [ "$id2" != "$rd_id" ]; then
    echo "The ID was updated by the server: $rd_id -> $id2"
    rd_id="$id2"
  fi

  printf 'ID: %s\nPassword: %s\n' "$rd_id" "$password" > "$CRED_FILE"
  echo "RustDesk ${VERSION} installed (root mode), ID: $rd_id"
}

install_user() {
  [ "$(uname -m)" = x86_64 ] || { echo "The RustDesk AppImage is only available for x86_64." >&2; return 1; }
  command -v curl >/dev/null || { echo "curl is required." >&2; return 1; }

  local base="${RUSTDESK_DIR:-$HOME/.local/share/rustdesk-portable}"
  step "Downloading the RustDesk AppImage"
  mkdir -p "$base"
  cd "$base"
  download rustdesk.AppImage rustdesk-x86_64.AppImage x86_64.AppImage

  step "Extracting the AppImage"
  # A server left over from a previous run runs from the directory we are about to replace.
  pkill -u "$(id -u)" -f "$base/squashfs-root/.*rustdesk --server" 2>/dev/null && sleep 1 || true
  chmod +x rustdesk.AppImage
  rm -rf squashfs-root
  ./rustdesk.AppImage --appimage-extract >/dev/null
  local bin="$base/squashfs-root/AppRun"
  [ -x "$bin" ] || { echo "Extracting the AppImage failed." >&2; return 1; }

  if [ ! -s /var/lib/dbus/machine-id ]; then
    echo "WARNING: /var/lib/dbus/machine-id is empty or missing. Without it the ID will not be registered." >&2
    echo "         Ask an administrator to run: sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id" >&2
  fi

  # RustDesk needs the X display of the graphical session. When the script runs without one
  # (for example over ssh), look for the session of this user: RUSTDESK_DISPLAY, then `who`,
  # then the first X socket.
  local disp="${RUSTDESK_DISPLAY:-${DISPLAY:-}}" sock
  if [ -z "$disp" ]; then
    disp="$(who 2>/dev/null | awk -v u="$(id -un)" '$1==u && $2 ~ /^:[0-9]+$/ {print $2; exit}')" || true
  fi
  if [ -z "$disp" ]; then
    for sock in /tmp/.X11-unix/X*; do
      [ -S "$sock" ] && { disp=":${sock##*/X}"; break; }
    done
  fi
  if [ -n "$disp" ]; then
    echo "Using the graphical session DISPLAY=$disp"
    export DISPLAY="$disp"
    [ -n "${XAUTHORITY:-}" ] || [ ! -f "$HOME/.Xauthority" ] || export XAUTHORITY="$HOME/.Xauthority"
  else
    echo "WARNING: no graphical session found. The server starts, but the screen cannot be shared" >&2
    echo "         until you log in to the desktop (the autostart entry will start it then)." >&2
  fi

  step "Adding autostart and starting the server"
  # Not named rustdesk.desktop: RustDesk deletes that file itself on every --server start.
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/rustdesk-portable.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=RustDesk
Exec=$bin --server
X-GNOME-Autostart-enabled=true
EOF
  # setsid + nohup: the server keeps running in the background after the terminal or ssh session closes.
  if ! pgrep -u "$(id -u)" -f "$base/squashfs-root/.*rustdesk --server" >/dev/null; then
    nohup setsid "$bin" --server >"$base/server.log" 2>&1 &
  fi

  step "Getting the RustDesk ID"
  local rd_id="" i
  for i in $(seq 1 30); do
    rd_id="$("$bin" --get-id 2>/dev/null | tail -n1 | tr -d '[:space:]')" || true
    [[ "$rd_id" =~ ^[0-9]+$ ]] && break
    rd_id=""
    sleep 2
  done
  [ -n "$rd_id" ] || { echo "Could not get the RustDesk ID (see $base/server.log)." >&2; return 1; }

  local note="Set a permanent password once in the RustDesk window: Settings -> Security -> Permanent password."
  if [ -n "${RUSTDESK_PASSWORD:-}" ]; then
    if "$bin" --password "$RUSTDESK_PASSWORD" 2>&1 | grep -q '^Done'; then
      note="Password: $RUSTDESK_PASSWORD"
    else
      echo "RustDesk refused to set the password without root."
    fi
  fi

  step "Checking that the server is running"
  sleep 5
  local pid
  pid="$(pgrep -u "$(id -u)" -f "$base/squashfs-root/.*rustdesk --server" | head -n1 || true)"
  if [ -z "$pid" ]; then
    echo "ERROR: the RustDesk server is not running (see $base/server.log)." >&2
    return 1
  fi
  echo "RustDesk server is running in the background (PID $pid, DISPLAY=${DISPLAY:-none})."
  if grep -q 'cannot open display' "$base/server.log" 2>/dev/null; then
    echo "WARNING: RustDesk cannot open the display ${DISPLAY:-}; the screen will not be shared." >&2
    echo "         Run the script again inside the desktop session or set RUSTDESK_DISPLAY=:N." >&2
  fi

  # Right after the first registration the public server can assign a new ID (UUID_MISMATCH),
  # so read the ID again once the server has had time to register.
  sleep 10
  local id2
  id2="$("$bin" --get-id 2>/dev/null | tail -n1 | tr -d '[:space:]')" || true
  if [[ "$id2" =~ ^[0-9]+$ ]] && [ "$id2" != "$rd_id" ]; then
    echo "The ID was updated by the server: $rd_id -> $id2"
    rd_id="$id2"
  fi

  printf 'ID: %s\n%s\n' "$rd_id" "$note" > "$CRED_FILE"
  if [ ! -s /var/lib/dbus/machine-id ]; then
    # Shown in the final summary too: without this the ID is not registered and nobody can connect.
    printf '%s\n%s\n%s\n' \
      "WARNING: this ID will NOT accept connections yet (/var/lib/dbus/machine-id is empty)." \
      "         Ask an administrator to run: sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id" \
      "         then run this script again (the ID may change)." >> "$CRED_FILE"
  fi
  echo "RustDesk ${VERSION} installed (portable, user mode) in $base, ID: $rd_id"
  echo "RustDesk window: $bin"
}

# Everything below goes to the terminal and to the log. The final summary with the ID and
# password is printed after the pipeline from the credentials file, and is also appended to the log.
run() {
  set -eE
  trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR
  echo "=== RustDesk install started $(date '+%F %T') (mode: $MODE, user: $(id -un), host: $(hostname)) ==="
  umask 077
  if [ "$MODE" = root ]; then install_root; else install_user; fi
}

echo "Install log: $LOG"
set +e
run </dev/null 2>&1 | tee -a "$LOG"
RC="${PIPESTATUS[0]}"
set -e

if [ "$RC" -ne 0 ]; then
  echo "=== FAILED (exit code $RC) $(date '+%F %T') ===" >> "$LOG"
  echo "Installation FAILED (exit code $RC). See the log: $LOG" >&2
  exit "$RC"
fi

{
  echo
  echo "RustDesk installed ($MODE mode)."
  sed 's/^/  /' "$CRED_FILE"
  echo "(saved to $CRED_FILE; install log: $LOG)"
  echo "=== Finished OK $(date '+%F %T') ==="
} | tee -a "$LOG"
