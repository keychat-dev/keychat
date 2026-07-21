use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Local display profile. KeyChat has no fixed account key, so this is the
/// only per-device identity data that needs to be persisted.
#[derive(Serialize, Deserialize)]
pub struct Profile {
    pub display_name: String,
    pub status_message: String,
    /// Absolute path to the avatar image file, if the user picked one.
    pub avatar_path: Option<String>,
}

fn profile_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("profile.json")
}

/// Saves the profile as JSON under `storage_dir`.
/// `storage_dir` must already exist (e.g. the app's documents directory,
/// resolved on the Dart side via path_provider).
pub fn save_profile(
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let profile = Profile {
        display_name,
        status_message,
        avatar_path,
    };
    let content = serde_json::to_string_pretty(&profile).map_err(|e| e.to_string())?;
    fs::write(profile_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Loads a previously saved profile, or `None` if none has been saved yet.
pub fn load_profile(storage_dir: String) -> Option<Profile> {
    let content = fs::read_to_string(profile_path(&storage_dir)).ok()?;
    serde_json::from_str(&content).ok()
}
