use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A confirmed friend: their per-relationship contact pubkey, and which of
/// *our own* NIP-06 account indices we use to talk to them (see
/// `keys::derive_contact_keys`). Every friend has a distinct pair of keys
/// on both sides, so leaking one relationship's key never exposes another.
#[derive(Serialize, Deserialize, Clone)]
pub struct Friend {
    /// The friend's contact pubkey (hex) — distinct from their account's
    /// core identity, minted specifically for this relationship.
    pub pubkey: String,
    /// Which of our own `account` indices we use to talk to this friend.
    pub my_account_index: u32,
    pub display_name: String,
    pub status_message: String,
    /// The friend's relays as of the last time we heard from them — where
    /// we publish future profile updates to.
    #[serde(default)]
    pub relays: Vec<String>,
    /// Local file path to the friend's avatar image, as last received —
    /// downloaded and cached on this device, not a remote URL.
    #[serde(default)]
    pub avatar_path: Option<String>,
    pub added_at: i64,
}

fn friends_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("friends.json")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Loads the saved friends list, or an empty list if none has been saved yet.
pub fn load_friends(storage_dir: String) -> Vec<Friend> {
    fs::read_to_string(friends_path(&storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

fn save_friends_list(storage_dir: &str, friends: &[Friend]) -> Result<(), String> {
    let content = serde_json::to_string_pretty(friends).map_err(|e| e.to_string())?;
    fs::write(friends_path(storage_dir), content).map_err(|e| e.to_string())
}

/// Adds (or updates the info of) a friend, deduplicating by their contact
/// pubkey.
pub fn add_friend(
    storage_dir: String,
    pubkey: String,
    my_account_index: u32,
    display_name: String,
    status_message: String,
    relays: Vec<String>,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let mut friends = load_friends(storage_dir.clone());
    friends.retain(|f| f.pubkey != pubkey);
    friends.push(Friend {
        pubkey,
        my_account_index,
        display_name,
        status_message,
        relays,
        avatar_path,
        added_at: now(),
    });
    save_friends_list(&storage_dir, &friends)
}

/// Updates a friend's display info (e.g. after they push a profile update),
/// including their current relay list — every friend-protocol event
/// carries the sender's up-to-date relays, so this is also how we notice a
/// friend has moved to different relays and keep publishing where they'll
/// actually see it. Leaves `my_account_index`/`added_at` untouched. A
/// no-op if there's no friend with that pubkey.
pub(crate) fn update_friend_profile(
    storage_dir: &str,
    pubkey: &str,
    display_name: String,
    status_message: String,
    relays: Vec<String>,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let mut friends = load_friends(storage_dir.to_string());
    for friend in friends.iter_mut() {
        if friend.pubkey == pubkey {
            friend.display_name = display_name;
            friend.status_message = status_message;
            if !relays.is_empty() {
                friend.relays = relays;
            }
            if avatar_path.is_some() {
                friend.avatar_path = avatar_path;
            }
            break;
        }
    }
    save_friends_list(storage_dir, &friends)
}

/// Removes a friend by their contact pubkey (e.g. after they're blocked).
pub fn remove_friend(storage_dir: String, pubkey: String) -> Result<(), String> {
    let mut friends = load_friends(storage_dir.clone());
    friends.retain(|f| f.pubkey != pubkey);
    save_friends_list(&storage_dir, &friends)
}

fn blocked_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("blocked.json")
}

/// Loads the set of contact pubkeys whose friend requests should be
/// silently ignored (rejected once, never shown again).
pub(crate) fn load_blocked(storage_dir: &str) -> Vec<String> {
    fs::read_to_string(blocked_path(storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

/// Permanently blocks a contact pubkey — e.g. after rejecting their friend
/// request, so re-sending it (with the same leaked/reused key) has no effect.
pub fn block_pubkey(storage_dir: String, pubkey: String) -> Result<(), String> {
    let mut blocked = load_blocked(&storage_dir);
    if !blocked.contains(&pubkey) {
        blocked.push(pubkey);
    }
    let content = serde_json::to_string_pretty(&blocked).map_err(|e| e.to_string())?;
    fs::write(blocked_path(&storage_dir), content).map_err(|e| e.to_string())
}
