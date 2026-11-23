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

# --- user mode helpers -------------------------------------------------------------------------

# Stop the portable server (systemd user unit and plain processes).
stop_server() {
  systemctl --user stop rustdesk-portable.service >/dev/null 2>&1 || true
  pkill -u "$(id -u)" -f "$1/squashfs-root/.*rustdesk --" 2>/dev/null || true
  sleep 2
}

# Start the portable server in the background. A transient systemd user unit is preferred: when the
# script runs over ssh, logind kills every process of the session at logout, even setsid ones.
start_server() {
  local bin="$1" base="$2" envs=()
  [ -z "${DISPLAY:-}" ] || envs+=(-E "DISPLAY=$DISPLAY")
  [ -z "${XAUTHORITY:-}" ] || envs+=(-E "XAUTHORITY=$XAUTHORITY")
  if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --quiet --collect \
      --unit=rustdesk-portable -p "StandardOutput=append:$base/server.log" \
      -p "StandardError=append:$base/server.log" ${envs[@]+"${envs[@]}"} "$bin" --server >/dev/null 2>&1; then
    echo "Server started as the systemd user unit rustdesk-portable (survives logout)."
  else
    nohup setsid "$bin" --server >"$base/server.log" 2>&1 </dev/null &
    echo "Server started with nohup setsid (it may stop when this login session ends)."
  fi
}

# Write the permanent password into RustDesk.toml. The server must be stopped: a running server
# keeps its own copy of the config and would overwrite the file.
set_config_password() {
  local cfg="$1" pw="$2" tmp
  tmp="$(mktemp)"
  if grep -q '^password = ' "$cfg"; then
    PW="$pw" awk -v q="'" '/^password = / && !done { print "password = " q ENVIRON["PW"] q; done=1; next } { print }' "$cfg" > "$tmp"
  else
    { printf "password = '%s'\n" "$pw"; cat "$cfg"; } > "$tmp"
  fi
  cat "$tmp" > "$cfg"   # keeps the owner and mode of the file
  rm -f "$tmp"
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
  chmod 644 "$CRED_FILE"   # plain document on purpose (the user asked for ordinary permissions)
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
  stop_server "$base"
  chmod +x rustdesk.AppImage
  rm -rf squashfs-root
  ./rustdesk.AppImage --appimage-extract >/dev/null
  local bin="$base/squashfs-root/AppRun"
  [ -x "$bin" ] || { echo "Extracting the AppImage failed." >&2; return 1; }

  # RustDesk takes the machine uuid from /var/lib/dbus/machine-id; when it is empty the ID is never
  # registered. Without root the file cannot be fixed, but RustDesk can be shown /etc/machine-id at
  # that path through a private mount namespace (unshare -Urm, no root needed). The config is
  # encrypted with a key derived from the uuid, so EVERY RustDesk process must go through the
  # launcher below: one started outside it sees another uuid and rewrites the config (password lost).
  local launcher="$base/rustdesk-run.sh" no_machine_id=""
  if [ ! -s /var/lib/dbus/machine-id ]; then
    if [ -s /etc/machine-id ] && command -v unshare >/dev/null 2>&1 \
        && unshare -Urm sh -c 'mount --bind /etc/machine-id /var/lib/dbus/machine-id' >/dev/null 2>&1; then
      echo "NOTE: /var/lib/dbus/machine-id is empty. RustDesk is started in a private mount namespace"
      echo "      where it points to /etc/machine-id (no root needed). Start RustDesk only via $launcher"
    else
      no_machine_id=1
      echo "WARNING: /var/lib/dbus/machine-id is empty or missing. Without it the ID will not be registered." >&2
      echo "         Ask an administrator to run: sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id" >&2
    fi
  fi
  {
    printf "#!/bin/sh\nBIN='%s'\n" "$bin"
    cat <<'EOF'
U=$(id -u); G=$(id -g)
MNT='mount --bind /etc/machine-id /var/lib/dbus/machine-id'
if [ ! -s /var/lib/dbus/machine-id ] && [ -s /etc/machine-id ]; then
  # Preferred: mount as the namespace root, then map the real uid/gid back, so RustDesk (and a
  # terminal opened from it) still runs as this user and not as a fake root.
  C1="$MNT && exec unshare -U --map-user=$U --map-group=$G \"\$0\" \"\$@\""
  if unshare -Urm sh -c "$C1" true >/dev/null 2>&1; then exec unshare -Urm sh -c "$C1" "$BIN" "$@"; fi
  # Older util-linux without --map-user: works, but the process then looks like root inside.
  C2="$MNT && exec \"\$0\" \"\$@\""
  if unshare -Urm sh -c "$C2" true >/dev/null 2>&1; then exec unshare -Urm sh -c "$C2" "$BIN" "$@"; fi
fi
exec "$BIN" "$@"
EOF
  } > "$launcher"
  chmod +x "$launcher"

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
Exec=$launcher --server
X-GNOME-Autostart-enabled=true
EOF
  start_server "$launcher" "$base"

  step "Getting the RustDesk ID"
  local rd_id="" i
  for i in $(seq 1 30); do
    rd_id="$("$launcher" --get-id 2>/dev/null | tail -n1 | tr -d '[:space:]')" || true
    [[ "$rd_id" =~ ^[0-9]+$ ]] && break
    rd_id=""
    sleep 2
  done
  [ -n "$rd_id" ] || { echo "Could not get the RustDesk ID (see $base/server.log)." >&2; return 1; }

  local password="${RUSTDESK_PASSWORD:-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')}"
  case "$password" in
    *\'*|*[[:cntrl:]]*) echo "The password must not contain a single quote or control characters." >&2; return 1 ;;
  esac

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

  step "Setting the permanent password"
  local cfg="$HOME/.config/rustdesk/RustDesk.toml"
  [ -f "$cfg" ] || { echo "RustDesk config not found: $cfg" >&2; return 1; }
  stop_server "$base"
  set_config_password "$cfg" "$password"
  start_server "$launcher" "$base"
  sleep 8
  grep -q "^password = '.\+'" "$cfg" || { echo "The password is missing from $cfg after the restart." >&2; return 1; }
  pid="$(pgrep -u "$(id -u)" -f "$base/squashfs-root/.*rustdesk --server" | head -n1 || true)"
  [ -n "$pid" ] || { echo "ERROR: the RustDesk server did not come back after setting the password." >&2; return 1; }
  echo "Permanent password stored in $cfg, server running (PID $pid)."

  # The public server can assign a new ID (UUID_MISMATCH) after a registration, and every server
  # start registers again, so read the ID last, after the final restart.
  step "Checking the final RustDesk ID"
  sleep 12
  local id2
  id2="$("$launcher" --get-id 2>/dev/null | tail -n1 | tr -d '[:space:]')" || true
  if [[ "$id2" =~ ^[0-9]+$ ]] && [ "$id2" != "$rd_id" ]; then
    echo "The ID was updated by the server: $rd_id -> $id2"
    rd_id="$id2"
  fi

  printf 'ID: %s\nPassword: %s\n' "$rd_id" "$password" > "$CRED_FILE"
  if [ -n "$no_machine_id" ]; then
    # Shown in the final summary too: without this the ID is not registered and nobody can connect.
    printf '%s\n%s\n%s\n' \
      "WARNING: this ID will NOT accept connections yet (/var/lib/dbus/machine-id is empty)." \
      "         Ask an administrator to run: sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id" \
      "         then run this script again (the ID may change)." >> "$CRED_FILE"
  fi
  chmod 644 "$CRED_FILE"   # plain document on purpose (the user asked for ordinary permissions)
  echo "RustDesk ${VERSION} installed (portable, user mode) in $base, ID: $rd_id"
  echo "RustDesk window (always start it via the launcher): $launcher"
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

main() {
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
}

# By default the install runs in the background and this command returns at once; read the log
# afterwards. RUSTDESK_FOREGROUND=1 runs it in the terminal instead.
# The background copy is a snapshot of the functions and variables of this shell written to a temp
# file, so it also works for `curl | bash` (there is no script file to run again). It is started as
# a transient systemd unit when possible, because logind kills plain background processes when an
# ssh session ends.
detach() {
  local payload v how="" linger="" sargs=()
  payload="$(mktemp "${TMPDIR:-/tmp}/rustdesk-install.XXXXXX.sh")"
  {
    echo 'rm -f -- "${BASH_SOURCE[0]}"'
    echo 'set -euo pipefail'
    declare -f
    declare -p CURL MIRROR VERSION MODE CRED_FILE DEFAULT_LOG LOG
    for v in $(compgen -v); do
      case "$v" in RUSTDESK_*|DISPLAY|XAUTHORITY|XDG_STATE_HOME|TMPDIR) declare -p "$v" ;; esac
    done
    echo main
  } > "$payload"

  # Without root the units live in the user's systemd manager, which logind stops (killing the
  # install and the RustDesk server) when the last login session ends, unless "linger" is on.
  # A normal user may enable linger for themselves (verified on Astra 1.8, no password asked).
  if [ "$MODE" != root ] && command -v loginctl >/dev/null 2>&1 \
      && [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
    if loginctl enable-linger >/dev/null 2>&1; then
      linger="NOTE: enabled 'linger' for $(id -un) so the install and RustDesk survive logout (undo: loginctl disable-linger)."
    else
      linger="WARNING: could not enable 'linger'. Do not log out until the log says Finished; after logout RustDesk may stop."
    fi
  fi

  if command -v systemd-run >/dev/null 2>&1; then
    [ "$MODE" = root ] || sargs=(--user)
    if systemd-run ${sargs[@]+"${sargs[@]}"} --quiet --collect --unit=rustdesk-install \
        -p StandardOutput=null -p StandardError=null bash "$payload" >/dev/null 2>&1; then
      how="systemd unit rustdesk-install"
    fi
  fi
  if [ -z "$how" ]; then
    nohup setsid bash "$payload" >/dev/null 2>&1 </dev/null &
    how="background process (it may stop when this login session ends)"
  fi

  echo "RustDesk install started in the background ($how)."
  [ -z "$linger" ] || echo "$linger"
  echo "  Log:         $LOG"
  echo "  Follow:      tail -f $LOG"
  echo "  Credentials: $CRED_FILE (written at the end)"
  echo "  The log ends with '=== Finished OK' or '=== FAILED'."
}

if [ -n "${RUSTDESK_FOREGROUND:-}" ]; then main; else detach; fi
