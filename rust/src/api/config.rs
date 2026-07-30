use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Personal app preferences — never shared with friends (unlike
/// `relays.json`, whose contents are deliberately included in the
/// friend-facing payloads so friends know where to reach us). Synced only
/// through this account's own self-encrypted backup slot.
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct AppConfig {
    /// BCP-47 language code (e.g. "en", "ja"), or `None` to follow the
    /// device locale.
    #[serde(default)]
    pub language: Option<String>,
}

fn config_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("config.json")
}

/// Saves the app config as JSON under `storage_dir`. `storage_dir` must
/// already exist (e.g. the app's documents directory, resolved on the
/// Dart side via path_provider).
pub fn save_config(storage_dir: String, config: AppConfig) -> Result<(), String> {
    let content = serde_json::to_string_pretty(&config).map_err(|e| e.to_string())?;
    fs::write(config_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Loads the saved app config, or defaults (follow device locale) if none
/// has been saved yet.
pub fn load_config(storage_dir: String) -> AppConfig {
    fs::read_to_string(config_path(&storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}
