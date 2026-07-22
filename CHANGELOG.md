# Changelog

All notable changes to this project are documented in this file.

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
