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
//! The fix used here: each device mints its own random X25519 "device
//! identity" keypair (never derived from the mnemonic, so it can't collide
//! across devices), and announces its public half to a friend over the
//! *existing* mnemonic-derived channel (a [DEVICE_ANNOUNCE_KIND] control
//! rumor, sent/verified exactly like `chat.rs`'s edit/delete rumors). Once
//! both sides know each other's device identity, they derive a Double
//! Ratchet session between *these two devices specifically* — so two of a
//! user's devices never share ratchet state, and the two-time-pad failure
//! mode can't occur. The outer Seal/Gift-Wrap transport (routing, sender
//! authentication, relay publishing) is completely unchanged; only the
//! rumor's `content` is, for [RATCHET_MESSAGE_KIND], itself the output of
//! this module's own encryption rather than plain text.
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
//! simultaneously, only the latest one participates in new ratchet
//! sessions. The session's very first message is derived purely from both
//! sides' static device-identity keys (no forward secrecy yet relative to
//! a compromise of those specific keys); every message from the second
//! ratchet step onward (i.e. as soon as either side has replied) is fully
//! forward-secret. Skipped/out-of-order message keys are cached (bounded —
//! see [MAX_SKIPPED_KEYS]) so Nostr's unordered, unreliable relay delivery
//! doesn't break the chain; a permanently-lost message just stays
//! undecryptable on its own; it never blocks later messages.

use crate::api::chat::{self, DEVICE_ANNOUNCE_KIND, RATCHET_MESSAGE_KIND};
use crate::api::friends;
use chacha20poly1305::aead::rand_core::{OsRng, RngCore};
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{KeyInit, XChaCha20Poly1305};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use nostr::event::{Event, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{JsonUtil, Keys, PublicKey};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret};

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

/// Cap on how many skipped-message keys a single session retains — bounds
/// memory/storage if a large batch of messages never arrives, at the cost
/// of those particular messages becoming permanently undecryptable once
/// exceeded (later messages are unaffected either way).
const MAX_SKIPPED_KEYS: usize = 1000;

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
// Device identity: this device's own X25519 keypair.
// ---------------------------------------------------------------------

fn identity_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("ratchet_identity.enc")
}

pub(crate) fn load_or_create_identity(storage_dir: &str, local_key: &[u8; 32]) -> Result<StaticSecret, String> {
    let path = identity_path(storage_dir);
    if let Ok(data) = std::fs::read(&path) {
        if let Ok(plaintext) = decrypt_at_rest(local_key, &data) {
            if let Ok(secret_bytes) = <[u8; 32]>::try_from(plaintext.as_slice()) {
                return Ok(StaticSecret::from(secret_bytes));
            }
        }
    }
    let secret = StaticSecret::random_from_rng(OsRng);
    std::fs::write(&path, encrypt_at_rest(local_key, &secret.to_bytes())).map_err(|e| e.to_string())?;
    Ok(secret)
}

/// This device's forward-secrecy identity public key (hex), generating one
/// if this device doesn't have one yet — call before [announce_device].
pub fn device_identity_pubkey(storage_dir: String, local_key: String) -> Result<String, String> {
    let local_key = hex32(&local_key)?;
    let secret = load_or_create_identity(&storage_dir, &local_key)?;
    Ok(hex::encode(XPublicKey::from(&secret).to_bytes()))
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

fn save_friend_device(storage_dir: &str, friend_pubkey: &str, device_pubkey_hex: &str) {
    let mut devices = load_friend_devices(storage_dir);
    devices.insert(friend_pubkey.to_string(), device_pubkey_hex.to_string());
    let _ = std::fs::write(
        friend_devices_path(storage_dir),
        serde_json::to_string(&devices).unwrap_or_default(),
    );
}

/// The forward-secrecy device public key `friend_pubkey` last announced to
/// us, if any — the UI uses this to decide whether to offer/attempt a
/// forward-secret send at all.
pub fn friend_device_pubkey(storage_dir: String, friend_pubkey: String) -> Option<String> {
    load_friend_devices(&storage_dir).get(&friend_pubkey).cloned()
}

#[derive(Serialize, Deserialize)]
struct DeviceAnnouncePayload {
    device_pubkey: String,
}

/// Publishes this device's identity public key to `friend_pubkey`, over the
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
    let pubkey_hex = device_identity_pubkey(storage_dir.clone(), local_key)?;
    let content = serde_json::to_string(&DeviceAnnouncePayload { device_pubkey: pubkey_hex })
        .map_err(|e| e.to_string())?;
    chat::send_control_rumor(&mnemonic, &storage_dir, &friend_pubkey, DEVICE_ANNOUNCE_KIND, content, true, None)
}

// ---------------------------------------------------------------------
// Double Ratchet session state, per friend (v1: one active remote device
// per friend — see module doc comment).
// ---------------------------------------------------------------------

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct RatchetSession {
    root_key: String,
    /// This side's current DH keypair (hex secret) — starts as this
    /// device's long-term identity secret and is replaced with a fresh
    /// ephemeral every time the other side ratchets forward.
    dhs_secret: String,
    /// The other side's last-known DH public key.
    dhr_pub: String,
    sending_chain: Option<String>,
    receiving_chain: Option<String>,
    sending_n: u32,
    receiving_n: u32,
    /// Length of the previous sending chain — lets the receiver know how
    /// many trailing keys to skip-cache from it before switching chains.
    prev_sending_n: u32,
    /// `"{dhr_pub_hex}:{n}"` -> message key (hex), for messages that
    /// arrived out of order relative to the sender's counter.
    skipped: HashMap<String, String>,
}

impl RatchetSession {
    pub(crate) fn new(my_identity_secret: [u8; 32], remote_identity_pub: [u8; 32]) -> Self {
        RatchetSession {
            root_key: hex::encode([0u8; 32]),
            dhs_secret: hex::encode(my_identity_secret),
            dhr_pub: hex::encode(remote_identity_pub),
            sending_chain: None,
            receiving_chain: None,
            sending_n: 0,
            receiving_n: 0,
            prev_sending_n: 0,
            skipped: HashMap::new(),
        }
    }
}

fn sessions_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("ratchet_sessions.enc")
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

fn kdf_rk(root_key: &[u8; 32], dh_out: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let hk = Hkdf::<Sha256>::new(Some(root_key), dh_out);
    let mut okm = [0u8; 64];
    hk.expand(b"keychat-ratchet-root", &mut okm).expect("64 bytes is a valid HKDF-SHA256 output length");
    let mut new_root = [0u8; 32];
    let mut chain = [0u8; 32];
    new_root.copy_from_slice(&okm[..32]);
    chain.copy_from_slice(&okm[32..]);
    (new_root, chain)
}

pub(crate) fn kdf_ck(chain_key: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    type HmacSha256 = Hmac<Sha256>;
    let mut mac: HmacSha256 = Mac::new_from_slice(chain_key).expect("HMAC accepts any key length");
    mac.update(&[0x01]);
    let next_chain: [u8; 32] = mac.finalize().into_bytes().into();

    let mut mac: HmacSha256 = Mac::new_from_slice(chain_key).expect("HMAC accepts any key length");
    mac.update(&[0x02]);
    let message_key: [u8; 32] = mac.finalize().into_bytes().into();
    (next_chain, message_key)
}

#[derive(Serialize, Deserialize)]
pub(crate) struct RatchetHeader {
    pub(crate) dh_pub: String,
    pn: u32,
    n: u32,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct RatchetMessagePayload {
    /// Locally-generated id, echoed back by the receiver so both sides
    /// store the decrypted plaintext under the same id — there's no seal
    /// id available yet at encryption time (the seal is only signed
    /// afterwards, by `chat::send_control_rumor`).
    pub(crate) id: String,
    pub(crate) header: RatchetHeader,
    nonce: String,
    ciphertext: String,
    pub(crate) created_at: i64,
}

pub(crate) fn ratchet_encrypt(session: &mut RatchetSession, plaintext: &[u8]) -> Result<RatchetMessagePayload, String> {
    if session.sending_chain.is_none() {
        let dhs = StaticSecret::from(hex32(&session.dhs_secret)?);
        let dhr = XPublicKey::from(hex32(&session.dhr_pub)?);
        let dh_out = dhs.diffie_hellman(&dhr);
        let (root, chain) = kdf_rk(&hex32(&session.root_key)?, dh_out.as_bytes());
        session.root_key = hex::encode(root);
        session.sending_chain = Some(hex::encode(chain));
        session.sending_n = 0;
    }
    let (next_chain, message_key) = kdf_ck(&hex32(session.sending_chain.as_ref().unwrap())?);
    session.sending_chain = Some(hex::encode(next_chain));

    let dh_pub_hex = {
        let dhs = StaticSecret::from(hex32(&session.dhs_secret)?);
        hex::encode(XPublicKey::from(&dhs).to_bytes())
    };
    let header = RatchetHeader { dh_pub: dh_pub_hex, pn: session.prev_sending_n, n: session.sending_n };
    session.sending_n += 1;

    let mut nonce = [0u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new((&message_key).into());
    let ciphertext = cipher.encrypt((&nonce).into(), plaintext).map_err(|e| e.to_string())?;

    Ok(RatchetMessagePayload {
        id: random_hex(16),
        header,
        nonce: hex::encode(nonce),
        ciphertext: base64_encode(&ciphertext),
        created_at: now(),
    })
}

/// Advances `session`'s receiving side to decrypt `payload`, ratcheting
/// forward (and caching any skipped keys) if `payload.header` carries a DH
/// public key we haven't seen before. Returns the plaintext.
pub(crate) fn ratchet_decrypt(session: &mut RatchetSession, payload: &RatchetMessagePayload) -> Result<Vec<u8>, String> {
    let skip_key = format!("{}:{}", payload.header.dh_pub, payload.header.n);
    if let Some(mk_hex) = session.skipped.remove(&skip_key) {
        return decrypt_with_key(&hex32(&mk_hex)?, &payload.nonce, &payload.ciphertext);
    }

    if session.receiving_chain.is_none() || payload.header.dh_pub != session.dhr_pub {
        // Cache any trailing keys from the *old* receiving chain before
        // switching, so messages still in flight on that chain (arriving
        // late) remain decryptable.
        if let Some(chain) = &session.receiving_chain {
            skip_receiving_keys(session, &chain.clone(), &session.dhr_pub.clone(), payload.header.pn)?;
        }
        let dhs = StaticSecret::from(hex32(&session.dhs_secret)?);
        let new_dhr = XPublicKey::from(hex32(&payload.header.dh_pub)?);
        let dh_out = dhs.diffie_hellman(&new_dhr);
        let (root, chain) = kdf_rk(&hex32(&session.root_key)?, dh_out.as_bytes());
        session.root_key = hex::encode(root);
        session.receiving_chain = Some(hex::encode(chain));
        session.receiving_n = 0;
        session.dhr_pub = payload.header.dh_pub.clone();

        // Ratchet our own sending side forward too, so our next message
        // (if any) uses a fresh ephemeral instead of re-using whatever DH
        // keypair was current before — this is what gives the *other*
        // side's future incoming messages forward secrecy on our end.
        session.prev_sending_n = session.sending_n;
        session.sending_n = 0;
        session.sending_chain = None;
        let fresh = StaticSecret::random_from_rng(OsRng);
        session.dhs_secret = hex::encode(fresh.to_bytes());
    }

    // Cache any keys between our current position and this message's `n`,
    // then derive this message's own key.
    skip_receiving_keys(session, session.receiving_chain.as_ref().unwrap().clone().as_str(), &session.dhr_pub.clone(), payload.header.n)?;
    let (next_chain, message_key) = kdf_ck(&hex32(session.receiving_chain.as_ref().unwrap())?);
    session.receiving_chain = Some(hex::encode(next_chain));
    session.receiving_n += 1;
    decrypt_with_key(&message_key, &payload.nonce, &payload.ciphertext)
}

/// Advances the receiving chain up to (but not including) `until_n`,
/// stashing each intermediate message key so a message that arrives late
/// can still be decrypted — bounded by [MAX_SKIPPED_KEYS].
fn skip_receiving_keys(
    session: &mut RatchetSession,
    chain: &str,
    dhr_pub: &str,
    until_n: u32,
) -> Result<(), String> {
    let mut chain_key = hex32(chain)?;
    while session.receiving_n < until_n {
        if session.skipped.len() >= MAX_SKIPPED_KEYS {
            break;
        }
        let (next_chain, message_key) = kdf_ck(&chain_key);
        session.skipped.insert(format!("{}:{}", dhr_pub, session.receiving_n), hex::encode(message_key));
        chain_key = next_chain;
        session.receiving_n += 1;
    }
    session.receiving_chain = Some(hex::encode(chain_key));
    Ok(())
}

fn decrypt_with_key(key: &[u8; 32], nonce_hex: &str, ciphertext_b64: &str) -> Result<Vec<u8>, String> {
    let nonce = hex::decode(nonce_hex).map_err(|e| e.to_string())?;
    let ciphertext = base64_decode(ciphertext_b64)?;
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(nonce.as_slice().into(), ciphertext.as_slice())
        .map_err(|_| "failed to decrypt ratchet message".to_string())
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
        let mut sessions = load_sessions(storage_dir, local_key_bytes);
        let mut session = match sessions.get(friend_pubkey) {
            Some(s) => s.clone(),
            None => {
                let identity = load_or_create_identity(storage_dir, local_key_bytes)?;
                let remote_hex = friend_device_pubkey(storage_dir.to_string(), friend_pubkey.to_string())
                    .ok_or("friend hasn't announced a forward-secrecy device yet")?;
                RatchetSession::new(identity.to_bytes(), hex32(&remote_hex)?)
            }
        };
        let payload = ratchet_encrypt(&mut session, &plaintext)?;
        sessions.insert(friend_pubkey.to_string(), session);
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
    // Same-order eviction as the skipped-key cache — this only needs to be
    // "big enough to outlast realistic relay-replay duplication", not
    // unbounded.
    if ids.len() > MAX_SKIPPED_KEYS * 4 {
        let excess = ids.len() - MAX_SKIPPED_KEYS * 4;
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
        save_friend_device(storage_dir, &expected_sender.to_hex(), &payload.device_pubkey);
        mark_processed(storage_dir, &seal_id);
        return Some(RatchetReceived::DeviceAnnounced);
    }

    let payload: RatchetMessagePayload = serde_json::from_str(&rumor.content).ok()?;
    let local_key_bytes = hex32(local_key).ok()?;
    let friend_pubkey = expected_sender.to_hex();

    let mut sessions = load_sessions(storage_dir, &local_key_bytes);
    let mut session = match sessions.get(&friend_pubkey) {
        Some(s) => s.clone(),
        None => {
            let identity = load_or_create_identity(storage_dir, &local_key_bytes).ok()?;
            RatchetSession::new(identity.to_bytes(), hex32(&payload.header.dh_pub).ok()?)
        }
    };
    let plaintext = ratchet_decrypt(&mut session, &payload).ok()?;
    sessions.insert(friend_pubkey.clone(), session);
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
// contact key, nor its X25519 device identity alone) per (group, member)
// pair, since group members generally aren't 1:1 friends of each other.
// See that module's doc comment for the full design; it reuses this
// module's `RatchetSession`/KDF/DH-step primitives (all `pub(crate)`)
// rather than duplicating them.
