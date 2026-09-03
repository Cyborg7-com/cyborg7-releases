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

# Render the systemd unit body. $1 = ABSOLUTE launcher path, $2 = WantedBy target,
# $3 = ABSOLUTE operator env-file path.
# The executable is double-quoted so a path containing spaces (e.g. a custom
# CYBORG_INSTALL_BIN_DIR under "Application Support") still parses — systemd requires
# an absolute ExecStart and treats an unquoted space as an argument separator. The
# ExecStart MUST pass `daemon start --replace` so that a later update reaps the old
# daemon instead of no-opping (a plain `daemon start` sees "already running" and
# exits, leaving the stale build serving); `--foreground` hands the process
# lifecycle to systemd (Type=simple). Restart=on-failure + the StartLimit* pair
# trip a crash-looping daemon to a visible `failed` state instead of hammering
# restarts (mirrors the relay unit's guardrails).
#
# EnvironmentFile (CYBORG-871) is how an operator gives the daemon secrets — chiefly
# CYBORG7_CRED_KEY, the credential-store master key, whose whole point is to live
# somewhere other than the folder it decrypts. It CANNOT be an `Environment=` line
# here: provision_systemd_unit byte-compares this rendered text against the on-disk
# unit and rewrites any difference, so a hand-added `Environment=` was silently
# deleted by the next `install.sh` run — and the daemon then came up with no key.
# The referenced file is created once by ensure_daemon_env_file and NEVER rewritten,
# so it survives every update. The `-` prefix marks it optional: a deleted file
# leaves the unit starting normally rather than failing to load. Left unquoted on
# purpose — systemd's quote handling for a prefixed path is not worth relying on,
# and a path with a space degrades to "optional file not found" (the daemon still
# starts) instead of an ExecStart-style hard parse failure.
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
EnvironmentFile=-$3
ExecStart="$1" daemon start --replace --foreground
Restart=on-failure
RestartSec=5

[Install]
WantedBy=$2
EOF
}

# Create the operator-owned env file ONCE, 0600, and never touch it again. $1 = path.
# This installer manages the unit; it deliberately does not manage this file, which is
# the entire reason a secret put here survives an update.
ensure_daemon_env_file() {
  [ -f "$1" ] && return 0
  mkdir -p "${1%/*}" 2>/dev/null || true
  # Create empty first, then tighten, then fill: the window where the mode is still
  # the default holds no bytes.
  : >"$1" 2>/dev/null || return 0
  chmod 600 "$1" 2>/dev/null || true
  cat >>"$1" <<'ENVEOF' || true
# Cyborg7 daemon environment — read by the cyborg7-daemon systemd unit.
# The installer creates this file once and NEVER rewrites it, so anything set here
# survives a `cyborg` update. One KEY=VALUE per line, no `export`, no quoting.
#
# CYBORG7_CRED_KEY: base64 of 32 random bytes (`openssl rand -base64 32`). Moves the
# credential-store master key out of ~/.cyborg7 entirely (CYBORG-921 already moved it
# off ~/.cyborg7/credentials, so it no longer sits beside the ciphertext it opens),
# so an offline copy of that folder (a backup, a synced drive) does not carry it. It
# defends against nothing that already runs as this user. THERE IS NO ROTATION:
# lose this value and every stored provider credential plus the persisted terminal
# scrollback stays sealed forever — the daemon refuses and says so rather than
# quietly minting a new key over them.
# CYBORG7_CRED_KEY=
ENVEOF
  step "Created $1 (0600) for daemon secrets — it is never overwritten by an update"
}

# Provision (create/update + enable) the systemd unit so the headless daemon starts
# on boot and restarts on crash. Prefers USER scope (no root needed); uses SYSTEM
# scope only when the installer runs as root. Idempotent: a byte-identical unit is a
# no-op; a drifted one is rewritten + daemon-reloaded. Degrades gracefully (prints a
# manual-start hint) when systemd isn't available — e.g. a container without an init.
# Does a unit of our name exist in the given scope, per systemd itself? Answers
# false when systemctl is absent or cannot reach that scope's manager — the caller
# falls back to a plain file test, so an unreachable user bus never blocks a
# legitimate system-scope install.
systemctl_other_scope_has_unit() {
  command -v systemctl >/dev/null 2>&1 || return 1
  if [ "$1" = "user" ]; then
    systemctl --user cat "${UNIT_NAME}.service" >/dev/null 2>&1
  else
    systemctl cat "${UNIT_NAME}.service" >/dev/null 2>&1
  fi
}

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
    env_file="/etc/cyborg7/daemon.env"
  else
    scope="user"
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    wanted="default.target"
    env_file="${XDG_CONFIG_HOME:-$HOME/.config}/cyborg7/daemon.env"
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

  # GUARD 1 — never add a rival unit in the other systemd scope.
  #
  # Scope is chosen from `id -u` alone, so the same host provisioned twice under
  # different UIDs gets TWO units with the SAME name in two namespaces. That is
  # never benign. The generated unit passes no --home, so it falls back to
  # DEFAULT_PASEO_HOME (~/.cyborg7) and the port comes from that home's
  # config.json:
  #   • different homes  → split state: two SQLite DBs, two server-ids, two relay
  #     enrollments, and a phantom extra daemon in the workspace.
  #   • the SAME home    → `--replace` is strictly per-home, so both units resolve
  #     the same pid lock and each restart reaps the other. A permanent kill loop.
  # Measured on a real host: a root-authored system unit from 2026-07-02 and an
  # installer-provisioned user unit from 2026-07-16 ran side by side for 48 days,
  # invisible because `systemctl status` without `--user` reports only one of them.
  #
  # The rest of this script already knows both scopes exist — the restart probe,
  # migrate_unit and the restart itself all check system AND user. Only the
  # provisioner did not; it was written a week after the both-scopes lesson landed
  # and did not carry it over. Adopt what is there and say so.
  if [ "$scope" = "system" ]; then
    other_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${UNIT_NAME}.service"
    other_scope="user"
  else
    other_unit="/etc/systemd/system/${UNIT_NAME}.service"
    other_scope="system"
  fi
  # `systemctl cat` also sees /usr/lib and /run units and honours a non-default
  # unit path; the -f test is the fallback when systemctl cannot answer.
  if systemctl_other_scope_has_unit "$other_scope" || [ -f "$other_unit" ]; then
    step "A $UNIT_NAME unit already exists in the $other_scope scope — leaving it in charge."
    step "Installing a second one would split daemon state (separate home, port and identity)."
    step "To switch scopes: disable and remove the $other_scope unit first, then re-run this installer."
    SYSTEMD_PROVISIONED=1
    return 0
  fi

  # GUARD 2 — an UPDATE must not create a unit that did not exist a second ago.
  #
  # `cyborg daemon update` runs this script with CYBORG_SKIP_RESTART=1, which
  # skips the restart block below but NOT this function. On a host whose daemon is
  # managed some other way (a hand-written unit, a container, a bare
  # `daemon start --foreground`), a routine update would silently gain an enabled
  # systemd unit nobody asked for. Refreshing one we already own stays allowed —
  # that is how a template change (e.g. the EnvironmentFile line, CYBORG-871)
  # reaches existing installs.
  if [ "${CYBORG_SKIP_RESTART:-0}" = "1" ] && [ ! -f "$unit_path" ]; then
    step "Update: no existing $UNIT_NAME unit in the $scope scope — not creating one."
    return 0
  fi

  # Before the unit, so the file the unit references already exists on a fresh host.
  ensure_daemon_env_file "$env_file"
  desired="$(render_unit "$launcher" "$wanted" "$env_file")"

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
  restart_hint="systemctl --user restart $UNIT_NAME"
else
  step "Then run a headless agent host with:  cyborg daemon start --foreground"
  restart_hint="cyborg daemon restart"
fi

# An installed, RUNNING daemon is still invisible to every workspace until it is
# CLAIMED: `cyborg daemon claim` writes daemon-owner + cyborg-relay-url, and the
# daemon resolves its relay ONCE at boot — so a daemon already started (by systemd
# above, or by hand) must be restarted after claiming. Printing the sequence here
# is the difference between "it just works" and a support thread: the installer
# used to end at "start the daemon", which is exactly where people stopped.
printf '\n'
step "Next — connect this machine to your workspace:"
step "  1. cyborg login --email you@example.com"
step "  2. cyborg daemon claim        # attaches this daemon to your account"
step "  3. $restart_hint   # the relay is resolved at boot"
step "  4. cyborg daemon doctor       # verify: online + claimed"
printf '\n'
step "Until it is claimed the daemon runs, but does NOT appear in any workspace."
step "Full guide: https://docs.cyborg7.com/how-to/add-a-daemon/"
