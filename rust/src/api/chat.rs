//! One-to-one chat, built on NIP-17-style gift-wrapped direct messages
//! (NIP-59): each message is wrapped in a `Seal` (kind 13, signed by the
//! sender's per-contact key, so authenticity is provable) which is itself
//! wrapped in a `Gift Wrap` (kind 1059, signed by a single-use random key
//! and NIP-44-encrypted to the recipient) before publishing. The Gift Wrap
//! layer is discarded after unwrapping — only the `Seal` (a normal signed
//! event, still content-encrypted) is persisted locally, so data at rest
//! never contains plaintext.
//!
//! Local storage uses `nostr-lmdb` (unlike the rest of `api`, which uses
//! plain JSON files) because chat history is genuinely a log of Nostr
//! events that benefits from being queried by kind/author/time — the same
//! store this module uses today for one-to-one Seals will hold group and
//! public-room events later.

use crate::api::friends;
use crate::api::keys::derive_contact_keys;
use crate::api::relay;
use crate::api::sync::{publish_to_relays, runtime};
use nostr::event::{Event, EventBuilder, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{Filter, JsonUtil, Keys, Kind, PublicKey, Timestamp};
use nostr_database::NostrDatabase;
use nostr_lmdb::NostrLMDB;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

fn db_cell() -> &'static Mutex<Option<Arc<NostrLMDB>>> {
    static CELL: OnceLock<Mutex<Option<Arc<NostrLMDB>>>> = OnceLock::new();
    CELL.get_or_init(|| Mutex::new(None))
}

fn db(storage_dir: &str) -> Arc<NostrLMDB> {
    let mut slot = db_cell().lock().expect("chat db lock poisoned");
    if let Some(db) = slot.as_ref() {
        return db.clone();
    }
    let path = Path::new(storage_dir).join("chat.lmdb");
    let db = Arc::new(NostrLMDB::open(path).expect("failed to open chat database"));
    *slot = Some(db.clone());
    db
}

/// Drops the cached chat database handle so the next access reopens it from
/// disk. Every account shares the same on-device storage directory, so
/// logging out (which deletes `chat.lmdb`) would otherwise leave this
/// process holding a handle into files that no longer exist — call this
/// right after wiping local storage, before a different account can log in
/// within the same app run.
pub fn reset_chat_db() {
    *db_cell().lock().expect("chat db lock poisoned") = None;
}

/// A single decrypted message, ready to show in the UI.
pub struct ChatMessage {
    pub id: String,
    pub sender_pubkey: String,
    pub content: String,
    pub created_at: i64,
    pub is_mine: bool,
}

/// Message length cap (characters), enforced by [send_chat_message] — a
/// generous limit for a chat bubble, mainly there to stop a single event
/// from ballooning (NIP-44 encryption inflates size further) rather than
/// to constrain normal conversation.
pub const MAX_MESSAGE_CHARS: usize = 4000;

/// Dart-callable accessor for [MAX_MESSAGE_CHARS] — lets the composer
/// enforce the same limit client-side instead of only finding out via a
/// failed [send_chat_message] call.
pub fn max_message_chars() -> u32 {
    MAX_MESSAGE_CHARS as u32
}

/// Builds a Gift Wrap for `message` addressed to `friend_pubkey`, persists
/// our own copy of the `Seal` locally (so our own sent messages show up in
/// [load_chat_history] immediately, even offline or if publishing fails),
/// and publishes it to the friend's relays.
///
/// Also wraps the same `Seal` a second time for ourselves and publishes it
/// to our own relays — the friend's relays have no reason to keep an event
/// we sent *them*, but this self-addressed copy means our own subscription
/// (which watches our own relays) can refetch our sent messages after a
/// reinstall or on another device, instead of them existing only in this
/// one local database. Best-effort: a failure to publish this copy doesn't
/// fail the send, since the message already reached the friend either way.
pub fn send_chat_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message: String,
) -> Result<(), String> {
    if message.chars().count() > MAX_MESSAGE_CHARS {
        return Err("message too long".to_string());
    }
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    if friends::load_blocked(&storage_dir).contains(&friend_pubkey) {
        return Err("friend is blocked".to_string());
    }
    let keys = derive_contact_keys(&mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(&friend_pubkey).map_err(|e| e.to_string())?;
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;

    runtime().block_on(async {
        let rumor: UnsignedEvent =
            EventBuilder::private_msg_rumor(friend_pk, message).build(keys.public_key());
        let seal: Event = EventBuilder::seal(&keys, &friend_pk, rumor)
            .await
            .map_err(|e| e.to_string())?
            .sign(&keys)
            .await
            .map_err(|e| e.to_string())?;
        let wrap_to_friend: Event = EventBuilder::gift_wrap_from_seal(&friend_pk, &seal, [])
            .map_err(|e| e.to_string())?;
        let wrap_to_self: Event =
            EventBuilder::gift_wrap_from_seal(&keys.public_key(), &seal, [])
                .map_err(|e| e.to_string())?;

        db(&storage_dir)
            .save_event(&seal)
            .await
            .map_err(|e| e.to_string())?;
        publish_to_relays(&friend.relays, &wrap_to_friend).await?;
        let _ = publish_to_relays(&my_relays, &wrap_to_self).await;
        Ok(())
    })
}

/// Loads the full decrypted message history with `friend_pubkey` from
/// local storage (no relay round-trip — the live subscription and
/// [send_chat_message] are what keep it current), oldest first.
///
/// Includes messages under any of the friend's `prior_identities` too —
/// each old (pubkey, my_account_index) pair this same account used before
/// being re-friended under a new relationship key (see
/// `friends::add_friend`'s UID merge) — so history from before a
/// delete-and-re-add isn't lost, even though it was encrypted with keys
/// distinct from the current relationship's.
pub fn load_chat_history(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
) -> Result<Vec<ChatMessage>, String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;

    let identities = std::iter::once((friend.pubkey.clone(), friend.my_account_index)).chain(
        friend
            .prior_identities
            .iter()
            .map(|p| (p.pubkey.clone(), p.my_account_index)),
    );

    let mut messages: Vec<ChatMessage> = Vec::new();
    for (contact_pubkey, account_index) in identities {
        let Ok(keys) = derive_contact_keys(&mnemonic, account_index) else {
            continue;
        };
        let Ok(friend_pk) = PublicKey::from_hex(&contact_pubkey) else {
            continue;
        };
        let my_pubkey = keys.public_key();
        let filter = Filter::new().kind(Kind::Seal).authors([my_pubkey, friend_pk]);
        let events = runtime()
            .block_on(db(&storage_dir).query(filter))
            .map_err(|e| e.to_string())?;
        messages.extend(
            events
                .into_iter()
                .filter_map(|seal| decrypt_seal(&keys, &friend_pk, &seal, my_pubkey)),
        );
    }
    if friend.is_blocked {
        let held = load_held(&storage_dir);
        messages.retain(|m| !held.contains(&m.id));
    }
    if let Some(cutoff) = load_cleared(&storage_dir).get(&friend_pubkey) {
        messages.retain(|m| m.created_at > *cutoff);
    }
    messages.sort_by_key(|m| m.created_at);
    Ok(messages)
}

/// Decrypts a stored/received `Seal` back into a [ChatMessage]. Returns
/// `None` on any malformed or spoofed input (e.g. the rumor claiming a
/// different author than the seal actually signed with).
fn decrypt_seal(
    keys: &Keys,
    friend_pk: &PublicKey,
    seal: &Event,
    my_pubkey: PublicKey,
) -> Option<ChatMessage> {
    let rumor_json = nip44::decrypt(keys.secret_key(), friend_pk, &seal.content).ok()?;
    let rumor = UnsignedEvent::from_json(rumor_json).ok()?;
    if rumor.pubkey != seal.pubkey {
        return None;
    }
    Some(ChatMessage {
        id: seal.id.to_hex(),
        sender_pubkey: seal.pubkey.to_hex(),
        content: rumor.content,
        created_at: rumor.created_at.as_secs() as i64,
        is_mine: seal.pubkey == my_pubkey,
    })
}

/// Unwraps an incoming Gift Wrap `event` addressed to `my_keys`, verifying
/// the `Seal` and that its sender is either `expected_sender` (the friend
/// this connection is watching for — a stranger can't forge messages that
/// appear to come from an established friend, since they don't hold that
/// friend's per-contact secret key) or ourselves (the self-addressed copy
/// [send_chat_message] publishes so our own sent messages sync back via
/// this same path). On success, persists the `Seal` locally and returns
/// the decrypted message.
pub(crate) async fn receive_gift_wrap(
    storage_dir: &str,
    my_keys: &Keys,
    expected_sender: &PublicKey,
    gift_wrap: &Event,
) -> Option<ChatMessage> {
    let seal_json = nip44::decrypt(my_keys.secret_key(), &gift_wrap.pubkey, &gift_wrap.content).ok()?;
    let seal = Event::from_json(seal_json).ok()?;
    let my_pubkey = my_keys.public_key();
    if seal.kind != Kind::Seal || (seal.pubkey != *expected_sender && seal.pubkey != my_pubkey) {
        return None;
    }
    seal.verify().ok()?;

    let message = decrypt_seal(my_keys, expected_sender, &seal, my_pubkey)?;
    db(storage_dir).save_event(&seal).await.ok()?;
    Some(message)
}

fn cleared_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("chat_cleared_at.json")
}

/// Maps friend pubkey -> the time [clear_chat_history] was last called for
/// them. A relay has no concept of "delete my local copy" — the friend's
/// Gift Wraps are still sitting on relays and get refetched by a fresh,
/// `since`-less subscription (e.g. after an app restart), which would
/// otherwise silently undo a clear. [load_chat_history] hides anything at
/// or before this cutoff instead of relying on local deletion alone.
fn load_cleared(storage_dir: &str) -> HashMap<String, i64> {
    std::fs::read_to_string(cleared_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_cleared(storage_dir: &str, cleared: &HashMap<String, i64>) -> Result<(), String> {
    let json = serde_json::to_string(cleared).map_err(|e| e.to_string())?;
    std::fs::write(cleared_path(storage_dir), json).map_err(|e| e.to_string())
}

pub(crate) fn cleared_snapshot(storage_dir: &str) -> HashMap<String, i64> {
    load_cleared(storage_dir)
}

pub(crate) fn set_cleared_snapshot(
    storage_dir: &str,
    cleared: HashMap<String, i64>,
) -> Result<(), String> {
    save_cleared(storage_dir, &cleared)
}

fn held_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("held_messages.json")
}

/// IDs of Seal messages that arrived while their sender was blocked. Kept
/// out of [load_chat_history]/[has_chat_history] (see the `is_blocked`
/// check there) so a still-blocked friend stays fully silent — no preview,
/// no unread badge, nothing — even though the message itself was already
/// saved to `chat.lmdb` so it's not lost once unblocked.
fn load_held(storage_dir: &str) -> Vec<String> {
    std::fs::read_to_string(held_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Marks a just-received message as held (see [load_held]) — call right
/// after saving a Seal from a currently-blocked sender.
pub(crate) fn hold_message(storage_dir: &str, message_id: &str) {
    let mut held = load_held(storage_dir);
    if !held.iter().any(|id| id == message_id) {
        held.push(message_id.to_string());
        let _ = std::fs::write(
            held_path(storage_dir),
            serde_json::to_string(&held).unwrap_or_default(),
        );
    }
}

fn started_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("chat_started.json")
}

/// Pubkeys of friends whose chat thread has been explicitly opened via the
/// "Talk" button on their profile — lets the Talk tab show only
/// conversations the user actually started, rather than every friend by
/// default. A friend who has *sent* us a message shows up regardless (see
/// [has_chat_history]), since obviously they've already started it.
fn load_started(storage_dir: &str) -> Vec<String> {
    std::fs::read_to_string(started_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub(crate) fn started_snapshot(storage_dir: &str) -> Vec<String> {
    load_started(storage_dir)
}

pub(crate) fn set_started_snapshot(storage_dir: &str, started: Vec<String>) -> Result<(), String> {
    let json = serde_json::to_string(&started).map_err(|e| e.to_string())?;
    std::fs::write(started_path(storage_dir), json).map_err(|e| e.to_string())
}

/// Marks `friend_pubkey`'s thread as started — call when the user taps
/// "Talk" on their profile, before opening the thread for the first time.
pub fn mark_chat_started(storage_dir: String, friend_pubkey: String) -> Result<(), String> {
    let mut started = load_started(&storage_dir);
    if !started.contains(&friend_pubkey) {
        started.push(friend_pubkey);
    }
    let json = serde_json::to_string(&started).map_err(|e| e.to_string())?;
    std::fs::write(started_path(&storage_dir), json).map_err(|e| e.to_string())
}

/// Whether any message has ever been exchanged with `friend_pubkey` — used
/// so a friend who messages us first shows up in the Talk tab even if we
/// never tapped "Talk" ourselves. Delegates to [load_chat_history] (rather
/// than a cheaper existence-only query) so this respects the same
/// held/cleared filtering — otherwise a blocked or just-cleared friend
/// with no *visible* messages could still count as "has history" and
/// wrongly reappear in the Talk tab.
fn has_chat_history(mnemonic: &str, storage_dir: &str, friend_pubkey: &str) -> bool {
    load_chat_history(mnemonic.to_string(), storage_dir.to_string(), friend_pubkey.to_string())
        .map(|messages| !messages.is_empty())
        .unwrap_or(false)
}

/// Pubkeys of friends who should show up in the Talk tab: either the user
/// explicitly started that thread, or a message already exists in either
/// direction.
pub fn list_active_chat_pubkeys(mnemonic: String, storage_dir: String) -> Vec<String> {
    let started = load_started(&storage_dir);
    friends::load_friends(storage_dir.clone())
        .into_iter()
        .map(|f| f.pubkey)
        .filter(|pubkey| started.contains(pubkey) || has_chat_history(&mnemonic, &storage_dir, pubkey))
        .collect()
}

fn read_state_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("chat_read_state.json")
}

/// Maps friend pubkey -> the timestamp of the last message the user has
/// seen in that thread, used to compute unread counts for the Talk list.
fn load_read_state(storage_dir: &str) -> HashMap<String, i64> {
    std::fs::read_to_string(read_state_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_read_state(storage_dir: &str, state: &HashMap<String, i64>) -> Result<(), String> {
    let json = serde_json::to_string(state).map_err(|e| e.to_string())?;
    std::fs::write(read_state_path(storage_dir), json).map_err(|e| e.to_string())
}

pub(crate) fn read_state_snapshot(storage_dir: &str) -> HashMap<String, i64> {
    load_read_state(storage_dir)
}

pub(crate) fn set_read_state_snapshot(
    storage_dir: &str,
    state: HashMap<String, i64>,
) -> Result<(), String> {
    save_read_state(storage_dir, &state)
}

/// Marks every message currently in `friend_pubkey`'s thread as read —
/// call when the user opens that thread.
pub fn mark_thread_read(storage_dir: String, friend_pubkey: String) -> Result<(), String> {
    let now = Timestamp::now().as_secs() as i64;
    let mut state = load_read_state(&storage_dir);
    state.insert(friend_pubkey, now);
    save_read_state(&storage_dir, &state)
}

/// Deletes the entire local message history with `friend_pubkey` (both
/// directions) and resets the thread back to "not started" — the friend
/// drops out of the Talk tab until either side messages again. Purely
/// local: doesn't notify the friend or affect the friendship itself, so
/// they can still message and reopen the thread later.
pub fn clear_chat_history(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
) -> Result<(), String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;

    let identities = std::iter::once((friend.pubkey.clone(), friend.my_account_index)).chain(
        friend
            .prior_identities
            .iter()
            .map(|p| (p.pubkey.clone(), p.my_account_index)),
    );
    for (contact_pubkey, account_index) in identities {
        let Ok(keys) = derive_contact_keys(&mnemonic, account_index) else {
            continue;
        };
        let Ok(friend_pk) = PublicKey::from_hex(&contact_pubkey) else {
            continue;
        };
        let filter = Filter::new().kind(Kind::Seal).authors([keys.public_key(), friend_pk]);
        runtime()
            .block_on(db(&storage_dir).delete(filter))
            .map_err(|e| e.to_string())?;
    }

    let mut started = load_started(&storage_dir);
    started.retain(|pk| pk != &friend_pubkey);
    std::fs::write(
        started_path(&storage_dir),
        serde_json::to_string(&started).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;

    let mut read_state = load_read_state(&storage_dir);
    read_state.remove(&friend_pubkey);
    save_read_state(&storage_dir, &read_state)?;

    // The friend's Gift Wraps are still sitting on relays — a fresh,
    // `since`-less subscription (e.g. after an app restart) would refetch
    // and re-save them, silently undoing the delete above. Recording this
    // cutoff lets [load_chat_history] keep hiding anything from before the
    // clear even after that happens.
    let mut cleared = load_cleared(&storage_dir);
    cleared.insert(friend_pubkey, Timestamp::now().as_secs() as i64);
    save_cleared(&storage_dir, &cleared)
}

pub struct UnreadCount {
    pub friend_pubkey: String,
    pub count: u32,
}

/// For each of `friend_pubkeys`, counts messages from that friend received
/// after the last time [mark_thread_read] was called for them (or all of
/// their messages, if the thread has never been opened).
pub fn load_unread_counts(
    mnemonic: String,
    storage_dir: String,
    friend_pubkeys: Vec<String>,
) -> Vec<UnreadCount> {
    let state = load_read_state(&storage_dir);
    friend_pubkeys
        .into_iter()
        .map(|pubkey| {
            let last_read = state.get(&pubkey).copied().unwrap_or(0);
            let count = load_chat_history(mnemonic.clone(), storage_dir.clone(), pubkey.clone())
                .map(|messages| {
                    messages
                        .iter()
                        .filter(|m| !m.is_mine && m.created_at > last_read)
                        .count() as u32
                })
                .unwrap_or(0);
            UnreadCount {
                friend_pubkey: pubkey,
                count,
            }
        })
        .collect()
}
