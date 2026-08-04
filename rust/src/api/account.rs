use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Local account identity: display info persisted per-device.
#[derive(Serialize, Deserialize)]
pub struct Account {
    pub display_name: String,
    pub status_message: String,
    /// Absolute path to the avatar image file, if the user picked one.
    pub avatar_path: Option<String>,
    /// Unix timestamp (seconds) of the last local edit. Used to decide
    /// whether the local copy or the relay-synced backup is newer.
    #[serde(default)]
    pub updated_at: i64,
}

fn account_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("account.json")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Writes `bytes` under a content-hash-suffixed filename in `storage_dir`
/// and deletes any previous `account_avatar_*` file. Flutter's
/// `FileImage`/`ImageCache` keys purely by path string (see `sync.rs`'s
/// `save_friend_avatar`, which fixes the same issue for friend avatars) —
/// reusing one fixed filename across edits means the new bytes land on disk
/// but every already-cached widget (e.g. the account card) keeps painting
/// the old bitmap for that unchanged path. Shared by both ways this
/// device's own avatar can change: a local edit ([save_account_avatar]) and
/// a newer copy pulled from a relay backup ([save_account_avatar_base64],
/// and `sync.rs`'s live-sync handling of the same backup slot).
fn write_avatar_bytes(storage_dir: &str, bytes: &[u8], extension: &str) -> Option<String> {
    let hash = hex::encode(Sha256::digest(bytes));
    let file_name = format!("account_avatar_{hash}.{extension}");
    let dir = Path::new(storage_dir);
    let dest = dir.join(&file_name);
    fs::write(&dest, bytes).ok()?;
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("account_avatar_") && name != file_name {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    Some(dest.to_string_lossy().to_string())
}

/// Copies a freshly-picked avatar image into permanent per-account storage.
/// Returns `None` if `picked_path` couldn't be read.
pub fn save_account_avatar(storage_dir: String, picked_path: String) -> Option<String> {
    let bytes = fs::read(&picked_path).ok()?;
    let extension = Path::new(&picked_path).extension().and_then(|e| e.to_str()).unwrap_or("jpg");
    write_avatar_bytes(&storage_dir, &bytes, extension)
}

/// Decodes a base64-encoded avatar pulled from a relay backup and saves it
/// the same content-hash-suffixed way as a locally-picked one.
pub fn save_account_avatar_base64(storage_dir: String, avatar_base64: String) -> Option<String> {
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD.decode(&avatar_base64).ok()?;
    write_avatar_bytes(&storage_dir, &bytes, "png")
}

/// Saves the account as JSON under `storage_dir`, stamping `updated_at` with
/// the current time. `storage_dir` must already exist (e.g. the app's
/// documents directory, resolved on the Dart side via path_provider).
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
        updated_at: now(),
    };
    let content = serde_json::to_string_pretty(&account).map_err(|e| e.to_string())?;
    fs::write(account_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Saves the account as JSON under `storage_dir` with an explicit
/// `updated_at`, used when overwriting the local copy with a newer backup
/// pulled from a relay (so the local timestamp matches the relay's).
pub fn save_account_with_timestamp(
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
    updated_at: i64,
) -> Result<(), String> {
    let account = Account {
        display_name,
        status_message,
        avatar_path,
        updated_at,
    };
    let content = serde_json::to_string_pretty(&account).map_err(|e| e.to_string())?;
    fs::write(account_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Loads a previously saved account, or `None` if none has been saved yet.
pub fn load_account(storage_dir: String) -> Option<Account> {
    let content = fs::read_to_string(account_path(&storage_dir)).ok()?;
    serde_json::from_str(&content).ok()
}
