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
| `configure_tools_windows.cmd` | Windows | CMD script with ANSI color output |
| `configure_tools_windows.ps1` | Windows | PowerShell script — most comprehensive |
| `universal_configure_tools.py` | All platforms | Python — unified cross-platform coverage |

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

### Windows scripts (PS1, CMD, Python on Windows)
- **Python environments** — discovers all installations via Python Launcher (`py`), PATH, and bundled CLIs (e.g. Azure CLI); patches `certifi` with an idempotent marker and sets `pip` global cert
- **Java / JDK truststores** — discovers JDKs via `JAVA_HOME`, PATH, registry, and common install locations; imports certs via `keytool`
- **VS Code** — sets `http.systemCertificates: true` in user settings (standard and Insiders editions)
- **Windows Certificate Store** — imports the CA cert into `LocalMachine\Root` (falls back to `CurrentUser\Root`)
- **.NET / NuGet** — covered by the Windows Certificate Store; detected and reported
- **Docker Desktop** — copies the bundle to `~/.docker/ca.pem`

## Requirements
- Python 3 (for the universal script; platform-specific scripts are standalone)
- OpenSSL CLI (for cert parsing; bundled with Windows scripts)

```
pip install -r requirements.txt  # install dependencies for the Python script
``` 

## ⚠️ Antivirus / Windows SmartScreen / macOS Gatekeeper Warning

These scripts and the GUI app may be flagged, blocked, or quarantined by antivirus software, endpoint protection, Windows SmartScreen, or macOS Gatekeeper. This is expected given what the tool does:

- **Fetches a certificate from a third party** (the Netskope tenant) and installs it into user and system trust stores.
- **Modifies user and system environment variables** to point tools at the certificate bundle.
- **Scans the system for installed applications** (Python, Java/JDK, VS Code, Docker, CLIs, etc.) to configure each one.
- The software is **ad-hoc signed but not notarized** (no paid Apple Developer / code-signing certificate — see below), so SmartScreen will show an "unknown publisher" warning and macOS Gatekeeper will show an "unidentified developer" prompt.

These behaviors are legitimate and core to the tool's purpose, but they resemble patterns that security software treats as suspicious. If the script or app is blocked:

- On Windows SmartScreen, click **More info → Run anyway**.
- Allow / unblock the file in your antivirus or endpoint protection, or add an exclusion for it.
- For the PowerShell script you may need to allow execution: `powershell -ExecutionPolicy Bypass -File .\configure_tools_windows.ps1`.
- On macOS, opening the GUI app's `.dmg`/`.app` for the first time shows **"Apple could not verify 'SSL Configurator' is free of malware"** (an unidentified-developer warning, not real corruption). Either:
  - Right-click (or Control-click) the app → **Open** → **Open** again in the dialog — no Terminal needed, works on most macOS versions, or
  - Remove the quarantine flag from Terminal:

    ```sh
    xattr -cr "/path/to/SSL Configurator.app"
    ```

  The app is ad-hoc signed (no cost, no Apple Developer account), which is enough to satisfy Apple Silicon's requirement that every binary be signed — without it, macOS would refuse to run the app at all with a hard **"is damaged and can't be opened"** error instead of the milder prompt above. Ad-hoc signing alone doesn't clear Gatekeeper's quarantine check; only Apple notarization (a paid Developer Program enrollment) does that.

Only run these tools from a source you trust, and review the contents before executing.

## Quick Start

Run one script for your platform, it is recommended to use the *Universal_configure_tools.py* for the broadest coverage and consistent experience across platforms. The script will prompt for your Netskope tenant name, org key, and desired certificate bundle location (with sensible defaults). It will then download the certs, create the bundle, and apply configuration to all detected tools.


```sh
# Linux
./configure_tools_linux.sh

# macOS
./configure_tools_mac.sh

# Windows CMD
configure_tools_windows.cmd

# Windows PowerShell
./configure_tools_windows.ps1

# Any platform (Python 3)
python universal_configure_tools.py
```

### Netskope-only bundle (opt out of the public CA roots)

By default the bundle contains the two Netskope certs (RootCA + SubCA) plus the public `curl.se/ca/cacert.pem` CA roots, so tools keep working whether or not a given connection is decrypted by the proxy. Pass `--netskope-only` to use just the two Netskope certs instead — only do this if you're certain every connection your tools make is intercepted by the proxy, otherwise non-intercepted endpoints (some proxies exclude auth/login flows, for example) will fail with certificate errors. A `netskope_only.pem` sidecar with just the two Netskope certs is also written alongside the main bundle in full-bundle (default) mode, so you have both on hand either way.

```sh
# Linux / macOS
./configure_tools_linux.sh --netskope-only
./configure_tools_mac.sh --netskope-only

# Windows CMD
configure_tools_windows.cmd netskope-only

# Windows PowerShell — set in the pre-set params block at the top of the file
# $netskopeOnly = $true

# Python
python universal_configure_tools.py --netskope-only
```

`--full-bundle` is still accepted everywhere as a no-op, since it's now the default.

### Use an existing bundle (skip download)

If you already have a certificate bundle — distributed centrally, or when the download endpoint is unreachable — point the script at it instead of downloading. The file is validated for a certificate before use. The GUI offers the same choice on the connection step.

```sh
# Linux / macOS
./configure_tools_linux.sh --cert-bundle /path/to/bundle.pem
./configure_tools_mac.sh --cert-bundle /path/to/bundle.pem

# Python
python universal_configure_tools.py --cert-bundle /path/to/bundle.pem

# Windows PowerShell — set in the pre-set params block at the top of the file
# $certBundle = "C:\path\to\bundle.pem"

# Windows CMD — answer "y" when prompted to use an existing bundle
configure_tools_windows.cmd
```

The interactive scripts (CMD and the `.sh` scripts) also prompt _"Use an existing certificate bundle instead of downloading?"_ when no flag is given.

## Rollback

Every script supports a rollback mode that removes all Netskope SSL configuration — no certificate bundle required.

```sh
# Linux
./configure_tools_linux.sh --rollback

# macOS
./configure_tools_mac.sh --rollback

# Windows CMD
configure_tools_windows.cmd rollback

# Windows PowerShell — set $rollback = $true at the top of the file
./configure_tools_windows.ps1

# Any platform (Python 3)
python universal_configure_tools.py --rollback
```

Rollback reverses: environment variables, Git, cURL `.curlrc`, gcloud, npm, Composer, Yarn, Python `certifi` marker + pip cert, Java keytool aliases (`netskope-0`, `netskope-1`), VS Code `http.systemCertificates`, Windows Certificate Store (matched by thumbprint, with subject/issuer fallback), and Docker `ca.pem`.

## Silent / Automated Deployment

### Linux / macOS / Python

Pass the tenant details as flags and the script runs with zero prompts — this is the supported path for software distributors pushing the script unattended:

```sh
# Linux / macOS
./configure_tools_linux.sh --tenant-name mytenant.eu.goskope.com --org-key your-org-key
./configure_tools_mac.sh   --tenant-name mytenant.eu.goskope.com --org-key your-org-key

# Optional: --cert-name, --cert-dir, --recreate (force re-download if the bundle already exists)
./configure_tools_mac.sh --tenant-name mytenant.eu.goskope.com --org-key your-org-key \
  --cert-name netskope-cert-bundle.pem --cert-dir ~/netskope --recreate

# Python
python universal_configure_tools.py --tenant-name mytenant.eu.goskope.com --org-key your-org-key
```

Passing `--cert-bundle` (an existing bundle) is silent by the same rule and, unlike the download path, never touches the network at all — the file is validated locally and used in place.

### Windows PowerShell

The PowerShell script supports pre-set parameters at the top of the file for fully unattended deployment. Edit the parameter block before running:

```powershell
$tenantName   = "mytenant.eu.goskope.com"
$orgKey       = "your-org-key"
$certName     = "netskope-cert-bundle.pem"
$certDir      = "C:\Users\username\netskope\"
$recreateCert = $false   # set $true to force re-download on every run
$rollback     = $false   # set $true to undo all Netskope SSL configuration
$netskopeOnly = $false   # set $true to skip the public curl.se CA bundle (Netskope certs only)
```

When all parameters are set the script runs without any interactive prompts.

## Replay Script

All scripts offer an optional replay script (`configured_tools.bat` / `configured_tools.ps1` / `configured_tools.sh`) that records every configuration command applied. Run it on another machine with the same cert bundle path to replicate the configuration without re-running the full interactive script.

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
