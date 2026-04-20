# SSL Configure Scripts

Cross-platform scripts to build a Netskope CA bundle and configure common developer tools to trust it.

Intended for environments with SSL inspection (MITM proxy), where tools fail TLS validation unless a trusted corporate certificate is configured.

## What These Scripts Do

1. Prompt for tenant details and bundle location (or use pre-set parameters for silent deployment).
2. Download and create a certificate bundle — by default **Netskope-only** (RootCA + SubCA). Pass `--full-bundle` to also append the public `curl.se/ca/cacert.pem` CA roots.
3. Detect installed tools and apply SSL certificate configuration automatically.
4. Optionally generate a replay script with the applied configuration commands for re-use on other machines.

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
- Azure Storage Explorer

### Windows scripts (PS1, CMD, Python on Windows)
- **Python environments** — discovers all installations via Python Launcher (`py`), PATH, and bundled CLIs (e.g. Azure CLI); patches `certifi` with an idempotent marker and sets `pip` global cert
- **Java / JDK truststores** — discovers JDKs via `JAVA_HOME`, PATH, registry, and common install locations; imports certs via `keytool`
- **VS Code** — sets `http.systemCertificates: true` in user settings (standard and Insiders editions)
- **Windows Certificate Store** — imports the CA cert into `LocalMachine\Root` (falls back to `CurrentUser\Root`)
- **.NET / NuGet** — covered by the Windows Certificate Store; detected and reported
- **Docker Desktop** — copies the bundle to `~/.docker/ca.pem`

## Quick Start

Run one script for your platform:

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

### Full bundle (optional)

By default the bundle contains only the two Netskope certs (RootCA + SubCA). Pass `--full-bundle` to also append the public `curl.se/ca/cacert.pem` CA roots. In full-bundle mode a `netskope_only.pem` sidecar is also written alongside the main bundle (PS1 and Python only).

```sh
# Linux / macOS
./configure_tools_linux.sh --full-bundle
./configure_tools_mac.sh --full-bundle

# Windows CMD
configure_tools_windows.cmd full-bundle

# Windows PowerShell — set in the pre-set params block at the top of the file
# $fullBundle = $true

# Python
python universal_configure_tools.py --full-bundle
```

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

## Silent / Automated Deployment (PowerShell)

The PowerShell script supports pre-set parameters at the top of the file for fully unattended deployment. Edit the parameter block before running:

```powershell
$tenantName   = "mytenant.eu.goskope.com"
$orgKey       = "your-org-key"
$certName     = "netskope-cert-bundle.pem"
$certDir      = "C:\netskope"
$recreateCert = $false   # set $true to force re-download on every run
$rollback     = $false   # set $true to undo all Netskope SSL configuration
$fullBundle   = $false   # set $true to append the public curl.se CA bundle
```

When all parameters are set the script runs without any interactive prompts.

## Replay Script

All scripts offer an optional replay script (`configured_tools.bat` / `configured_tools.ps1` / `configured_tools.sh`) that records every configuration command applied. Run it on another machine with the same cert bundle path to replicate the configuration without re-running the full interactive script.

## Credit

Original creator and upstream repository: https://github.com/duduke/ssl-configure-scripts

Enhanced by the Bulwarx Ltd team:
- Expanded tool coverage (VS Code, Docker Desktop, Java/JDK, Windows Certificate Store, .NET/NuGet)
- Advanced Python discovery (Python Launcher, bundled CLIs, idempotent certifi patching)
- Parameterized / silent deployment mode
- ANSI color output and structured logging
- Replay script support
- Rollback support across all scripts
- Netskope-only bundle by default (RootCA + SubCA, correct chain order); optional full public CA bundle via `--full-bundle`
