mod cert;
mod platform;
mod replay;
mod rollback;
mod tools;

/// When running elevated, the admin account's %LOCALAPPDATA% may not exist or
/// may not be writable — WebView2 then fails with "couldn't create data
/// directory". Pre-creating the folder and pinning `WEBVIEW2_USER_DATA_FOLDER`
/// makes the path explicit and guaranteed to exist before WebView2 boots.
fn prepare_webview_data_dir() {
    let base = dirs::data_local_dir()
        .or_else(|| dirs::home_dir().map(|h| h.join("AppData").join("Local")))
        .unwrap_or_else(std::env::temp_dir);
    let dir = base.join("Bulwarx").join("SSLConfigurator").join("EBWebView");
    let _ = std::fs::create_dir_all(&dir);
    // SAFETY: called from `run()` before Tauri spawns any threads, so no
    // other thread can race on the env block.
    unsafe { std::env::set_var("WEBVIEW2_USER_DATA_FOLDER", &dir) };
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    prepare_webview_data_dir();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            cert::test_connection,
            cert::download_bundle,
            cert::default_bundle_dir,
            tools::detect_tools,
            tools::configure_tools,
            rollback::rollback_tools,
            replay::generate_replay_script,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
