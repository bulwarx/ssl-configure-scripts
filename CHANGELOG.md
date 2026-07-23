# Changelog

All notable changes to this project are documented in this file.

## [0.5.1] - 2026-07-23

### Fixed
- **`configure_tools_windows.ps1` silent/unattended runs were broken by a real parameter-binding bug**: none of the `param()` fields declared a `Position`, so PowerShell auto-assigns positions by declaration order. Invoking the script with a bare path and no `-CertBundle` name (`pwsh -File configure_tools_windows.ps1 C:\bundle.pem`) silently bound that path to `-TenantName` instead — `$CertBundle` and `$OrgKey` stayed empty, `$silentRun` evaluated false, and every prompt fired, exactly matching a user report of "not silent, and doesn't use the certificate bundle I gave it, no orgkey or url". Fixed with `[CmdletBinding(PositionalBinding = $false)]` plus `[Parameter(Position = 0)]` on `CertBundle` alone — named parameters now work for everything, and the one bare-positional case supported is the cert bundle path itself (the recommended enterprise path). `-CertBundle` (or a bare path) already took precedence over stale `-TenantName`/`-OrgKey` values once actually bound correctly — that part of the logic was already right; the parameter binding was silently preventing it from ever being exercised.

### Added
- **CI smoke tests for the actual silent/unattended install paths**, on both `windows-latest` and `ubuntu-latest`, since these can't be tested on macOS. Runs each script against a throwaway self-signed cert bundle and asserts: no prompt fires, the given `--cert-bundle`/`-CertBundle` is actually used, and it takes precedence over stale tenant/orgkey values passed alongside it. Includes a dedicated regression test for the bare-positional-argument bug above. Covers `configure_tools_linux.sh`, `universal_configure_tools.py`, `configure_tools_windows.ps1`, and `configure_tools_windows.cmd`.

## [0.5.0] - 2026-07-23

### Added
- **`configure_tools_windows.ps1` now has a real `[CmdletBinding()] param()` block** (`-TenantName`, `-OrgKey`, `-CertBundle`, `-CertName`, `-CertDir`, `-Recreate`, `-Rollback`, `-NetskopeOnly`, `-CreateReplay`) with full comment-based help (`Get-Help .\configure_tools_windows.ps1 -Full` now works) — replacing the "hand-edit variables inside the file" mechanism as the primary way to run it unattended. Editing the parameter defaults directly still works unchanged, for contexts that can't pass arguments at all (e.g. Intune "platform scripts").
- **`configure_tools_windows.cmd` gained named flag parsing** (`tenant-name=`, `org-key=`, `cert-name=`, `cert-dir=`, `cert-bundle=`, `recreate`, `create-replay`) — previously it could not perform an unattended download at all; every value except `rollback`/`netskope-only` was interactive-only.
- **README: rewrote "Silent / Automated Deployment"** with per-MDM-tool guidance (Intune Win32 app vs. platform script, Jamf's positional-only script parameters, SCCM, BigFix) and promotes `--cert-bundle`/`-CertBundle` as the recommended path for MDM/at-scale deployment — pre-distributing the bundle means the org key never has to touch the endpoint at all, unlike the tenant+org-key download path where it inevitably appears in a flag/parameter/policy log somewhere (the same tradeoff Netskope's and Zscaler's own silent MSI installers accept for their enrollment tokens).

### Fixed
- **`configure_tools_windows.ps1`: the "create replay script?" silent-mode fix from the previous release was silently broken** — a leftover `$createReplay = $false` further down in the file was unconditionally re-initializing the variable after the parameter block set it, discovered while implementing the `param()` block above.
- Windows PowerShell 5.1 vs 7 requirement documented consistently across the README (Requirements section, scripts table, Quick Start, rollback examples, SmartScreen guidance) and the script's own `#Requires` line, which previously under-declared its actual minimum version (5.1 instead of 7.0) and so failed partway through with confusing errors instead of refusing to run with a clear message.

## [0.4.1] - 2026-07-23

### Fixed
- **macOS build was completely unsigned**, which is why opening the app showed the hard "'SSL Configurator' is damaged and can't be opened" error on Apple Silicon — arm64 macOS refuses to run any binary without at least a signature. The build now sets `bundle.macOS.signingIdentity = "-"` in `tauri.conf.json`, which ad-hoc signs the app (free, no Apple Developer account needed) and CI verifies the signature (`codesign --verify`) before packaging. This does **not** notarize the app — Gatekeeper still shows an "unidentified developer" prompt for a downloaded copy (right-click → Open, or `xattr -cr`, still needed), but that's a much milder prompt than the previous hard block. Full notarization (no prompt at all) requires an Apple Developer Program enrollment, which isn't set up.

## [0.4.0] - 2026-07-23

### Fixed
- **Tauri app couldn't see Homebrew-installed tools (npm, pnpm, az, etc.)** — a GUI app launched from Finder/Dock gets a minimal `PATH` from launchd (just `/usr/bin:/bin:/usr/sbin:/sbin`), which omits `/opt/homebrew/bin`. The app now asks the user's login shell for its real `PATH` at startup (falling back to appending common tool directories) and applies it process-wide, fixing both detection and the actual configuration commands. The mac/Linux scripts got the same defensive `PATH` augmentation in case they're run outside an interactive login shell.
- **macOS sidebar footer showed "MacIntel" on Apple Silicon** — that came from `navigator.platform`, which WebKit hardcodes to "MacIntel" for every Mac regardless of real CPU architecture (intentional web-compat behavior, not a bug in your hardware). The footer now uses a new Rust `platform_info` command that reports the actual compiled-for OS/arch, e.g. "macOS (Apple Silicon)".
- **`mkdir -p $certDir` was unquoted** in `configure_tools_mac.sh` / `configure_tools_linux.sh` — a `--cert-dir` path containing spaces would be split into multiple arguments and fail to create the directory. Same issue existed in every `post_command` string (gcloud/npm/composer/yarn/pnpm config calls) built with an unquoted `$certDir/$certName` and passed through `eval` — all now quoted. (Found via GitHub Copilot's review on the v0.3.0 PR.)
- **Stale `netskope_only.pem` sidecar** — the sidecar is only written in full-bundle mode; switching to `--netskope-only` on a machine that previously ran full-bundle left the old sidecar in place with no indication it was stale. All scripts (bash, cmd, PowerShell, Python) now remove it when running in `--netskope-only` mode. (Also found via the Copilot review; the sidecar's explanatory comment was also fixed — it's for connections *always* intercepted by the proxy, not ones that bypass it.)
- **The `pnpm`/adjacent tool config commands in `configure_tools_windows.cmd` and `universal_configure_tools.py` were also unquoted** (`cmd.exe`'s `%certDir%\%certName%` and Python's `shell=True` post-command strings) — same space-in-path breakage as the bash fix above, caught by a second Copilot pass on this PR.
- **PATH-fix fallback could add an empty PATH entry** in both the Tauri app (Rust) and `universal_configure_tools.py` if `PATH` was unset/empty when prepending fallback directories — an empty PATH segment means "search the current working directory for executables", a real (if narrow) security footgun. Both now avoid producing that trailing/leading empty segment.
- **Tauri app's Refresh button could wrongly uncheck newly-installed tools** — it restored prior deselections by unchecking anything not previously selected, which also caught tools that had just become installed (and were never selectable before). Now only restores deselection for tools that were already installed *and* explicitly unchecked before the refresh.

### Added
- **pnpm support** across every script and the Tauri app — it wasn't a detection bug, pnpm was never in the tool list at all. Configured via the same `cafile` key npm uses.
- **Refresh button** on the Tauri app's Select Tools step — re-runs detection without restarting the app (e.g. after installing a tool mid-session), preserving any tool you'd manually unchecked.

### Changed
- Upgraded all Cargo dependencies to their latest versions, including major bumps: `reqwest` 0.12 → 0.13 (its `rustls-tls` feature was renamed to `rustls`), `which` 6 → 8, `dirs` 5 → 6, `winreg` 0.52 → 0.56 (Windows-only). Plus `tauri` 2.11.2 → 2.11.5 and other transitive dependencies to their latest compatible patch versions.
- Upgraded GitHub Actions: `actions/checkout` v6 → v7, `actions/cache` v5 → v6, `actions/setup-node` v6 → v7, `dependabot/fetch-metadata` v2 → v3.
- Dependabot flagged an open `glib` advisory (unsound `Iterator` impls, fixed in 0.20.0) — not fixable today: `tauri` 2.11.x itself pins `gtk = "^0.18"`, which requires `glib ^0.18`. This is blocked on an upstream Tauri release moving to a newer gtk-rs generation; Dependabot will pick up the fix automatically once that lands (already configured for weekly cargo updates in this repo).

## [0.3.0] - 2026-07-22

### Changed
- **Full bundle is now the default** (Netskope RootCA + SubCA + public `curl.se/ca/cacert.pem` CA roots) across every script and the Tauri app. Previously the default was Netskope-only, which broke tools/endpoints not decrypted by the proxy (e.g. some proxies exclude auth/login flows from inspection) with certificate-verification errors — this is what caused `az login` to fail with a self-signed-certificate error even after the Azure CLI was "configured". Pass `--netskope-only` (or the `netskopeOnly`/`$netskopeOnly` preset param) to opt back into the old minimal bundle. `--full-bundle` is still accepted everywhere as a no-op for backward compatibility.
- The bash and CMD scripts now also write a `netskope_only.pem` sidecar in full-bundle mode, matching the existing PowerShell/Python behavior.
- The Tauri app's bundle-type toggle now defaults to "Full" (previously "Netskope-only").

### Fixed
- `configure_tools_mac.sh`: `openssl --version` failed on Apple's system LibreSSL (`Error: '--version' is an invalid command.`) — now uses `openssl version`. Same fix applied to the Linux, Windows (CMD/PowerShell), and Python scripts for portability across OpenSSL/LibreSSL builds.
- `configure_tools_mac.sh`: AWS CLI was checked against the wrong binary name (`awscli` instead of `aws`), so it was never actually detected on macOS.
- `configure_tools_mac.sh`: Oracle Cloud CLI was checked against `oci-cli` instead of the real binary name `oci`.
- `configure_tools_mac.sh` / `universal_configure_tools.py`: Yarn was only checked as `yarnpkg` (the Debian-specific binary name); Homebrew and most other installs ship it as `yarn`, so it was never detected on macOS.

### Added
- Silent/unattended distributor mode for `configure_tools_mac.sh`, `configure_tools_linux.sh`, and `universal_configure_tools.py`: `--tenant-name`, `--org-key`, `--cert-name`, `--cert-dir`, and `--recreate` let the download path run with zero interactive prompts, matching the coverage `--cert-bundle` already had. `--cert-bundle` (existing-bundle mode) has always been fully offline (no network call at all) — this is unchanged, just documented more clearly.
- `universal_configure_tools.py` no longer blocks on the "Create replay script?" prompt during a silent/unattended run or when using an existing bundle; use `--no-replay` to suppress it explicitly.
- README: documented the new flags, the macOS Gatekeeper "app is damaged" warning (unsigned/unnotarized builds) with the `xattr -cr` workaround, and a "Silent / Automated Deployment" section for the shell/Python scripts (previously PowerShell-only).

## [0.2.0] - 2026-06-16

Prior release. See git history (`git log v0.1.1..v0.2.0`) for details — highlights include existing-bundle support (`--cert-bundle`), fail-fast certificate download errors, the self-contained macOS `.app` zip, and Dependabot automation.

## [0.1.1] / [0.1.0]

Initial releases forked from [duduke/ssl-configure-scripts](https://github.com/duduke/ssl-configure-scripts), enhanced by the Bulwarx Ltd team — see the README's "Credit" section for a summary of enhancements.
