use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Local account identity: display info persisted per-device.
#[derive(Serialize, Deserialize)]
pub struct Account {
    pub display_name: String,
    pub status_message: String,
    /// Absolute path to the avatar image file, if the user picked one.
    pub avatar_path: Option<String>,
}

fn account_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("account.json")
}

/// Saves the account as JSON under `storage_dir`.
/// `storage_dir` must already exist (e.g. the app's documents directory,
/// resolved on the Dart side via path_provider).
pub fn save_account(
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let account = Account {
        display_name,
        status_message,
        avatar_path,
    };
    let content = serde_json::to_string_pretty(&account).map_err(|e| e.to_string())?;
    fs::write(account_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Loads a previously saved account, or `None` if none has been saved yet.
pub fn load_account(storage_dir: String) -> Option<Account> {
    let content = fs::read_to_string(account_path(&storage_dir)).ok()?;
    serde_json::from_str(&content).ok()
}
