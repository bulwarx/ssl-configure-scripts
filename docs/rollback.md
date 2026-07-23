# Rollback

[← Back to README](../README.md)

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

> In the bash scripts, `--rollback` only triggers rollback if it is literally the first argument (`$1`) — see [Parameters Reference](parameters-reference.md) note 2.

Rollback reverses: environment variables, Git, cURL `.curlrc`, gcloud, npm, Composer, Yarn, Python `certifi` marker + pip cert, Java keytool aliases (`netskope-0`, `netskope-1`), VS Code `http.systemCertificates`, Windows Certificate Store (matched by thumbprint, with subject/issuer fallback), and Docker `ca.pem`.

For an MDM/RMM uninstall command, use the same rollback invocation — see the relevant [deployment guide](../README.md#deploying-via-a-specific-mdmrmm-tool) for exact placement (e.g. Intune's "Uninstall command" field).
