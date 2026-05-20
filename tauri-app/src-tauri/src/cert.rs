use serde::Serialize;
use std::{fs, path::PathBuf};

#[tauri::command]
pub fn default_bundle_dir() -> String {
    dirs::home_dir()
        .map(|h| h.join("netskope"))
        .unwrap_or_else(|| PathBuf::from("."))
        .to_string_lossy()
        .to_string()
}

/// Reduce whatever the user pasted to a bare host like `mytenant.eu.goskope.com`.
/// Tolerates `https://`, `http://`, trailing slashes, and accidental path/query
/// suffixes — anything else would produce a malformed URL when we splice it
/// into `https://addon-{tenant}/...`.
fn normalize_tenant(raw: &str) -> String {
    let mut t = raw.trim();
    for prefix in ["https://", "http://"] {
        if let Some(rest) = t.strip_prefix(prefix) {
            t = rest;
            break;
        }
    }
    // Drop anything after the host (path, query, fragment).
    let host_end = t
        .find(|c: char| c == '/' || c == '?' || c == '#')
        .unwrap_or(t.len());
    t[..host_end].trim_end_matches('.').to_string()
}

#[derive(Serialize)]
pub struct ConnectionResult {
    pub ok: bool,
    pub message: String,
}

#[tauri::command]
pub async fn test_connection(tenant: String, org_key: String) -> Result<ConnectionResult, String> {
    let tenant = normalize_tenant(&tenant);
    let url = format!(
        "https://addon-{}/config/org/cert?orgkey={}",
        tenant, org_key
    );

    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    match client.head(&url).send().await {
        Ok(resp) => {
            let ok = resp.status().is_success() || resp.status().as_u16() < 400;
            Ok(ConnectionResult {
                ok,
                message: if ok {
                    format!("Tenant reachable — {}", tenant)
                } else {
                    format!("Unexpected status {} from {}", resp.status(), tenant)
                },
            })
        }
        Err(e) => Ok(ConnectionResult {
            ok: false,
            message: format!("Connection failed: {}", e),
        }),
    }
}

#[derive(Serialize)]
pub struct BundleResult {
    pub path: String,
    pub sidecar_path: Option<String>,
}

#[tauri::command]
pub async fn download_bundle(
    tenant: String,
    org_key: String,
    cert_dir: String,
    cert_name: String,
    full_bundle: bool,
) -> Result<BundleResult, String> {
    let tenant = normalize_tenant(&tenant);
    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;

    // RootCA first, then SubCA — correct chain order
    let netskope_urls = [
        format!("https://addon-{}/config/org/cert?orgkey={}", tenant, org_key),
        format!("https://addon-{}/config/ca/cert?orgkey={}", tenant, org_key),
    ];

    let dir = PathBuf::from(&cert_dir);
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create directory: {}", e))?;

    // Download Netskope certs
    let mut netskope_bytes: Vec<Vec<u8>> = Vec::new();
    for url in &netskope_urls {
        let bytes = client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("Download failed: {}", e))?
            .bytes()
            .await
            .map_err(|e| e.to_string())?
            .to_vec();
        netskope_bytes.push(bytes);
    }

    // Optionally download public CA bundle
    let public_ca = if full_bundle {
        let bytes = client
            .get("https://curl.se/ca/cacert.pem")
            .send()
            .await
            .map_err(|e| format!("Failed to download public CA bundle: {}", e))?
            .bytes()
            .await
            .map_err(|e| e.to_string())?
            .to_vec();
        Some(bytes)
    } else {
        None
    };

    // Write main bundle file
    let bundle_path = dir.join(&cert_name);
    let mut bundle: Vec<u8> = Vec::new();
    for b in &netskope_bytes {
        bundle.extend_from_slice(b);
    }
    if let Some(ref ca) = public_ca {
        bundle.extend_from_slice(ca);
    }
    fs::write(&bundle_path, &bundle).map_err(|e| format!("Cannot write bundle: {}", e))?;

    // Write netskope_only.pem sidecar when full_bundle mode is active
    let sidecar_path = if full_bundle {
        let sidecar = dir.join("netskope_only.pem");
        let mut content: Vec<u8> = Vec::new();
        for b in &netskope_bytes {
            content.extend_from_slice(b);
        }
        fs::write(&sidecar, &content).map_err(|e| format!("Cannot write sidecar: {}", e))?;
        Some(sidecar.to_string_lossy().to_string())
    } else {
        None
    };

    Ok(BundleResult {
        path: bundle_path.to_string_lossy().to_string(),
        sidecar_path,
    })
}
