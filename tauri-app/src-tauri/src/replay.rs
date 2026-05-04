use crate::tools::ToolResult;

#[tauri::command]
pub fn generate_replay_script(
    results: Vec<ToolResult>,
    platform: String,
    bundle_path: String,
    tenant: String,
) -> Result<String, String> {
    match platform.as_str() {
        "windows" => Ok(generate_bat(&results, &bundle_path, &tenant)),
        _ => Ok(generate_sh(&results, &bundle_path, &tenant)),
    }
}

fn generate_bat(results: &[ToolResult], bundle_path: &str, tenant: &str) -> String {
    let mut lines = vec![
        "@echo off".to_string(),
        ":: Bulwarx SSL Configurator — replay script".to_string(),
        format!(":: Tenant: {}", tenant),
        format!(":: Bundle: {}", bundle_path),
        String::new(),
        format!("set BUNDLE={}", bundle_path),
        String::new(),
    ];

    for r in results.iter().filter(|r| r.ok) {
        if let Some(cmd) = &r.command {
            lines.push(format!(":: {}", r.name));
            lines.push(cmd.clone());
            lines.push(String::new());
        }
    }

    lines.push("echo Done.".to_string());
    lines.join("\r\n")
}

fn generate_sh(results: &[ToolResult], bundle_path: &str, tenant: &str) -> String {
    let mut lines = vec![
        "#!/usr/bin/env bash".to_string(),
        "# Bulwarx SSL Configurator — replay script".to_string(),
        format!("# Tenant: {}", tenant),
        format!("# Bundle: {}", bundle_path),
        String::new(),
        format!("BUNDLE=\"{}\"", bundle_path),
        String::new(),
    ];

    for r in results.iter().filter(|r| r.ok) {
        if let Some(cmd) = &r.command {
            lines.push(format!("# {}", r.name));
            lines.push(cmd.clone());
            lines.push(String::new());
        }
    }

    lines.push("echo 'Done.'".to_string());
    lines.join("\n")
}
