use serde::{Deserialize, Serialize};
use std::{
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use tauri::Emitter;
use which::which;

/// Create a `Command` that does NOT flash a console window on Windows.
/// Must be used for every subprocess spawn in a GUI app — otherwise
/// any .cmd/.bat invocation or console-mode tool briefly opens a black window.
pub(crate) fn silent_command<S: AsRef<OsStr>>(prog: S) -> Command {
    let mut cmd = Command::new(prog);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    cmd
}

#[derive(Serialize, Clone)]
pub struct ToolStatus {
    pub id: String,
    pub name: String,
    pub group: String,
    pub installed: bool,
    pub path: Option<String>,
    pub version: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct ToolResult {
    pub id: String,
    pub name: String,
    pub ok: bool,
    pub message: String,
    pub command: Option<String>,
}

// ── Detection ────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn detect_tools() -> Vec<ToolStatus> {
    let mut tools = vec![
        // Baseline — always relevant (these env vars are read by git, node, python, etc.)
        ToolStatus {
            id: "ssl_env".to_string(),
            name: "SSL environment variables".to_string(),
            group: "Developer Tools".to_string(),
            installed: true,
            path: None,
            version: None,
        },
        // Developer Tools
        detect_cmd("git", "Git", "Developer Tools"),
        detect_cmd("openssl", "OpenSSL", "Developer Tools"),
        detect_cmd("curl", "cURL", "Developer Tools"),
        detect_cmd("go", "Go", "Developer Tools"),
        detect_cmd("ruby", "Ruby", "Developer Tools"),
        detect_cmd("composer", "PHP Composer", "Developer Tools"),
        detect_cmd("cargo", "Cargo (Rust)", "Developer Tools"),
        // Package Managers
        detect_cmd("npm", "NPM / Node.js", "Package Managers"),
        detect_python(),
        detect_cmd("yarn", "Yarn", "Package Managers"),
        detect_cmd("pnpm", "pnpm", "Package Managers"),
        // Cloud CLIs
        detect_cmd("aws", "AWS CLI", "Cloud CLIs"),
        detect_cmd("gcloud", "Google Cloud CLI", "Cloud CLIs"),
        detect_cmd("az", "Azure CLI", "Cloud CLIs"),
        detect_cmd("oci", "Oracle Cloud CLI", "Cloud CLIs"),
    ];

    #[cfg(target_os = "windows")]
    tools.extend(crate::platform::windows::detect_windows_tools());

    tools
}

fn detect_cmd(cmd: &str, name: &str, group: &str) -> ToolStatus {
    // Detection is just a PATH lookup — no subprocess, no hang, no CMD flash.
    // Version strings can be fetched later on demand; they're cosmetic.
    match which(cmd) {
        Ok(path) => ToolStatus {
            id: cmd.to_string(),
            name: name.to_string(),
            group: group.to_string(),
            installed: true,
            path: Some(path.to_string_lossy().to_string()),
            version: None,
        },
        Err(_) => ToolStatus {
            id: cmd.to_string(),
            name: name.to_string(),
            group: group.to_string(),
            installed: false,
            path: None,
            version: None,
        },
    }
}

fn detect_python() -> ToolStatus {
    for cmd in &["py", "python3", "python"] {
        if let Ok(path) = which(cmd) {
            return ToolStatus {
                id: "python".to_string(),
                name: "Python / pip".to_string(),
                group: "Package Managers".to_string(),
                installed: true,
                path: Some(path.to_string_lossy().to_string()),
                version: None,
            };
        }
    }
    ToolStatus {
        id: "python".to_string(),
        name: "Python / pip".to_string(),
        group: "Package Managers".to_string(),
        installed: false,
        path: None,
        version: None,
    }
}

// ── Configuration ─────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn configure_tools(
    tool_ids: Vec<String>,
    bundle_path: String,
    app_handle: tauri::AppHandle,
) -> Result<Vec<ToolResult>, String> {
    let mut results = Vec::new();

    app_handle
        .emit("tool-progress", ("l-hdr", "── Starting configuration ────────────────────────"))
        .ok();

    for id in &tool_ids {
        app_handle
            .emit("tool-progress", ("l-dim", format!("  Configuring {}…", id)))
            .ok();

        let result = configure_one(id, &bundle_path).await;

        let cls = if result.ok { "l-ok" } else { "l-err" };
        let prefix = if result.ok { "✓" } else { "✗" };
        app_handle
            .emit(
                "tool-progress",
                (cls, format!("  {} {}", prefix, result.message)),
            )
            .ok();

        results.push(result);
    }

    let ok_count = results.iter().filter(|r| r.ok).count();
    app_handle
        .emit(
            "tool-progress",
            (
                "l-ok",
                format!("✓ Done — {}/{} tools configured.", ok_count, results.len()),
            ),
        )
        .ok();

    Ok(results)
}

async fn configure_one(id: &str, bundle_path: &str) -> ToolResult {
    match id {
        "git" => configure_git(bundle_path),
        "ssl_env" => configure_env_ssl(bundle_path),
        "openssl" => configure_env_ssl(bundle_path), // back-compat
        "curl" => configure_curl(bundle_path),
        "npm" => configure_npm(bundle_path),
        "yarn" => configure_yarn(bundle_path),
        "pnpm" => configure_pnpm(bundle_path),
        "aws" => configure_aws(bundle_path),
        "gcloud" => configure_gcloud(bundle_path),
        "az" => configure_az(bundle_path),
        "oci" => configure_oci(bundle_path),
        "go" => configure_go(bundle_path),
        "cargo" => configure_cargo(bundle_path),
        "composer" => configure_composer(bundle_path),
        "python" => configure_python(bundle_path),
        #[cfg(target_os = "windows")]
        "windows_certstore" => crate::platform::windows::configure_cert_store(bundle_path).await,
        #[cfg(target_os = "windows")]
        "vscode" => crate::platform::windows::configure_vscode(bundle_path),
        #[cfg(target_os = "windows")]
        "docker" => crate::platform::windows::configure_docker(bundle_path),
        #[cfg(target_os = "windows")]
        "jdk" => crate::platform::windows::configure_jdk(bundle_path).await,
        _ => ToolResult {
            id: id.to_string(),
            name: id.to_string(),
            ok: false,
            message: format!("Unknown tool: {}", id),
            command: None,
        },
    }
}

// ── Tool configurators ────────────────────────────────────────────────────────

pub(crate) fn run_cmd(prog: &str, args: &[&str]) -> Result<(), String> {
    // Resolve the full path — on Windows this handles .cmd/.bat/.exe extensions
    // via PATHEXT that plain Command::new() does not.
    let resolved = which::which(prog)
        .map_err(|_| format!("{} not found in PATH", prog))?;
    let status = silent_command(&resolved)
        .args(args)
        .status()
        .map_err(|e| format!("Failed to run {}: {}", prog, e))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{} exited with code {:?}", prog, status.code()))
    }
}

pub fn configure_git(bundle_path: &str) -> ToolResult {
    let cmd = format!("git config --global http.sslCAInfo \"{}\"", bundle_path);
    match run_cmd("git", &["config", "--global", "http.sslCAInfo", bundle_path]) {
        Ok(_) => ToolResult {
            id: "git".into(),
            name: "Git".into(),
            ok: true,
            message: "Git http.sslCAInfo configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "git".into(),
            name: "Git".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

/// Env vars Configure sets — every one of these takes a *file* path
/// (a PEM bundle). Anything that's semantically a *directory* path
/// (SSL_CERT_DIR, GIT_SSL_CAPATH, …) must NOT go here: strict consumers
/// like `uv` and OpenSSL warn / error when they see a file under a dir var.
pub(crate) const SSL_ENV_VARS_SET: &[&str] = &[
    "SSL_CERT_FILE",
    "REQUESTS_CA_BUNDLE",
    "CURL_CA_BUNDLE",
    "NODE_EXTRA_CA_CERTS",
    "GIT_SSL_CAINFO",
    "AWS_CA_BUNDLE",
];

/// Vars Rollback clears — superset of SET that also includes the
/// legacy directory-var names earlier versions wrongly wrote a file path
/// into. Keeps `Rollback` honest against old installs.
pub(crate) const SSL_ENV_VARS_CLEAR: &[&str] = &[
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "REQUESTS_CA_BUNDLE",
    "CURL_CA_BUNDLE",
    "NODE_EXTRA_CA_CERTS",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "AWS_CA_BUNDLE",
];

pub fn configure_env_ssl(bundle_path: &str) -> ToolResult {
    let mut all_ok = true;
    let mut set_count = 0;

    for var in SSL_ENV_VARS_SET {
        match crate::platform::set_env_var(var, bundle_path) {
            Ok(_) => set_count += 1,
            Err(_) => all_ok = false,
        }
    }

    ToolResult {
        id: "openssl".into(),
        name: "OpenSSL / SSL env vars".into(),
        ok: all_ok,
        message: format!("{}/{} SSL env vars set", set_count, SSL_ENV_VARS_SET.len()),
        command: None,
    }
}

pub fn configure_curl(bundle_path: &str) -> ToolResult {
    let curlrc = dirs::home_dir()
        .unwrap_or_default()
        .join(".curlrc");
    let content = format!("cacert = {}\n", bundle_path);

    match append_unique(&curlrc, &content, "cacert = ") {
        Ok(_) => ToolResult {
            id: "curl".into(),
            name: "cURL".into(),
            ok: true,
            message: "~/.curlrc cafile configured".into(),
            command: Some(format!("echo 'cacert = {}' >> ~/.curlrc", bundle_path)),
        },
        Err(e) => ToolResult {
            id: "curl".into(),
            name: "cURL".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_npm(bundle_path: &str) -> ToolResult {
    let cmd = format!("npm config set cafile \"{}\"", bundle_path);
    match run_cmd("npm", &["config", "set", "cafile", bundle_path]) {
        Ok(_) => ToolResult {
            id: "npm".into(),
            name: "NPM / Node.js".into(),
            ok: true,
            message: "npm cafile configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "npm".into(),
            name: "NPM / Node.js".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_yarn(bundle_path: &str) -> ToolResult {
    let cmd = format!("yarn config set cafile \"{}\"", bundle_path);
    match run_cmd("yarn", &["config", "set", "cafile", bundle_path]) {
        Ok(_) => ToolResult {
            id: "yarn".into(),
            name: "Yarn".into(),
            ok: true,
            message: "yarn cafile configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "yarn".into(),
            name: "Yarn".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_pnpm(bundle_path: &str) -> ToolResult {
    // pnpm reads the same npm-compatible "cafile" config key.
    let cmd = format!("pnpm config set cafile \"{}\"", bundle_path);
    match run_cmd("pnpm", &["config", "set", "cafile", bundle_path]) {
        Ok(_) => ToolResult {
            id: "pnpm".into(),
            name: "pnpm".into(),
            ok: true,
            message: "pnpm cafile configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "pnpm".into(),
            name: "pnpm".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_aws(bundle_path: &str) -> ToolResult {
    let cmd = format!("aws configure set ca_bundle \"{}\"", bundle_path);
    match run_cmd("aws", &["configure", "set", "ca_bundle", bundle_path]) {
        Ok(_) => ToolResult {
            id: "aws".into(),
            name: "AWS CLI".into(),
            ok: true,
            message: "AWS CLI ca_bundle configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "aws".into(),
            name: "AWS CLI".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_gcloud(bundle_path: &str) -> ToolResult {
    let cmd = format!(
        "gcloud config set core/custom_ca_certs_file \"{}\"",
        bundle_path
    );
    match run_cmd(
        "gcloud",
        &["config", "set", "core/custom_ca_certs_file", bundle_path],
    ) {
        Ok(_) => ToolResult {
            id: "gcloud".into(),
            name: "Google Cloud CLI".into(),
            ok: true,
            message: "gcloud custom_ca_certs_file configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "gcloud".into(),
            name: "Google Cloud CLI".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_az(bundle_path: &str) -> ToolResult {
    let arg = format!("core.ca_bundle_path={}", bundle_path);
    let cmd = format!("az config set \"{}\"", arg);
    match run_cmd("az", &["config", "set", &arg]) {
        Ok(_) => ToolResult {
            id: "az".into(),
            name: "Azure CLI".into(),
            ok: true,
            message: "Azure CLI ca_bundle_path configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "az".into(),
            name: "Azure CLI".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_oci(bundle_path: &str) -> ToolResult {
    let oci_config = dirs::home_dir()
        .unwrap_or_default()
        .join(".oci")
        .join("config");

    if !oci_config.exists() {
        return ToolResult {
            id: "oci".into(),
            name: "Oracle Cloud CLI".into(),
            ok: false,
            message: "~/.oci/config not found".into(),
            command: None,
        };
    }

    let content = format!("\ncustom_cert_bundle = {}\n", bundle_path);
    match append_unique(&oci_config, &content, "custom_cert_bundle = ") {
        Ok(_) => ToolResult {
            id: "oci".into(),
            name: "Oracle Cloud CLI".into(),
            ok: true,
            message: "OCI custom_cert_bundle configured".into(),
            command: None,
        },
        Err(e) => ToolResult {
            id: "oci".into(),
            name: "Oracle Cloud CLI".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_go(bundle_path: &str) -> ToolResult {
    // Go respects SSL_CERT_FILE env var set system-wide
    match crate::platform::set_env_var("SSL_CERT_FILE", bundle_path) {
        Ok(_) => ToolResult {
            id: "go".into(),
            name: "Go".into(),
            ok: true,
            message: "SSL_CERT_FILE env var set (Go uses system SSL_CERT_FILE)".into(),
            command: None,
        },
        Err(e) => ToolResult {
            id: "go".into(),
            name: "Go".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_cargo(bundle_path: &str) -> ToolResult {
    let cargo_config = dirs::home_dir()
        .unwrap_or_default()
        .join(".cargo")
        .join("config.toml");

    if let Some(parent) = cargo_config.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let existing = fs::read_to_string(&cargo_config).unwrap_or_default();
    // TOML literal string (single quotes) — no backslash escape processing.
    // Using double quotes would break on Windows paths where `\U` is read as a
    // Unicode escape.
    let new_cainfo = format!("cainfo = '{}'", bundle_path);

    let updated = if existing
        .lines()
        .any(|l| l.trim_start().starts_with("cainfo"))
    {
        // Replace existing cainfo line — no duplicate [http] section.
        existing
            .lines()
            .map(|l| {
                if l.trim_start().starts_with("cainfo") {
                    new_cainfo.clone()
                } else {
                    l.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    } else if existing.lines().any(|l| l.trim() == "[http]") {
        // [http] section exists (probably left over from rollback) — insert cainfo into it.
        let mut lines: Vec<String> = existing.lines().map(String::from).collect();
        if let Some(idx) = lines.iter().position(|l| l.trim() == "[http]") {
            lines.insert(idx + 1, new_cainfo);
        }
        lines.join("\n")
    } else {
        // Fresh append — add [http] section at end.
        let sep = if existing.is_empty() || existing.ends_with('\n') {
            ""
        } else {
            "\n"
        };
        format!("{}{}\n[http]\n{}\n", existing, sep, new_cainfo)
    };

    match fs::write(&cargo_config, updated) {
        Ok(_) => ToolResult {
            id: "cargo".into(),
            name: "Cargo (Rust)".into(),
            ok: true,
            message: "~/.cargo/config.toml http.cainfo configured".into(),
            command: None,
        },
        Err(e) => ToolResult {
            id: "cargo".into(),
            name: "Cargo (Rust)".into(),
            ok: false,
            message: e.to_string(),
            command: None,
        },
    }
}

pub fn configure_composer(bundle_path: &str) -> ToolResult {
    let cmd = format!("composer config -g cafile \"{}\"", bundle_path);
    match run_cmd("composer", &["config", "-g", "cafile", bundle_path]) {
        Ok(_) => ToolResult {
            id: "composer".into(),
            name: "PHP Composer".into(),
            ok: true,
            message: "Composer global cafile configured".into(),
            command: Some(cmd),
        },
        Err(e) => ToolResult {
            id: "composer".into(),
            name: "PHP Composer".into(),
            ok: false,
            message: e,
            command: None,
        },
    }
}

pub fn configure_python(bundle_path: &str) -> ToolResult {
    let pythons = find_pythons();
    if pythons.is_empty() {
        return ToolResult {
            id: "python".into(),
            name: "Python / pip".into(),
            ok: false,
            message: "No Python installations found".into(),
            command: None,
        };
    }

    let mut patched = 0;
    let mut msgs = Vec::new();

    for py in &pythons {
        match patch_certifi(py, bundle_path) {
            Ok(msg) => {
                patched += 1;
                msgs.push(msg);
            }
            Err(e) => msgs.push(format!("skipped ({})", e)),
        }

        // Set pip global cert for first Python found
        if patched == 1 {
            let _ = run_cmd(
                &py.to_string_lossy(),
                &["-m", "pip", "config", "set", "global.cert", bundle_path],
            );
        }
    }

    // Set REQUESTS_CA_BUNDLE env var
    let _ = crate::platform::set_env_var("REQUESTS_CA_BUNDLE", bundle_path);

    ToolResult {
        id: "python".into(),
        name: "Python / pip".into(),
        ok: patched > 0,
        message: format!(
            "{}/{} Python installs patched — {}",
            patched,
            pythons.len(),
            msgs.join("; ")
        ),
        command: None,
    }
}

fn find_pythons() -> Vec<PathBuf> {
    let mut found = Vec::new();

    // py launcher (Windows)
    if let Ok(out) = silent_command("py").args(["-0p"]).output() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let path = PathBuf::from(line.trim());
            if path.exists() && !found.contains(&path) {
                found.push(path);
            }
        }
    }

    // Fall back to which
    for cmd in &["python3", "python"] {
        if let Ok(path) = which(cmd) {
            if !found.contains(&path) {
                found.push(path);
            }
        }
    }

    found
}

fn patch_certifi(python: &Path, bundle_path: &str) -> Result<String, String> {
    let out = silent_command(python)
        .args(["-c", "import certifi; print(certifi.where())"])
        .output()
        .map_err(|e| e.to_string())?;

    let certifi_path_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if certifi_path_str.is_empty() {
        return Err("certifi not installed".into());
    }

    let certifi_path = PathBuf::from(&certifi_path_str);
    let mut content = fs::read(&certifi_path).map_err(|e| e.to_string())?;

    let marker = b"# Netskope SSL bundle";
    if content.windows(marker.len()).any(|w| w == marker) {
        return Ok(format!(
            "{} already patched",
            python.file_name().unwrap_or_default().to_string_lossy()
        ));
    }

    let bundle_bytes = fs::read(bundle_path).map_err(|e| e.to_string())?;
    content.extend_from_slice(b"\n# Netskope SSL bundle\n");
    content.extend_from_slice(&bundle_bytes);
    content.extend_from_slice(b"\n# End Netskope SSL bundle\n");

    fs::write(&certifi_path, content).map_err(|e| e.to_string())?;

    Ok(format!(
        "{} certifi patched",
        python.file_name().unwrap_or_default().to_string_lossy()
    ))
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn append_unique(path: &Path, content: &str, dedup_prefix: &str) -> Result<(), String> {
    let existing = fs::read_to_string(path).unwrap_or_default();
    if existing.contains(dedup_prefix) {
        return Ok(()); // already configured
    }
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    use std::io::Write;
    file.write_all(content.as_bytes())
        .map_err(|e| e.to_string())
}
