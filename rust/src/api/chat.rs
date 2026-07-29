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
use crate::api::sync::{publish_to_relays, runtime};
use nostr::event::{Event, EventBuilder, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{Filter, JsonUtil, Keys, Kind, PublicKey, Timestamp};
use nostr_database::NostrDatabase;
use nostr_lmdb::NostrLMDB;
use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;

fn db(storage_dir: &str) -> &'static NostrLMDB {
    static DB: OnceLock<NostrLMDB> = OnceLock::new();
    DB.get_or_init(|| {
        let path = Path::new(storage_dir).join("chat.lmdb");
        NostrLMDB::open(path).expect("failed to open chat database")
    })
}

/// A single decrypted message, ready to show in the UI.
pub struct ChatMessage {
    pub id: String,
    pub sender_pubkey: String,
    pub content: String,
    pub created_at: i64,
    pub is_mine: bool,
}

/// Builds a Gift Wrap for `message` addressed to `friend_pubkey`, persists
/// our own copy of the `Seal` locally (so our own sent messages show up in
/// [load_chat_history] too), and publishes the wrap to the friend's relays.
pub fn send_chat_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message: String,
) -> Result<(), String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    let keys = derive_contact_keys(&mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(&friend_pubkey).map_err(|e| e.to_string())?;

    runtime().block_on(async {
        let rumor: UnsignedEvent =
            EventBuilder::private_msg_rumor(friend_pk, message).build(keys.public_key());
        let seal: Event = EventBuilder::seal(&keys, &friend_pk, rumor)
            .await
            .map_err(|e| e.to_string())?
            .sign(&keys)
            .await
            .map_err(|e| e.to_string())?;
        let wrap: Event = EventBuilder::gift_wrap_from_seal(&friend_pk, &seal, [])
            .map_err(|e| e.to_string())?;

        db(&storage_dir)
            .save_event(&seal)
            .await
            .map_err(|e| e.to_string())?;
        publish_to_relays(&friend.relays, &wrap).await
    })
}

/// Loads the full decrypted message history with `friend_pubkey` from
/// local storage (no relay round-trip — the live subscription and
/// [send_chat_message] are what keep it current), oldest first.
pub fn load_chat_history(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
) -> Result<Vec<ChatMessage>, String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    let keys = derive_contact_keys(&mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(&friend_pubkey).map_err(|e| e.to_string())?;
    let my_pubkey = keys.public_key();

    let filter = Filter::new().kind(Kind::Seal).authors([my_pubkey, friend_pk]);
    let events = runtime()
        .block_on(db(&storage_dir).query(filter))
        .map_err(|e| e.to_string())?;

    let mut messages: Vec<ChatMessage> = events
        .into_iter()
        .filter_map(|seal| decrypt_seal(&keys, &friend_pk, &seal, my_pubkey))
        .collect();
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
/// the `Seal` and that its sender matches `expected_sender` (the friend
/// this connection is watching for — a stranger can't forge messages that
/// appear to come from an established friend, since they don't hold that
/// friend's per-contact secret key). On success, persists the `Seal`
/// locally and returns the decrypted message.
pub(crate) async fn receive_gift_wrap(
    storage_dir: &str,
    my_keys: &Keys,
    expected_sender: &PublicKey,
    gift_wrap: &Event,
) -> Option<ChatMessage> {
    let seal_json = nip44::decrypt(my_keys.secret_key(), &gift_wrap.pubkey, &gift_wrap.content).ok()?;
    let seal = Event::from_json(seal_json).ok()?;
    if seal.kind != Kind::Seal || seal.pubkey != *expected_sender {
        return None;
    }
    seal.verify().ok()?;

    let message = decrypt_seal(my_keys, expected_sender, &seal, my_keys.public_key())?;
    db(storage_dir).save_event(&seal).await.ok()?;
    Some(message)
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

/// Marks every message currently in `friend_pubkey`'s thread as read —
/// call when the user opens that thread.
pub fn mark_thread_read(storage_dir: String, friend_pubkey: String) -> Result<(), String> {
    let now = Timestamp::now().as_secs() as i64;
    let mut state = load_read_state(&storage_dir);
    state.insert(friend_pubkey, now);
    save_read_state(&storage_dir, &state)
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
