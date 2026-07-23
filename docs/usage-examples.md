# Usage Examples by Scenario

[← Back to README](../README.md) · See [Parameters Reference](parameters-reference.md) for what each flag means.

```sh
# Interactive (no flags) — prompts for everything, sensible defaults offered
./configure_tools_mac.sh
./configure_tools_linux.sh
pwsh -File .\configure_tools_windows.ps1
python universal_configure_tools.py
```

```sh
# Silent download with tenant + org key — no prompts, but the org key is
# visible on the command line (process list / MDM policy logs). Fine for a
# single machine; prefer the --cert-bundle scenario below for fleet deployment.
./configure_tools_mac.sh    --tenant-name mytenant.eu.goskope.com --org-key your-org-key
./configure_tools_linux.sh  --tenant-name mytenant.eu.goskope.com --org-key your-org-key
pwsh -File .\configure_tools_windows.ps1 -TenantName mytenant.eu.goskope.com -OrgKey your-org-key
python universal_configure_tools.py --tenant-name mytenant.eu.goskope.com --org-key your-org-key
```

```sh
# Silent deployment with a pre-distributed bundle (recommended for MDM/at-scale —
# see "Creating a Cert Bundle Manually" for how to produce bundle.pem)
./configure_tools_mac.sh   --cert-bundle /path/to/bundle.pem
./configure_tools_linux.sh --cert-bundle /path/to/bundle.pem
pwsh -File .\configure_tools_windows.ps1 -CertBundle C:\netskope\bundle.pem
python universal_configure_tools.py --cert-bundle /path/to/bundle.pem
```

```sh
# Netskope-only bundle, silent (skip the public CA roots)
./configure_tools_mac.sh --tenant-name mytenant.eu.goskope.com --org-key your-org-key --netskope-only
pwsh -File .\configure_tools_windows.ps1 -TenantName mytenant.eu.goskope.com -OrgKey your-org-key -NetskopeOnly
python universal_configure_tools.py --cert-bundle /path/to/bundle.pem --netskope-only
```

```sh
# Custom bundle name/location, forcing a fresh download even if one already exists
./configure_tools_mac.sh --tenant-name mytenant.eu.goskope.com --org-key your-org-key \
  --cert-name corp-bundle.pem --cert-dir /opt/netskope --recreate

pwsh -File .\configure_tools_windows.ps1 -TenantName mytenant.eu.goskope.com -OrgKey your-org-key `
  -CertName corp-bundle.pem -CertDir C:\ProgramData\netskope -Recreate
```

```sh
# Rollback — undo everything, on every platform
./configure_tools_mac.sh --rollback           # must be the first argument, see Parameters Reference note 2
./configure_tools_linux.sh --rollback         # ditto
pwsh -File .\configure_tools_windows.ps1 -Rollback
python universal_configure_tools.py --rollback
```

```sh
# Replay script control (see Parameters Reference note 3 for why the flags/defaults differ)
python universal_configure_tools.py --cert-bundle /path/to/bundle.pem --no-replay   # opt out
pwsh -File .\configure_tools_windows.ps1 -CertBundle C:\netskope\bundle.pem -CreateReplay  # opt in
# bash: no flag needed — configured_tools.sh is always written
```

See the [deployment guides](../README.md#deploying-via-a-specific-mdmrmm-tool) for MDM/RMM-specific walkthroughs (Intune, Jamf, SCCM, BigFix).
