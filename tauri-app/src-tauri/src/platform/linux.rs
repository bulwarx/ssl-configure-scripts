use std::{fs, path::PathBuf};

const MARKER: &str = "# Netskope SSL";

fn rc_files() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    vec![
        home.join(".bashrc"),
        home.join(".profile"),
    ]
}

pub fn set_env_var(name: &str, value: &str) -> Result<(), String> {
    let line = format!("export {}=\"{}\" {}", name, value, MARKER);
    for rc in rc_files() {
        let existing = fs::read_to_string(&rc).unwrap_or_default();
        if existing.contains(&format!("export {}=", name)) {
            let updated: Vec<&str> = existing
                .lines()
                .map(|l| {
                    if l.contains(&format!("export {}=", name)) {
                        line.as_str()
                    } else {
                        l
                    }
                })
                .collect();
            fs::write(&rc, updated.join("\n")).map_err(|e| e.to_string())?;
        } else {
            let mut content = existing;
            if !content.ends_with('\n') {
                content.push('\n');
            }
            content.push_str(&line);
            content.push('\n');
            fs::write(&rc, content).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

pub fn remove_env_var(name: &str) -> Result<(), String> {
    for rc in rc_files() {
        if !rc.exists() {
            continue;
        }
        let content = fs::read_to_string(&rc).map_err(|e| e.to_string())?;
        let filtered: Vec<&str> = content
            .lines()
            .filter(|l| !l.contains(&format!("export {}=", name)))
            .collect();
        fs::write(&rc, filtered.join("\n")).map_err(|e| e.to_string())?;
    }
    Ok(())
}
