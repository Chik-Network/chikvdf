#!/usr/bin/env bash
# Exercises the macOS artifact-name derivation without macOS tools.
#
# macOS bundles are not signed with a Developer ID and not notarized. This test
# pins that decision, the artifact names the release manifest requires, and the
# fact that legacy signing inputs are accepted but ignored.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
script="${root}/scripts/package-macos-bundle.sh"
manifest="${root}/.github/actions/publish-github-release/manifests/chikvdf.txt"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_plan() {
  env -i PATH="$PATH" \
    MACOS_ARCH=arm64 \
    RELEASE_TAG=v1.2.3 \
    "$@" \
    bash "$script" --print-plan
}

assert_has() {
  local output="$1" want="$2" desc="$3"
  printf '%s\n' "$output" | grep -Fxq "$want" || fail "$desc: missing [$want] in [$output]"
}

# The release manifest is written with a {tag} placeholder, so compare in that
# form. A name that is not listed there would make publish-release refuse to
# upload anything.
assert_in_manifest() {
  local name="$1" desc="$2" expected
  expected=$(printf '%s\n' "$name" | sed 's/v1\.2\.3/{tag}/')
  grep -Fxq "$expected" "$manifest" || fail "$desc: $expected is not in the release manifest"
}

unsigned_status="ad-hoc signed (no Developer ID; codesign -s - after install_name_tool); not notarized"
pkg_status="unsigned (no Developer ID Installer); not notarized; not for distribution"

# A normal push: ad-hoc, and the names already match the release manifest.
output="$(run_plan)"
assert_has "$output" "mode=adhoc" "default build is ad-hoc"
assert_has "$output" "asset_name=chikvdf-v1.2.3-macos-arm64.zip" "zip name carries no -unsigned suffix"
assert_has "$output" "pkg_name=chikvdf-v1.2.3-macos-arm64.pkg" "pkg name carries no -unsigned suffix"
assert_has "$output" "bundle_status=${unsigned_status}" "bundle status says ad-hoc"
assert_has "$output" "pkg_status=${pkg_status}" "pkg status says unsigned"
assert_in_manifest "chikvdf-v1.2.3-macos-arm64.zip" "zip name"
assert_in_manifest "chikvdf-v1.2.3-macos-arm64.pkg" "pkg name"
echo "ok: default build is ad-hoc and release-named"

# A final release with no Apple credentials at all must not fail. This is the
# case that used to die with "Release/notarized builds require Apple signing
# certificate secrets" and block the whole release.
output="$(run_plan IS_RELEASE=true REQUEST_NOTARIZE=true)"
assert_has "$output" "mode=adhoc" "final release without secrets stays ad-hoc"
assert_has "$output" "asset_name=chikvdf-v1.2.3-macos-arm64.zip" "final release keeps the release zip name"
assert_has "$output" "pkg_name=chikvdf-v1.2.3-macos-arm64.pkg" "final release keeps the release pkg name"
echo "ok: final release no longer requires Apple credentials"

# Legacy signing inputs are still accepted so older callers do not break, but
# they must not change the mode or the artifact names.
output="$(run_plan \
  IS_RELEASE=true \
  REQUEST_NOTARIZE=true \
  HAS_APPLE_SECRET=true \
  HAS_INSTALLER_SECRET=true \
  HAS_NOTARIZE_SECRETS=true \
  APP_SIGNING_IDENTITY=app-hash \
  INSTALLER_SIGNING_IDENTITY=installer-name \
  APPLE_NOTARIZE_USERNAME=user \
  APPLE_NOTARIZE_PASSWORD=pass \
  APPLE_TEAM_ID=TEAM123)"
assert_has "$output" "mode=adhoc" "legacy signing inputs are ignored"
assert_has "$output" "bundle_status=${unsigned_status}" "legacy inputs do not claim a Developer ID signature"
assert_has "$output" "pkg_status=${pkg_status}" "legacy inputs do not claim a signed package"
echo "ok: legacy signing inputs are ignored"

# The script must not resurrect a notarization or Developer ID path.
if grep -Fq 'xcrun notarytool' "$script"; then
  fail "macOS packaging still calls notarytool"
fi
if grep -Fq 'codesign --force --timestamp --options runtime --sign' "$script"; then
  fail "macOS packaging still signs with a Developer ID identity"
fi
if grep -Fq 'spctl -a' "$script"; then
  fail "macOS packaging still gatekeeper-assesses a notarized package"
fi
echo "ok: no Developer ID or notarization code path"

echo "macOS bundle release plan checks passed"
