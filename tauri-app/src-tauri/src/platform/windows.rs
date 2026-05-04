use crate::tools::ToolResult;
use serde_json::Value;
use std::{
    fs,
    path::PathBuf,
};
use winreg::{enums::*, RegKey};

// ── Environment variables (HKCU\Environment) ─────────────────────────────────

pub fn set_env_var(name: &str, value: &str) -> Result<(), String> {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let env = hkcu
        .open_subkey_with_flags("Environment", KEY_SET_VALUE)
        .map_err(|e| format!("Cannot open HKCU\\Environment: {}", e))?;
    env.set_value(name, &value)
        .map_err(|e| format!("Cannot set {}: {}", name, e))
}

pub fn remove_env_var(name: &str) -> Result<(), String> {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let env = hkcu
        .open_subkey_with_flags("Environment", KEY_SET_VALUE)
        .map_err(|e| e.to_string())?;
    env.delete_value(name)
        .map_err(|e| format!("Cannot remove {}: {}", name, e))
}

// ── Windows Certificate Store (certutil, elevation) ───────────────────────────

/// Check whether the current process is running with admin privileges.
/// Uses a write-probe on HKLM which only succeeds when elevated.
pub fn is_elevated() -> bool {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    hklm.open_subkey_with_flags(
        "SOFTWARE\\Microsoft\\Windows\\CurrentVersion",
        KEY_WRITE,
    )
    .is_ok()
}

pub async fn configure_cert_store(bundle_path: &str) -> ToolResult {
    // Decide store up-front based on elevation — never pop UAC mid-flow.
    let (args, scope_label) = if is_elevated() {
        (
            vec!["-addstore", "-f", "Root", bundle_path],
            "computer store",
        )
    } else {
        (
            vec!["-addstore", "-f", "-user", "Root", bundle_path],
            "user store",
        )
    };

    let result = crate::tools::silent_command("certutil")
        .args(&args)
        .output();

    match result {
        Ok(o) if o.status.success() => ToolResult {
            id: "windows_certstore".into(),
            name: "Windows Certificate Store".into(),
            ok: true,
            message: format!(
                "Imported to Trusted Root ({}){}",
                scope_label,
                if scope_label == "user store" {
                    " — run as admin for machine-wide install"
                } else {
                    ""
                }
            ),
            command: Some(format!("certutil {}", args.join(" "))),
        },
        Ok(o) => ToolResult {
            id: "windows_certstore".into(),
            name: "Windows Certificate Store".into(),
            ok: false,
            message: format!(
                "certutil failed (exit {}): {}",
                o.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&o.stderr).trim()
            ),
            command: None,
        },
        Err(e) => ToolResult {
            id: "windows_certstore".into(),
            name: "Windows Certificate Store".into(),
            ok: false,
            message: format!("Failed to run certutil: {}", e),
            command: None,
        },
    }
}

pub async fn rollback_cert_store() -> ToolResult {
    // Match the install scope — never pop UAC mid-flow.
    let scope_flag: &[&str] = if is_elevated() { &[] } else { &["-user"] };

    for alias in &["netskope-0", "netskope-1"] {
        let mut args = vec!["-delstore"];
        args.extend_from_slice(scope_flag);
        args.push("Root");
        args.push(alias);
        let _ = crate::tools::silent_command("certutil")
            .args(&args)
            .output();
    }

    ToolResult {
        id: "windows_certstore".into(),
        name: "Windows Certificate Store".into(),
        ok: true,
        message: format!(
            "Netskope certs removed from Trusted Root ({})",
            if is_elevated() { "computer store" } else { "user store" }
        ),
        command: None,
    }
}

// ── VS Code ───────────────────────────────────────────────────────────────────

pub fn configure_vscode(_bundle_path: &str) -> ToolResult {
    // http.systemCertificates instructs VS Code to trust the Windows cert store,
    // so no bundle path is needed here — just enable the flag.
    let settings_path = dirs::config_dir()
        .unwrap_or_default()
        .join("Code")
        .join("User")
        .join("settings.json");

    match update_json_file(&settings_path, "http.systemCertificates", Value::Bool(true)) {
        Ok(_) => ToolResult {
            id: "vscode".into(),
            name: "VS Code".into(),
            ok: true,
            message: "http.systemCertificates: true set in settings.json".into(),
            command: None,
        },
        Err(e) => ToolResult {
            id: "vscode".into(),
            name: "VS Code".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn rollback_vscode() -> ToolResult {
    let settings_path = dirs::config_dir()
        .unwrap_or_default()
        .join("Code")
        .join("User")
        .join("settings.json");

    match remove_json_key(&settings_path, "http.systemCertificates") {
        Ok(_) => ToolResult {
            id: "vscode".into(),
            name: "VS Code".into(),
            ok: true,
            message: "http.systemCertificates removed from settings.json".into(),
            command: None,
        },
        Err(e) => ToolResult {
            id: "vscode".into(),
            name: "VS Code".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

// ── Docker Desktop ────────────────────────────────────────────────────────────

pub fn configure_docker(bundle_path: &str) -> ToolResult {
    let docker_dir = dirs::home_dir().unwrap_or_default().join(".docker");
    let _ = fs::create_dir_all(&docker_dir);
    let ca_path = docker_dir.join("ca.pem");

    match fs::copy(bundle_path, &ca_path) {
        Ok(_) => ToolResult {
            id: "docker".into(),
            name: "Docker Desktop".into(),
            ok: true,
            message: format!("Bundle copied to {}", ca_path.display()),
            command: Some(format!(
                "copy \"{}\" \"{}\"",
                bundle_path,
                ca_path.display()
            )),
        },
        Err(e) => ToolResult {
            id: "docker".into(),
            name: "Docker Desktop".into(),
            ok: false,
            message: e.to_string(),
            command: None,
        },
    }
}

pub fn rollback_docker() -> ToolResult {
    let ca_path = dirs::home_dir().unwrap_or_default().join(".docker").join("ca.pem");
    if !ca_path.exists() {
        return ToolResult {
            id: "docker".into(),
            name: "Docker Desktop".into(),
            ok: true,
            message: "~/.docker/ca.pem not found — nothing to do".into(),
            command: None,
        };
    }
    match fs::remove_file(&ca_path) {
        Ok(_) => ToolResult {
            id: "docker".into(),
            name: "Docker Desktop".into(),
            ok: true,
            message: "~/.docker/ca.pem deleted".into(),
            command: None,
        },
        Err(e) => ToolResult {
            id: "docker".into(),
            name: "Docker Desktop".into(),
            ok: false,
            message: e.to_string(),
            command: None,
        },
    }
}

// ── Java / JDK (keytool) ──────────────────────────────────────────────────────

pub async fn configure_jdk(bundle_path: &str) -> ToolResult {
    let jdks = find_jdks();
    if jdks.is_empty() {
        return ToolResult {
            id: "jdk".into(),
            name: "Java / JDK (keytool)".into(),
            ok: false,
            message: "No JDK installations found".into(),
            command: None,
        };
    }

    let mut ok_count = 0;
    let mut msgs = Vec::new();

    for jdk in &jdks {
        let keytool = jdk.join("bin").join("keytool.exe");
        if !keytool.exists() {
            continue;
        }

        for (i, alias) in ["netskope-0", "netskope-1"].iter().enumerate() {
            // Delete existing alias first (ignore errors)
            let _ = crate::tools::silent_command(&keytool)
                .args([
                    "-delete",
                    "-alias",
                    alias,
                    "-cacerts",
                    "-storepass",
                    "changeit",
                    "-noprompt",
                ])
                .output();

            let result = crate::tools::silent_command(&keytool)
                .args([
                    "-import",
                    "-alias",
                    alias,
                    "-cacerts",
                    "-file",
                    bundle_path,
                    "-storepass",
                    "changeit",
                    "-noprompt",
                ])
                .output();

            match result {
                Ok(o) if o.status.success() => {
                    if i == 0 {
                        ok_count += 1;
                        msgs.push(format!(
                            "{} imported",
                            jdk.file_name().unwrap_or_default().to_string_lossy()
                        ));
                    }
                }
                Ok(o) => {
                    // System-installed JDKs need admin to write to cacerts;
                    // surface the failure rather than pop a mid-flow UAC prompt.
                    let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                    msgs.push(format!(
                        "{} skipped ({})",
                        jdk.file_name().unwrap_or_default().to_string_lossy(),
                        if stderr.contains("Access") || stderr.contains("denied") {
                            "requires admin"
                        } else {
                            "keytool error"
                        }
                    ));
                }
                Err(_) => {}
            }
        }
    }

    ToolResult {
        id: "jdk".into(),
        name: "Java / JDK (keytool)".into(),
        ok: ok_count > 0,
        message: if ok_count > 0 {
            format!("{} JDK(s) configured — {}", ok_count, msgs.join(", "))
        } else {
            "keytool import failed for all JDKs".into()
        },
        command: None,
    }
}

pub async fn rollback_jdk() -> ToolResult {
    let jdks = find_jdks();
    let mut cleaned = 0;

    for jdk in &jdks {
        let keytool = jdk.join("bin").join("keytool.exe");
        if !keytool.exists() {
            continue;
        }
        for alias in &["netskope-0", "netskope-1"] {
            let _ = crate::tools::silent_command(&keytool)
                .args([
                    "-delete",
                    "-alias",
                    alias,
                    "-cacerts",
                    "-storepass",
                    "changeit",
                    "-noprompt",
                ])
                .output();
        }
        cleaned += 1;
    }

    ToolResult {
        id: "jdk".into(),
        name: "Java / JDK (keytool)".into(),
        ok: true,
        message: format!("Netskope aliases removed from {} JDK(s)", cleaned),
        command: None,
    }
}

fn find_jdks() -> Vec<PathBuf> {
    let mut jdks = Vec::new();

    // JAVA_HOME
    if let Ok(java_home) = std::env::var("JAVA_HOME") {
        let p = PathBuf::from(java_home);
        if p.join("bin").join("keytool.exe").exists() {
            jdks.push(p);
        }
    }

    // Registry: HKLM\SOFTWARE\JavaSoft
    for root_key in &[
        r"SOFTWARE\JavaSoft\JDK",
        r"SOFTWARE\JavaSoft\Java Development Kit",
        r"SOFTWARE\Eclipse Adoptium\JDK",
        r"SOFTWARE\Eclipse Foundation\JDK",
        r"SOFTWARE\Microsoft\JDK",
    ] {
        let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
        if let Ok(jdk_key) = hklm.open_subkey(root_key) {
            for version in jdk_key.enum_keys().filter_map(|r| r.ok()) {
                if let Ok(ver_key) = jdk_key.open_subkey(&version) {
                    let home: Result<String, _> = ver_key.get_value("JavaHome");
                    if let Ok(home) = home {
                        let p = PathBuf::from(home);
                        if p.join("bin").join("keytool.exe").exists()
                            && !jdks.contains(&p)
                        {
                            jdks.push(p);
                        }
                    }
                }
            }
        }
    }

    // Common install locations
    let common_roots = [
        r"C:\Program Files\Eclipse Adoptium",
        r"C:\Program Files\Microsoft",
        r"C:\Program Files\Java",
        r"C:\Program Files\BellSoft",
    ];
    for root in &common_roots {
        let root_path = PathBuf::from(root);
        if root_path.exists() {
            if let Ok(entries) = fs::read_dir(&root_path) {
                for entry in entries.filter_map(|e| e.ok()) {
                    let p = entry.path();
                    if p.join("bin").join("keytool.exe").exists() && !jdks.contains(&p) {
                        jdks.push(p);
                    }
                }
            }
        }
    }

    jdks
}

// ── Tool detection (Windows-specific additions) ───────────────────────────────

pub fn detect_windows_tools() -> Vec<crate::tools::ToolStatus> {
    vec![
        detect_jdk(),
        detect_vscode(),
        detect_windows_certstore(),
        detect_docker(),
    ]
}

fn detect_jdk() -> crate::tools::ToolStatus {
    let jdks = find_jdks();
    let installed = !jdks.is_empty();
    crate::tools::ToolStatus {
        id: "jdk".to_string(),
        name: "Java / JDK (keytool)".to_string(),
        group: "Windows Platform".to_string(),
        installed,
        path: jdks.first().map(|p| p.to_string_lossy().to_string()),
        version: if installed {
            Some(format!("{} JDK(s) found", jdks.len()))
        } else {
            None
        },
    }
}

fn detect_vscode() -> crate::tools::ToolStatus {
    let settings = dirs::config_dir()
        .unwrap_or_default()
        .join("Code")
        .join("User")
        .join("settings.json");
    let installed = settings.exists() || which::which("code").is_ok();
    crate::tools::ToolStatus {
        id: "vscode".to_string(),
        name: "VS Code".to_string(),
        group: "Windows Platform".to_string(),
        installed,
        path: which::which("code")
            .ok()
            .map(|p| p.to_string_lossy().to_string()),
        version: None,
    }
}

fn detect_windows_certstore() -> crate::tools::ToolStatus {
    crate::tools::ToolStatus {
        id: "windows_certstore".to_string(),
        name: "Windows Certificate Store".to_string(),
        group: "Windows Platform".to_string(),
        installed: true, // always available on Windows
        path: None,
        version: None,
    }
}

fn detect_docker() -> crate::tools::ToolStatus {
    let installed = which::which("docker").is_ok()
        || PathBuf::from(r"C:\Program Files\Docker\Docker\Docker Desktop.exe").exists();
    crate::tools::ToolStatus {
        id: "docker".to_string(),
        name: "Docker Desktop".to_string(),
        group: "Windows Platform".to_string(),
        installed,
        path: which::which("docker")
            .ok()
            .map(|p| p.to_string_lossy().to_string()),
        version: None,
    }
}

// ── JSON helpers ──────────────────────────────────────────────────────────────

fn update_json_file(path: &PathBuf, key: &str, value: Value) -> Result<(), String> {
    let mut obj: Value = if path.exists() {
        let content = fs::read_to_string(path).map_err(|e| e.to_string())?;
        serde_json::from_str(&content).unwrap_or(Value::Object(Default::default()))
    } else {
        Value::Object(Default::default())
    };

    if let Value::Object(ref mut map) = obj {
        map.insert(key.to_string(), value);
    }

    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let pretty = serde_json::to_string_pretty(&obj).map_err(|e| e.to_string())?;
    fs::write(path, pretty).map_err(|e| e.to_string())
}

fn remove_json_key(path: &PathBuf, key: &str) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let content = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut obj: Value =
        serde_json::from_str(&content).unwrap_or(Value::Object(Default::default()));
    if let Value::Object(ref mut map) = obj {
        map.remove(key);
    }
    let pretty = serde_json::to_string_pretty(&obj).map_err(|e| e.to_string())?;
    fs::write(path, pretty).map_err(|e| e.to_string())
}
