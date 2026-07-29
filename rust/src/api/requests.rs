use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A friend request we sent out, not yet known to be accepted. Tracks
/// which of our own account indices we used, and where to look for the
/// other side's acceptance (the same relays we sent the request to).
#[derive(Serialize, Deserialize, Clone)]
pub struct OutgoingRequest {
    pub my_account_index: u32,
    pub invite_pubkey: String,
    pub invite_relays: Vec<String>,
    pub created_at: i64,
}

fn requests_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("outgoing_requests.json")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub(crate) fn load(storage_dir: &str) -> Vec<OutgoingRequest> {
    fs::read_to_string(requests_path(storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

fn save(storage_dir: &str, requests: &[OutgoingRequest]) -> Result<(), String> {
    let content = serde_json::to_string_pretty(requests).map_err(|e| e.to_string())?;
    fs::write(requests_path(storage_dir), content).map_err(|e| e.to_string())
}

pub(crate) fn add(
    storage_dir: &str,
    my_account_index: u32,
    invite_pubkey: String,
    invite_relays: Vec<String>,
) -> Result<(), String> {
    let mut requests = load(storage_dir);
    requests.push(OutgoingRequest {
        my_account_index,
        invite_pubkey,
        invite_relays,
        created_at: now(),
    });
    save(storage_dir, &requests)
}

/// Removes the outgoing request for `my_account_index` — called once it's
/// been resolved (accepted and turned into a friend).
pub(crate) fn remove(storage_dir: &str, my_account_index: u32) -> Result<(), String> {
    let mut requests = load(storage_dir);
    requests.retain(|r| r.my_account_index != my_account_index);
    save(storage_dir, &requests)
}
