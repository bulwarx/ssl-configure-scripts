# Replay Script

[← Back to README](../README.md)

All scripts offer an optional replay script (`configured_tools.bat` / `configured_tools.ps1` / `configured_tools.sh`) that records every configuration command applied. Run it on another machine with the same cert bundle path to replicate the configuration without re-running the full interactive script.

Whether it's written automatically, on request, or by default differs per script — see [Parameters Reference](parameters-reference.md) note 3 and the replay-script row in that table for the exact flag (`--no-replay` for Python, `-CreateReplay` for PowerShell, always-on for bash) and its default.

The replay script is written next to the main script (same directory) and contains only the commands actually applied — nothing that was already configured, and nothing skipped because a tool wasn't detected.
