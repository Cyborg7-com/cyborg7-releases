# cybo installer (Windows) — downloads the self-contained bundle and writes a launcher.
#
#   irm https://raw.githubusercontent.com/Cyborg7-com/cyborg7-releases/main/cybo/install.ps1 | iex
#
# Requires system Node 20+ (PI is bundled). Installs to %LOCALAPPDATA%\cybo.
# Releases live in the PUBLIC cyborg7-releases repo; this file is mirrored there
# at cybo/install.ps1 (source of truth: packages/cybo-runner/scripts/install/).
param([string]$Version = "latest")
$ErrorActionPreference = "Stop"

$Repo   = "Cyborg7-com/cyborg7-releases"
$BinDir = if ($env:CYBO_INSTALL_BIN_DIR) { $env:CYBO_INSTALL_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "cybo\bin" }
$AppDir = if ($env:CYBO_INSTALL_APP_DIR) { $env:CYBO_INSTALL_APP_DIR } else { Join-Path $env:LOCALAPPDATA "cybo" }

function Step($m) { Write-Host "==> $m" }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node 20.19+ is required" }
$nodeOk = & node -e "const [a,b]=process.versions.node.split('.').map(Number); process.stdout.write(a>20||(a===20&&b>=19)?'1':'0')"
if ($nodeOk -ne "1") { throw "Node 20.19+ required (found $(& node -v))" }

# The release repo also hosts frequent desktop releases, so scanning the API for
# the newest cybo-v* would page off. Each release pins the version in
# cybo/version.txt on the default branch. Pin an exact one with -Version.
function Resolve-Version {
  switch -Regex ($Version) {
    '^(latest|stable|)$' {
      $ver = (Invoke-RestMethod "https://raw.githubusercontent.com/$Repo/main/cybo/version.txt").ToString().Trim()
      if (-not $ver) { throw "could not resolve the latest cybo release" }
      return $ver
    }
    '^v' { return $Version.TrimStart('v') }
    default { return $Version }
  }
}

$resolved = Resolve-Version
$archive  = "cybo-$resolved.tar.gz"
$baseUrl  = if ($env:CYBO_INSTALL_BASE_URL) { $env:CYBO_INSTALL_BASE_URL } else { "https://github.com/$Repo/releases/download/cybo-v$resolved" }

Step "Installing cybo $resolved"
$tmp = Join-Path $env:TEMP "cybo-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  Step "Downloading $archive"
  Invoke-WebRequest "$baseUrl/$archive" -OutFile (Join-Path $tmp $archive)

  Step "Extracting to $AppDir"
  if (Test-Path (Join-Path $AppDir "app")) { Remove-Item -Recurse -Force (Join-Path $AppDir "app") }
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  & tar -xzf (Join-Path $tmp $archive) -C $AppDir
  if (-not (Test-Path (Join-Path $AppDir "app\cybo.mjs"))) { throw "bundle missing app\cybo.mjs" }

  Step "Writing launcher to $BinDir\cybo.cmd"
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  "@echo off`r`nnode `"$AppDir\app\cybo.mjs`" %*" | Set-Content -Encoding ASCII (Join-Path $BinDir "cybo.cmd")

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $paths = if ($userPath) { $userPath -split ';' } else { @() }
  if ($paths -notcontains $BinDir) {
    $newPath = if ($userPath) { "$BinDir;$userPath" } else { $BinDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Step "Added $BinDir to your user PATH (restart your terminal)"
  }
  Step "Done. Then: cybo doctor   (sign in to PI once with: cybo config)"
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
