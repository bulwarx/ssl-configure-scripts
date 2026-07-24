# Antivirus / Windows SmartScreen / macOS Gatekeeper Warning

[← Back to README](../README.md)

These scripts and the GUI app may be flagged, blocked, or quarantined by antivirus software, endpoint protection, Windows SmartScreen, or macOS Gatekeeper. This is expected given what the tool does:

- **Fetches a certificate from a third party** (the Netskope tenant) and installs it into user and system trust stores.
- **Modifies user and system environment variables** to point tools at the certificate bundle.
- **Scans the system for installed applications** (Python, Java/JDK, VS Code, Docker, CLIs, etc.) to configure each one.
- The macOS app is **ad-hoc signed but not notarized** (no paid Apple Developer / code-signing certificate — see below). Windows builds are still unsigned, so SmartScreen may show an "unknown publisher" warning; macOS Gatekeeper will show an "unidentified developer" prompt.

These behaviors are legitimate and core to the tool's purpose, but they resemble patterns that security software treats as suspicious. If the script or app is blocked:

- On Windows SmartScreen, click **More info → Run anyway**.
- Allow / unblock the file in your antivirus or endpoint protection, or add an exclusion for it.
- For the PowerShell script you may need to allow execution: `powershell.exe -ExecutionPolicy Bypass -File .\configure_tools_windows.ps1` (or `pwsh -ExecutionPolicy Bypass -File ...` — both PowerShell editions work, see [Requirements](../README.md#requirements)).
- On macOS, opening the GUI app's `.dmg`/`.app` for the first time shows **"Apple could not verify 'SSL Configurator' is free of malware that may harm your Mac or compromise your privacy"**, with only a "Move to Trash" option in the dialog — this is not real corruption, and it's expected given the app is ad-hoc signed rather than signed with a paid Apple Developer ID. Unlike a Developer-ID-signed (but unnotarized) app, an ad-hoc-signed app doesn't get an "Open Anyway" button in System Settings → Privacy & Security — Gatekeeper treats ad-hoc signing as still effectively unidentified. The only way through today is Terminal:

    ```sh
    xattr -cr "/path/to/SSL Configurator.app"
    ```

  The app is ad-hoc signed (no cost, no Apple Developer account), which is enough to satisfy Apple Silicon's requirement that every binary be signed — without it, macOS would refuse to run the app at all with an even harder **"is damaged and can't be opened"** error and no `xattr` workaround. Eliminating this prompt entirely (no Terminal step for anyone) requires a paid Apple Developer Program enrollment and full notarization, which isn't set up.

Only run these tools from a source you trust, and review the contents before executing.
