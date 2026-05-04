#[cfg(target_os = "windows")]
pub mod windows;

#[cfg(target_os = "macos")]
pub mod mac;

#[cfg(target_os = "linux")]
pub mod linux;

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
