# Parameters Reference

[← Back to README](../README.md)

Every parameter below is optional — supply only what a given scenario needs. Naming differs by convention (kebab-case flags for bash/Python, PascalCase named parameters for PowerShell) but the meaning and default are identical unless noted.

Once the tenant name + org key (or an existing cert bundle path) resolve to a non-empty value — from a flag/parameter, or a hardcoded default — **every** prompt is skipped, not just the ones that ask for those two values directly. That includes "use an existing bundle?", "recreate certificate bundle?", and "create replay script?".

| Purpose | bash (`configure_tools_mac.sh` / `_linux.sh`) | Python (`universal_configure_tools.py`) | PowerShell (`configure_tools_windows.ps1`) | Default | Notes |
|---|---|---|---|---|---|
| Netskope tenant hostname | `--tenant-name VALUE` | `--tenant-name VALUE` | `-TenantName VALUE` | *(prompted if empty and not running silently)* | e.g. `mytenant.eu.goskope.com`. Combined with the org key, builds the two cert-download URLs. |
| Netskope org key | `--org-key VALUE` | `--org-key VALUE` | `-OrgKey VALUE` | *(prompted if empty and not running silently)* | Supplying **both** tenant name and org key is what puts a script into silent/unattended mode. |
| Existing cert bundle path | `--cert-bundle VALUE` | `--cert-bundle VALUE` | `-CertBundle VALUE` (also accepts a bare positional value, see note 1) | *(none — falls through to the download flow, or a prompt, if empty)* | Skips the download entirely; the file is validated for a PEM certificate, then **copied** to the `cert-dir`/`cert-name` location below. Takes precedence over tenant/org-key if both are given. **This is the recommended flag for MDM/at-scale deployment** — see [Deployment Guides](deployment-intune.md). |
| Bundle file name | `--cert-name VALUE` | `--cert-name VALUE` | `-CertName VALUE` | `netskope-cert-bundle.pem` | |
| Bundle directory | `--cert-dir VALUE` | `--cert-dir VALUE` | `-CertDir VALUE` | `~/netskope` (bash/Python) or `%USERPROFILE%\netskope` (PowerShell) | |
| Force regeneration | `--recreate` | `--recreate` | `-Recreate` | off | Re-download (or re-copy, if using `--cert-bundle`) even if a bundle already exists at the target path. Without it, an existing file there is reused as-is. |
| Netskope-only bundle | `--netskope-only` | `--netskope-only` | `-NetskopeOnly` | off (full bundle is the default) | Skips the public `curl.se` CA roots. Only use this if you're certain every connection your tools make is intercepted by the proxy. |
| Full bundle (explicit) | `--full-bundle` *(no-op — already the default)* | `--full-bundle` *(no-op — already the default)* | *(not declared — passing it throws an error)* | on | Kept in bash/Python only for backward compatibility with older invocations. Don't pass it to the PowerShell script. |
| Rollback | `--rollback` (see note 2) | `--rollback` (any position) | `-Rollback` (any position) | off | Removes all Netskope SSL configuration from every detected tool. Doesn't need or touch a cert bundle file. |
| Replay script | *(always written — no flag)* | `--no-replay` (see note 3) | `-CreateReplay` (see note 3) | see note 3 | Writes `configured_tools.sh` / `.ps1` / `.bat`, recording every configuration command applied, for reuse on another machine (see [Replay Script](replay-script.md)). |

**Notes:**
1. `-CertBundle` is the only PowerShell parameter that also accepts a bare, unnamed value: `pwsh -File configure_tools_windows.ps1 C:\bundle.pem` works the same as `-CertBundle C:\bundle.pem`. Every other PowerShell parameter must be named.
2. In the bash scripts, `--rollback` only triggers rollback if it is **literally the first argument** (`$1`) — e.g. `./configure_tools_mac.sh --rollback` works, but `./configure_tools_mac.sh --cert-dir ~/x --rollback` does not trigger rollback. Python and PowerShell recognize `--rollback`/`-Rollback` in any position.
3. Replay-script behavior differs by script: the **bash scripts always write `configured_tools.sh`**, unconditionally, with no way to opt out. **Python** creates it by default during a silent/unattended run (tenant+org-key, or `--cert-bundle`) unless you pass `--no-replay`; interactively it still asks. **PowerShell** is the opposite polarity — `-CreateReplay` is an opt-in switch (off by default, even during a silent run); without it, a silent PowerShell run simply skips the replay file rather than asking.
4. Named-value flags accept both `--flag value` and `--flag=value` in bash/Python. PowerShell uses `-Flag value` or `-Flag:value` — the `-Flag=value` form is not supported.

For contexts that run `configure_tools_windows.ps1` with no arguments at all (Intune "platform scripts" and similar), edit the parameter defaults directly in its `param()` block instead of passing flags — every parameter above has a matching default there. Run `Get-Help .\configure_tools_windows.ps1 -Full` for the built-in parameter descriptions and examples.

See [Usage Examples](usage-examples.md) for these parameters applied to real scenarios.
