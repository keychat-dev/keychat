//! Forward secrecy for 1:1 chat, layered *inside* the existing per-friend
//! Seal/Gift-Wrap transport (`chat.rs`) rather than replacing it.
//!
//! `chat.rs`'s NIP-44 encryption uses a fixed per-friend key derived from
//! the mnemonic — safe against reuse (NIP-44 mixes in a fresh random nonce
//! every time) but with no forward secrecy: whoever learns that key can
//! decrypt every past message. A textbook Double Ratchet fixes this by
//! discarding each message's key right after use, but a ratchet is
//! *stateful* — advancing it is a one-way, one-shot operation — so it
//! cannot simply reuse the same mnemonic-derived key on every device the
//! way `chat.rs` does: two devices independently "spending" the same
//! chain step would each encrypt different content under the *same*
//! keystream (a two-time-pad break, leaking both messages' content to
//! anyone who sees both ciphertexts).
//!
//! The fix used here: each device mints its own random Olm account (never
//! derived from the mnemonic, so it can't collide across devices), and
//! announces its public key material to a friend over the *existing*
//! mnemonic-derived channel (a [DEVICE_ANNOUNCE_KIND] control rumor,
//! sent/verified exactly like `chat.rs`'s edit/delete rumors). Once both
//! sides know each other's, they establish an Olm session between *these
//! two devices specifically* — so two of a user's devices never share
//! ratchet state, and the two-time-pad failure mode can't occur. The outer
//! Seal/Gift-Wrap transport (routing, sender authentication, relay
//! publishing) is completely unchanged; only the rumor's `content` is, for
//! [RATCHET_MESSAGE_KIND], itself the output of this module's own
//! encryption rather than plain text.
//!
//! The ratchet itself is [vodozemac]'s Olm implementation — the audited
//! library Matrix uses in production — rather than a hand-rolled Double
//! Ratchet. Implementation mistakes in ratchet code are the kind that leave
//! messages flowing normally while silently voiding forward secrecy, so
//! this deliberately delegates every cryptographic step (key agreement,
//! chain advancement, skipped-key caching, AEAD) and keeps only the parts
//! that are genuinely KeyChat-specific: how key material is announced, and
//! how sessions and decrypted plaintext are stored.
//!
//! Sessions use [SessionConfig::version_1], the Olm version deployed
//! across Matrix, in preference to the crate's `version_2` (an untruncated
//! MAC, but gated behind an `experimental-session-config` feature) —
//! staying on the best-exercised code path is the whole reason for using
//! this library, and v1's 8-byte MAC truncation isn't a practical forgery
//! risk over this transport. Worth revisiting if v2 stops being
//! experimental.
//!
//! Olm needs a "one-time key" from the recipient to start a session, which
//! normally means a key server handing out a fresh one per conversation.
//! There isn't one here, so the announce carries a *fallback* key instead
//! — the mechanism Olm itself defines for when one-time keys run out. It's
//! deliberately reusable, so it costs forward secrecy only for a session's
//! very first message (exactly the property the hand-rolled version had,
//! since it started from static identity keys), and every message from the
//! first reply onward is fully forward-secret. Announcing a genuinely
//! one-time key per friend would close that last gap: the announce is
//! already per-friend and end-to-end encrypted, so only that friend could
//! spend it — left for later since Olm accounts evict unused one-time keys
//! once full, which needs care to not strand a friend mid-handshake.
//!
//! Two consequences worth knowing:
//! - Only the device that receives a ratchet message can ever decrypt it —
//!   its key is discarded immediately after. So (unlike `chat.rs`, which
//!   stores ciphertext and re-derives the same key from the mnemonic on
//!   every [chat::load_chat_history] call) this module has to store the
//!   *plaintext* locally the moment it's decrypted. That plaintext is
//!   itself encrypted at rest with a per-device local storage key (see
//!   [generate_local_storage_key]) — not derived from the mnemonic, kept
//!   in OS Keystore/Keychain by the Dart side — so a copy of this device's
//!   files alone (without also compromising the running device) still
//!   reveals nothing.
//! - Each of a user's devices maintains an entirely independent session
//!   and plaintext store per friend. Sent/received ratchet messages do
//!   not sync to a user's other devices (unlike ordinary chat messages'
//!   self-echo) — a deliberate trade-off for avoiding the two-time-pad
//!   problem without a full multi-device-aware transport.
//!
//! v1 scope: a friend can only have one *active* announced device at a
//! time (the most recently announced one) — if they use multiple devices
//! simultaneously, only the latest one participates in new sessions.
//! Skipped/out-of-order and duplicated deliveries are handled inside the
//! Olm session, which matters because Nostr relay delivery is unordered
//! and duplicates freely; a permanently-lost message just stays
//! undecryptable on its own and never blocks later ones.

use crate::api::chat::{self, DEVICE_ANNOUNCE_KIND, RATCHET_MESSAGE_KIND};
use crate::api::friends;
use chacha20poly1305::aead::rand_core::{OsRng, RngCore};
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{KeyInit, XChaCha20Poly1305};
use nostr::event::{Event, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{JsonUtil, Keys, PublicKey};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use vodozemac::olm::{
    Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle,
};
use vodozemac::Curve25519PublicKey;

/// The Olm version every session uses — see this module's doc comment on
/// why not `version_2`.
fn session_config() -> SessionConfig {
    SessionConfig::version_1()
}

/// Serializes every ratchet session read-modify-write (sending *or*
/// receiving) across this process. Needed because `sync.rs` runs one
/// subscription task per relay, and a friend's relays typically overlap
/// with ours — the same Gift Wrap (or near-simultaneous distinct ones)
/// can arrive on two relay tasks at once, and without this lock their
/// independent load-session -> mutate -> save-session cycles can race
/// and silently clobber each other's chain advancement, corrupting the
/// session for every message after. A single process-wide lock (rather
/// than one per friend) is coarser than necessary but this module's I/O
/// is small and infrequent enough that it isn't worth the bookkeeping.
fn ratchet_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Cap on how many processed seal ids are remembered for duplicate
/// suppression — only needs to be "big enough to outlast realistic relay
/// replay", not unbounded.
pub(crate) const MAX_PROCESSED_IDS: usize = 4000;

/// Cap on how many sessions are retained per peer. More than one is normal
/// (see [store_session]), but the list must not grow without bound.
const MAX_SESSIONS_PER_PEER: usize = 5;

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub(crate) fn random_hex(len: usize) -> String {
    let mut bytes = vec![0u8; len];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

pub(crate) fn hex32(s: &str) -> Result<[u8; 32], String> {
    let bytes = hex::decode(s).map_err(|e| e.to_string())?;
    bytes.try_into().map_err(|_| "expected 32 bytes".to_string())
}

// ---------------------------------------------------------------------
// Local storage key (Keystore-backed on the Dart side) and the small
// XChaCha20-Poly1305 helpers everything else in this module uses to keep
// device-local secrets (identity key, session state, decrypted plaintext)
// encrypted at rest.
// ---------------------------------------------------------------------

/// A fresh random key for encrypting this module's local state at rest —
/// call once and persist the result via `flutter_secure_storage` (see this
/// module's doc comment), the same way `keys.rs`'s seed phrase is handled.
/// Deliberately not derived from the mnemonic: unlike every other secret in
/// this app, this key must differ per device, since (per this module's doc
/// comment) sharing ratchet state across devices is exactly what breaks it.
pub fn generate_local_storage_key() -> String {
    random_hex(32)
}

fn encrypt_at_rest(local_key: &[u8; 32], plaintext: &[u8]) -> Vec<u8> {
    let mut nonce = [0u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new(local_key.into());
    let ciphertext = cipher
        .encrypt((&nonce).into(), plaintext)
        .expect("XChaCha20-Poly1305 encryption of an in-memory buffer cannot fail");
    let mut out = nonce.to_vec();
    out.extend(ciphertext);
    out
}

fn decrypt_at_rest(local_key: &[u8; 32], data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 24 {
        return Err("corrupt local ratchet storage".to_string());
    }
    let (nonce, ciphertext) = data.split_at(24);
    let cipher = XChaCha20Poly1305::new(local_key.into());
    cipher.decrypt(nonce.into(), ciphertext).map_err(|e| e.to_string())
}

pub(crate) fn write_encrypted<T: Serialize>(path: &Path, local_key: &[u8; 32], value: &T) -> Result<(), String> {
    let json = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    std::fs::write(path, encrypt_at_rest(local_key, &json)).map_err(|e| e.to_string())
}

pub(crate) fn read_encrypted<T: for<'de> Deserialize<'de> + Default>(path: &Path, local_key: &[u8; 32]) -> T {
    let Ok(data) = std::fs::read(path) else { return T::default() };
    let Ok(plaintext) = decrypt_at_rest(local_key, &data) else { return T::default() };
    serde_json::from_slice(&plaintext).unwrap_or_default()
}

// ---------------------------------------------------------------------
// Device identity: this device's own Olm account.
// ---------------------------------------------------------------------

fn account_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("ratchet_account.enc")
}

/// This device's Olm account, minting one (with its fallback key) on first
/// use. Always carries an unpublished fallback key: [Account::fallback_key]
/// only reports one while it's unpublished, and [announce_device] must keep
/// reporting the same value on every call, so nothing here ever calls
/// `mark_keys_as_published`.
pub(crate) fn load_or_create_account(
    storage_dir: &str,
    local_key: &[u8; 32],
) -> Result<Account, String> {
    let path = account_path(storage_dir);
    if let Ok(data) = std::fs::read(&path) {
        if let Ok(plaintext) = decrypt_at_rest(local_key, &data) {
            if let Ok(pickle) = serde_json::from_slice::<AccountPickle>(&plaintext) {
                let mut account = Account::from_pickle(pickle);
                if account.fallback_key().is_empty() {
                    account.generate_fallback_key();
                    save_account(storage_dir, local_key, &account)?;
                }
                return Ok(account);
            }
        }
    }
    let mut account = Account::new();
    account.generate_fallback_key();
    save_account(storage_dir, local_key, &account)?;
    Ok(account)
}

pub(crate) fn save_account(
    storage_dir: &str,
    local_key: &[u8; 32],
    account: &Account,
) -> Result<(), String> {
    let json = serde_json::to_vec(&account.pickle()).map_err(|e| e.to_string())?;
    std::fs::write(account_path(storage_dir), encrypt_at_rest(local_key, &json))
        .map_err(|e| e.to_string())
}

/// The public key material a peer needs to start a session with this
/// device: an Olm identity key plus the reusable fallback key standing in
/// for a one-time key (see this module's doc comment).
///
/// Travels as one opaque `"<identity>.<fallback>"` string so that
/// everything carrying it — the announce payload, `friend_devices.json`,
/// a group roster's `device_pubkey`, and the Dart side's "does this friend
/// have a device yet?" check — stays a single string it never parses.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DeviceBundle {
    pub(crate) identity: Curve25519PublicKey,
    pub(crate) fallback: Curve25519PublicKey,
}

impl DeviceBundle {
    fn encode(&self) -> String {
        format!("{}.{}", self.identity.to_base64(), self.fallback.to_base64())
    }

    pub(crate) fn decode(encoded: &str) -> Result<Self, String> {
        let (identity, fallback) =
            encoded.split_once('.').ok_or("malformed device key bundle")?;
        Ok(DeviceBundle {
            identity: Curve25519PublicKey::from_base64(identity).map_err(|e| e.to_string())?,
            fallback: Curve25519PublicKey::from_base64(fallback).map_err(|e| e.to_string())?,
        })
    }

    fn of(account: &Account) -> Result<Self, String> {
        let fallback = *account
            .fallback_key()
            .values()
            .next()
            .ok_or("this device's Olm account has no fallback key")?;
        Ok(DeviceBundle { identity: account.curve25519_key(), fallback })
    }
}

/// This device's announceable public key material (see [DeviceBundle]),
/// creating its Olm account if this device doesn't have one yet — call
/// before [announce_device].
pub fn device_identity_pubkey(storage_dir: String, local_key: String) -> Result<String, String> {
    let local_key = hex32(&local_key)?;
    let account = load_or_create_account(&storage_dir, &local_key)?;
    Ok(DeviceBundle::of(&account)?.encode())
}

// ---------------------------------------------------------------------
// Announced device public keys, per friend — plain (non-secret) local
// state, so no at-rest encryption needed here (mirrors `friends.json`).
// ---------------------------------------------------------------------

fn friend_devices_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("friend_devices.json")
}

fn load_friend_devices(storage_dir: &str) -> HashMap<String, String> {
    std::fs::read_to_string(friend_devices_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_friend_device(storage_dir: &str, friend_pubkey: &str, bundle: &str) {
    let mut devices = load_friend_devices(storage_dir);
    devices.insert(friend_pubkey.to_string(), bundle.to_string());
    let _ = std::fs::write(
        friend_devices_path(storage_dir),
        serde_json::to_string(&devices).unwrap_or_default(),
    );
}

/// Drops every session with `friend_pubkey` when `announced` carries a
/// different *identity* key than what they'd announced before — that means
/// a new Olm account (a reinstall, or a switch to another device), whose
/// holder has none of the old sessions and so can't decrypt anything sent
/// on them. Without this, a friend reinstalling would leave this side
/// encrypting into a session that's gone forever.
///
/// A changed *fallback* key alone is left alone deliberately: that's key
/// rotation on the same account, and the established sessions stay valid.
fn forget_sessions_if_reinstalled(
    storage_dir: &str,
    local_key: &[u8; 32],
    friend_pubkey: &str,
    announced: &str,
) {
    let Ok(new_bundle) = DeviceBundle::decode(announced) else { return };
    let previous = load_friend_devices(storage_dir).get(friend_pubkey).cloned();
    let Some(previous) = previous else { return };
    let Ok(old_bundle) = DeviceBundle::decode(&previous) else { return };
    if old_bundle.identity == new_bundle.identity {
        return;
    }
    let mut sessions = load_sessions(storage_dir, local_key);
    if sessions.remove(friend_pubkey).is_some() {
        let _ = save_sessions(storage_dir, local_key, &sessions);
    }
}

/// The forward-secrecy device key bundle (see [DeviceBundle]) that
/// `friend_pubkey` last announced to us, if any — the UI uses this to
/// decide whether to offer/attempt a forward-secret send at all, and
/// otherwise treats it as opaque.
///
/// Anything unparseable is reported as "no device announced" rather than
/// handed back for a send to choke on: a stored announce predating the
/// [DeviceBundle] format is exactly that, and the friendly failure is to
/// fall back to ordinary (non-forward-secret) chat until that friend's app
/// re-announces, which it does on the next thread open.
pub fn friend_device_pubkey(storage_dir: String, friend_pubkey: String) -> Option<String> {
    let announced = load_friend_devices(&storage_dir).get(&friend_pubkey).cloned()?;
    DeviceBundle::decode(&announced).ok().map(|_| announced)
}

#[derive(Serialize, Deserialize)]
struct DeviceAnnouncePayload {
    device_pubkey: String,
}

/// Publishes this device's public key bundle to `friend_pubkey`, over the
/// existing mnemonic-derived channel (so it's authenticated/encrypted the
/// same way any other control rumor is) — call once per friend (idempotent
/// to call again; the friend's app just re-applies the same value, or
/// switches to a new one if this device was reinstalled).
pub fn announce_device(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    local_key: String,
) -> Result<(), String> {
    let bundle = device_identity_pubkey(storage_dir.clone(), local_key)?;
    let content = serde_json::to_string(&DeviceAnnouncePayload { device_pubkey: bundle })
        .map_err(|e| e.to_string())?;
    chat::send_control_rumor(&mnemonic, &storage_dir, &friend_pubkey, DEVICE_ANNOUNCE_KIND, content, true, None)
}

// ---------------------------------------------------------------------
// Olm session state, per peer.
// ---------------------------------------------------------------------

/// One Olm session with a peer, plus what's needed to choose between
/// several of them.
#[derive(Clone, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct StoredSession {
    /// Olm's own session id, kept alongside the pickle so sessions can be
    /// matched against an incoming pre-key message without unpickling each.
    session_id: String,
    /// The pickled session. Held as generic JSON rather than a
    /// [SessionPickle] because a pickle can only be turned back into a
    /// [Session] by consuming it, and these have to stay in place to be
    /// tried repeatedly.
    pickle: serde_json::Value,
    created_at: i64,
    /// Whether anything has ever been decrypted on this session, i.e.
    /// whether the peer is known to actually be using it.
    received: bool,
}

impl StoredSession {
    fn new(session: &Session, received: bool) -> Result<Self, String> {
        Ok(StoredSession {
            session_id: session.session_id(),
            pickle: serde_json::to_value(session.pickle()).map_err(|e| e.to_string())?,
            created_at: now(),
            received,
        })
    }

    fn session(&self) -> Result<Session, String> {
        let pickle: SessionPickle =
            serde_json::from_value(self.pickle.clone()).map_err(|e| e.to_string())?;
        Ok(Session::from_pickle(pickle))
    }
}

/// Every session with one peer, newest last.
///
/// More than one is normal and must be tolerated rather than overwritten:
/// if both sides send their first message before either has received one,
/// each independently starts an outbound session against the other's
/// (reusable) fallback key, and the two are genuinely different sessions.
/// Keeping them all means decryption can just try each, so neither side's
/// messages are lost to the race.
#[derive(Clone, Default, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SessionStore {
    sessions: Vec<StoredSession>,
}

fn sessions_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("ratchet_sessions.enc")
}

fn load_sessions(storage_dir: &str, local_key: &[u8; 32]) -> HashMap<String, SessionStore> {
    read_encrypted(&sessions_path(storage_dir), local_key)
}

fn save_sessions(
    storage_dir: &str,
    local_key: &[u8; 32],
    sessions: &HashMap<String, SessionStore>,
) -> Result<(), String> {
    write_encrypted(&sessions_path(storage_dir), local_key, sessions)
}

/// The transport form of an encrypted message: an Olm message plus the two
/// pieces of metadata the callers need alongside it.
#[derive(Serialize, Deserialize)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RatchetMessagePayload {
    /// Locally-generated id, echoed back by the receiver so both sides
    /// store the decrypted plaintext under the same id — there's no seal
    /// id available yet at encryption time (the seal is only signed
    /// afterwards, by `chat::send_control_rumor`).
    pub(crate) id: String,
    pub(crate) created_at: i64,
    /// [OlmMessage::to_parts]' discriminant: whether `ciphertext` is a
    /// pre-key message (one that can establish a session) or a normal one.
    message_type: usize,
    ciphertext: String,
}

impl RatchetMessagePayload {
    fn new(id: String, message: &OlmMessage) -> Self {
        let (message_type, ciphertext) = message.to_parts();
        RatchetMessagePayload {
            id,
            created_at: now(),
            message_type,
            ciphertext: base64_encode(&ciphertext),
        }
    }

    fn to_olm_message(&self) -> Result<OlmMessage, String> {
        OlmMessage::from_parts(self.message_type, &base64_decode(&self.ciphertext)?)
            .map_err(|e| e.to_string())
    }
}

/// Adds `session` to `store`, replacing an existing entry for the same Olm
/// session id rather than accumulating duplicates of it, and trimming the
/// oldest once past [MAX_SESSIONS_PER_PEER].
fn store_session(store: &mut SessionStore, session: &Session, received: bool) -> Result<(), String> {
    let updated = StoredSession::new(session, received)?;
    match store.sessions.iter_mut().find(|s| s.session_id == updated.session_id) {
        Some(existing) => {
            existing.pickle = updated.pickle;
            existing.received |= received;
        }
        None => {
            store.sessions.push(updated);
            if store.sessions.len() > MAX_SESSIONS_PER_PEER {
                let excess = store.sessions.len() - MAX_SESSIONS_PER_PEER;
                store.sessions.drain(0..excess);
            }
        }
    }
    Ok(())
}

/// Encrypts `plaintext` for the peer described by `peer`, over the best
/// existing session with them or a fresh outbound one.
///
/// Prefers a session the peer has demonstrably used (something was
/// decrypted on it) over one we opened optimistically, and the newest among
/// those — so after the crossed-first-message race above, both sides
/// converge onto sessions that are known to work instead of talking past
/// each other. Either side can still decrypt whichever session the other
/// picks, since [ratchet_decrypt] tries them all.
pub(crate) fn ratchet_encrypt(
    account: &Account,
    store: &mut SessionStore,
    peer: &DeviceBundle,
    plaintext: &[u8],
) -> Result<RatchetMessagePayload, String> {
    let best = store
        .sessions
        .iter()
        .enumerate()
        .max_by_key(|(index, s)| (s.received, s.created_at, *index))
        .map(|(index, _)| index);

    let mut session = match best {
        Some(index) => store.sessions[index].session()?,
        None => account
            .create_outbound_session(session_config(), peer.identity, peer.fallback)
            .map_err(|e| e.to_string())?,
    };
    let message = session.encrypt(plaintext).map_err(|e| e.to_string())?;
    store_session(store, &session, false)?;
    Ok(RatchetMessagePayload::new(random_hex(16), &message))
}

/// Decrypts `payload`, establishing a new inbound session if it's a pre-key
/// message for one we don't have yet. `account` is mutated when that
/// happens, so the caller must persist it as well as `store`.
pub(crate) fn ratchet_decrypt(
    account: &mut Account,
    store: &mut SessionStore,
    payload: &RatchetMessagePayload,
) -> Result<Vec<u8>, String> {
    let message = payload.to_olm_message()?;

    // A pre-key message that belongs to a session we already have is just
    // an ordinary message on it — Olm keeps sending pre-key messages until
    // the peer's first reply proves the session took, so most of them
    // arrive for an already-established session.
    if let OlmMessage::PreKey(pre_key) = &message {
        let session_id = pre_key.session_id();
        if !store.sessions.iter().any(|s| s.session_id == session_id) {
            let result = account
                .create_inbound_session(session_config(), pre_key.identity_key(), pre_key)
                .map_err(|e| e.to_string())?;
            store_session(store, &result.session, true)?;
            return Ok(result.plaintext);
        }
    }

    // Otherwise try each session: which one a normal message belongs to
    // isn't knowable from the outside, and a failed attempt leaves the
    // stored session untouched (only the unpickled copy is advanced).
    for index in (0..store.sessions.len()).rev() {
        let mut session = store.sessions[index].session()?;
        if let Ok(plaintext) = session.decrypt(&message) {
            store_session(store, &session, true)?;
            return Ok(plaintext);
        }
    }
    Err("no session could decrypt this ratchet message".to_string())
}

fn base64_encode(data: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(data)
}

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(s).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Locally-decrypted plaintext store — see module doc comment on why this
// (uniquely, among this app's chat data) has to persist plaintext rather
// than re-derivable ciphertext.
// ---------------------------------------------------------------------

/// A forward-secret message, already decrypted — exposed to the UI to be
/// merged into a friend's regular (non-forward-secret) history.
#[derive(Clone, Serialize, Deserialize)]
pub struct RatchetChatMessage {
    pub id: String,
    pub friend_pubkey: String,
    pub content: String,
    pub created_at: i64,
    pub is_mine: bool,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub is_edited: bool,
    #[serde(default)]
    pub is_deleted: bool,
    #[serde(default)]
    pub reply_to: Option<String>,
}

/// What a decrypted [RatchetMessagePayload]'s plaintext actually is — a
/// message (optionally replying to an earlier one), or a control
/// instruction targeting a message this device (specifically — see module
/// doc comment on why history isn't shared across a user's devices) has
/// already stored. Unlike `chat.rs`, which authenticates edit/delete via
/// the outer Seal's signature, there's no separate signature layer here:
/// the ratchet key agreement itself is what authenticates the sender, the
/// same way it authenticates every ordinary message.
#[derive(Serialize, Deserialize)]
#[serde(tag = "t")]
enum RatchetContent {
    #[serde(rename = "msg")]
    Msg {
        body: String,
        #[serde(default)]
        reply_to: Option<String>,
    },
    #[serde(rename = "edit")]
    Edit { target: String, body: String },
    #[serde(rename = "delete")]
    Delete { target: String },
}

fn messages_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("ratchet_messages.enc")
}

fn load_all_messages(storage_dir: &str, local_key: &[u8; 32]) -> Vec<RatchetChatMessage> {
    read_encrypted(&messages_path(storage_dir), local_key)
}

fn append_message(storage_dir: &str, local_key: &[u8; 32], message: RatchetChatMessage) -> Result<(), String> {
    let mut all = load_all_messages(storage_dir, local_key);
    if !all.iter().any(|m| m.id == message.id) {
        all.push(message);
    }
    write_encrypted(&messages_path(storage_dir), local_key, &all)
}

/// This device's forward-secret history with `friend_pubkey`, oldest
/// first — merge into [chat::load_chat_history]'s result for display. Only
/// ever grows via messages sent/received *by this specific device* (see
/// module doc comment) — a fresh device starts with none.
pub fn load_ratchet_history(
    storage_dir: String,
    local_key: String,
    friend_pubkey: String,
) -> Result<Vec<RatchetChatMessage>, String> {
    let local_key = hex32(&local_key)?;
    let mut messages: Vec<RatchetChatMessage> = load_all_messages(&storage_dir, &local_key)
        .into_iter()
        .filter(|m| m.friend_pubkey == friend_pubkey && !m.hidden)
        .collect();
    messages.sort_by_key(|m| m.created_at);
    Ok(messages)
}

/// Hides a forward-secret message from this device's view only — there's
/// no signed retraction for ratchet messages (see module doc: only the
/// receiving device ever holds the plaintext, so there's nothing for a
/// friend's device to authenticate against), so unlike [chat]'s
/// hide/edit/unsend this can't be anything but local.
pub fn hide_ratchet_message(storage_dir: String, local_key: String, message_id: String) -> Result<(), String> {
    let local_key = hex32(&local_key)?;
    let mut all = load_all_messages(&storage_dir, &local_key);
    let Some(m) = all.iter_mut().find(|m| m.id == message_id) else {
        return Ok(());
    };
    m.hidden = true;
    write_encrypted(&messages_path(&storage_dir), &local_key, &all)
}

// ---------------------------------------------------------------------
// Sending.
// ---------------------------------------------------------------------

/// Sends `content` to `friend_pubkey` with forward secrecy, over a Double
/// Ratchet session with their most-recently-announced device — fails with
/// a clear error if they haven't announced one yet (call
/// [friend_device_pubkey] first to check).
pub fn send_ratchet_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    local_key: String,
    content: String,
    reply_to: Option<String>,
) -> Result<(), String> {
    let local_key_bytes = hex32(&local_key)?;
    let envelope = RatchetContent::Msg { body: content.clone(), reply_to: reply_to.clone() };
    let msg_id = send_ratchet_envelope(&mnemonic, &storage_dir, &friend_pubkey, &local_key_bytes, &envelope)?;
    append_message(
        &storage_dir,
        &local_key_bytes,
        RatchetChatMessage {
            id: msg_id,
            friend_pubkey,
            content,
            created_at: now(),
            is_mine: true,
            hidden: false,
            is_edited: false,
            is_deleted: false,
            reply_to,
        },
    )
}

/// Replaces the content of a message this device previously sent, both
/// locally and (via a fresh ratchet-encrypted `edit` envelope) for the
/// friend's copy of it.
pub fn edit_ratchet_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    local_key: String,
    message_id: String,
    new_content: String,
) -> Result<(), String> {
    let local_key_bytes = hex32(&local_key)?;
    let envelope = RatchetContent::Edit { target: message_id.clone(), body: new_content.clone() };
    send_ratchet_envelope(&mnemonic, &storage_dir, &friend_pubkey, &local_key_bytes, &envelope)?;

    let mut all = load_all_messages(&storage_dir, &local_key_bytes);
    if let Some(m) = all.iter_mut().find(|m| m.id == message_id && m.is_mine) {
        m.content = new_content;
        m.is_edited = true;
    }
    write_encrypted(&messages_path(&storage_dir), &local_key_bytes, &all)
}

/// Unsends a message this device previously sent, both locally and (via a
/// fresh ratchet-encrypted `delete` envelope) for the friend's copy.
pub fn delete_ratchet_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    local_key: String,
    message_id: String,
) -> Result<(), String> {
    let local_key_bytes = hex32(&local_key)?;
    let envelope = RatchetContent::Delete { target: message_id.clone() };
    send_ratchet_envelope(&mnemonic, &storage_dir, &friend_pubkey, &local_key_bytes, &envelope)?;

    let mut all = load_all_messages(&storage_dir, &local_key_bytes);
    if let Some(m) = all.iter_mut().find(|m| m.id == message_id && m.is_mine) {
        m.content = String::new();
        m.is_deleted = true;
    }
    write_encrypted(&messages_path(&storage_dir), &local_key_bytes, &all)
}

/// Encrypts `envelope` over this device's ratchet session with
/// `friend_pubkey` and publishes it as a [RATCHET_MESSAGE_KIND] control
/// rumor, the same way an ordinary message is sent — a message and an
/// edit/delete instruction are indistinguishable at the transport layer,
/// only the decrypted plaintext's `t` tag tells them apart. Returns the
/// payload's locally-generated id (only meaningful for a plain `Msg`).
fn send_ratchet_envelope(
    mnemonic: &str,
    storage_dir: &str,
    friend_pubkey: &str,
    local_key_bytes: &[u8; 32],
    envelope: &RatchetContent,
) -> Result<String, String> {
    friends::load_friends(storage_dir.to_string())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    if friends::load_blocked(storage_dir).contains(&friend_pubkey.to_string()) {
        return Err("friend is blocked".to_string());
    }
    let plaintext = serde_json::to_vec(envelope).map_err(|e| e.to_string())?;

    // See [ratchet_lock]'s doc comment — this device's own concurrent
    // relay-delivered receives must not race this send's session
    // read-modify-write either. Scoped to just the session update, not
    // the network publish below, so a slow relay round-trip doesn't
    // block incoming messages from being processed.
    let payload = {
        let _guard = ratchet_lock().lock().unwrap_or_else(|e| e.into_inner());
        let announced = friend_device_pubkey(storage_dir.to_string(), friend_pubkey.to_string())
            .ok_or("friend hasn't announced a forward-secrecy device yet")?;
        let peer = DeviceBundle::decode(&announced)?;
        let account = load_or_create_account(storage_dir, local_key_bytes)?;
        let mut sessions = load_sessions(storage_dir, local_key_bytes);
        let store = sessions.entry(friend_pubkey.to_string()).or_default();
        let payload = ratchet_encrypt(&account, store, &peer, &plaintext)?;
        save_sessions(storage_dir, local_key_bytes, &sessions)?;
        payload
    };

    let msg_id = payload.id.clone();
    let json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    chat::send_control_rumor(mnemonic, storage_dir, friend_pubkey, RATCHET_MESSAGE_KIND, json, true, None)?;
    Ok(msg_id)
}

// ---------------------------------------------------------------------
// Receiving — called from `sync.rs`'s live subscription, alongside (not
// instead of) `chat::receive_gift_wrap`.
// ---------------------------------------------------------------------

pub(crate) enum RatchetReceived {
    DeviceAnnounced,
    Message,
}

fn processed_ids_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("ratchet_processed_ids.json")
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
    if ids.len() > MAX_PROCESSED_IDS {
        let excess = ids.len() - MAX_PROCESSED_IDS;
        ids.drain(0..excess);
    }
    let _ = std::fs::write(processed_ids_path(storage_dir), serde_json::to_string(&ids).unwrap_or_default());
}

/// Unwraps and applies an incoming Gift Wrap that turned out to carry a
/// [DEVICE_ANNOUNCE_KIND] or [RATCHET_MESSAGE_KIND] rumor — mirrors
/// [chat::receive_gift_wrap]'s unwrap/verify logic independently (rather
/// than sharing it) since, unlike every `chat.rs` message kind, a
/// [RATCHET_MESSAGE_KIND] payload can only be decrypted here, once, and
/// needs `local_key` to do it — which `chat::receive_gift_wrap`'s callers
/// don't otherwise have a reason to carry around.
pub(crate) async fn receive_ratchet_gift_wrap(
    storage_dir: &str,
    local_key: &str,
    my_keys: &Keys,
    expected_sender: &PublicKey,
    gift_wrap: &Event,
) -> Option<RatchetReceived> {
    let seal_json = nip44::decrypt(my_keys.secret_key(), &gift_wrap.pubkey, &gift_wrap.content).ok()?;
    let seal = Event::from_json(seal_json).ok()?;
    if seal.kind != nostr::Kind::Seal || seal.pubkey != *expected_sender {
        // Unlike `chat::receive_gift_wrap`, self-authored copies are
        // skipped outright: a self-echo of our own sent ratchet message
        // can never decrypt against our own receiving chain (it was
        // encrypted with our sending chain), and we've already recorded
        // our own sent plaintext locally at send time anyway.
        return None;
    }
    seal.verify().ok()?;
    let rumor_json = nip44::decrypt(my_keys.secret_key(), expected_sender, &seal.content).ok()?;
    let rumor = UnsignedEvent::from_json(rumor_json).ok()?;
    if rumor.pubkey != seal.pubkey {
        return None;
    }
    if rumor.kind != DEVICE_ANNOUNCE_KIND && rumor.kind != RATCHET_MESSAGE_KIND {
        return None;
    }

    let seal_id = seal.id.to_hex();
    // Held for the rest of this function — see [ratchet_lock]'s doc
    // comment for why concurrent relay deliveries need this serialized.
    let _guard = ratchet_lock().lock().unwrap_or_else(|e| e.into_inner());

    if already_processed(storage_dir, &seal_id) {
        return None;
    }

    if rumor.kind == DEVICE_ANNOUNCE_KIND {
        let payload: DeviceAnnouncePayload = serde_json::from_str(&rumor.content).ok()?;
        let friend_pubkey = expected_sender.to_hex();
        if let Ok(local_key_bytes) = hex32(local_key) {
            forget_sessions_if_reinstalled(
                storage_dir,
                &local_key_bytes,
                &friend_pubkey,
                &payload.device_pubkey,
            );
        }
        save_friend_device(storage_dir, &friend_pubkey, &payload.device_pubkey);
        mark_processed(storage_dir, &seal_id);
        return Some(RatchetReceived::DeviceAnnounced);
    }

    let payload: RatchetMessagePayload = serde_json::from_str(&rumor.content).ok()?;
    let local_key_bytes = hex32(local_key).ok()?;
    let friend_pubkey = expected_sender.to_hex();

    let mut account = load_or_create_account(storage_dir, &local_key_bytes).ok()?;
    let mut sessions = load_sessions(storage_dir, &local_key_bytes);
    let store = sessions.entry(friend_pubkey.clone()).or_default();
    let plaintext = ratchet_decrypt(&mut account, store, &payload).ok()?;
    // Establishing an inbound session consumes key material from the
    // account, so it has to be persisted alongside the session itself.
    save_account(storage_dir, &local_key_bytes, &account).ok()?;
    save_sessions(storage_dir, &local_key_bytes, &sessions).ok()?;

    let envelope: RatchetContent = serde_json::from_slice(&plaintext).ok()?;
    match envelope {
        RatchetContent::Msg { body, reply_to } => {
            let _ = append_message(
                storage_dir,
                &local_key_bytes,
                RatchetChatMessage {
                    id: payload.id,
                    friend_pubkey,
                    content: body,
                    created_at: payload.created_at,
                    is_mine: false,
                    hidden: false,
                    is_edited: false,
                    is_deleted: false,
                    reply_to,
                },
            );
        }
        RatchetContent::Edit { target, body } => {
            let mut all = load_all_messages(storage_dir, &local_key_bytes);
            if let Some(m) = all.iter_mut().find(|m| m.id == target && !m.is_mine) {
                m.content = body;
                m.is_edited = true;
                let _ = write_encrypted(&messages_path(storage_dir), &local_key_bytes, &all);
            }
        }
        RatchetContent::Delete { target } => {
            let mut all = load_all_messages(storage_dir, &local_key_bytes);
            if let Some(m) = all.iter_mut().find(|m| m.id == target && !m.is_mine) {
                m.content = String::new();
                m.is_deleted = true;
                let _ = write_encrypted(&messages_path(storage_dir), &local_key_bytes, &all);
            }
        }
    }
    mark_processed(storage_dir, &seal_id);
    Some(RatchetReceived::Message)
}

// Group chat forward+backward secrecy lives in `group_ratchet.rs` instead
// of here — it needs a *third* identity (not this module's per-friend
// contact key, nor its Olm device identity alone) per (group, member)
// pair, since group members generally aren't 1:1 friends of each other.
// See that module's doc comment for the full design; it reuses this
// module's session store and encrypt/decrypt helpers (all `pub(crate)`)
// rather than duplicating them.

#[cfg(test)]
mod tests {
    use super::*;

    /// A throwaway storage directory, since the account/session helpers are
    /// file-backed.
    fn temp_dir(tag: &str) -> String {
        let path = std::env::temp_dir().join(format!("keychat-ratchet-test-{tag}-{}", random_hex(8)));
        std::fs::create_dir_all(&path).expect("create temp storage dir");
        path.to_string_lossy().to_string()
    }

    /// One side of a conversation: an Olm account plus its sessions.
    struct Device {
        account: Account,
        store: SessionStore,
    }

    impl Device {
        fn new() -> Self {
            let mut account = Account::new();
            account.generate_fallback_key();
            Device { account, store: SessionStore::default() }
        }

        fn bundle(&self) -> DeviceBundle {
            DeviceBundle::of(&self.account).expect("a fallback key exists")
        }

        fn send(&mut self, peer: &DeviceBundle, text: &str) -> RatchetMessagePayload {
            ratchet_encrypt(&self.account, &mut self.store, peer, text.as_bytes())
                .expect("encrypts")
        }

        fn receive(&mut self, payload: &RatchetMessagePayload) -> Result<String, String> {
            let plaintext = ratchet_decrypt(&mut self.account, &mut self.store, payload)?;
            String::from_utf8(plaintext).map_err(|e| e.to_string())
        }
    }

    /// The payload has to survive the JSON round-trip it makes as a rumor's
    /// `content` on the way through a relay.
    fn over_the_wire(payload: &RatchetMessagePayload) -> RatchetMessagePayload {
        let json = serde_json::to_string(payload).expect("serializes");
        serde_json::from_str(&json).expect("deserializes")
    }

    #[test]
    fn device_bundle_round_trip() {
        let device = Device::new();
        let encoded = device.bundle().encode();
        let decoded = DeviceBundle::decode(&encoded).expect("decodes");
        assert_eq!(decoded.identity, device.account.curve25519_key());
        assert_eq!(decoded.fallback, device.bundle().fallback);
    }

    #[test]
    fn device_bundle_rejects_garbage() {
        assert!(DeviceBundle::decode("no-separator").is_err());
        assert!(DeviceBundle::decode("not.base64!!").is_err());
        // An old-format announce (a bare hex X25519 key) must be rejected
        // rather than silently misread as a bundle.
        assert!(DeviceBundle::decode(&random_hex(32)).is_err());
    }

    #[test]
    fn message_round_trip_between_two_devices() {
        let mut alice = Device::new();
        let mut bob = Device::new();
        let bob_bundle = bob.bundle();
        let alice_bundle = alice.bundle();

        let first = alice.send(&bob_bundle, "hello bob");
        assert_eq!(bob.receive(&over_the_wire(&first)).unwrap(), "hello bob");

        let reply = bob.send(&alice_bundle, "hello alice");
        assert_eq!(alice.receive(&over_the_wire(&reply)).unwrap(), "hello alice");

        // And keeps working once both chains are established.
        let third = alice.send(&bob_bundle, "still here");
        assert_eq!(bob.receive(&over_the_wire(&third)).unwrap(), "still here");
    }

    /// Each payload carries its own id, which both sides store the message
    /// under — so they must not collide across messages.
    #[test]
    fn each_message_gets_a_distinct_id() {
        let mut alice = Device::new();
        let bob_bundle = Device::new().bundle();
        let a = alice.send(&bob_bundle, "one");
        let b = alice.send(&bob_bundle, "two");
        assert_ne!(a.id, b.id);
    }

    /// Relays deliver in no particular order.
    #[test]
    fn out_of_order_delivery() {
        let mut alice = Device::new();
        let mut bob = Device::new();
        let bob_bundle = bob.bundle();

        let one = alice.send(&bob_bundle, "one");
        let two = alice.send(&bob_bundle, "two");
        let three = alice.send(&bob_bundle, "three");

        assert_eq!(bob.receive(&two).unwrap(), "two");
        assert_eq!(bob.receive(&three).unwrap(), "three");
        assert_eq!(bob.receive(&one).unwrap(), "one", "a late earlier message must still decrypt");
    }

    /// Relays also deliver the same event repeatedly, and `sync.rs` can hand
    /// the same payload here more than once — that must not wedge the
    /// session for everything after it.
    #[test]
    fn duplicate_delivery_leaves_the_session_usable() {
        let mut alice = Device::new();
        let mut bob = Device::new();
        let bob_bundle = bob.bundle();

        let first = alice.send(&bob_bundle, "one");
        assert_eq!(bob.receive(&first).unwrap(), "one");
        assert!(bob.receive(&first).is_err(), "a replay must not decrypt twice");

        let second = alice.send(&bob_bundle, "two");
        assert_eq!(bob.receive(&second).unwrap(), "two", "the session survives the replay");
    }

    /// The case a single-session-per-peer store would lose messages on: both
    /// sides send before either has received, so each starts its own
    /// outbound session against the other's reusable fallback key.
    #[test]
    fn crossed_first_messages_keep_both_directions_working() {
        let mut alice = Device::new();
        let mut bob = Device::new();
        let alice_bundle = alice.bundle();
        let bob_bundle = bob.bundle();

        let from_alice = alice.send(&bob_bundle, "from alice");
        let from_bob = bob.send(&alice_bundle, "from bob");

        assert_eq!(bob.receive(&from_alice).unwrap(), "from alice");
        assert_eq!(alice.receive(&from_bob).unwrap(), "from bob");

        // Both sides now hold two sessions; conversation has to continue
        // regardless of which one either picks to send on.
        for i in 0..4 {
            let a = alice.send(&bob_bundle, &format!("a{i}"));
            assert_eq!(bob.receive(&a).unwrap(), format!("a{i}"));
            let b = bob.send(&alice_bundle, &format!("b{i}"));
            assert_eq!(alice.receive(&b).unwrap(), format!("b{i}"));
        }
    }

    /// Sessions are retained per peer but must not grow without bound.
    #[test]
    fn session_count_is_capped() {
        let mut bob = Device::new();
        let bob_bundle = bob.bundle();
        // Each fresh peer establishes a distinct inbound session with Bob.
        for i in 0..(MAX_SESSIONS_PER_PEER + 3) {
            let mut peer = Device::new();
            let payload = peer.send(&bob_bundle, &format!("peer {i}"));
            // Deliberately all filed under one peer key, which is what a
            // long-lived conversation that re-handshakes repeatedly looks
            // like to the store.
            let text = ratchet_decrypt(&mut bob.account, &mut bob.store, &payload).unwrap();
            assert_eq!(String::from_utf8(text).unwrap(), format!("peer {i}"));
        }
        assert_eq!(bob.store.sessions.len(), MAX_SESSIONS_PER_PEER);
    }

    /// An account must come back identical across restarts, or every friend's
    /// cached copy of our announce would go stale.
    #[test]
    fn account_persists_with_a_stable_bundle() {
        let dir = temp_dir("account");
        let local_key = hex32(&random_hex(32)).unwrap();

        let first = load_or_create_account(&dir, &local_key).unwrap();
        let announced = DeviceBundle::of(&first).unwrap().encode();

        let second = load_or_create_account(&dir, &local_key).unwrap();
        assert_eq!(DeviceBundle::of(&second).unwrap().encode(), announced);
    }

    /// The at-rest encryption must actually be keyed by `local_key`.
    #[test]
    fn account_is_unreadable_with_the_wrong_local_key() {
        let dir = temp_dir("wrong-key");
        let right = hex32(&random_hex(32)).unwrap();
        let wrong = hex32(&random_hex(32)).unwrap();

        let announced = DeviceBundle::of(&load_or_create_account(&dir, &right).unwrap())
            .unwrap()
            .encode();
        // A wrong key can't decrypt it, so a *different* account is minted
        // rather than the caller getting the original one back.
        let other = DeviceBundle::of(&load_or_create_account(&dir, &wrong).unwrap()).unwrap().encode();
        assert_ne!(other, announced);
    }

    /// Sessions have to survive an app restart mid-conversation.
    #[test]
    fn sessions_persist_across_a_reload() {
        let dir = temp_dir("sessions");
        let local_key = hex32(&random_hex(32)).unwrap();
        let peer_key = "friend-pubkey";

        let alice = Device::new();
        let mut bob = Device::new();
        let bob_bundle = bob.bundle();

        // Alice sends, persists, and "restarts".
        let first = {
            let account = load_or_create_account(&dir, &local_key).unwrap();
            let mut sessions: HashMap<String, SessionStore> = load_sessions(&dir, &local_key);
            let store = sessions.entry(peer_key.to_string()).or_default();
            let payload = ratchet_encrypt(&account, store, &bob_bundle, b"before restart").unwrap();
            save_sessions(&dir, &local_key, &sessions).unwrap();
            payload
        };
        assert_eq!(bob.receive(&first).unwrap(), "before restart");

        let reloaded = load_sessions(&dir, &local_key);
        assert_eq!(reloaded.get(peer_key).map(|s| s.sessions.len()), Some(1));

        // The restored session keeps the same chain rather than starting over.
        let second = {
            let account = load_or_create_account(&dir, &local_key).unwrap();
            let mut sessions = reloaded;
            let store = sessions.entry(peer_key.to_string()).or_default();
            ratchet_encrypt(&account, store, &bob_bundle, b"after restart").unwrap()
        };
        assert_eq!(bob.receive(&second).unwrap(), "after restart");

        // Sanity: `alice` (the in-memory device) was never used here, so the
        // persisted path really is what carried the conversation.
        assert!(alice.store.sessions.is_empty());
    }

    /// A friend reinstalling announces a brand-new identity key, and the
    /// sessions bound to the old one have to go — nothing sent on them
    /// could ever be decrypted again.
    #[test]
    fn reinstalled_friend_clears_stale_sessions() {
        let dir = temp_dir("reinstall");
        let local_key = hex32(&random_hex(32)).unwrap();
        let friend = "friend-pubkey";

        // Establish a session against their first device, and store it.
        let first_device = Device::new();
        let mut sessions: HashMap<String, SessionStore> = HashMap::new();
        let account = load_or_create_account(&dir, &local_key).unwrap();
        let store = sessions.entry(friend.to_string()).or_default();
        ratchet_encrypt(&account, store, &first_device.bundle(), b"hi").unwrap();
        save_sessions(&dir, &local_key, &sessions).unwrap();
        save_friend_device(&dir, friend, &first_device.bundle().encode());
        assert_eq!(load_sessions(&dir, &local_key).get(friend).map(|s| s.sessions.len()), Some(1));

        // Re-announcing the *same* device must not disturb anything, even
        // though its fallback key could have rotated.
        forget_sessions_if_reinstalled(
            &dir,
            &local_key,
            friend,
            &first_device.bundle().encode(),
        );
        assert_eq!(load_sessions(&dir, &local_key).get(friend).map(|s| s.sessions.len()), Some(1));

        // A different account (reinstall) drops them.
        let reinstalled = Device::new();
        forget_sessions_if_reinstalled(&dir, &local_key, friend, &reinstalled.bundle().encode());
        assert!(load_sessions(&dir, &local_key).get(friend).is_none());
    }

    /// A payload that isn't decryptable by any session must fail cleanly
    /// rather than corrupting the store.
    #[test]
    fn undecryptable_payload_is_rejected() {
        let mut alice = Device::new();
        let mut bob = Device::new();
        let mut eve = Device::new();
        let bob_bundle = bob.bundle();

        let good = alice.send(&bob_bundle, "legit");
        assert_eq!(bob.receive(&good).unwrap(), "legit");
        let sessions_before = bob.store.sessions.len();

        // A message from a third party's session with Bob decrypts (it's a
        // valid prekey message), but a *tampered* one must not.
        let mut tampered = eve.send(&bob_bundle, "spoofed");
        tampered.ciphertext = base64_encode(b"garbage that is not an olm message");
        assert!(bob.receive(&tampered).is_err());

        let next = alice.send(&bob_bundle, "still fine");
        assert_eq!(bob.receive(&next).unwrap(), "still fine");
        assert_eq!(bob.store.sessions.len(), sessions_before);
    }
}
