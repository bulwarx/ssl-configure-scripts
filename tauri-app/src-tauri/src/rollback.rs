use crate::tools::ToolResult;
use std::{fs, path::PathBuf};
use tauri::Emitter;

#[tauri::command]
pub async fn rollback_tools(
    tool_ids: Vec<String>,
    app_handle: tauri::AppHandle,
) -> Result<Vec<ToolResult>, String> {
    let mut results = Vec::new();

    app_handle
        .emit(
            "tool-progress",
            ("l-hdr", "── Starting rollback ─────────────────────────────"),
        )
        .ok();

    for id in &tool_ids {
        app_handle
            .emit("tool-progress", ("l-dim", format!("  Rolling back {}…", id)))
            .ok();

        let result = rollback_one(id).await;

        let cls = if result.ok { "l-ok" } else { "l-wrn" };
        let prefix = if result.ok { "✓" } else { "·" };
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
                format!("✓ Rollback complete — {}/{} tools cleaned.", ok_count, results.len()),
            ),
        )
        .ok();

    Ok(results)
}

async fn rollback_one(id: &str) -> ToolResult {
    match id {
        "git" => rollback_git(),
        "ssl_env" => rollback_env_ssl(),
        "openssl" => rollback_env_ssl(), // back-compat
        "curl" => rollback_curl(),
        "npm" => rollback_npm(),
        "yarn" => rollback_yarn(),
        "aws" => rollback_aws(),
        "gcloud" => rollback_gcloud(),
        "az" => rollback_az(),
        "oci" => rollback_oci(),
        "go" => rollback_go(),
        "cargo" => rollback_cargo(),
        "composer" => rollback_composer(),
        "python" => rollback_python(),
        #[cfg(target_os = "windows")]
        "windows_certstore" => crate::platform::windows::rollback_cert_store().await,
        #[cfg(target_os = "windows")]
        "vscode" => crate::platform::windows::rollback_vscode(),
        #[cfg(target_os = "windows")]
        "docker" => crate::platform::windows::rollback_docker(),
        #[cfg(target_os = "windows")]
        "jdk" => crate::platform::windows::rollback_jdk().await,
        _ => ok_result(id, id, format!("Unknown tool: {}", id)),
    }
}

// ── Individual rollback functions ─────────────────────────────────────────────

fn ok_result(id: &str, name: &str, msg: String) -> ToolResult {
    ToolResult {
        id: id.into(),
        name: name.into(),
        ok: true,
        message: msg,
        command: None,
    }
}

fn err_result(id: &str, name: &str, msg: String) -> ToolResult {
    ToolResult {
        id: id.into(),
        name: name.into(),
        ok: false,
        message: msg,
        command: None,
    }
}

fn run_or_skip(id: &str, name: &str, prog: &str, args: &[&str], ok_msg: &str) -> ToolResult {
    match which::which(prog) {
        Ok(resolved) => {
            let status = crate::tools::silent_command(&resolved).args(args).status();
            match status {
                Ok(_) => ok_result(id, name, ok_msg.into()),
                Err(e) => err_result(id, name, e.to_string()),
            }
        }
        Err(_) => ok_result(id, name, format!("{} not installed — nothing to do", prog)),
    }
}

fn rollback_git() -> ToolResult {
    run_or_skip(
        "git", "Git", "git",
        &["config", "--global", "--unset", "http.sslCAInfo"],
        "Git http.sslCAInfo removed",
    )
}

fn rollback_env_ssl() -> ToolResult {
    for var in crate::tools::SSL_ENV_VARS_CLEAR {
        let _ = crate::platform::remove_env_var(var);
    }
    ok_result(
        "openssl",
        "OpenSSL",
        format!(
            "{} SSL env vars removed",
            crate::tools::SSL_ENV_VARS_CLEAR.len()
        ),
    )
}

fn rollback_curl() -> ToolResult {
    let curlrc = dirs::home_dir().unwrap_or_default().join(".curlrc");
    if !curlrc.exists() {
        return ok_result("curl", "cURL", "~/.curlrc not found — nothing to do".into());
    }
    match remove_lines_containing(&curlrc, "cacert") {
        Ok(_) => ok_result("curl", "cURL", "~/.curlrc cacert line removed".into()),
        Err(e) => err_result("curl", "cURL", e),
    }
}

fn rollback_npm() -> ToolResult {
    run_or_skip(
        "npm", "NPM / Node.js", "npm",
        &["config", "delete", "cafile"],
        "npm cafile deleted",
    )
}

fn rollback_yarn() -> ToolResult {
    run_or_skip(
        "yarn", "Yarn", "yarn",
        &["config", "delete", "cafile"],
        "yarn cafile deleted",
    )
}

fn rollback_aws() -> ToolResult {
    run_or_skip(
        "aws", "AWS CLI", "aws",
        &["configure", "set", "ca_bundle", ""],
        "AWS CLI ca_bundle cleared",
    )
}

fn rollback_gcloud() -> ToolResult {
    run_or_skip(
        "gcloud", "Google Cloud CLI", "gcloud",
        &["config", "unset", "core/custom_ca_certs_file"],
        "gcloud custom_ca_certs_file unset",
    )
}

fn rollback_az() -> ToolResult {
    run_or_skip(
        "az", "Azure CLI", "az",
        &["config", "unset", "core.ca_bundle_path"],
        "Azure CLI ca_bundle_path unset",
    )
}

fn rollback_oci() -> ToolResult {
    let oci_config = dirs::home_dir()
        .unwrap_or_default()
        .join(".oci")
        .join("config");
    if !oci_config.exists() {
        return ok_result("oci", "Oracle Cloud CLI", "~/.oci/config not found".into());
    }
    match remove_lines_containing(&oci_config, "custom_cert_bundle") {
        Ok(_) => ok_result(
            "oci",
            "Oracle Cloud CLI",
            "OCI custom_cert_bundle removed".into(),
        ),
        Err(e) => err_result("oci", "Oracle Cloud CLI", e),
    }
}

fn rollback_go() -> ToolResult {
    let _ = crate::platform::remove_env_var("SSL_CERT_FILE");
    ok_result("go", "Go", "SSL_CERT_FILE env var removed".into())
}

fn rollback_cargo() -> ToolResult {
    let cargo_config = dirs::home_dir()
        .unwrap_or_default()
        .join(".cargo")
        .join("config.toml");
    if !cargo_config.exists() {
        return ok_result("cargo", "Cargo", "~/.cargo/config.toml not found".into());
    }

    let existing = match fs::read_to_string(&cargo_config) {
        Ok(s) => s,
        Err(e) => return err_result("cargo", "Cargo (Rust)", e.to_string()),
    };

    // Drop cainfo lines first.
    let mut lines: Vec<String> = existing
        .lines()
        .filter(|l| !l.trim_start().starts_with("cainfo"))
        .map(String::from)
        .collect();

    // Drop an `[http]` header if nothing follows it but whitespace, comments,
    // or the next section — otherwise we leave an empty section that corrupts
    // the file when configure re-runs.
    let mut i = 0;
    while i < lines.len() {
        if lines[i].trim() == "[http]" {
            let next_key = lines[i + 1..]
                .iter()
                .map(|l| l.trim())
                .find(|t| !t.is_empty() && !t.starts_with('#'));
            let empty_section = next_key
                .map(|t| t.starts_with('['))
                .unwrap_or(true);
            if empty_section {
                lines.remove(i);
                continue;
            }
        }
        i += 1;
    }

    match fs::write(&cargo_config, lines.join("\n")) {
        Ok(_) => ok_result(
            "cargo",
            "Cargo (Rust)",
            "~/.cargo/config.toml http.cainfo removed".into(),
        ),
        Err(e) => err_result("cargo", "Cargo (Rust)", e.to_string()),
    }
}

fn rollback_composer() -> ToolResult {
    run_or_skip(
        "composer", "PHP Composer", "composer",
        &["config", "-g", "--unset", "cafile"],
        "Composer global cafile unset",
    )
}

fn rollback_python() -> ToolResult {
    let pythons = find_pythons();
    let mut cleaned = 0;

    for py in &pythons {
        if let Ok(out) = crate::tools::silent_command(py)
            .args(["-c", "import certifi; print(certifi.where())"])
            .output()
        {
            let certifi_path_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !certifi_path_str.is_empty() {
                let _ = remove_certifi_marker(&PathBuf::from(certifi_path_str));
                cleaned += 1;
            }
        }
        // Remove pip cert setting
        let _ = crate::tools::silent_command(py)
            .args(["-m", "pip", "config", "unset", "global.cert"])
            .status();
    }

    let _ = crate::platform::remove_env_var("REQUESTS_CA_BUNDLE");

    ok_result(
        "python",
        "Python / pip",
        format!("{} Python installs cleaned", cleaned),
    )
}

fn find_pythons() -> Vec<PathBuf> {
    let mut found = Vec::new();
    if let Ok(out) = crate::tools::silent_command("py").args(["-0p"]).output() {
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let p = PathBuf::from(line.trim());
            if p.exists() {
                found.push(p);
            }
        }
    }
    for cmd in &["python3", "python"] {
        if let Ok(p) = which::which(cmd) {
            if !found.contains(&p) {
                found.push(p);
            }
        }
    }
    found
}

fn remove_certifi_marker(path: &PathBuf) -> Result<(), String> {
    let content = fs::read(path).map_err(|e| e.to_string())?;
    let start_marker = b"# Netskope SSL bundle";
    let end_marker = b"# End Netskope SSL bundle";

    let start = content
        .windows(start_marker.len())
        .position(|w| w == start_marker);
    let end = content
        .windows(end_marker.len())
        .position(|w| w == end_marker);

    if let (Some(s), Some(e)) = (start, end) {
        let mut new_content = content[..s].to_vec();
        new_content.extend_from_slice(&content[e + end_marker.len()..]);
        // Trim trailing newlines from the seam
        while new_content.ends_with(b"\n\n") {
            new_content.pop();
        }
        fs::write(path, new_content).map_err(|e| e.to_string())?;
    }
    Ok(())
}

// ── File helpers ──────────────────────────────────────────────────────────────

fn remove_lines_containing(path: &PathBuf, keyword: &str) -> Result<(), String> {
    let content = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let filtered: Vec<&str> = content
        .lines()
        .filter(|l| !l.contains(keyword))
        .collect();
    fs::write(path, filtered.join("\n")).map_err(|e| e.to_string())
}
