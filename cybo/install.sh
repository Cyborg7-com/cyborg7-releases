#!/bin/sh
# cybo installer — downloads the self-contained bundle and writes a launcher.
#
#   curl -fsSL https://raw.githubusercontent.com/Cyborg7-com/cyborg7-releases/main/cybo/install.sh | sh
#
# Layout (feynman-style): launcher at ~/.local/bin/cybo, app at
# ~/.local/share/cybo/app. Only system Node 20+ is required (PI is bundled).
#
# Releases live in the PUBLIC cyborg7-releases repo (the private source repo's
# assets aren't reachable unauthenticated). This file is mirrored there at
# cybo/install.sh — source of truth is packages/cybo-runner/scripts/install/.
set -eu

REPO="Cyborg7-com/cyborg7-releases"
VERSION="${1:-latest}"
BIN_DIR="${CYBO_INSTALL_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${CYBO_INSTALL_APP_DIR:-$HOME/.local/share/cybo}"
SKIP_PATH_UPDATE="${CYBO_INSTALL_SKIP_PATH_UPDATE:-0}"

step() { printf '==> %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found"; }

download() {
  # download <url> <out>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "need curl or wget"
  fi
}

require tar
require node

# Node >= 20.19 (PI's floor; also covers import.meta APIs)
node_ok="$(node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.stdout.write(a>20||(a===20&&b>=19)?"1":"0")' 2>/dev/null || echo 0)"
[ "$node_ok" = "1" ] || die "Node 20.19+ required (found: $(node -v 2>/dev/null || echo none))"

# Resolve the latest cybo-v* release tag (the repo also ships non-cybo releases,
# so we can't use /releases/latest). Pin an exact version by passing it as arg 1.
resolve_version() {
  case "$VERSION" in
    latest|stable|"")
      # The release repo also hosts frequent desktop releases, so scanning the
      # releases API for the newest cybo-v* would page off. Each cybo release
      # pins the current version in cybo/version.txt on the default branch.
      ver="$(download "https://raw.githubusercontent.com/$REPO/main/cybo/version.txt" /dev/stdout 2>/dev/null | tr -d '[:space:]')"
      [ -n "$ver" ] || die "could not resolve the latest cybo release"
      printf '%s\n' "$ver"
      ;;
    v*) printf '%s\n' "${VERSION#v}" ;;
    *) printf '%s\n' "$VERSION" ;;
  esac
}

resolved="$(resolve_version)"
archive="cybo-${resolved}.tar.gz"
base_url="${CYBO_INSTALL_BASE_URL:-https://github.com/$REPO/releases/download/cybo-v${resolved}}"
url="$base_url/$archive"

step "Installing cybo ${resolved}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step "Downloading $archive"
download "$url" "$tmp/$archive"

step "Extracting to $APP_DIR"
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/app"
tar -xzf "$tmp/$archive" -C "$APP_DIR"
[ -f "$APP_DIR/app/cybo.mjs" ] || die "bundle missing app/cybo.mjs"

step "Writing launcher to $BIN_DIR/cybo"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/cybo" <<EOF
#!/bin/sh
exec node "$APP_DIR/app/cybo.mjs" "\$@"
EOF
chmod +x "$BIN_DIR/cybo"

# Ensure BIN_DIR is on PATH for future shells.
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
    printf '\n# Added by cybo installer\n%s\n' "$line" >>"$profile"
    step "Added $BIN_DIR to PATH in $profile"
  fi
fi

step "Done. Restart your shell (or run: export PATH=\"$BIN_DIR:\$PATH\")"
step "Then: cybo doctor   (sign in to PI once with: cybo config)"
