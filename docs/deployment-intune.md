# Deploying via Microsoft Intune

[← Back to README](../README.md) · See also: [Parameters Reference](parameters-reference.md) · [Creating a Cert Bundle Manually](creating-a-cert-bundle.md)

Intune has two mechanisms that can run this script: a **Win32 app** (recommended — supports a full install command line, named parameters, detection rules, and an uninstall command) or a **platform script** (no arguments possible at all). This guide covers both, plus optional ongoing drift-checking with Proactive Remediations.

## Option A: Win32 app (recommended)

This is the full path from "I have a `.pem` and a script" to "it's installed on managed devices."

**Prerequisites, before you start:**
- **The [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)** (`IntuneWinAppUtil.exe`) — this is what packages a folder into the `.intunewin` file Intune requires for Win32 apps. Free download, run it on any Windows machine (doesn't need to be a managed device).
- **No PowerShell version pre-deployment needed.** `configure_tools_windows.ps1` runs on the Windows PowerShell 5.1 (`powershell.exe`) that ships with every supported Windows version, as well as PowerShell 7+ (`pwsh.exe`) if your fleet already has it — either works, with no extra Win32 app/dependency required first.

**1. Prepare a source folder** containing just the script and the bundle, nothing else:
```
C:\intune-package\
├── configure_tools_windows.ps1
└── netskope-cert-bundle.pem      # built via Creating a Cert Bundle Manually
```

**2. Wrap it into a `.intunewin`:**
```
IntuneWinAppUtil.exe -c C:\intune-package -s configure_tools_windows.ps1 -o C:\intune-output
```
This produces `C:\intune-output\configure_tools_windows.intunewin`.

**3. Create the Win32 app** in the Intune admin center: **Apps → Windows → Add → Windows app (Win32)** → upload `configure_tools_windows.intunewin`. Give it a name/description on the App information step.

**4. Program tab:**
```
Install command:    powershell.exe -ExecutionPolicy Bypass -File configure_tools_windows.ps1 -CertBundle ".\netskope-cert-bundle.pem"
Uninstall command:   powershell.exe -ExecutionPolicy Bypass -File configure_tools_windows.ps1 -Rollback
Install behavior:    User   ← see the callout below before picking System instead
```
(`pwsh.exe` works identically instead of `powershell.exe` if you'd rather target PowerShell 7+ specifically.)
Intune runs the install command with its working directory set to the extracted package folder, so the relative `.\netskope-cert-bundle.pem` resolves correctly — no `%~dp0`/`$PSScriptRoot` wrapper needed. The script copies that bundle out to `%USERPROFILE%\netskope\netskope-cert-bundle.pem` (or wherever `-CertDir`/`-CertName` point) before configuring anything, so it survives Intune deleting the staging folder after install.

> **Install behavior: User vs. System — this determines whether the tool actually works.** Everything this script configures — Git, npm, pip/certifi, VS Code settings, Docker's `ca.pem`, the `.curlrc` — lives under the signed-in user's profile (`$env:USERPROFILE`, `$env:APPDATA`). If you set **Install behavior: System**, the script runs as the `SYSTEM` account instead of the real user, so `$env:USERPROFILE` resolves to the SYSTEM profile and every one of those per-user configs gets written somewhere nobody will ever use. **Install behavior: User** is almost always the right choice here — it runs in the actual signed-in user's context, so the per-user configs land in the right place. The one thing that prefers `System` (importing the cert into the machine-wide `LocalMachine\Root` store) still works fine under `User` context: the script tries `LocalMachine\Root` first and automatically falls back to `CurrentUser\Root`, which every browser and CLI tool here already trusts.
>
> Because of this, assign the app to a **user group**, not a device group — `Install behavior: User` only runs while that user is signed in.
>
> **If you must use System context anyway** (your Intune setup only supports device-targeted Win32 apps, or you have another reason to require it), at minimum override `-CertDir` to a location every user can read and write, e.g. `-CertDir C:\ProgramData\netskope\certs` — the default `%USERPROFILE%\netskope` resolves to the SYSTEM account's own profile under System context (`C:\Windows\System32\config\systemprofile\netskope`), which ordinary users can't read. Adjust the detection rule's path to match. **This only fixes where the bundle file itself ends up** — it does not fix the per-user tool configuration (Git, npm, pip/certifi, VS Code, `.curlrc`), which still gets written into the SYSTEM profile instead of the real user's, so those tools still won't pick up the certificate. Pair a System-context Win32 app (for the machine-wide cert store) with a separate per-user mechanism — a logon script, scheduled task, or Proactive Remediation running as the logged-on user — that runs `-CertBundle C:\ProgramData\netskope\certs\netskope-cert-bundle.pem` against the shared copy to cover the per-user tools too.

**5. Requirements tab:** set the minimum OS version and architecture as usual for your fleet; there's no PowerShell-version-specific requirement to add.

**6. Detection rules:** add a **File** rule — path `%USERPROFILE%\netskope`, file `netskope-cert-bundle.pem`, "File exists". Intune only marks the app installed once the script has actually copied the bundle to that stable path, and won't try to reinstall it on every subsequent check-in.

**7. Assignment:** assign as **Required** to the user group from step 4. It installs silently the next time each user's device checks in — no interaction, no prompt (beyond whatever SmartScreen shows the first time an unsigned script runs, see [Antivirus / SmartScreen / Gatekeeper](antivirus-and-code-signing.md)).

## Option B: Platform script

Intune "platform scripts" (Devices → Scripts and remediations → Platform scripts) can't pass any arguments at all — the script just runs as-is. For this path, edit the parameter defaults directly in `configure_tools_windows.ps1`'s `param()` block before uploading (every flag from [Parameters Reference](parameters-reference.md) has a matching default there), then upload the edited file. The bash/Python scripts don't have an equivalent editable-defaults block today — they need at least one flag, so they aren't a fit for this option.

Platform scripts run in the **SYSTEM** context by default (with an option to run in the logged-on user's context) — the same User-vs-System reasoning from the Win32 app section above applies, including the `-CertDir` override if you're stuck running as SYSTEM; prefer running in the user's context if your Intune version offers that toggle for platform scripts.

## Optional: ongoing drift-checking with Intune Proactive Remediations

A separate, lighter-weight mechanism from the Win32 app above — use it to periodically confirm the bundle is still in place and re-apply configuration if not:

```powershell
# detection script
if (-not (Test-Path "$env:USERPROFILE\netskope\netskope-cert-bundle.pem")) {
    Write-Output "Cert bundle missing at expected location"
    exit 1   # non-compliant — triggers the remediation script
}
exit 0
```

```powershell
# remediation script — needs its own copy of the bundle available at this path,
# e.g. dropped there by the Win32 app above, or a separate config profile
pwsh -File "C:\path\to\configure_tools_windows.ps1" -CertBundle "$env:USERPROFILE\netskope\netskope-cert-bundle.pem"
```

Proactive Remediation scripts also run in the signed-in user's context by default — the same User-vs-System reasoning above applies here too.

## Also see

- [Deploying via Other MDM/RMM Tools (Generic)](deployment-generic-mdm.md) — Jamf, SCCM, BigFix, or anything else; not officially supported, but the same building blocks apply
