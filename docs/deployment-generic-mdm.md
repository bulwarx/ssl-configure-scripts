# Deploying via Other MDM/RMM Tools (Generic)

[← Back to README](../README.md) · See also: [Parameters Reference](parameters-reference.md) · [Creating a Cert Bundle Manually](creating-a-cert-bundle.md)

**Microsoft Intune is the only MDM this repo officially supports, with a full tested walkthrough — see [Deploying via Microsoft Intune](deployment-intune.md).** Everything below is generic guidance for adapting these scripts to whatever other MDM/RMM tool you use (Jamf Pro, SCCM/ConfigMgr, BigFix, or anything else) — it isn't tool-specific and hasn't been validated against any of them, but the underlying scripts don't care what invokes them, so the same building blocks apply everywhere.

Every deployment onto an MDM/RMM tool boils down to the same four building blocks:

**1. Get the script and a cert bundle onto the endpoint.** Most tools let you attach files alongside a script/package (however that tool packages content) — otherwise a small wrapper step that copies both into place first works too. See [Creating a Cert Bundle Manually](creating-a-cert-bundle.md) to produce the `.pem` without running any script interactively.

**2. Run the install command with `--cert-bundle`/`-CertBundle`.** This is the recommended flag for any MDM/RMM path — it never puts the Netskope org key on the endpoint, in a log, or in a command line anywhere (see [Parameters Reference](parameters-reference.md)):
```sh
# Linux/macOS
/bin/bash configure_tools_mac.sh --cert-bundle /path/to/bundle.pem

# Windows (built-in Windows PowerShell 5.1 or PowerShell 7+, either works)
powershell.exe -ExecutionPolicy Bypass -File configure_tools_windows.ps1 -CertBundle "C:\path\to\bundle.pem"

# Any platform
python universal_configure_tools.py --cert-bundle /path/to/bundle.pem
```
If your tool only supports **positional** parameters instead of named flags (e.g. Jamf Pro's `$4`–`$11` script parameters), wrap the call in a 1-line script that maps the tool's positional value onto `--cert-bundle`:
```sh
#!/bin/bash
# $4 here stands in for whatever positional slot your tool provides
/bin/bash /path/to/configure_tools_mac.sh --cert-bundle "$4"
```
If your tool can only run a script with **no arguments at all** (e.g. Intune "platform scripts", or similarly restrictive script-only mechanisms elsewhere), edit the parameter defaults directly in the script instead of passing flags — `configure_tools_windows.ps1`'s `param()` block has a matching default for every flag in [Parameters Reference](parameters-reference.md); the bash/Python scripts don't have an equivalent editable-defaults block today, so they need at least one flag/argument to run unattended.

**3. Verify success with a detection/compliance check.** The script copies the given bundle to a canonical, stable location — `~/netskope/netskope-cert-bundle.pem` (bash/Python) or `%USERPROFILE%\netskope\netskope-cert-bundle.pem` (PowerShell), or wherever `--cert-dir`/`--cert-name` point — before configuring anything. Most tools' detection/compliance mechanism is a "file exists" check; point it at that path.

**4. Wire up rollback/uninstall.** Every script's `--rollback`/`-Rollback` mode removes all Netskope SSL configuration without needing the cert bundle — see [Rollback](rollback.md). Use the same invocation as your tool's uninstall/removal action:
```sh
/bin/bash configure_tools_mac.sh --rollback              # must be the first argument in bash — see Parameters Reference note 2
pwsh.exe -File configure_tools_windows.ps1 -Rollback
python universal_configure_tools.py --rollback
```

**A caveat worth checking regardless of tool:** everything this script configures (Git, npm, pip/certifi, VS Code, Docker, `.curlrc`) lives under the *signed-in user's* profile (`$HOME`/`%USERPROFILE%`), not a machine-wide location. If your MDM/RMM tool runs its install/script step as `root`/`SYSTEM` rather than in the logged-on user's context, those per-user configs get written to the wrong profile and the tools won't actually pick up the certificate. Prefer whatever "run as the logged-on user" option your tool offers. The one thing that does benefit from elevated/system context — importing the cert into a machine-wide trust store (Windows Certificate Store) — already falls back gracefully to a per-user store if it can't write to the machine one, so running in user context doesn't break that part.

If your tool only runs as `SYSTEM`/`root` with no per-user option, at minimum override `--cert-dir`/`-CertDir` to a location every user can read, e.g. `C:\ProgramData\netskope\certs` on Windows or `/usr/local/share/netskope` on Linux/macOS — the default (`%USERPROFILE%\netskope`/`~/netskope`) resolves to the SYSTEM/root account's own profile, not somewhere a real user's tools would ever look. This only fixes where the bundle file itself lives, not the per-user tool configuration — you'd still need a second, per-user-context run (a logon script, scheduled task, or your tool's user-context equivalent) pointed at that shared path to actually cover Git/npm/pip/VS Code/etc.

If you get this working reliably on a specific tool and want to contribute a dedicated guide for it, a PR is welcome.
