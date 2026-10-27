#!/usr/bin/env bash
# Assemble, ad-hoc sign, and package the macOS release artifacts.
#
# macOS bundles are NOT signed with a Developer ID and are NOT notarized. The
# workflow imports no Apple certificate, and no Apple secret is read. Every
# staged binary is still re-signed ad-hoc (codesign -s -) for two reasons:
# install_name_tool breaks the Mach-O linker signature, and arm64 refuses to
# execute an unsigned Mach-O.
#
# Ad-hoc signatures do not satisfy Gatekeeper. Users see "cannot be opened
# because Apple cannot check it" and must right-click Open, or clear the
# quarantine attribute. The installer pkg is likewise unsigned.
#
# The zip and pkg names are the ones a Developer ID build would produce, so the
# release manifest in .github/actions/publish-github-release/manifests stays
# satisfied and the Homebrew asset names do not change. What was actually
# applied is recorded in <base>.signing-status.txt and
# <base>.codesign-summary.txt, so a release never claims to be signed when it
# is not.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# shellcheck source=scripts/macos-bundle-tools.sh
source "$script_dir/macos-bundle-tools.sh"

usage() {
  cat <<'EOF'
Usage: scripts/package-macos-bundle.sh [--print-plan]

Environment:
  RELEASE_TAG                  release tag or CI version (required)
  MACOS_ARCH                   arm64 or intel (default: host architecture)
  IS_RELEASE                   true for a final release (selects the Homebrew
                               asset copies; it does not enable signing)

REQUEST_NOTARIZE, HAS_APPLE_SECRET, HAS_NOTARIZE_SECRETS, HAS_INSTALLER_SECRET,
APP_SIGNING_IDENTITY, INSTALLER_SIGNING_IDENTITY, APPLE_NOTARIZE_USERNAME,
APPLE_NOTARIZE_PASSWORD and APPLE_TEAM_ID are accepted and ignored. They are
kept so older callers do not break; nothing in this script signs with a
Developer ID or talks to notarytool.

--print-plan prints the derived mode and artifact names without touching the
filesystem. It is useful for debugging the release inputs and for tests.
EOF
}

die() {
  echo "package-macos-bundle: $*" >&2
  exit 1
}

print_plan=false
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 1
fi
case "${1:-}" in
  '') ;;
  --print-plan) print_plan=true ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
esac

release_tag=${RELEASE_TAG:-}
[ -n "$release_tag" ] || die "RELEASE_TAG is required"

macos_arch=${MACOS_ARCH:-}
if [ -z "$macos_arch" ]; then
  case "$(uname -m)" in
    arm64) macos_arch=arm64 ;;
    x86_64) macos_arch=intel ;;
    *) die "Unsupported macOS architecture: $(uname -m)" ;;
  esac
fi
case "$macos_arch" in
  arm64|intel) ;;
  *) die "MACOS_ARCH must be arm64 or intel, got: $macos_arch" ;;
esac

is_release=${IS_RELEASE:-false}

# One mode only. There is no Developer ID and no notarization path any more, so
# a release can never be blocked by missing Apple credentials.
mode=adhoc
bundle_status="ad-hoc signed (no Developer ID; codesign -s - after install_name_tool); not notarized"
pkg_status="unsigned (no Developer ID Installer); not notarized; not for distribution"

# Deliberately identical to the Developer ID build names: the release manifest
# and the Homebrew asset names must not change just because signing is gone.
base_name="chikvdf-${release_tag}-macos-${macos_arch}"
asset_name="${base_name}.zip"
pkg_name="${base_name}.pkg"

if [ "$print_plan" = true ]; then
  printf 'mode=%s\n' "$mode"
  printf 'asset_name=%s\n' "$asset_name"
  printf 'pkg_name=%s\n' "$pkg_name"
  printf 'bundle_status=%s\n' "$bundle_status"
  printf 'pkg_status=%s\n' "$pkg_status"
  exit 0
fi

cd "$repo_root"

bundle_root="dist/macos/${base_name}"
bin_dir="${bundle_root}/bin"
libexec_dir="${bundle_root}/libexec/chikvdf"
mkdir -p "$bin_dir" "$libexec_dir"

for tool in "${MACOS_BUNDLE_TOOLS[@]}"; do
  cp "src/$tool" "$bin_dir/"
done

# FTDI and Homebrew GMP share one libexec directory. The staging script rewrites
# install names and the executable rpath in one install_name_tool pass, before
# the codesign pass below.
scripts/stage-macos-bundle-dylibs.sh "$bin_dir" "$libexec_dir"

dylib_files=()
for dylib in "$libexec_dir"/*; do
  if [ -L "$dylib" ] || [ ! -f "$dylib" ]; then
    continue
  fi
  dylib_files+=("$dylib")
done
if [ "${#dylib_files[@]}" -eq 0 ]; then
  die "No dylibs staged into ${libexec_dir}"
fi

sign_targets=()
for exe in "$bin_dir/"*; do
  if [ ! -f "$exe" ] || [ -L "$exe" ]; then
    die "Unexpected bundle entry: $exe"
  fi
  sign_targets+=("$exe")
done
for dylib in "${dylib_files[@]}"; do
  sign_targets+=("$dylib")
done

# install_name_tool breaks the linker signature. arm64 will not execute that
# Mach-O until it is signed again. There is no Developer ID, so re-sign ad-hoc.
for target in "${sign_targets[@]}"; do
  codesign -s - --force "$target"
done

# Record what was applied. The release manifest requires this file, so it must
# exist even though nothing carries a Developer ID signature.
codesign_summary_path="dist/macos/${base_name}.codesign-summary.txt"
: > "$codesign_summary_path"
printf "codesign -dv summary for %s (ad-hoc signed; no Developer ID)\n\n" "$base_name" >> "$codesign_summary_path"
echo "codesign -dv summary (ad-hoc):"
for target in "${sign_targets[@]}"; do
  printf "==== %s ====\n" "$target" | tee -a "$codesign_summary_path"
  codesign -dv "$target" 2>&1 |
    grep -E '^(Identifier=|Format=|CodeDirectory v=|Signature=|Authority=|TeamIdentifier=|Timestamp=)' |
    tee -a "$codesign_summary_path"
  echo | tee -a "$codesign_summary_path"
done

(cd dist/macos && ditto -c -k --keepParent "$base_name" "$asset_name")
# Launch the zip that will be published. A binary that still carries a Homebrew
# absolute path fails library validation only on a user's machine, never here.
scripts/verify-macos-bundle.sh "dist/macos/${asset_name}"

# Build the installer package from the same staged tree the zip was verified
# from. Installer writes payload files without the quarantine attribute, so
# first launch needs no Gatekeeper lookup. No installer identity is passed, so
# package-macos-pkg.sh produces an unsigned package.
pkg_path="dist/macos/${pkg_name}"
scripts/package-macos-pkg.sh "$bundle_root" "$pkg_path" "$release_tag" ""

status_path="dist/macos/${base_name}.signing-status.txt"
{
  printf "macOS %s release bundle status: %s\n" "$macos_arch" "$bundle_status"
  printf "macOS %s installer package status: %s\n" "$macos_arch" "$pkg_status"
} > "$status_path"

shasum -a 256 "dist/macos/${asset_name}" | awk '{print $1}' > "dist/macos/${asset_name}.sha256"
shasum -a 256 "$pkg_path" | awk '{print $1}' > "${pkg_path}.sha256"

if [ "$is_release" = true ]; then
  if [ "$macos_arch" = arm64 ]; then
    brew_arch=arm64
  else
    brew_arch=amd64
  fi
  brew_asset_name="chikvdf-darwin-${brew_arch}.zip"
  cp "dist/macos/${asset_name}" "dist/macos/${brew_asset_name}"
  cp "dist/macos/${asset_name}.sha256" "dist/macos/${brew_asset_name}.sha256"
fi

cat "$status_path"
