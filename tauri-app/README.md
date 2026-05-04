# Bulwarx SSL Configurator — Tauri App

A cross-platform GUI for the ssl-configure-scripts project. Built with Tauri 2 (Rust backend + HTML/CSS/JS frontend).

## Prerequisites

| Tool | Install |
|------|---------|
| Rust (stable) | https://rustup.rs |
| Node.js 18+ | https://nodejs.org |
| Tauri CLI | `npm install -g @tauri-apps/cli@latest` |
| Linux only | `sudo apt install libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf` |

## Setup

Logos and icons are committed — no copy step needed. Just install the prerequisites above and you're ready.

## Development

```sh
# Open dev window with hot-reload
cd tauri-app
cargo tauri dev
```

## Production Build

```sh
cd tauri-app
cargo tauri build
```

Output:
- Windows: `src-tauri/target/release/bundle/nsis/*.exe`
- macOS:   `src-tauri/target/release/bundle/dmg/*.dmg`
- Linux:   `src-tauri/target/release/bundle/appimage/*.AppImage`

## Architecture

```
tauri-app/
├── src-tauri/        Rust backend
│   ├── src/
│   │   ├── lib.rs          Tauri app entry + command registration
│   │   ├── cert.rs         Certificate download + bundle creation
│   │   ├── tools.rs        Tool detection + configuration
│   │   ├── rollback.rs     Rollback all tool configuration
│   │   ├── replay.rs       Replay script generation
│   │   └── platform/       OS-specific env var + cert store operations
│   ├── Cargo.toml
│   └── tauri.conf.json
└── frontend/         HTML/CSS/JS wizard UI
    ├── index.html
    ├── styles.css
    └── app.js        Tauri IPC — calls Rust via invoke()
```

## CI / Releases

Push a tag matching `v*` (e.g. `v2.1.0`) to trigger the GitHub Actions build.
Artifacts are automatically attached to the GitHub Release.
