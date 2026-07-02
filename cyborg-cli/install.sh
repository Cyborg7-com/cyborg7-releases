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
exec "$APP_DIR/app/node/bin/node" "$APP_DIR/app/dist/cyborg.js" "\$@"
EOF
chmod +x "$BIN_DIR/cyborg"

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
step "Then run a headless agent host with:  cyborg daemon start --foreground"
