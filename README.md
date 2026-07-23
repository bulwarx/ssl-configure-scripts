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
- **PowerShell 7+ (`pwsh`) for `configure_tools_windows.ps1`** — Windows PowerShell 5.1 (the version built into Windows, `powershell.exe`) throws errors partway through the script and is not supported. Install PowerShell 7 from [aka.ms/powershell](https://aka.ms/powershell) (or `winget install Microsoft.PowerShell`) and run the script with `pwsh -File .\configure_tools_windows.ps1`, not `powershell -File ...`.

```
pip install -r requirements.txt  # install dependencies for the Python script
``` 

## ⚠️ Antivirus / Windows SmartScreen / macOS Gatekeeper Warning

These scripts and the GUI app may be flagged, blocked, or quarantined by antivirus software, endpoint protection, Windows SmartScreen, or macOS Gatekeeper. This is expected given what the tool does:

- **Fetches a certificate from a third party** (the Netskope tenant) and installs it into user and system trust stores.
- **Modifies user and system environment variables** to point tools at the certificate bundle.
- **Scans the system for installed applications** (Python, Java/JDK, VS Code, Docker, CLIs, etc.) to configure each one.
- The macOS app is **ad-hoc signed but not notarized** (no paid Apple Developer / code-signing certificate — see below). Windows builds are still unsigned, so SmartScreen may show an "unknown publisher" warning; macOS Gatekeeper will show an "unidentified developer" prompt.

These behaviors are legitimate and core to the tool's purpose, but they resemble patterns that security software treats as suspicious. If the script or app is blocked:

- On Windows SmartScreen, click **More info → Run anyway**.
- Allow / unblock the file in your antivirus or endpoint protection, or add an exclusion for it.
- For the PowerShell script you may need to allow execution: `pwsh -ExecutionPolicy Bypass -File .\configure_tools_windows.ps1` (requires PowerShell 7+ — see Requirements above).
- On macOS, opening the GUI app's `.dmg`/`.app` for the first time shows **"Apple could not verify 'SSL Configurator' is free of malware that may harm your Mac or compromise your privacy"**, with only a "Move to Trash" option in the dialog — this is not real corruption, and it's expected given the app is ad-hoc signed rather than signed with a paid Apple Developer ID. Unlike a Developer-ID-signed (but unnotarized) app, an ad-hoc-signed app doesn't get an "Open Anyway" button in System Settings → Privacy & Security — Gatekeeper treats ad-hoc signing as still effectively unidentified. The only way through today is Terminal:

    ```sh
    xattr -cr "/path/to/SSL Configurator.app"
    ```

  The app is ad-hoc signed (no cost, no Apple Developer account), which is enough to satisfy Apple Silicon's requirement that every binary be signed — without it, macOS would refuse to run the app at all with an even harder **"is damaged and can't be opened"** error and no `xattr` workaround. Eliminating this prompt entirely (no Terminal step for anyone) requires a paid Apple Developer Program enrollment and full notarization, which isn't set up.

Only run these tools from a source you trust, and review the contents before executing.

## Quick Start

Run one script for your platform, it is recommended to use the *Universal_configure_tools.py* for the broadest coverage and consistent experience across platforms. The script will prompt for your Netskope tenant name, org key, and desired certificate bundle location (with sensible defaults). It will then download the certs, create the bundle, and apply configuration to all detected tools.


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

### Netskope-only bundle (opt out of the public CA roots)

By default the bundle contains the two Netskope certs (RootCA + SubCA) plus the public `curl.se/ca/cacert.pem` CA roots, so tools keep working whether or not a given connection is decrypted by the proxy. Pass `--netskope-only` to use just the two Netskope certs instead — only do this if you're certain every connection your tools make is intercepted by the proxy, otherwise non-intercepted endpoints (some proxies exclude auth/login flows, for example) will fail with certificate errors. A `netskope_only.pem` sidecar with just the two Netskope certs is also written alongside the main bundle in full-bundle (default) mode, so you have both on hand either way.

```sh
# Linux / macOS
./configure_tools_linux.sh --netskope-only
./configure_tools_mac.sh --netskope-only

# Windows PowerShell
pwsh -File .\configure_tools_windows.ps1 -NetskopeOnly

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

# Windows PowerShell
pwsh -File .\configure_tools_windows.ps1 -CertBundle C:\path\to\bundle.pem
```

The interactive `.sh` scripts also prompt _"Use an existing certificate bundle instead of downloading?"_ when no flag is given.

## Rollback

Every script supports a rollback mode that removes all Netskope SSL configuration — no certificate bundle required.

```sh
# Linux
./configure_tools_linux.sh --rollback

# macOS
./configure_tools_mac.sh --rollback

# Windows PowerShell
pwsh -File .\configure_tools_windows.ps1 -Rollback

# Any platform (Python 3)
python universal_configure_tools.py --rollback
```

Rollback reverses: environment variables, Git, cURL `.curlrc`, gcloud, npm, Composer, Yarn, Python `certifi` marker + pip cert, Java keytool aliases (`netskope-0`, `netskope-1`), VS Code `http.systemCertificates`, Windows Certificate Store (matched by thumbprint, with subject/issuer fallback), and Docker `ca.pem`.

## Silent / Automated Deployment

Every script follows the same rule: once the tenant name + org key (or an existing cert bundle path) resolve to a non-empty value — from a flag/parameter, or a hardcoded default — **every** prompt is skipped, not just the ones that ask for those two values directly. That includes "use an existing bundle?", "recreate certificate bundle?", and "create replay script?".

### Recommended for MDM / at-scale deployment: distribute an existing bundle

If you're pushing this via Intune, Jamf, SCCM, or BigFix to machines, prefer `--cert-bundle` (or `-CertBundle`) over the tenant+org-key download path.
Using a certificate file bundled with the script prevents saving the Org-key into the script or end-user machines or logs in MDM.

Have your security team download the bundle interactively once, ship the `.pem` as a package resource / attached file alongside the script, and point every script at it.

### Creating a cert bundle manually (for distribution)

To prepare a bundle for distribution without running any of the scripts interactively, build it directly with two requests — this is exactly what the scripts do internally, so the result is a drop-in replacement for `--cert-bundle`/`-CertBundle` anywhere in this README:

```sh
# Linux / macOS
TENANT=mytenant.eu.goskope.com
ORGKEY=your-org-key

curl -k -f "https://addon-$TENANT/config/org/cert?orgkey=$ORGKEY" > netskope-cert-bundle.pem   # RootCA first
curl -k -f "https://addon-$TENANT/config/ca/cert?orgkey=$ORGKEY" >> netskope-cert-bundle.pem    # SubCA second

# Optional: append the public CA roots too (full bundle, the default the scripts produce, full bundle is recommended in most use cases and it make sure the applications will still work even when there is an ssl decryption bypass)
curl -k -f -L https://curl.se/ca/cacert.pem >> netskope-cert-bundle.pem

# Sanity check — should print 2 (or 3 with the public roots appended)
grep -c "BEGIN CERTIFICATE" netskope-cert-bundle.pem
```

```powershell
# Windows PowerShell
$tenant = "mytenant.eu.goskope.com"
$orgKey = "your-org-key"

$root = (Invoke-WebRequest -Uri "https://addon-$tenant/config/org/cert?orgkey=$orgKey" -SkipCertificateCheck).Content
$sub  = (Invoke-WebRequest -Uri "https://addon-$tenant/config/ca/cert?orgkey=$orgKey"  -SkipCertificateCheck).Content
[System.IO.File]::WriteAllBytes("netskope-cert-bundle.pem", $root + $sub)

# Optional: append the public CA roots too (full bundle, the default the scripts produce, full bundle is recommended in most use cases and it make sure the applications will still work even when there is an ssl decryption bypass)
$pub = (Invoke-WebRequest -Uri "https://curl.se/ca/cacert.pem" -SkipCertificateCheck).Content
[System.IO.File]::WriteAllBytes("netskope-cert-bundle.pem", $root + $sub + $pub)
```

The order matters — RootCA, then SubCA, then (optionally) the public roots — since that's the chain order every script here produces and validates against.

### Command-line flags / parameters (bash, Python)

```sh
# Linux / macOS
./configure_tools_linux.sh --cert-bundle /path/to/bundle.pem
./configure_tools_mac.sh   --tenant-name mytenant.eu.goskope.com --org-key your-org-key

# Optional: --cert-name, --cert-dir, --recreate (force re-download if the bundle already exists)
./configure_tools_mac.sh --tenant-name mytenant.eu.goskope.com --org-key your-org-key \
  --cert-name netskope-cert-bundle.pem --cert-dir ~/netskope --recreate

# Python
python universal_configure_tools.py --cert-bundle /path/to/bundle.pem
```

### Windows PowerShell

Requires PowerShell 7+ (`pwsh`) — see Requirements above. Two ways to run unattended, for two different deployment situations:

```powershell
# Named parameters — for anything that lets you supply a full command line
# (Intune Win32 apps, SCCM, BigFix):
pwsh -File configure_tools_windows.ps1 -CertBundle C:\netskope\bundle.pem
pwsh -File configure_tools_windows.ps1 -TenantName mytenant.eu.goskope.com -OrgKey your-org-key -CertName netskope-cert-bundle.pem -CertDir C:\netskope\bundle -Recreate
```

```powershell
# Or edit the parameter defaults directly in the file — for contexts that run
# a .ps1 with no arguments at all (e.g. Intune "platform scripts"):
param(
    [string]$TenantName   = "mytenant.eu.goskope.com",
    [string]$OrgKey       = "your-org-key",
    [string]$CertName     = "netskope-cert-bundle.pem",
    [string]$CertDir      = "C:\Users\username\netskope\",
    [string]$CertBundle   = "",     # set to an existing .pem path to skip the download entirely
    [switch]$Recreate,              # force re-download on every run
    [switch]$Rollback,              # undo all Netskope SSL configuration
    [switch]$NetskopeOnly,          # skip the public curl.se CA bundle (Netskope certs only)
    [switch]$CreateReplay           # write configured_tools.ps1 without being asked
)
```

Run `Get-Help .\configure_tools_windows.ps1 -Full` for parameter descriptions and examples.

### Deploying via a specific MDM/RMM tool

| Tool | How parameters reach the script | Example |
|---|---|---|
| **Intune** — Win32 app | Full "Install command" string, named params work directly | `pwsh -File configure_tools_windows.ps1 -CertBundle "%ProgramData%\netskope\bundle.pem"` |
| **Intune** — platform script | No arguments possible at all | Edit the `.ps1` parameter defaults before uploading (the bash/Python scripts don't have an equivalent editable-defaults block today — they need at least one flag) |
| **Jamf Pro** | Only positional `$4`–`$11` script parameters, no named flags | Ship a 1-line wrapper the policy calls instead of contorting the script: `configure_tools_mac.sh --tenant-name "$4" --org-key "$5"` (or `--cert-bundle "$4"` for the recommended path). Consider Jamf's parameter-encryption convention (community.jamf.com) if passing an org key this way. |
| **SCCM/ConfigMgr** | Full command line (Installation program field) | Same as any silent installer — put the flags directly in the command line |
| **BigFix** | Parameters embedded directly in the Fixlet action script | Bake the flags into the action script text |

Across every tool, the safest option against policy-log/process-list exposure is still `--cert-bundle` — it needs no secret in the command line at all.

### Bundling the cert with an Intune Win32 app package

Package the `.pem` file inside the `.intunewin` alongside the script and point `-CertBundle`/`--cert-bundle` straight at the package's own content path — no wrapper script needed. **Intune extracts Win32 app content into a temporary staging folder that gets deleted once install completes**, but the script itself copies the given bundle to a stable location (`%USERPROFILE%\netskope\netskope-cert-bundle.pem` by default, or wherever `-CertDir`/`-CertName` point) before configuring any tool, so nothing ends up pointing at a path that disappears a few minutes later:

```
# Intune "Install command"
pwsh.exe -File configure_tools_windows.ps1 -CertBundle "%~dp0bundle.pem"
```

Use that same stable path as the Win32 app's **detection rule** (File exists) — Intune only marks the app installed once the copy actually succeeded, and won't try to reinstall on every check-in once it has.

For ongoing drift-checking with **Intune Proactive Remediations**, the detection script just checks the stable path; the remediation script re-runs the configure step against the package's bundle (Intune re-stages Win32 app content for each remediation run, or point it at a copy you've placed somewhere permanent):

```powershell
# detection script
if (-not (Test-Path "$env:USERPROFILE\netskope\netskope-cert-bundle.pem")) {
    Write-Output "Cert bundle missing at expected location"
    exit 1   # non-compliant — triggers the remediation script
}
exit 0
```

```powershell
# remediation script
pwsh -File "C:\path\to\configure_tools_windows.ps1" -CertBundle "C:\path\to\bundle.pem"
```

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
- Automated Silent install options for MDM
