//! Forward+backward secrecy for group chat, letting members reach each
//! other directly — including members `self` is *not* individually a 1:1
//! friend of — instead of always fanning a message out over each
//! recipient's pre-existing 1:1 relationship (`groups.rs`'s original
//! design; see that module's doc comment).
//!
//! Every account mints one dedicated Nostr identity keypair *per group*
//! (deterministically, via the same NIP-06 multi-account derivation
//! `keys::derive_contact_keys` already uses for 1:1 relationships — a
//! fresh sequential `account` index, allocated the same way an invite's or
//! friend's index is, so it costs no new key-management machinery and
//! stays unlinkable to this account's other relationships). This identity
//! is shared with the rest of the group via the membership roster
//! (`groups::GroupMember::group_pubkey`/`relays`) — once a member knows
//! it, they can Gift-Wrap directly to it, no 1:1 friendship required, the
//! same way `chat.rs` Gift-Wraps to any known pubkey.
//!
//! On top of that direct transport, every *pair* of group members gets its
//! own persistent Double Ratchet session (reusing `ratchet.rs`'s session
//! type/KDF/DH-step logic verbatim, just keyed by `"{group_id}:{their
//! group_pubkey}"` instead of `friend_pubkey`, and sharing this device's
//! *same* X25519 device identity `ratchet.rs` already maintains — no
//! second device keypair needed). Every roster update and every chat
//! message to a given member goes through that member's session, giving
//! the exact same forward secrecy (chain key discarded after use) and
//! post-compromise security (fresh DH ephemeral generated whenever the
//! peer's DH public key changes) 1:1 chat already has — see `ratchet.rs`'s
//! module doc for why that combination works.
//!
//! A member who *is* also a 1:1 friend still gets a completely separate
//! session here rather than reusing their 1:1 ratchet session — mixing a
//! group's key material into an unrelated 1:1 relationship's chain would
//! entangle the two contexts (e.g. leaving the group shouldn't affect the
//! 1:1 relationship's ratchet state, or vice versa).
//!
//! v1 scope, matching `ratchet.rs`'s: no check that an incoming message's
//! sender is actually a roster member before decrypting it — anyone who
//! somehow learns this device's per-group pubkey (normally only obtainable
//! by being told it via the roster) can address it a syntactically valid
//! Gift-Wrap. The Seal's signature still proves *who* sent it (so it can't
//! be forged as a specific other member), just not that they're currently
//! a member in good standing; `groups.rs`'s caller is responsible for any
//! roster-membership check it wants on top of that.

use crate::api::invites;
use crate::api::keys::derive_contact_keys;
use crate::api::ratchet::{
    hex32, load_or_create_identity, read_encrypted, write_encrypted, ratchet_decrypt,
    ratchet_encrypt, RatchetMessagePayload, RatchetSession,
};
use crate::api::sync::publish_to_relays;
use nostr::event::{Event, EventBuilder, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{JsonUtil, Keys, Kind, PublicKey};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// See [crate::api::ratchet]'s identically-purposed lock — a single
/// process-wide lock over every group session's read-modify-write, rather
/// than one per (group, peer), for the same reason: this module's I/O is
/// small and infrequent enough that finer-grained locking isn't worth the
/// bookkeeping.
fn group_ratchet_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

const MAX_SKIPPED_KEYS: usize = 1000;

// ---------------------------------------------------------------------
// Per-group Nostr routing identity.
// ---------------------------------------------------------------------

fn identity_accounts_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("group_identity_accounts.json")
}

fn load_identity_accounts(storage_dir: &str) -> HashMap<String, u32> {
    std::fs::read_to_string(identity_accounts_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_identity_accounts(storage_dir: &str, accounts: &HashMap<String, u32>) {
    let _ = std::fs::write(
        identity_accounts_path(storage_dir),
        serde_json::to_string(accounts).unwrap_or_default(),
    );
}

/// This device's dedicated Nostr identity for `group_id`, minting (and
/// persisting the NIP-06 account index for) one if it doesn't have one
/// yet. Reused for every message/roster-update this device sends to that
/// group — see module doc comment for why a fresh index rather than a
/// random keypair.
pub(crate) fn own_group_keys(mnemonic: &str, storage_dir: &str, group_id: &str) -> Result<Keys, String> {
    let mut accounts = load_identity_accounts(storage_dir);
    let index = match accounts.get(group_id) {
        Some(idx) => *idx,
        None => {
            let idx = invites::allocate_account_index(storage_dir)?;
            accounts.insert(group_id.to_string(), idx);
            save_identity_accounts(storage_dir, &accounts);
            idx
        }
    };
    derive_contact_keys(mnemonic, index)
}

/// Every group this device already has its own identity minted for, as
/// `(that identity's pubkey, group_id)` — used to build the live
/// subscription's watch list (`sync.rs`) so incoming Gift-Wraps addressed
/// to any of them get delivered. Doesn't mint new identities itself (same
/// as `sync.rs`'s existing invite/friend watch entries, which only read
/// already-allocated indices) — [own_group_keys] does that, called the
/// first time this device processes a given group.
pub(crate) fn own_group_identities(mnemonic: &str, storage_dir: &str) -> Vec<(PublicKey, String)> {
    load_identity_accounts(storage_dir)
        .into_iter()
        .filter_map(|(group_id, idx)| {
            derive_contact_keys(mnemonic, idx).ok().map(|k| (k.public_key(), group_id))
        })
        .collect()
}

// ---------------------------------------------------------------------
// Pairwise Double Ratchet session per (group_id, peer_group_pubkey) —
// reuses `ratchet.rs`'s session type/KDF/DH-step logic verbatim.
// ---------------------------------------------------------------------

fn sessions_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("group_ratchet_sessions.enc")
}

fn load_sessions(storage_dir: &str, local_key: &[u8; 32]) -> HashMap<String, RatchetSession> {
    read_encrypted(&sessions_path(storage_dir), local_key)
}

fn save_sessions(
    storage_dir: &str,
    local_key: &[u8; 32],
    sessions: &HashMap<String, RatchetSession>,
) -> Result<(), String> {
    write_encrypted(&sessions_path(storage_dir), local_key, sessions)
}

fn session_key(group_id: &str, peer_group_pubkey: &str) -> String {
    format!("{group_id}:{peer_group_pubkey}")
}

fn processed_ids_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("group_processed_ids.json")
}

fn already_processed(storage_dir: &str, seal_id: &str) -> bool {
    let ids: Vec<String> = std::fs::read_to_string(processed_ids_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    ids.iter().any(|id| id == seal_id)
}

fn mark_processed(storage_dir: &str, seal_id: &str) {
    let mut ids: Vec<String> = std::fs::read_to_string(processed_ids_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    ids.push(seal_id.to_string());
    if ids.len() > MAX_SKIPPED_KEYS * 4 {
        let excess = ids.len() - MAX_SKIPPED_KEYS * 4;
        ids.drain(0..excess);
    }
    let _ = std::fs::write(processed_ids_path(storage_dir), serde_json::to_string(&ids).unwrap_or_default());
}

/// Encrypts `plaintext` for `peer_group_pubkey` via this group's pairwise
/// Double Ratchet session with them (bootstrapping one from
/// `peer_device_pubkey` if none exists yet), and Gift-Wraps/publishes it
/// as a `kind` rumor directly to that pubkey over `peer_relays` — no 1:1
/// friendship with them required. Must be called from a context already
/// running on `sync::runtime()` (see `chat::send_control_rumor_async`'s
/// doc comment for why) since `groups.rs`'s send paths already are.
pub(crate) async fn send_to_member(
    mnemonic: &str,
    storage_dir: &str,
    local_key: &str,
    group_id: &str,
    peer_group_pubkey: &str,
    peer_device_pubkey: &str,
    peer_relays: &[String],
    kind: Kind,
    plaintext: &str,
) -> Result<(), String> {
    let local_key_bytes = hex32(local_key)?;
    let my_keys = own_group_keys(mnemonic, storage_dir, group_id)?;
    let peer_pk = PublicKey::from_hex(peer_group_pubkey).map_err(|e| e.to_string())?;

    let payload = {
        let _guard = group_ratchet_lock().lock().unwrap_or_else(|e| e.into_inner());
        let key = session_key(group_id, peer_group_pubkey);
        let mut sessions = load_sessions(storage_dir, &local_key_bytes);
        let mut session = match sessions.get(&key) {
            Some(s) => s.clone(),
            None => {
                let identity = load_or_create_identity(storage_dir, &local_key_bytes)?;
                RatchetSession::new(identity.to_bytes(), hex32(peer_device_pubkey)?)
            }
        };
        let payload = ratchet_encrypt(&mut session, plaintext.as_bytes())?;
        sessions.insert(key, session);
        save_sessions(storage_dir, &local_key_bytes, &sessions)?;
        payload
    };

    let payload_json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let rumor: UnsignedEvent = EventBuilder::new(kind, payload_json).build(my_keys.public_key());
    let seal: Event = EventBuilder::seal(&my_keys, &peer_pk, rumor)
        .await
        .map_err(|e| e.to_string())?
        .sign(&my_keys)
        .await
        .map_err(|e| e.to_string())?;
    let wrap: Event = EventBuilder::gift_wrap_from_seal(&peer_pk, &seal, []).map_err(|e| e.to_string())?;
    publish_to_relays(peer_relays, &wrap).await
}

/// What [receive_gift_wrap] decrypted, for `groups.rs` to apply.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct GroupRatchetReceived {
    pub sender_group_pubkey: String,
    pub kind: Kind,
    pub plaintext: String,
    pub created_at: i64,
    /// The ratchet payload's own locally-generated id (see
    /// `RatchetMessagePayload::id`'s doc comment) — stable across both
    /// sides, unlike a seal id, which `groups.rs` uses as the stored
    /// message's id.
    pub id: String,
}

/// Unwraps an incoming Gift-Wrap addressed to `my_group_keys` (one of this
/// device's per-group identities — see [own_group_keys]) — `sync.rs` tries
/// this for every event matched via a `Watch::Group` entry. Unlike
/// `chat::receive_gift_wrap`/`ratchet::receive_ratchet_gift_wrap`, accepts
/// *any* sender (see module doc's v1-scope note) since group membership
/// isn't cross-checked here.
pub(crate) async fn receive_gift_wrap(
    storage_dir: &str,
    local_key: &str,
    group_id: &str,
    my_group_keys: &Keys,
    gift_wrap: &Event,
) -> Option<GroupRatchetReceived> {
    let seal_json =
        nip44::decrypt(my_group_keys.secret_key(), &gift_wrap.pubkey, &gift_wrap.content).ok()?;
    let seal = Event::from_json(seal_json).ok()?;
    if seal.kind != nostr::Kind::Seal {
        return None;
    }
    seal.verify().ok()?;
    let rumor_json = nip44::decrypt(my_group_keys.secret_key(), &seal.pubkey, &seal.content).ok()?;
    let rumor = UnsignedEvent::from_json(rumor_json).ok()?;
    if rumor.pubkey != seal.pubkey {
        return None;
    }

    let seal_id = seal.id.to_hex();
    // Held for the rest of this function — see [group_ratchet_lock]'s doc
    // comment for why concurrent relay deliveries need this serialized.
    let _guard = group_ratchet_lock().lock().unwrap_or_else(|e| e.into_inner());
    if already_processed(storage_dir, &seal_id) {
        return None;
    }

    let payload: RatchetMessagePayload = serde_json::from_str(&rumor.content).ok()?;
    let local_key_bytes = hex32(local_key).ok()?;
    let sender_group_pubkey = seal.pubkey.to_hex();
    let key = session_key(group_id, &sender_group_pubkey);

    let mut sessions = load_sessions(storage_dir, &local_key_bytes);
    let mut session = match sessions.get(&key) {
        Some(s) => s.clone(),
        None => {
            let identity = load_or_create_identity(storage_dir, &local_key_bytes).ok()?;
            RatchetSession::new(identity.to_bytes(), hex32(&payload.header.dh_pub).ok()?)
        }
    };
    let plaintext_bytes = ratchet_decrypt(&mut session, &payload).ok()?;
    sessions.insert(key, session);
    save_sessions(storage_dir, &local_key_bytes, &sessions).ok()?;
    mark_processed(storage_dir, &seal_id);

    let plaintext = String::from_utf8(plaintext_bytes).ok()?;
    Some(GroupRatchetReceived {
        sender_group_pubkey,
        kind: rumor.kind,
        plaintext,
        created_at: payload.created_at,
        id: payload.id,
    })
}
