#[cfg(target_os = "windows")]
pub mod windows;

#[cfg(target_os = "macos")]
pub mod mac;

#[cfg(target_os = "linux")]
pub mod linux;

#[cfg(not(target_os = "windows"))]
use std::path::PathBuf;

/// Set a persistent user-scope environment variable.
pub fn set_env_var(name: &str, value: &str) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    return windows::set_env_var(name, value);

    #[cfg(target_os = "macos")]
    return mac::set_env_var(name, value);

    #[cfg(target_os = "linux")]
    return linux::set_env_var(name, value);

    #[allow(unreachable_code)]
    Err("Unsupported platform".into())
}

/// Remove a persistent user-scope environment variable.
pub fn remove_env_var(name: &str) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    return windows::remove_env_var(name);

    #[cfg(target_os = "macos")]
    return mac::remove_env_var(name);

    #[cfg(target_os = "linux")]
    return linux::remove_env_var(name);

    #[allow(unreachable_code)]
    Err("Unsupported platform".into())
}

/// Fix the process PATH on macOS/Linux GUI launches.
///
/// A GUI app launched from Finder/Dock/a `.desktop` file is started by
/// launchd/the desktop session, not a login shell — it inherits a minimal
/// PATH (typically just `/usr/bin:/bin:/usr/sbin:/sbin`) that omits
/// Homebrew (`/opt/homebrew/bin`), nvm/volta/asdf shims, `~/.cargo/bin`, etc.
/// Every tool this app detects or configures via a bare command name (npm,
/// pnpm, az, yarn, ...) is invisible until this is fixed — and it needs
/// fixing for real subprocess spawns too, not just `which()` lookups, since
/// `Command::new("npm")` also resolves against process PATH.
///
/// Ask the user's own login shell for its real PATH (sources .zprofile/
/// .zshrc/.bashrc so it picks up whatever the user's setup adds — nvm, asdf,
/// Homebrew shellenv, etc.) and fall back to appending common tool
/// directories if that fails or comes back empty.
#[cfg(not(target_os = "windows"))]
pub fn fix_path_env() {
    use std::process::Command;

    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    // Markers guard against .zshrc/.bashrc printing a MOTD/banner before the
    // PATH we actually asked for.
    let marker = "__SSL_CONFIGURATOR_PATH__";
    let script = format!("echo {marker}$PATH{marker}");

    let shell_path = Command::new(&shell)
        .args(["-ilc", &script])
        .output()
        .ok()
        .and_then(|out| {
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            let start = stdout.find(marker)? + marker.len();
            let end = stdout[start..].find(marker)? + start;
            let path = stdout[start..end].trim();
            if path.is_empty() { None } else { Some(path.to_string()) }
        });

    let mut path = shell_path.unwrap_or_else(|| std::env::var("PATH").unwrap_or_default());

    let home = dirs::home_dir().unwrap_or_default();
    let fallback_dirs = [
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/opt/homebrew/sbin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/local/sbin"),
        PathBuf::from("/home/linuxbrew/.linuxbrew/bin"),
        home.join(".cargo/bin"),
        home.join(".local/bin"),
        home.join("Library/pnpm"),
        home.join(".local/share/pnpm"),
    ];
    for dir in fallback_dirs {
        if !dir.is_dir() {
            continue;
        }
        let dir_str = dir.to_string_lossy();
        if !path.split(':').any(|p| p == dir_str) {
            path = format!("{}:{}", dir_str, path);
        }
    }

    // SAFETY: called from `run()` before Tauri spawns any threads.
    unsafe { std::env::set_var("PATH", path) };
}

#[cfg(target_os = "windows")]
pub fn fix_path_env() {
    // Windows GUI apps inherit the full user/system PATH from the registry
    // via the environment broadcast — no fix-up needed.
}
