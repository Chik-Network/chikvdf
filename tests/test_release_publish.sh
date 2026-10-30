#!/usr/bin/env bash
# Truth table for release policy and the single GitHub publish path.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
policy="${root}/.github/actions/release-policy/policy.sh"
publish="${root}/.github/actions/publish-github-release/publish.sh"
manifest_dir="${root}/.github/actions/publish-github-release/manifests"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_policy() {
  local out
  out=$(mktemp)
  EVENT_NAME=$1 \
    EVENT_ACTION=$2 \
    PRERELEASE_JSON=$3 \
    MACOS_NOTARIZE_JSON=$4 \
    GITHUB_OUTPUT=$out \
    bash "$policy"
  cat "$out"
  rm -f "$out"
}

assert_policy() {
  local label=$1 expected_final=$2 expected_notarize=$3
  shift 3
  local out
  out=$(run_policy "$@")
  got_final=$(printf '%s\n' "$out" | awk -F= '$1 == "is_final" { print $2 }')
  got_notarize=$(printf '%s\n' "$out" | awk -F= '$1 == "notarize_macos" { print $2 }')
  if [ "$got_final" != "$expected_final" ] || [ "$got_notarize" != "$expected_notarize" ]; then
    fail "${label}: expected final=${expected_final} notarize=${expected_notarize}, got final=${got_final} notarize=${got_notarize}"
  fi
}

assert_policy "final release" true true release published false null
assert_policy "prerelease" false false release published true null
assert_policy "missing prerelease flag" false false release published null null
assert_policy "string false is not boolean false" false false release published '"false"' null
assert_policy "release edited" false false release edited false null
assert_policy "push" false false push "" null null
assert_policy "dispatch notarizes" false true workflow_dispatch workflow_dispatch null true
assert_policy "dispatch string true" false true workflow_dispatch workflow_dispatch null '"true"'
assert_policy "dispatch boolean false" false false workflow_dispatch workflow_dispatch null false

tag=1.2.3
assets=$(mktemp -d)
calls=$(mktemp)
output=$(mktemp)
gh_bin=$(mktemp -d)
cat > "${gh_bin}/gh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
exit "${GH_EXIT:-0}"
EOF
chmod +x "${gh_bin}/gh"

asset_names=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}
  line=${line//[[:space:]]/}
  [ -z "$line" ] && continue
  asset_names+=("${line//\{tag\}/$tag}")
done < <(cat "${manifest_dir}/chikvdf.txt" "${manifest_dir}/chikvdfc.txt")

write_tree() {
  local dest=$1
  rm -rf "$dest"
  mkdir -p "$dest/debian" "$dest/macos" "$dest/windows" "$dest/c"
  local name payload
  for name in "${asset_names[@]}"; do
    case "$name" in
      *.sha256) continue ;;
    esac
    case "$name" in
      *.deb) payload="${dest}/debian/${name}" ;;
      chikvdfc-*) payload="${dest}/c/${name}" ;;
      *windows*|*win64*) payload="${dest}/windows/${name}" ;;
      *) payload="${dest}/macos/${name}" ;;
    esac
    printf 'asset %s\n' "$name" > "$payload"
  done
  for name in "${asset_names[@]}"; do
    case "$name" in
      *.sha256)
        payload=${name%.sha256}
        find "$dest" -type f -name "$payload" -exec sha256sum {} \; | awk '{print $1}' > "${dest}/macos/${name}"
        # Windows sidecars live next to their zip. Keep one copy; basename search allows either directory.
        if [[ "$name" == *windows* || "$name" == *win64* ]]; then
          mv "${dest}/macos/${name}" "${dest}/windows/${name}"
        fi
        ;;
    esac
  done
}

run_publish() {
  local final=$1 manifests=$2 dir=$3
  : > "$calls"
  : > "$output"
  set +e
  IS_FINAL=$final \
    RELEASE_TAG=$tag \
    ASSETS_DIR=$dir \
    MANIFESTS=$manifests \
    GITHUB_OUTPUT=$output \
    GH_CALLS=$calls \
    GH_EXIT=${GH_EXIT:-0} \
    PATH="${gh_bin}:${PATH}" \
    bash "$publish"
  status=$?
  set -e
}

assert_no_gh() {
  if [ -s "$calls" ]; then
    fail "$1: gh was invoked: $(cat "$calls")"
  fi
}

write_tree "$assets"
run_publish false "chikvdf,chikvdfc" "$assets"
if [ "$status" -ne 0 ]; then
  fail "prerelease publish should skip, status ${status}"
fi
assert_no_gh "prerelease"
if [ "$(awk -F= '$1 == "published" { print $2 }' "$output")" != "false" ]; then
  fail "prerelease should record published=false"
fi

run_publish "" "chikvdf,chikvdfc" "$assets"
if [ "$status" -ne 0 ]; then
  fail "empty IS_FINAL should skip, status ${status}"
fi
assert_no_gh "ambiguous release"

run_publish true "chikvdf,chikvdfc" "$assets"
if [ "$status" -ne 0 ]; then
  fail "final publish failed with status ${status}"
fi
if [ "$(wc -l < "$calls")" -ne 1 ]; then
  fail "final publish should call gh once, got: $(cat "$calls")"
fi
if ! grep -q -- '--clobber' "$calls"; then
  fail "final publish did not pass --clobber: $(cat "$calls")"
fi
if ! grep -q -- "release upload --clobber ${tag} " "$calls"; then
  fail "final publish did not target ${tag}: $(cat "$calls")"
fi
for name in "${asset_names[@]}"; do
  if ! grep -F -q -- "/${name}" "$calls" && ! grep -F -q -- " ${name}" "$calls"; then
    fail "uploaded set is missing ${name}"
  fi
done
if ! grep -qx 'published=true' "$output"; then
  fail "final publish did not record published=true: $(cat "$output")"
fi

# Re-run after a successful upload still clobbers. The script has no memory of the first call.
run_publish true "chikvdf,chikvdfc" "$assets"
if [ "$status" -ne 0 ] || ! grep -q -- '--clobber' "$calls"; then
  fail "re-run should upload again with --clobber"
fi

# One missing C library archive blocks the client assets too.
rm -f "${assets}/c/"chikvdfc-windows-intel.zip
run_publish true "chikvdf,chikvdfc" "$assets"
if [ "$status" -eq 0 ]; then
  fail "missing asset should fail the publish"
fi
assert_no_gh "missing asset"

# A bad digest fails before gh, same as a missing file.
write_tree "$assets"
printf 'deadbeef\n' > "${assets}/windows/chikvdf-win64.zip.sha256"
run_publish true "chikvdf,chikvdfc" "$assets"
if [ "$status" -eq 0 ]; then
  fail "bad sha256 should fail the publish"
fi
assert_no_gh "bad sha256"

# Two copies of a required basename are ambiguous.
write_tree "$assets"
cp "${assets}/windows/chikvdf-win64.zip" "${assets}/debian/chikvdf-win64.zip"
run_publish true "chikvdf,chikvdfc" "$assets"
if [ "$status" -eq 0 ]; then
  fail "duplicate basename should fail the publish"
fi
assert_no_gh "duplicate basename"

# Unsafe tags never reach gh.
write_tree "$assets"
: > "$calls"
: > "$output"
set +e
IS_FINAL=true RELEASE_TAG='1.2.3;rm' ASSETS_DIR=$assets MANIFESTS='chikvdf,chikvdfc' \
  GITHUB_OUTPUT=$output GH_CALLS=$calls \
  PATH="${gh_bin}:${PATH}" bash "$publish"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail "unsafe tag should fail"
fi
assert_no_gh "unsafe tag"

# gh failing mid-upload does not record a successful publish.
write_tree "$assets"
: > "$calls"
: > "$output"
set +e
IS_FINAL=true RELEASE_TAG=$tag ASSETS_DIR=$assets MANIFESTS='chikvdf,chikvdfc' \
  GITHUB_OUTPUT=$output GH_CALLS=$calls GH_EXIT=1 \
  PATH="${gh_bin}:${PATH}" bash "$publish"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail "gh failure should fail the publish"
fi
if grep -q '^published=true$' "$output"; then
  fail "gh failure should not record published=true"
fi

job_field() {
  local file=$1 job=$2 key=$3
  awk -v job="  ${job}:" -v key="$key" '
    $0 == job { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_.-]+:/ { exit }
    in_job && $0 ~ ("^[[:space:]]+" key ":") {
      sub("^[[:space:]]+" key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$file"
}

job_block() {
  local file=$1 job=$2
  awk -v job="  ${job}:" '
    $0 == job { in_job = 1; print; next }
    in_job && /^  [A-Za-z0-9_.-]+:/ { exit }
    in_job { print }
  ' "$file"
}

# publish-release waits on the jobs that produce or validate release assets.
# ASAN/TSAN stay in their own matrix and are not part of that set.
# shellcheck disable=SC2016
assert_publish_dependencies() {
  packages="${root}/.github/workflows/build-packages.yml"
  client="${root}/.github/workflows/build-client.yml"

  needs=$(job_field "$packages" publish-release needs)
  if [ "$needs" != "[release-policy, package, c-libraries, release-publish-checks]" ]; then
    fail "publish-release needs ${needs:-<missing>}"
  fi

  publish_block=$(job_block "$packages" publish-release)
  if ! printf '%s\n' "$publish_block" | grep -q "needs.package.result == 'success'"; then
    fail "publish-release does not require the package job"
  fi
  if printf '%s\n' "$publish_block" | grep -Eq 'needs\.(sanitize|build)(\.|[[:space:]])'; then
    fail "publish-release still depends on a sanitizer or mixed build job"
  fi

  pkg_configs=$(job_field "$packages" package configs)
  san_configs=$(job_field "$packages" sanitize configs)
  if [ "$pkg_configs" != "'[\"optimized=1\"]'" ]; then
    fail "package configs are ${pkg_configs:-<missing>}"
  fi
  case "$san_configs" in
    *TSAN=1*) ;;
    *) fail "sanitize configs missing TSAN: ${san_configs:-<missing>}" ;;
  esac
  case "$san_configs" in
    *ASAN=1*) ;;
    *) fail "sanitize configs missing ASAN: ${san_configs:-<missing>}" ;;
  esac
  case "$san_configs" in
    *optimized=1*) fail "sanitize configs include the packaging build" ;;
  esac

  for job in package sanitize; do
    uses=$(job_field "$packages" "$job" uses)
    if [ "$uses" != "./.github/workflows/build-client.yml" ]; then
      fail "${job} does not call the client matrix workflow: ${uses:-<missing>}"
    fi
    if printf '%s\n' "$(job_block "$packages" "$job")" | grep -q '^    if:'; then
      fail "${job} filters matrix entries with a job if"
    fi
  done

  if ! grep -q 'is_final: ${{ steps.policy.outputs.is_final }}' "$packages"; then
    fail "release-policy output is_final was renamed"
  fi
  if ! grep -q 'is_final: ${{ needs.release-policy.outputs.is_final }}' "$packages"; then
    fail "package does not pass needs.release-policy.outputs.is_final"
  fi
  if grep -q 'sign_windows\|windows_sign' "$packages" "$client"; then
    fail "Windows signing is still gated by sign_windows/windows_sign"
  fi

  if grep -q 'config: \[optimized=1, TSAN=1, ASAN=1\]' "$packages" "$client"; then
    fail "artifact and sanitizer configs share one matrix"
  fi
  if ! grep -q 'config: ${{ fromJSON(inputs.configs) }}' "$client"; then
    fail "client matrix is not selected by the caller"
  fi
}

# shellcheck disable=SC2016
assert_windows_packaging_wiring() {
  client="${root}/.github/workflows/build-client.yml"
  packages="${root}/.github/workflows/build-packages.yml"
  script="${root}/scripts/package-windows-bundle.ps1"
  installer_script="${root}/scripts/windows-installer.ps1"
  driver_script="${root}/scripts/get-libft4222.ps1"
  ftdi_script="${root}/scripts/windows-ftdi-driver.ps1"
  installer="${root}/installer/windows/chikvdf.iss"
  inno_action="${root}/.github/actions/install-inno-setup/action.yml"
  win_job=package-windows
  build_block="$(job_block "$client" build)"
  win_block="$(job_block "$client" "$win_job")"
  publish_block="$(job_block "$packages" publish-release)"

  if [ -z "$win_block" ]; then
    fail "Windows packaging job ${win_job} is missing"
  fi
  # Windows bundles and installers are unsigned: no signing environment, no OIDC
  # token, and therefore no reason to skip pull requests.
  if [ -n "$(job_field "$client" "$win_job" environment)" ]; then
    fail "Windows packaging job still enters a signing environment"
  fi
  if [ -n "$(job_field "$client" "$win_job" id-token)" ]; then
    fail "Windows packaging job still requests id-token"
  fi
  if [ "$(job_field "$client" "$win_job" needs)" != "[build]" ]; then
    fail "Windows packaging job does not need the build job"
  fi
  if [ "$(job_field "$client" "$win_job" if)" != "contains(inputs.configs, 'optimized=1')" ]; then
    fail "Windows packaging job is not tied to optimized builds on every event"
  fi
  if [ "$(job_field "$client" "$win_job" runs-on)" != "windows-latest" ]; then
    fail "Windows packaging job does not run on windows-latest"
  fi
  if [ "$(job_field "$client" "$win_job" timeout-minutes)" != "30" ]; then
    fail "Windows packaging job does not have a bounded timeout"
  fi
  if [ "$(job_field "$client" "$win_job" contents)" != "read" ]; then
    fail "Windows packaging job does not limit contents permission to read"
  fi

  if ! printf '%s\n' "$build_block" | grep -Fq 'name: windows-amd64-binaries'; then
    fail "build job does not upload windows-amd64-binaries"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq 'name: windows-amd64-binaries'; then
    fail "sign job does not download windows-amd64-binaries"
  fi
  if printf '%s\n' "$build_block" | grep -Fq 'name: windows-amd64-bundle'; then
    fail "build job uploads the Windows bundle itself"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq 'name: windows-amd64-bundle'; then
    fail "packaging job does not upload windows-amd64-bundle"
  fi
  # The packaging job must say it is unsigned rather than rely on a default.
  if ! printf '%s\n' "$win_block" | grep -Fq "REQUIRE_SIGNATURES: 'false'"; then
    fail "Windows packaging does not declare that signatures are not verified"
  fi
  if printf '%s\n' "$win_block" | grep -Fq "REQUIRE_SIGNATURES: 'true'"; then
    fail "Windows packaging still requires signature verification"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq 'IS_RELEASE: ${{ inputs.is_final }}'; then
    fail "Windows packaging does not read inputs.is_final"
  fi
  if printf '%s\n' "$win_block" | grep -Fq 'sign/azure-windows'; then
    fail "Windows packaging still calls the Azure Windows signing action"
  fi
  if printf '%s\n' "$win_block" | grep -Fq 'sign_files'; then
    fail "Windows packaging still produces a signing file list"
  fi
  if printf '%s\n' "$win_block" | grep -Fq 'ListInstallerSignFile'; then
    fail "Windows packaging still lists the installer with ListInstallerSignFile"
  fi
  if printf '%s\n' "$win_block" | grep -Fq -- '-Action ListSignFiles'; then
    fail "Windows packaging still lists signing files with ListSignFiles"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq -- '-Action BuildInstaller'; then
    fail "Windows packaging does not build the installer"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq -- '-Action FinalizeInstaller'; then
    fail "Windows packaging does not finalize the installer"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq -- '-Action VerifyInstaller'; then
    fail "Windows packaging does not verify the installer"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq -- '-Action TestInstaller'; then
    fail "Windows signing does not smoke-test the installer"
  fi
  if grep -Fq 'choco install innosetup' "$client" "$inno_action"; then
    fail "Windows workflow still installs Inno Setup with Chocolatey"
  fi
  if ! grep -Fq 'innosetup-6.7.3.exe' "$inno_action" ||
    ! grep -Fq '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732' "$inno_action" ||
    ! grep -Fq 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe' "$inno_action"; then
    fail "Inno Setup action does not pin the official 6.7.3 installer and its SHA-256"
  fi
  if [ "$(printf '%s\n' "$win_block" | grep -Fc 'uses: ./.github/actions/install-inno-setup')" -ne 1 ]; then
    fail "Inno Setup is not installed exactly once in the Windows packaging job"
  fi
  if grep -Fq 'Get-ChildItem -Path (Join-Path $base' "$client"; then
    fail "Windows workflow still has the redundant ISCC lookup loop"
  fi
  if printf '%s\n' "$win_block" | grep -Fq 'INSTALLER_SIGTOOL'; then
    fail "Windows packaging still passes an installer SignTool to ISCC"
  fi
  build_line=$(printf '%s\n' "$win_block" | grep -n -F 'name: Build Windows installer' | cut -d: -f1)
  finalize_line=$(printf '%s\n' "$win_block" | grep -n -F 'name: Finalize Windows installer' | cut -d: -f1)
  verify_line=$(printf '%s\n' "$win_block" | grep -n -F 'name: Verify Windows installer' | cut -d: -f1)
  if [ -z "$build_line" ] || [ -z "$finalize_line" ] || [ -z "$verify_line" ] ||
    [ "$build_line" -ge "$finalize_line" ] || [ "$finalize_line" -ge "$verify_line" ]; then
    fail "Windows installer build/finalize/verify steps are out of order"
  fi
  if ! printf '%s\n' "$build_block" | grep -Fq 'src/hw/libft4222/driver/**'; then
    fail "Windows build artifact does not upload the staged FTDI driver"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq 'src/hw/libft4222/driver/ftdibus.inf'; then
    fail "Windows packaging does not verify the staged FTDI driver"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq 'tests/test_windows_installer_version.ps1'; then
    fail "Windows packaging job does not run the installer version regression test"
  fi
  if ! printf '%s\n' "$win_block" | grep -Fq 'step-security/msvc-dev-cmd@v1.13.1'; then
    fail "Windows packaging job does not set up the MSVC environment"
  fi
  if grep -Fq 'ilammy/msvc-dev-cmd' "$client"; then
    fail "Windows workflow still uses ilammy/msvc-dev-cmd"
  fi
  if printf '%s\n' "$win_block" | grep -Eq 'EXPECTED_SIGNER_SUBJECT|EXPECTED_SIGNER_THUMBPRINT|EXPECTED_VENDOR_SUBJECT'; then
    fail "Windows packaging pins expected signer identities without signing"
  fi
  if grep -Fq 'AZURE_SIGNING' "$client" "$packages"; then
    fail "workflows still reference Azure signing secrets"
  fi
  if ! printf '%s\n' "$publish_block" | grep -Fq 'pattern: windows-amd64-bundle'; then
    fail "publish-release does not download windows-amd64-bundle"
  fi

  if ! grep -Fq "ValidateSet('Assemble', 'ListSignFiles', 'Package', 'BuildInstaller', 'FinalizeInstaller', 'VerifyInstaller', 'TestInstaller')" "$script"; then
    fail "Windows script does not expose the installer actions"
  fi
  if grep -Fq 'ListInstallerSignFile' "$script" "$installer_script" "$client"; then
    fail "ListInstallerSignFile is still present"
  fi
  for ps_file in "$script" "$installer_script"; do
    lines=$(wc -l < "$ps_file")
    if [ "$lines" -ge 1000 ]; then
      fail "$(basename "$ps_file") has $lines lines (limit is 999)"
    fi
  done
  if ! grep -Fq 'ftdibus.inf' "$installer" || ! grep -Fq 'pnputil.exe' "$installer"; then
    fail "Inno Setup script does not stage the FTDI driver"
  fi
  if ! grep -Fq 'DisableDirPage=auto' "$installer"; then
    fail "Inno Setup script does not use DisableDirPage=auto"
  fi
  if ! grep -Fq 'SignedUninstaller=yes' "$installer" ||
    ! grep -Fq 'SignTool={#MySignTool}' "$installer"; then
    fail "Inno Setup script does not enable a signed uninstaller"
  fi
  if grep -Fq 'DefaultGroupName=' "$installer" ||
    grep -Fq 'RestartIfNeededByRun' "$installer" ||
    grep -Fq 'PrivilegesRequiredOverridesAllowed=' "$installer"; then
    fail "Inno Setup script still has directives that do nothing"
  fi
  if ! grep -Fq 'UninstallDisplayName=chikvdf' "$installer" ||
    grep -Eq 'UninstallDisplayName=chikvdf \{#' "$installer"; then
    fail "Inno Setup uninstall display name still contains the version"
  fi
  # Installer behaviour is covered by compiling and running the .iss under a
  # real Inno Setup, not by grepping its Pascal source in this test.
  if ! grep -Fq 'Install-Ftd2xxDriver' "$driver_script" ||
    ! grep -Fq 'windows-ftdi-driver.ps1' "$driver_script" ||
    ! grep -Fq 'Assert-FtdiDriverSource' "$driver_script"; then
    fail "FT4222 fetch script does not use the shared FTDI driver validator"
  fi
  if ! grep -Fq 'windows-ftdi-driver.ps1' "$script" ||
    ! grep -Fq 'Assert-FtdiDriverSource' "$installer_script"; then
    fail "Windows packaging does not use the shared FTDI driver validator"
  fi
  if ! grep -Fq 'Microsoft Windows Hardware Compatibility Publisher' "$ftdi_script" ||
    grep -Fq 'EXPECTED_VENDOR_SUBJECT' "$ftdi_script" ||
    grep -Fq 'Microsoft|FTDI|Future Technology' "$ftdi_script"; then
    fail "FTDI catalog signer check is not pinned to the exact publisher CN"
  fi
  if ! grep -Fq 'Assert-Authenticode -Path' "$installer_script" ||
    grep -Fq 'Assert-InstallerSignature' "$installer_script"; then
    fail "Installer signature verification does not reuse Assert-Authenticode"
  fi
  if ! grep -Fq 'Publish-ReleaseAlias' "$script" ||
    ! grep -Fq 'Publish-ReleaseAlias' "$installer_script" ||
    grep -Fq 'Publish-InstallerAlias' "$installer_script"; then
    fail "Installer alias publishing does not reuse the shared alias helper"
  fi
  if ! grep -Fq "Require-Text 'INSTALLER_SIGNTOOL'" "$installer_script" ||
    ! grep -Fq '/SChikSignTool=' "$installer_script"; then
    fail "Installer build does not pass the workflow SignTool to ISCC"
  fi
  if ! grep -Fq '/DRIVER=1' "$installer_script" ||
    ! grep -Fq '/enum-drivers' "$installer_script" ||
    ! grep -Fq 'Get-MachinePathEntryCount' "$installer_script"; then
    fail "Installer smoke test does not exercise the driver, driver store, and PATH dedupe"
  fi
  if ! grep -Fq 'if ($env:CI)' "$installer_script" ||
    ! grep -Fq 'must run elevated in CI' "$installer_script"; then
    fail "Installer smoke test does not fail when non-elevated in CI"
  fi
  if ! grep -Fq "Require-Flag 'REQUIRE_SIGNATURES'" "$script"; then
    fail "Windows script does not require REQUIRE_SIGNATURES for Package"
  fi
  if ! grep -Fq 'Get-AuthenticodeSignature' "$script"; then
    fail "Windows script does not verify publisher signatures"
  fi
  if ! grep -Fq 'TimeStamperCertificate' "$script"; then
    fail "Windows script does not require a signature timestamp"
  fi
  if ! grep -Fq 'EXPECTED_SIGNER_SUBJECT' "$script" ||
    ! grep -Fq 'EXPECTED_SIGNER_THUMBPRINT' "$script" ||
    ! grep -Fq 'EXPECTED_VENDOR_SUBJECT' "$script"; then
    fail "Windows script does not support expected signer variables"
  fi
  if grep -Fq 'REQUEST_WINDOWS_SIGNING' "$script" || grep -Fq 'HAS_WINDOWS_SIGNING_SECRET' "$script"; then
    fail "Windows script still references the old DigiCert signing flags"
  fi
  if grep -Fq "ValidateSet('Assemble', 'Sign', 'Package')" "$script"; then
    fail "Windows script still exposes the removed local Sign action"
  fi
  if grep -E 'REQUIRE_SIGNATURES:|IS_RELEASE:' "$client" | grep -q 'github.event_name'; then
    fail "signing or IS_RELEASE still keys off github.event_name"
  fi
  if grep -Eq 'SM_(API_KEY|CLIENT_CERT_FILE_B64|CODE_SIGNING_CERT_SHA1_HASH|CERTKEY_ALIAS)' "$client"; then
    fail "client workflow still references DigiCert SM_* secrets"
  fi
  for asset in \
    'chikvdf-{tag}-windows-amd64-setup.exe' \
    'chikvdf-{tag}-windows-amd64-setup.exe.sha256' \
    'chikvdf-win64-setup.exe' \
    'chikvdf-win64-setup.exe.sha256'; do
    if ! grep -Fq "$asset" "${manifest_dir}/chikvdf.txt"; then
      fail "release manifest is missing ${asset}"
    fi
  done
}

# macOS bundles are neither Developer ID signed nor notarized. The packaging
# script owns that decision; this pins the workflow side so the certificate
# imports and the Apple secrets cannot come back unnoticed.
# shellcheck disable=SC2016
assert_macos_packaging_wiring() {
  client="${root}/.github/workflows/build-client.yml"
  script="${root}/scripts/package-macos-bundle.sh"

  if grep -Fq 'import-codesign-certs' "$client"; then
    fail "client workflow still imports Apple signing certificates"
  fi
  if grep -Eq 'APPLE_DEV_ID_APP|APPLE_DEV_ID_INSTALLER|APPLE_NOTARIZE_(USERNAME|PASSWORD)|APPLE_TEAM_ID' "$client"; then
    fail "client workflow still reads Apple signing secrets"
  fi
  if grep -Fq 'scripts/select-macos-signing-identities.sh' "$client"; then
    fail "client workflow still selects Apple signing identities"
  fi
  if grep -Eq 'HAS_APPLE_SECRET|HAS_INSTALLER_SECRET|HAS_NOTARIZE_SECRETS' "$client"; then
    fail "client workflow still gates macOS packaging on Apple secret presence"
  fi

  if grep -Fq 'xcrun notarytool' "$script"; then
    fail "macOS packaging still calls notarytool"
  fi
  if ! grep -Fxq 'mode=adhoc' "$script"; then
    fail "macOS packaging does not pin a single ad-hoc mode"
  fi
  # A release used to die here when the Apple secrets were absent, which blocked
  # publish-release. That gate must not return.
  if grep -Fq 'Release/notarized builds require' "$script"; then
    fail "macOS packaging still refuses a release build without Apple secrets"
  fi
}

# Publishing depends only on the GitHub token. The release path used to require
# a GLUE_URL and die without it, which blocked releases whenever the
# GLUE_API_URL secret was absent. Every publish check above now runs with no
# GLUE_URL in the environment at all.
# shellcheck disable=SC2016
assert_no_glue_wiring() {
  local action="${root}/.github/actions/publish-github-release/action.yml"
  local publish_sh="${root}/.github/actions/publish-github-release/publish.sh"
  local packages_yml="${root}/.github/workflows/build-packages.yml"

  if grep -Fqi 'glue' "$publish_sh"; then
    fail "publish.sh still references glue"
  fi
  if grep -Fqi 'glue' "$action"; then
    fail "publish action still declares or calls glue"
  fi
  if grep -Fqi 'glue' "$packages_yml"; then
    fail "build-packages.yml still passes a glue URL"
  fi
}

# A ctest case whose executable the workflow never builds fails on exactly one
# platform: Windows runs ctest against the full build tree (BUILD_HW_TOOLS=ON),
# while the Ubuntu regression step reconfigure with BUILD_HW_TOOLS=OFF and never
# registers the HW tests. That asymmetry is how a missing build target ships
# green on three OSes and red on Windows.
# shellcheck disable=SC2016
assert_ci_build_targets() {
  local client="${root}/.github/workflows/build-client.yml"
  local cmake="${root}/src/CMakeLists.txt"
  local win_build target

  win_build=$(grep -F 'cmake --build build --target' "$client" | head -1)
  if [ -z "$win_build" ]; then
    fail "Windows job does not build with cmake --build build --target"
  fi
  for target in $(grep -oE 'add_test\(NAME regression\.[A-Za-z0-9_.]+ COMMAND [A-Za-z0-9_]+' "$cmake" |
    awk '{print $NF}'); do
    case " $win_build " in
      *" $target "*) ;;
      *) fail "CMake registers a regression test for ${target}, but the Windows job never builds it" ;;
    esac
  done
}

assert_publish_dependencies
assert_windows_packaging_wiring
assert_macos_packaging_wiring
assert_no_glue_wiring
assert_ci_build_targets

rm -rf "$assets" "$gh_bin"
rm -f "$calls" "$output"
echo "release publish checks passed"
