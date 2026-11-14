#!/bin/sh
# PingKit Agent for Raspberry Pi: install, update or remove (headless agent plan, 6.3).
#
#   curl -fsSL https://pingkit.app/agent/install.sh | sudo sh
#   curl -fsSL https://pingkit.app/agent/install.sh | sudo sh -s -- --claim-code ABCD2345
#   sudo sh install.sh --update | --uninstall [--purge] | --help
#   sudo sh install.sh --enable-auto-update | --disable-auto-update
#
# PingKit Agent watches your own network from a Pi that stays on and tells PingKit on your
# iPhone when the internet goes down (about three minutes), when a new device joins, and,
# if you turn it on, when a device goes offline (up to 45 minutes at the default sweep).
# It needs 64-bit Raspberry Pi OS on a Raspberry Pi 4 or 5.
#
# What this script does, in order, and nothing else:
#   1. refuses anything but 64-bit Linux on arm64 with systemd, and refuses to run unless root
#   2. downloads the release tarball and checks its SHA-256 against the value pinned
#      below BEFORE unpacking or running anything; a mismatch stops with nothing installed
#   3. creates the system user and group pingkit-agent (no shell, no home)
#   4. installs /usr/local/lib/pingkit-agent/ (the binary and its data), the link
#      /usr/local/bin/pingkit-agent, and the systemd unit from the tarball
#   5. creates /var/lib/pingkit-agent (0700, owned by pingkit-agent): the only writable path
#   6. lets that group, and only that group, open ICMP datagram sockets
#      (/etc/sysctl.d/60-pingkit-agent.conf), unless ping is already allowed for it
#   7. writes /etc/pingkit-agent/env (0640) with the claim code, if you give one
#   8. enables and starts pingkit-agent.service and prints the status page address
#
# Automatic updates are off unless you ask for them. --enable-auto-update adds a daily
# systemd timer that runs as root, because the agent cannot write its own binary. What it runs,
# in order, and nothing else: the install script already on this Pi; curl or wget for
# latest.json and its signature; `pingkit-agent update-verify`, which checks that signature
# against the key compiled into the installed binary; and, only for a newer version, the
# download and SHA-256 check above, then tar, cp, rm, mv, ln, chmod, chown and systemctl
# for steps 4, 5 and 8. No downloaded script runs. The agent itself stays unprivileged.
#
# The release process pins PINGKIT_VERSION and PINGKIT_SHA256_AARCH64 in the copy served
# from pingkit.app and attached to each release; this repository copy holds a
# placeholder and refuses to install.
set -eu

PINGKIT_VERSION="1.0.0"
PINGKIT_SHA256_AARCH64="4ee3f1bf413f86f4a1f5e113c253f041bf9a27ecfca58f7e0a1299e3a5697b8e"
PINGKIT_RELEASE_BASE="https://github.com/pingkit/agent/releases/download"
PINGKIT_MANIFEST_URL="https://pingkit.app/agent/latest.json"

# Paths; PINGKIT_ROOT is for the script's own tests only (an empty root in production).
ROOT="${PINGKIT_ROOT:-}"
LIB_DIR="$ROOT/usr/local/lib/pingkit-agent"
BIN_LINK="$ROOT/usr/local/bin/pingkit-agent"
UNIT_FILE="$ROOT/etc/systemd/system/pingkit-agent.service"
UPDATE_SERVICE="$ROOT/etc/systemd/system/pingkit-agent-update.service"
UPDATE_TIMER="$ROOT/etc/systemd/system/pingkit-agent-update.timer"
ENV_DIR="$ROOT/etc/pingkit-agent"
ENV_FILE="$ENV_DIR/env"
STATE_DIR="$ROOT/var/lib/pingkit-agent"
SYSCTL_FILE="$ROOT/etc/sysctl.d/60-pingkit-agent.conf"
SERVICE_USER="pingkit-agent"
STATUS_PORT=7474

say() { printf '%s\n' "$*"; }
fail() { printf 'PingKit Agent: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
PingKit Agent for Raspberry Pi (64-bit Raspberry Pi OS on a Pi 4 or 5)

  install.sh [--claim-code CODE]     install and start the agent
  install.sh --update                install the version this script pins, keep settings
  install.sh --uninstall [--purge]   remove it; --purge also deletes its state and user
  install.sh --enable-auto-update    add a daily check that installs signed updates (runs as root)
  install.sh --disable-auto-update   remove that check
  install.sh --help

CODE is the 8-character code your iPhone shows under Agents > Add an Agent. Without it,
type the code on the status page (http://<this Pi>:7474/) instead.
USAGE
}

# ---- Seams: each one is a function so the tests can replace it ----------------------
pk_uname_m() { uname -m; }
pk_userland_arch() { if command -v dpkg >/dev/null 2>&1; then dpkg --print-architecture; else echo unknown; fi; }
pk_is_root() { [ "$(id -u)" = 0 ]; }
pk_has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
pk_fetch() { # URL DEST
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -O "$2" "$1"
  else
    fail "needs curl or wget to download the release"
  fi
}
pk_sha256() { # FILE -> hex
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
pk_sys() { "$@"; }           # every command that changes the system goes through here
pk_ping_range() { cat /proc/sys/net/ipv4/ping_group_range 2>/dev/null || echo "1 0"; }
pk_group_id() { getent group "$SERVICE_USER" | cut -d: -f3; }
pk_has_group() { getent group "$SERVICE_USER" >/dev/null 2>&1; }
pk_has_user() { getent passwd "$SERVICE_USER" >/dev/null 2>&1; }
pk_tty_read() { # prompt into the variable REPLY_CODE, from the terminal even under curl | sh
  REPLY_CODE=""
  if [ -r /dev/tty ] && [ -t 2 ]; then
    printf '%s' "$1" >&2
    read -r REPLY_CODE </dev/tty || REPLY_CODE=""
  fi
}
pk_address() { hostname -I 2>/dev/null | cut -d' ' -f1; }
pk_verify_manifest() { "$LIB_DIR/pingkit-agent" update-verify "$@"; } # exit 0 newer, 3 current

# ---- Checks -----------------------------------------------------------------------
check_platform() {
  machine="$(pk_uname_m)"
  case "$machine" in
    aarch64|arm64) ;;
    armv7l|armv6l|armhf)
      fail "PingKit Agent needs 64-bit Raspberry Pi OS. This system runs a 32-bit OS ($machine). Install Raspberry Pi OS (64-bit) on a Raspberry Pi 4 or 5, then run this again." ;;
    *)
      fail "PingKit Agent for Raspberry Pi needs 64-bit Raspberry Pi OS on a Raspberry Pi 4 or 5; this system is $machine. On other Linux hosts, use the Docker image (https://pingkit.app/agent/)." ;;
  esac
  userland="$(pk_userland_arch)"
  case "$userland" in
    arm64|unknown) ;;
    *) fail "PingKit Agent needs 64-bit Raspberry Pi OS. This Pi runs a 64-bit kernel with a 32-bit system ($userland). Install Raspberry Pi OS (64-bit), then run this again." ;;
  esac
  pk_has_systemd || fail "needs systemd (Raspberry Pi OS has it); this system does not run it"
}

# CODE -> normalised code on stdout, or nothing when it is not a claim code.
normalise_code() {
  code="$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -d ' -')"
  case "$code" in
    *[!0-9ABCDEFGHJKMNPQRSTVWXYZ]*|"") return 1 ;;
  esac
  [ "${#code}" -eq 8 ] || return 1
  printf '%s' "$code"
}

pinned_sum() {
  case "$PINGKIT_SHA256_AARCH64" in
    *[!0-9a-f]*|"") fail "this copy of the script has no pinned checksum, so it installs nothing. Use the copy from https://pingkit.app/agent/install.sh or from a release on github.com/pingkit/agent." ;;
  esac
  [ "${#PINGKIT_SHA256_AARCH64}" -eq 64 ] || fail "the pinned checksum is not a SHA-256; this copy of the script is damaged"
  printf '%s' "$PINGKIT_SHA256_AARCH64"
}

# Download into WORK and verify; prints the unpacked folder. Nothing outside WORK changes.
fetch_and_verify() {
  expected="$(pinned_sum)"
  name="pingkit-agent-$PINGKIT_VERSION-linux-arm64"
  url="$PINGKIT_RELEASE_BASE/v$PINGKIT_VERSION/$name.tar.gz"
  say "Downloading PingKit Agent $PINGKIT_VERSION" >&2
  pk_fetch "$url" "$WORK/$name.tar.gz" >&2 || fail "could not download $url"
  actual="$(pk_sha256 "$WORK/$name.tar.gz")"
  if [ "$actual" != "$expected" ]; then
    fail "the download's SHA-256 is $actual, not the pinned $expected. Refusing to install it; nothing was changed. Try again, and report it at https://github.com/pingkit/agent/issues if it repeats."
  fi
  say "Checksum verified ($expected)" >&2
  tar -xzf "$WORK/$name.tar.gz" -C "$WORK" || fail "the verified tarball did not unpack"
  dir="$WORK/$name"
  [ -x "$dir/pingkit-agent" ] && [ -x "$dir/swift-backtrace" ] && [ -d "$dir/PingKitCore_PingKitCore.resources" ] \
    && [ -f "$dir/pingkit-agent.service" ] \
    && [ -f "$dir/install.sh" ] && [ -f "$dir/pingkit-agent-update.service" ] && [ -f "$dir/pingkit-agent-update.timer" ] \
    || fail "the tarball is missing a file it should carry; nothing was installed"
  grep -qx "version=$PINGKIT_VERSION" "$dir/BUILD-INFO" || fail "the tarball's BUILD-INFO does not name $PINGKIT_VERSION"
  printf '%s' "$dir"
}

# ---- Steps ------------------------------------------------------------------------
create_user() {
  if ! pk_has_group; then
    pk_sys groupadd --system "$SERVICE_USER"
  fi
  if ! pk_has_user; then
    pk_sys useradd --system --gid "$SERVICE_USER" --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
}

install_files() { # DIR
  rm -rf "$LIB_DIR.new"
  mkdir -p "$LIB_DIR.new" "$(dirname "$BIN_LINK")" "$(dirname "$UNIT_FILE")"
  cp "$1/pingkit-agent" "$LIB_DIR.new/pingkit-agent"
  cp "$1/swift-backtrace" "$LIB_DIR.new/swift-backtrace"
  cp -R "$1/PingKitCore_PingKitCore.resources" "$LIB_DIR.new/"
  cp "$1/BUILD-INFO" "$LIB_DIR.new/BUILD-INFO"
  cp "$1/install.sh" "$1/pingkit-agent-update.service" "$1/pingkit-agent-update.timer" "$LIB_DIR.new/"
  chmod 0755 "$LIB_DIR.new" "$LIB_DIR.new/pingkit-agent" "$LIB_DIR.new/swift-backtrace"
  chmod 0644 "$LIB_DIR.new/install.sh" "$LIB_DIR.new/pingkit-agent-update.service" "$LIB_DIR.new/pingkit-agent-update.timer"
  chmod -R u=rwX,go=rX "$LIB_DIR.new/PingKitCore_PingKitCore.resources"
  rm -rf "$LIB_DIR"
  mv "$LIB_DIR.new" "$LIB_DIR"
  ln -sf /usr/local/lib/pingkit-agent/pingkit-agent "$BIN_LINK"
  cp "$1/pingkit-agent.service" "$UNIT_FILE"
  chmod 0644 "$UNIT_FILE"
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  pk_sys chown "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR"
}

# Allow ICMP datagram sockets for the service group. ping_group_range is one system-wide
# range: if it already covers the group, leave it; if ping sockets are off ("1 0"), allow
# exactly this group and remember the old value for --uninstall; if another range is set,
# never narrow it, and say how to add the group by hand.
configure_ping() {
  gid="$(pk_group_id)"
  [ -n "$gid" ] || { say "Could not read the $SERVICE_USER group id; ping stays off (the agent uses ARP and TCP checks)."; return 0; }
  set -- $(pk_ping_range)
  low="${1:-1}"; high="${2:-0}"
  if [ "$low" -le "$gid" ] && [ "$gid" -le "$high" ]; then
    say "Ping: already allowed for group $gid ($low $high)."
    return 0
  fi
  if [ "$low" -gt "$high" ]; then
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    {
      say "# PingKit Agent: ICMP datagram sockets (ping) for the pingkit-agent group only."
      say "# previous: $low $high"
      say "net.ipv4.ping_group_range = $gid $gid"
    } > "$SYSCTL_FILE"
    pk_sys sysctl -q -p "$SYSCTL_FILE" || say "Could not apply $SYSCTL_FILE now; it applies at the next boot."
    say "Ping: allowed for group $gid only ($SYSCTL_FILE)."
    return 0
  fi
  say "Ping: this system already sets ping_group_range to '$low $high', which leaves out group $gid."
  say "      The agent uses ARP and TCP checks instead. To add ping, widen that range to include $gid."
}

write_env() { # CODE (may be empty)
  mkdir -p "$ENV_DIR"
  if [ ! -f "$ENV_FILE" ]; then
    {
      say "# PingKit Agent settings (read by pingkit-agent.service). Every PINGKIT_ setting has a"
      say "# default; see https://pingkit.app/agent/ for the list. Restart after a change:"
      say "#   sudo systemctl restart pingkit-agent"
    } > "$ENV_FILE"
  fi
  if [ -n "$1" ]; then
    grep -v '^PINGKIT_CLAIM_CODE=' "$ENV_FILE" > "$ENV_FILE.new" || true
    say "PINGKIT_CLAIM_CODE=$1" >> "$ENV_FILE.new"
    mv "$ENV_FILE.new" "$ENV_FILE"
  fi
  chmod 0640 "$ENV_FILE"
  pk_sys chown "root:$SERVICE_USER" "$ENV_FILE"
}

start_service() { # restart|start
  pk_sys systemctl daemon-reload
  pk_sys systemctl enable pingkit-agent.service >/dev/null 2>&1 || pk_sys systemctl enable pingkit-agent.service
  pk_sys systemctl "$1" pingkit-agent.service
}

print_done() {
  address="$(pk_address)"
  [ -n "$address" ] || address="<the address of this Pi>"
  say ""
  say "PingKit Agent $PINGKIT_VERSION is running."
  say "Status page: http://$address:$STATUS_PORT/"
  say "Logs:        journalctl -u pingkit-agent -f"
}

# ---- Commands -----------------------------------------------------------------------
do_install() { # CODE
  code="$1"
  check_platform
  pk_is_root || fail "run it as root: curl -fsSL https://pingkit.app/agent/install.sh | sudo sh"
  if [ -z "$code" ] && [ ! -f "$ENV_FILE" ]; then
    pk_tty_read "Code from your iPhone (Agents > Add an Agent), or Return to type it on the status page later: "
    if [ -n "$REPLY_CODE" ]; then
      code="$(normalise_code "$REPLY_CODE")" || fail "'$REPLY_CODE' is not a claim code (8 letters and digits, no I, L, O or U)"
    fi
  fi
  dir="$(fetch_and_verify)"
  create_user
  install_files "$dir"
  configure_ping
  write_env "$code"
  start_service restart
  print_done
}

do_update() {
  check_platform
  pk_is_root || fail "run it as root: sudo sh install.sh --update"
  [ -x "$LIB_DIR/pingkit-agent" ] || fail "PingKit Agent is not installed here; run the script without --update"
  if grep -qx "version=$PINGKIT_VERSION" "$LIB_DIR/BUILD-INFO" 2>/dev/null; then
    say "PingKit Agent $PINGKIT_VERSION is already installed; nothing to do."
    return 0
  fi
  dir="$(fetch_and_verify)"
  create_user
  install_files "$dir"
  configure_ping
  start_service restart
  print_done
}

# The opt-in: copies the units the installed version carries and starts the timer. Refused
# on a build with no signing key compiled in, where the timer could only ever fail.
do_enable_auto_update() {
  pk_is_root || fail "run it as root: sudo sh install.sh --enable-auto-update"
  [ -x "$LIB_DIR/pingkit-agent" ] || fail "PingKit Agent is not installed here; install it first"
  pk_verify_manifest --key-pinned || fail "this version of PingKit Agent cannot verify updates yet; update by hand with --update"
  install_update_units
  pk_sys systemctl daemon-reload
  pk_sys systemctl enable --now pingkit-agent-update.timer
  say "Automatic updates are on: a daily check installs signed updates, as root."
  say "Turn them off with: sudo sh $LIB_DIR/install.sh --disable-auto-update"
}

install_update_units() {
  cp "$LIB_DIR/pingkit-agent-update.service" "$UPDATE_SERVICE"
  cp "$LIB_DIR/pingkit-agent-update.timer" "$UPDATE_TIMER"
  chmod 0644 "$UPDATE_SERVICE" "$UPDATE_TIMER"
}

do_disable_auto_update() {
  pk_is_root || fail "run it as root: sudo sh install.sh --disable-auto-update"
  pk_sys systemctl disable --now pingkit-agent-update.timer 2>/dev/null || true
  rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER"
  pk_sys systemctl daemon-reload 2>/dev/null || true
  say "Automatic updates are off."
}

# What the timer runs. The pins come from a manifest the installed binary has verified, never
# from a script off the network. A refusal exits non-zero with nothing changed, which the
# journal shows; "nothing newer" is success.
do_auto_update() {
  check_platform
  pk_is_root || fail "run it as root"
  [ -x "$LIB_DIR/pingkit-agent" ] || fail "PingKit Agent is not installed here"
  pk_fetch "$PINGKIT_MANIFEST_URL" "$WORK/latest.json" || fail "could not download $PINGKIT_MANIFEST_URL"
  pk_fetch "$PINGKIT_MANIFEST_URL.sig" "$WORK/latest.json.sig" || fail "could not download $PINGKIT_MANIFEST_URL.sig"
  status=0
  verdict="$(pk_verify_manifest "$WORK/latest.json" "$WORK/latest.json.sig")" || status=$?
  case "$status" in
    0) ;;
    3) say "PingKit Agent is up to date."; return 0 ;;
    *) fail "latest.json did not verify (exit $status); nothing was changed" ;;
  esac
  PINGKIT_VERSION="$(printf '%s\n' "$verdict" | sed -n 's/^version=//p')"
  PINGKIT_SHA256_AARCH64="$(printf '%s\n' "$verdict" | sed -n 's/^sha256=//p')"
  case "$PINGKIT_VERSION" in
    *[!0-9.]*|"") fail "latest.json named an unusable version; nothing was changed" ;;
  esac
  dir="$(fetch_and_verify)"
  install_files "$dir"
  if [ -f "$UPDATE_TIMER" ]; then install_update_units; fi
  start_service restart
  say "PingKit Agent $PINGKIT_VERSION is installed."
}

do_uninstall() { # PURGE(0|1)
  pk_is_root || fail "run it as root: sudo sh install.sh --uninstall"
  pk_sys systemctl disable --now pingkit-agent-update.timer 2>/dev/null || true
  pk_sys systemctl disable --now pingkit-agent.service 2>/dev/null || true
  rm -f "$UNIT_FILE" "$BIN_LINK" "$UPDATE_SERVICE" "$UPDATE_TIMER"
  rm -rf "$LIB_DIR" "$ENV_DIR"
  pk_sys systemctl daemon-reload 2>/dev/null || true
  if [ -f "$SYSCTL_FILE" ]; then
    previous="$(sed -n 's/^# previous: //p' "$SYSCTL_FILE")"
    rm -f "$SYSCTL_FILE"
    [ -n "$previous" ] && pk_sys sysctl -q -w "net.ipv4.ping_group_range=$previous" || true
  fi
  if [ "$1" = 1 ]; then
    rm -rf "$STATE_DIR"
    pk_sys userdel "$SERVICE_USER" 2>/dev/null || true
    pk_sys groupdel "$SERVICE_USER" 2>/dev/null || true
    say "PingKit Agent, its state and its user are removed."
  else
    say "PingKit Agent is removed. Its state is kept in /var/lib/pingkit-agent and its user"
    say "pingkit-agent remains; --uninstall --purge removes both."
  fi
}

main() {
  mode=install
  code=""
  purge=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --claim-code|--claim)
        [ "$#" -ge 2 ] || fail "$1 needs the code from your iPhone"
        code="$(normalise_code "$2")" || fail "'$2' is not a claim code (8 letters and digits, no I, L, O or U)"
        shift 2 ;;
      --claim-code=*|--claim=*)
        value="${1#*=}"
        code="$(normalise_code "$value")" || fail "'$value' is not a claim code (8 letters and digits, no I, L, O or U)"
        shift ;;
      --update) [ "$mode" = install ] || fail "choose one of --update and --uninstall"; mode=update; shift ;;
      --uninstall) [ "$mode" = install ] || fail "choose one of --update and --uninstall"; mode=uninstall; shift ;;
      --enable-auto-update) [ "$mode" = install ] || fail "choose one action"; mode=enable-auto-update; shift ;;
      --disable-auto-update) [ "$mode" = install ] || fail "choose one action"; mode=disable-auto-update; shift ;;
      --auto-update) [ "$mode" = install ] || fail "choose one action"; mode=auto-update; shift ;;
      --purge) purge=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; printf 'PingKit Agent: unknown option %s\n' "$1" >&2; exit 64 ;;
    esac
  done
  [ "$purge" = 0 ] || [ "$mode" = uninstall ] || fail "--purge goes with --uninstall"
  [ -z "$code" ] || [ "$mode" = install ] || fail "--claim-code goes with an install, not --$mode"

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT INT TERM
  case "$mode" in
    install) do_install "$code" ;;
    update) do_update ;;
    uninstall) do_uninstall "$purge" ;;
    enable-auto-update) do_enable_auto_update ;;
    disable-auto-update) do_disable_auto_update ;;
    auto-update) do_auto_update ;;
  esac
}

# The tests source this file with PINGKIT_INSTALL_SOURCED=1 to replace the seams.
if [ "${PINGKIT_INSTALL_SOURCED:-0}" != 1 ]; then
  main "$@"
fi
