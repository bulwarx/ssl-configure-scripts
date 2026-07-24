# SSL Configure Scripts

Cross-platform scripts to build a Netskope CA bundle and configure common developer tools to trust it.

Intended for environments with SSL inspection (MITM proxy), where tools fail TLS validation unless a trusted corporate certificate is configured.

## What These Scripts Do

1. Prompt for tenant details and bundle location (or use pre-set parameters for silent deployment).
2. Download and create a certificate bundle — by default the **full bundle** (Netskope RootCA + SubCA, plus the public `curl.se/ca/cacert.pem` CA roots). This covers both traffic intercepted by the proxy and any endpoints it doesn't decrypt (e.g. some proxies exclude auth/login flows from inspection) — using a Netskope-only bundle in that case causes certificate errors on the excluded endpoints. Pass `--netskope-only` to use just the two Netskope certs instead.
3. Detect installed tools and apply SSL certificate configuration automatically.
4. Optionally generate a replay script with the applied configuration commands for re-use on other machines.

## Why Use These Scripts?

- **Comprehensive coverage** — supports a wide range of tools across Linux, macOS, and Windows, including Git, cURL, AWS CLI, gcloud, npm, Python environments, Java/JDK truststores, VS Code, Docker Desktop, and more.
- **Cross-platform** — separate scripts for each platform, plus a universal Python script for consistent experience across all supported systems.

## Scripts Included

| Script | Platform | Notes |
|--------|----------|-------|
| `configure_tools_linux.sh` | Linux | Shell script |
| `configure_tools_mac.sh` | macOS | Shell script |
| `configure_tools_windows.ps1` | Windows | PowerShell script — most comprehensive. **Requires PowerShell 7+ (`pwsh`)**, not Windows PowerShell 5.1 |
| `universal_configure_tools.py` | All platforms | Python — unified cross-platform coverage |

> **`configure_tools_windows.cmd` is deprecated** and has moved to [`old_scripts/`](old_scripts/) — kept for historical reference only, not maintained or tested. Use `configure_tools_windows.ps1` for Windows.

## Documentation

| Topic | Description |
|---|---|
| [Parameters Reference](docs/parameters-reference.md) | Every flag/parameter across all four scripts — names, defaults, and the real differences between them |
| [Usage Examples by Scenario](docs/usage-examples.md) | Copy-pasteable commands for interactive, silent, netskope-only, rollback, and replay-script scenarios |
| [Creating a Cert Bundle Manually](docs/creating-a-cert-bundle.md) | Build a distributable `.pem` bundle without running any script interactively |
| [Rollback](docs/rollback.md) | Undo all Netskope SSL configuration |
| [Replay Script](docs/replay-script.md) | Record and reuse the exact configuration applied on one machine |
| [Antivirus / SmartScreen / Gatekeeper Warning](docs/antivirus-and-code-signing.md) | Why this gets flagged, and how to get past it on each platform |
| **Deployment guides** | |
| [Deploying via Microsoft Intune](docs/deployment-intune.md) | The only officially supported MDM — Win32 app packaging (step-by-step) and platform scripts |
| [Deploying via Other MDM/RMM Tools (Generic)](docs/deployment-generic-mdm.md) | Jamf, SCCM, BigFix, or anything else — generic guidance, not officially supported |

## Supported Tools

### All scripts (Linux / macOS / Windows)
- Git
- OpenSSL
- cURL
- AWS CLI
- Google Cloud CLI
- NPM / Node.js
- Ruby
- PHP Composer
- Go
- Azure CLI
- Oracle Cloud CLI
- Cargo
- Yarn
- pnpm
- Azure Storage Explorer

### Windows scripts (PS1, Python on Windows)
- **Python environments** — discovers all installations via Python Launcher (`py`), PATH, and bundled CLIs (e.g. Azure CLI); patches `certifi` with an idempotent marker and sets `pip` global cert
- **Java / JDK truststores** — discovers JDKs via `JAVA_HOME`, PATH, registry, and common install locations; imports certs via `keytool`
- **VS Code** — sets `http.systemCertificates: true` in user settings (standard and Insiders editions)
- **Windows Certificate Store** — imports the CA cert into `LocalMachine\Root` (falls back to `CurrentUser\Root`)
- **.NET / NuGet** — covered by the Windows Certificate Store; detected and reported
- **Docker Desktop** — copies the bundle to `~/.docker/ca.pem`

## Requirements
- Python 3 (for the universal script; platform-specific scripts are standalone)
- OpenSSL CLI (for cert parsing; bundled with Windows scripts)
- **PowerShell 7+ (`pwsh`) for `configure_tools_windows.ps1`** — Windows PowerShell 5.1 (the version built into Windows, `powershell.exe`) throws errors partway through the script and is not supported. Install PowerShell 7 from [aka.ms/powershell](https://aka.ms/powershell) (or `winget install Microsoft.PowerShell`) and run the script with `pwsh -File .\configure_tools_windows.ps1`, not `powershell -File ...`.


```
pip install -r requirements.txt  # install dependencies for the Python script
```

## ⚠️ Antivirus / Windows SmartScreen / macOS Gatekeeper Warning

These scripts and the GUI app may be flagged, blocked, or quarantined by antivirus software, endpoint protection, Windows SmartScreen, or macOS Gatekeeper — fetching a third-party certificate, modifying environment variables/trust stores, and scanning for installed applications are all legitimate parts of what this tool does, but resemble patterns security software treats as suspicious. The macOS app is ad-hoc signed but not notarized, so it still shows Gatekeeper's "unidentified developer" prompt.

See **[Antivirus / SmartScreen / Gatekeeper Warning](docs/antivirus-and-code-signing.md)** for how to get past each platform's warning, including the exact `xattr -cr` command needed on macOS.

Only run these tools from a source you trust, and review the contents before executing.

## Quick Start

Run one script for your platform — it is recommended to use *universal_configure_tools.py* for the broadest coverage and consistent experience across platforms. The script will prompt for your Netskope tenant name, org key, and desired certificate bundle location (with sensible defaults). It will then download the certs, create the bundle, and apply configuration to all detected tools.

```sh
# Linux
./configure_tools_linux.sh

# macOS
./configure_tools_mac.sh

# Windows PowerShell (requires PowerShell 7+ / pwsh — see Requirements)
pwsh -File .\configure_tools_windows.ps1

# Any platform (Python 3)
python universal_configure_tools.py
```

By default the bundle contains the two Netskope certs (RootCA + SubCA) plus the public `curl.se/ca/cacert.pem` CA roots.
pass `--netskope-only`/`-NetskopeOnly` to use just the two Netskope certs, or `--cert-bundle`/`-CertBundle` to use an existing bundle instead of downloading. 
See **[Usage Examples by Scenario](docs/usage-examples.md)** for these and more (silent deployment, custom bundle location, forced recreation, etc.) and **[Parameters Reference](docs/parameters-reference.md)** for what every flag means.

## Rollback

Every script supports a rollback mode that removes all Netskope SSL configuration — no certificate bundle required.

```sh
./configure_tools_linux.sh --rollback         # Linux
./configure_tools_mac.sh --rollback           # macOS
pwsh -File .\configure_tools_windows.ps1 -Rollback   # Windows PowerShell
python universal_configure_tools.py --rollback       # Any platform (Python 3)
```

See **[Rollback](docs/rollback.md)** for exactly what's reversed.

## Silent / Automated Deployment

Every script follows the same rule: once the tenant name + org key (or an existing cert bundle path) resolve to a non-empty value — from a flag/parameter, or a hardcoded default — **every** prompt is skipped, not just the ones that ask for those two values directly.

**Recommended for MDM / at-scale deployment:** prefer `--cert-bundle`/`-CertBundle` (an existing, pre-distributed bundle) over the tenant+org-key download path — it never puts the org key on the endpoint, in logs, or in a command line anywhere. Have your security team download the bundle interactively once (or build it directly — see [Creating a Cert Bundle Manually](docs/creating-a-cert-bundle.md)), ship the `.pem` alongside the script, and point every script at it. See [Parameters Reference](docs/parameters-reference.md) and [Usage Examples by Scenario](docs/usage-examples.md) for the exact flags and commands.

### Deploying via a specific MDM/RMM tool

**Microsoft Intune is the only MDM this repo officially supports.** Other tools (Jamf Pro, SCCM/ConfigMgr, BigFix, etc.) can run these scripts too, but only generic, unverified guidance is provided for them.

| Tool | How parameters reach the script | Guide |
|---|---|---|
| **Intune** — Win32 app | Full "Install command" string, named params work directly | [Step-by-step walkthrough](docs/deployment-intune.md) |
| **Intune** — platform script | No arguments possible at all | [Same guide, Option B](docs/deployment-intune.md#option-b-platform-script) |
| Any other MDM/RMM (Jamf, SCCM, BigFix, etc.) | Varies by tool | [Generic guidance](docs/deployment-generic-mdm.md) — not officially supported |

Across every tool, the safest option against policy-log/process-list exposure is still `--cert-bundle` — it needs no secret in the command line at all.

## Replay Script

All scripts offer an optional replay script (`configured_tools.bat` / `configured_tools.ps1` / `configured_tools.sh`) that records every configuration command applied. Run it on another machine with the same cert bundle path to replicate the configuration without re-running the full interactive script. See **[Replay Script](docs/replay-script.md)** for how it's enabled/disabled per script.

## GUI App (Tauri)

A cross-platform GUI is available in [`tauri-app/`](tauri-app/), built with Tauri 2 (Rust backend + HTML/CSS/JS frontend). It provides the same functionality as the scripts through a 5-step wizard — no terminal required.

**Download:** pre-built installers are attached to each GitHub Release (`.exe` / `.dmg` / `.AppImage`).

Or

**Build from source:** see [`tauri-app/README.md`](tauri-app/README.md).

The GUI and the scripts are independent — both live in this repo and serve different audiences. Users who want to modify or automate the configuration should use the scripts directly.

The Select Tools step has a **Refresh** button — use it after installing a tool without restarting the app (any tool you'd already manually unchecked stays unchecked). On macOS/Linux, the app also fixes up its own `PATH` at startup by asking your login shell for it, since GUI apps launched from Finder/Dock otherwise only see a minimal PATH that omits Homebrew, nvm, `~/.cargo/bin`, etc. — this is also why a tool installed via one of those could be invisible until the app's `PATH` fix runs (first launch after an update) or you hit Refresh.

## Credit

Original creator and upstream repository: https://github.com/duduke/ssl-configure-scripts

Enhanced by the Bulwarx Ltd team:
- Expanded tool coverage (VS Code, Docker Desktop, Java/JDK, Windows Certificate Store, .NET/NuGet)
- Advanced Python discovery (Python Launcher, bundled CLIs, idempotent certifi patching)
- Parameterized / silent deployment mode
- ANSI color output and structured logging
- Replay script support
- Rollback support across all scripts
- Full bundle by default (Netskope RootCA + SubCA, correct chain order, plus public CA roots); optional Netskope-only bundle via `--netskope-only`
- Automated Silent install options for MDM
