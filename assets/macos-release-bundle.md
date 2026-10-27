# macOS release bundles and installer packages

> **Status: unsigned.** Bundles are ad-hoc signed (`codesign -s -`) and the
> installer package is unsigned. There is no Developer ID identity and no
> notarization: the workflow imports no Apple certificate and reads no Apple
> secret, so a release can no longer fail on missing credentials.
>
> User impact: Gatekeeper reports that the app "cannot be opened because Apple
> cannot check it". Users must right-click → Open, or clear the quarantine
> attribute (`xattr -d com.apple.quarantine`). The pkg installer likewise
> triggers an unidentified-developer warning.
>
> Artifact names are unchanged, so the release manifest and the Homebrew asset
> names still match. Actual signing state is recorded in
> `<name>.signing-status.txt` and `<name>.codesign-summary.txt`.

This repository publishes macOS ARM64 and Intel release archives intended for Homebrew/cask consumption, plus an unsigned installer package for direct installs.

## Archive layout

- `bin/`
  - `hw_vdf_client`
  - `emu_hw_vdf_client`
  - `hw_test`
  - `emu_hw_test`
  - `vdf_client`
  - `vdf_bench`
- `libexec/chikvdf/`
  - `libft4222.dylib`
  - `libft4222.1.4.4.190.dylib`
  - `libftd2xx.dylib`
  - versioned `libgmp` and `libgmpxx` (the sonames the binaries were linked against)

## Installer package

`chikvdf-<tag>-macos-<arch>.pkg` contains the same `bin/` and `libexec/chikvdf/` tree and installs it under `/usr/local`, so the `@loader_path/../libexec/chikvdf` rpath resolves to `/usr/local/libexec/chikvdf`. Uninstall with `pkgutil --forget com.chik.chikvdf` and remove the installed files.

## Dynamic library path policy

- Hardware binaries may be built with a development-time rpath of `@executable_path/hw/libft4222`.
- `scripts/stage-macos-bundle-dylibs.sh` deletes that rpath and adds `@loader_path/../libexec/chikvdf` in the same `install_name_tool` pass that rewrites GMP install names. Dylibs do not get that rpath edit.
- FTDI dylibs are copied into `libexec/chikvdf` with the `@rpath` install names set by `scripts/get-libft4222.sh`.
- GMP is linked from Homebrew at build time. The same staging step copies those dylibs into `libexec/chikvdf` and rewrites their install names to `@rpath/<basename>` with `install_name_tool`.
- Dylibs and binaries are re-signed ad-hoc together. Every staged Mach-O gets `codesign -s - --force` so arm64 can launch after `install_name_tool`. Library validation stays enabled and `--disable-library-validation` is not used.
- CI unzips the shipped zip, rejects any Mach-O load path or rpath under `/opt/homebrew` or `/usr/local`, and runs every executable in `scripts/macos-bundle-tools.sh` with `--version` and `DYLD_*` unset. `vdf_client` and `vdf_bench` call `init_gmp()` before printing the version. The other tools still load GMP through dyld before `--version` returns.

## Signing behavior

There is exactly one mode, for every event including final releases:

- Sign the staged Mach-O files ad-hoc (`codesign -s - --force`). No Developer ID, no hardened runtime, no timestamp.
- Build the `chikvdf-<tag>-macos-<arch>.pkg` from the same staged tree. No installer identity is passed, so the package is unsigned.
- Do not call `notarytool` and do not staple. No Apple secret is read and no `Apple-Actions/import-codesign-certs` step exists, so a release cannot be blocked by missing credentials.
- Artifact names are identical to the Developer ID build names (`chikvdf-<tag>-macos-<arch>.zip` / `.pkg`); the old `-unsigned` suffix is gone, which keeps the release manifest and the Homebrew asset names valid.
- Upload `.signing-status.txt` (human-readable mode description) and `.codesign-summary.txt` (`codesign -dv` output) with the other artifacts. Both are required by the release manifest, and both state plainly that the artifacts are not signed for distribution.

`notarize_macos` and the legacy `HAS_*` / `APP_*` / `APPLE_*` variables are still accepted by `scripts/package-macos-bundle.sh` so older callers do not break, but they no longer change the mode or the names.

## Local development

- `scripts/get-libft4222.sh install` does not require code signing.
- The script clears macOS download attributes on fetched FTDI files.
- Optional local escape hatch:
  - `CHIKVDF_ADHOC_SIGN_FTDI=1 ./scripts/get-libft4222.sh install`
