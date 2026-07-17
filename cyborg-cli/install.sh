#!/bin/sh
# Cyborg CLI installer — downloads the self-contained bundle and writes a launcher.
#
#   curl -fsSL https://raw.githubusercontent.com/Cyborg7-com/cyborg7-releases/main/cyborg-cli/install.sh | sh
#
# Layout: launcher at ~/.local/bin/cyborg, app at ~/.local/share/cyborg-cli/app.
# The bundle ships its OWN Node runtime (app/node), so NO system Node is required
# and the native-module ABI always matches — headless agent hosts just work.
#
# Releases live in the PUBLIC cyborg7-releases repo. This file is mirrored there
# at cyborg-cli/install.sh — source of truth is packages/cli/scripts/install/.
set -eu

REPO="Cyborg7-com/cyborg7-releases"
VERSION="${1:-latest}"
BIN_DIR="${CYBORG_INSTALL_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${CYBORG_INSTALL_APP_DIR:-$HOME/.local/share/cyborg-cli}"
SKIP_PATH_UPDATE="${CYBORG_INSTALL_SKIP_PATH_UPDATE:-0}"
# The systemd unit provisioned below (CYBORG-81) so the headless daemon auto-starts
# on boot and self-heals on crash. Opt out with CYBORG_SKIP_SYSTEMD=1.
UNIT_NAME="cyborg7-daemon"
SKIP_SYSTEMD="${CYBORG_SKIP_SYSTEMD:-0}"
# Set to 1 once the unit is installed AND enabled, so the closing message reports
# systemd management instead of the manual-start hint (a bare `command -v systemctl`
# is not enough: systemd can be present yet the user manager unreachable / enable fail).
SYSTEMD_PROVISIONED=0

step() { printf '==> %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "need curl or wget"
  fi
}

command -v tar >/dev/null 2>&1 || die "tar is required but not found"

# Platform/arch — the bundle is platform-specific (native deps).
os="$(uname -s)"
case "$os" in
  Linux) platform="linux" ;;
  Darwin) platform="darwin" ;;
  *) die "unsupported OS: $os" ;;
esac
machine="$(uname -m)"
case "$machine" in
  aarch64 | arm64) arch="arm64" ;;
  x86_64 | amd64) arch="x64" ;;
  *) die "unsupported arch: $machine" ;;
esac

# Resolve the latest cyborg-cli-v* release. The release repo also hosts frequent
# desktop/mobile releases, so we read the pinned version from version.txt rather
# than paging the releases API. Pin an exact version by passing it as arg 1.
resolve_version() {
  case "$VERSION" in
    latest | stable | "")
      ver="$(download "https://raw.githubusercontent.com/$REPO/main/cyborg-cli/version.txt" /dev/stdout 2>/dev/null | tr -d '[:space:]')"
      [ -n "$ver" ] || die "could not resolve the latest cyborg-cli release"
      printf '%s\n' "$ver"
      ;;
    v*) printf '%s\n' "${VERSION#v}" ;;
    *) printf '%s\n' "$VERSION" ;;
  esac
}

resolved="$(resolve_version)"
archive="cyborg-cli-${resolved}-${platform}-${arch}.tar.gz"
base_url="${CYBORG_INSTALL_BASE_URL:-https://github.com/$REPO/releases/download/cyborg-cli-v${resolved}}"
url="$base_url/$archive"

step "Installing Cyborg CLI ${resolved} (${platform}-${arch})"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step "Downloading $archive"
download "$url" "$tmp/$archive"

step "Extracting to $APP_DIR"
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/app"
tar -xzf "$tmp/$archive" -C "$APP_DIR"
[ -f "$APP_DIR/app/dist/cyborg.js" ] || die "bundle missing app/dist/cyborg.js"
[ -x "$APP_DIR/app/node/bin/node" ] || die "bundle missing app/node/bin/node"

step "Writing launcher to $BIN_DIR/cyborg"
mkdir -p "$BIN_DIR"
# Export CYBORG7_DOCS_DIR so the daemon's cyborg7_read_docs MCP tool finds the
# bundled Markdown corpus. @cyborg7/docs-lib's walk-up would also resolve it
# (the corpus ships at app/packages/docs/src/content/docs), but pinning it here
# is deterministic and survives any node_modules hoist-layout change. The daemon
# spawned by `cyborg daemon start` inherits this env from the launcher.
cat >"$BIN_DIR/cyborg" <<EOF
#!/bin/sh
export CYBORG7_DOCS_DIR="\${CYBORG7_DOCS_DIR:-$APP_DIR/app/packages/docs/src/content/docs}"
# Export CYBORG7_SOURCE_DIR so the daemon's cyborg7_read_source MCP tool finds the
# bundled read-only source snapshot. The tool is git-checkout-gated by default and
# this bundle has no .git, so without this it would never register (CYBORG-85);
# @cyborg7/docs-lib trusts this override without requiring .git. The repo-scoped
# path guard + secret denylist still apply to every read under it.
export CYBORG7_SOURCE_DIR="\${CYBORG7_SOURCE_DIR:-$APP_DIR/app/source-snapshot}"
exec "$APP_DIR/app/node/bin/node" "$APP_DIR/app/dist/cyborg.js" "\$@"
EOF
chmod +x "$BIN_DIR/cyborg"

# Render the systemd unit body. $1 = ABSOLUTE launcher path, $2 = WantedBy target.
# The executable is double-quoted so a path containing spaces (e.g. a custom
# CYBORG_INSTALL_BIN_DIR under "Application Support") still parses — systemd requires
# an absolute ExecStart and treats an unquoted space as an argument separator. The
# ExecStart MUST pass `daemon start --replace` so that a later update reaps the old
# daemon instead of no-opping (a plain `daemon start` sees "already running" and
# exits, leaving the stale build serving); `--foreground` hands the process
# lifecycle to systemd (Type=simple). Restart=on-failure + the StartLimit* pair
# trip a crash-looping daemon to a visible `failed` state instead of hammering
# restarts (mirrors the relay unit's guardrails).
render_unit() {
  cat <<EOF
[Unit]
Description=Cyborg7 headless daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart="$1" daemon start --replace --foreground
Restart=on-failure
RestartSec=5

[Install]
WantedBy=$2
EOF
}

# Provision (create/update + enable) the systemd unit so the headless daemon starts
# on boot and restarts on crash. Prefers USER scope (no root needed); uses SYSTEM
# scope only when the installer runs as root. Idempotent: a byte-identical unit is a
# no-op; a drifted one is rewritten + daemon-reloaded. Degrades gracefully (prints a
# manual-start hint) when systemd isn't available — e.g. a container without an init.
provision_systemd_unit() {
  [ "$SKIP_SYSTEMD" = "1" ] && return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    step "systemd not detected — skipping unit install (daemon won't auto-start on boot)."
    step "Start it manually with:  cyborg daemon start --foreground"
    return 0
  fi

  # systemd requires an ABSOLUTE ExecStart path. BIN_DIR defaults to an absolute
  # $HOME/.local/bin, but a custom CYBORG_INSTALL_BIN_DIR may be relative — resolve
  # it so the unit is valid regardless. realpath/readlink first, then a $PWD anchor.
  launcher="$BIN_DIR/cyborg"
  if command -v realpath >/dev/null 2>&1; then
    launcher="$(realpath "$launcher" 2>/dev/null || printf '%s' "$launcher")"
  elif command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$launcher" 2>/dev/null || true)"
    [ -n "$resolved" ] && launcher="$resolved"
  fi
  case "$launcher" in
    /*) ;;
    *) launcher="$(pwd)/$launcher" ;;
  esac

  uid="$(id -u 2>/dev/null || echo 1000)"

  if [ "$uid" = "0" ]; then
    scope="system"
    unit_dir="/etc/systemd/system"
    wanted="multi-user.target"
  else
    scope="user"
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    wanted="default.target"
    # A per-user manager must be reachable (it is NOT in a bare container, a
    # `docker exec` without a user bus, or a non-interactive session with no
    # DBUS_SESSION_BUS_ADDRESS). Probe defensively and fall back GRACEFULLY to the
    # manual hint — never leave a half-enabled unit or fail the install. is-system-
    # running answers whenever the manager is reachable (even in a `degraded` state);
    # show-environment is the fallback probe when that subcommand is unavailable.
    if ! systemctl --user is-system-running >/dev/null 2>&1 \
      && ! systemctl --user show-environment >/dev/null 2>&1; then
      step "systemd user manager not reachable — skipping unit install."
      step "Start it manually with:  cyborg daemon start --foreground"
      return 0
    fi
  fi

  unit_path="$unit_dir/${UNIT_NAME}.service"
  desired="$(render_unit "$launcher" "$wanted")"

  if [ -f "$unit_path" ] && [ "$(cat "$unit_path" 2>/dev/null)" = "$desired" ]; then
    step "systemd unit already up to date ($unit_path)"
  else
    step "Installing systemd unit ($scope scope) at $unit_path"
    mkdir -p "$unit_dir" 2>/dev/null || true
    printf '%s\n' "$desired" >"$unit_path" 2>/dev/null || { step "Could not write $unit_path — skipping unit install (run: cyborg daemon start --foreground)."; return 0; }
  fi

  # Resolve the username defensively, same care as the UID above (`id` can be absent
  # or fail in a minimal image) — used for the enable-linger hint/call.
  user_name="$(id -un 2>/dev/null || printf '%s' "${USER:-${LOGNAME:-$uid}}")"

  if [ "$scope" = "user" ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    # enable-linger so the user service starts at boot without an active login. Needs
    # privilege on most distros; best-effort, non-fatal (the daemon still starts on
    # login, and auto-restarts, without it).
    loginctl enable-linger "$user_name" >/dev/null 2>&1 \
      || step "note: enable linger for boot-start:  sudo loginctl enable-linger $user_name"
    if systemctl --user enable --now "${UNIT_NAME}.service" >/dev/null 2>&1; then
      SYSTEMD_PROVISIONED=1
      step "Enabled + started $UNIT_NAME (systemctl --user)"
    else
      step "Could not enable the unit — start it with:  systemctl --user start $UNIT_NAME"
    fi
  else
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable --now "${UNIT_NAME}.service" >/dev/null 2>&1; then
      SYSTEMD_PROVISIONED=1
      step "Enabled + started $UNIT_NAME (system scope)"
    else
      step "Could not enable the unit — start it with:  systemctl start $UNIT_NAME"
    fi
  fi
}

# Apply the update to a RUNNING daemon — otherwise the new bundle just sits on disk
# while the old process keeps serving (the "I updated but nothing changed" bug). Skip
# with CYBORG_SKIP_RESTART=1. Best-effort: a restart failure never fails the install.
if [ "${CYBORG_SKIP_RESTART:-0}" != "1" ] && "$BIN_DIR/cyborg" daemon status >/dev/null 2>&1; then
  step "Restarting the running daemon to apply the update"
  if command -v systemctl >/dev/null 2>&1 && { systemctl is-active --quiet cyborg7-daemon || systemctl --user is-active --quiet cyborg7-daemon; } 2>/dev/null; then
    # systemd-managed: the unit's ExecStart must pass `cyborg daemon start --replace`
    # so a restart reaps the stale build instead of no-opping. Units written BEFORE
    # the flag existed don't have it, which made `systemctl restart` a silent no-op
    # (`daemon start` saw "already running" and exited) — the old build kept serving
    # and the user still needed a MANUAL `cyborg daemon restart` after every update.
    # MIGRATE such units in place (idempotent: only touches an ExecStart that runs
    # `cyborg daemon start` without --replace; scoped to this unit file, so a
    # coexisting genuine-Paseo daemon is never affected), then daemon-reload.
    migrate_unit() { # $1 = unit file path, $2 = optional command prefix ("sudo -n")
      [ -n "$1" ] && [ -f "$1" ] || return 1
      grep -qE '^ExecStart=.*cyborg daemon start' "$1" || return 1
      grep -qE '^ExecStart=.*--replace' "$1" && return 1
      ${2:-} sed -i '/^ExecStart=.*cyborg daemon start/ s/[[:space:]]*$/ --replace/' "$1" 2>/dev/null || return 1
      step "Migrated systemd unit to 'daemon start --replace' (updates now apply without manual restarts)"
    }
    if systemctl is-active --quiet cyborg7-daemon 2>/dev/null; then
      UNIT_PATH=$(systemctl show -p FragmentPath --value cyborg7-daemon 2>/dev/null)
      migrate_unit "$UNIT_PATH" "sudo -n" && sudo -n systemctl daemon-reload 2>/dev/null
    elif systemctl --user is-active --quiet cyborg7-daemon 2>/dev/null; then
      UNIT_PATH=$(systemctl --user show -p FragmentPath --value cyborg7-daemon 2>/dev/null)
      migrate_unit "$UNIT_PATH" && systemctl --user daemon-reload 2>/dev/null
    fi
    { sudo -n systemctl restart cyborg7-daemon 2>/dev/null \
      || systemctl --user restart cyborg7-daemon 2>/dev/null \
      || "$BIN_DIR/cyborg" daemon restart --force 2>/dev/null; } \
      || step "Could not auto-restart — run: cyborg daemon restart"
  else
    "$BIN_DIR/cyborg" daemon restart --force 2>/dev/null \
      || step "Could not auto-restart — run: cyborg daemon restart"
  fi
fi

# Provision the systemd unit so the daemon auto-starts on boot and self-heals on
# crash. Runs AFTER the update-restart above: on an update the running daemon was
# already cycled to the new build; here we only ensure the unit exists (installing
# it on a first-time host) and enable it. `enable --now` starts the daemon on a
# fresh install where nothing was running yet (the restart block was skipped). The
# ExecStart's `--replace` makes systemd take over any daemon started by hand.
provision_systemd_unit

case ":$PATH:" in
  *":$BIN_DIR:"*) on_path=1 ;;
  *) on_path=0 ;;
esac
if [ "$on_path" = "0" ] && [ "$SKIP_PATH_UPDATE" != "1" ]; then
  case "${SHELL:-}" in
    *zsh) profile="$HOME/.zshrc" ;;
    *bash) profile="$HOME/.bashrc" ;;
    *) profile="$HOME/.profile" ;;
  esac
  line="export PATH=\"$BIN_DIR:\$PATH\""
  if [ ! -f "$profile" ] || ! grep -Fq "$line" "$profile" 2>/dev/null; then
    printf '\n# Added by cyborg installer\n%s\n' "$line" >>"$profile"
    step "Added $BIN_DIR to PATH in $profile"
  fi
fi

step "Done. Restart your shell (or run: export PATH=\"$BIN_DIR:\$PATH\")"
if [ "$SYSTEMD_PROVISIONED" = "1" ]; then
  step "The headless daemon is managed by systemd ($UNIT_NAME) — it auto-starts on boot."
  step "Check it with:  systemctl --user status $UNIT_NAME   (or 'systemctl status' when installed as root)"
else
  step "Then run a headless agent host with:  cyborg daemon start --foreground"
fi
