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
cat >"$BIN_DIR/cyborg" <<EOF
#!/bin/sh
exec "$APP_DIR/app/node/bin/node" "$APP_DIR/app/dist/cyborg.js" "\$@"
EOF
chmod +x "$BIN_DIR/cyborg"

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
