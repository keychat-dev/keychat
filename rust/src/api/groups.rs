//! Group chat: n-way messaging with no shared group key or single event two
//! arbitrary members both see — every message is individually re-encrypted
//! per recipient. Two delivery channels exist, tried in this order for
//! each member:
//!
//! 1. **Direct, via `group_ratchet.rs`** — once a member's dedicated
//!    per-group Nostr identity (`GroupMember::group_pubkey`) is known,
//!    messages/roster-updates go straight there over a per-(group, member)
//!    Double Ratchet session, giving full forward + backward secrecy and
//!    (crucially) working even when `self` has never 1:1-friended that
//!    member — see `group_ratchet.rs`'s module doc for how members learn
//!    each other's routing info transitively through the roster.
//! 2. **Fallback over the member's existing 1:1 relationship** (the
//!    original design) — used only while their `group_pubkey` isn't known
//!    yet (a brief bootstrap window right after they're added) or ever,
//!    for a member reachable only this way. Same per-contact key
//!    (`keys::derive_contact_keys`) an ordinary direct message would use.
//!    Not forward/backward secret. A member reachable by *neither* channel
//!    is silently skipped rather than failing the whole send.
//!
//! Because a member's 1:1 pubkey is different in every one of their
//! relationships (deliberately — see `derive_contact_keys`'s doc), pubkeys
//! can't identify a member consistently across different senders' views of
//! the group. Membership is tracked by stable account UID
//! (`keys::derive_uid`) instead, which every friend already learned when
//! the relationship was formed (see `friends::Friend::uid`).
//!
//! Membership (`groups.json`) is plain JSON, same as `friends.json`/
//! `relays.json` — including each member's routing info, which is public
//! within the group by necessity (everyone needs it to reach everyone).
//! Message *content* gets the same at-rest protection as ratchet messages:
//! NIP-44 self-encrypted (with this account's core identity key) into
//! `group_messages.enc`, since unlike membership lists it's actual
//! conversation content.

use crate::api::attachment::{self, AttachmentUploadEvent};
use crate::api::chat::{GROUP_ATTACHMENT_KIND, GROUP_INVITE_KIND, GROUP_MESSAGE_KIND, MAX_MESSAGE_CHARS};
use crate::api::friends;
use crate::api::group_ratchet::{self, GroupRatchetReceived};
use crate::api::keys::{derive_contact_keys, derive_keys, derive_uid};
use crate::api::ratchet;
use crate::api::sync::{publish_to_relays, runtime};
use crate::frb_generated::StreamSink;
use nostr::event::{Event, EventBuilder, Kind, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{JsonUtil, Keys, PublicKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;

#[derive(Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct GroupMember {
    pub uid: String,
    pub display_name: String,
    /// This member's dedicated per-group Nostr routing identity (hex
    /// pubkey) — see `group_ratchet.rs`'s module doc. `None` until they've
    /// announced it (self-reported the first time their own device
    /// processes this group). Once set, messages/roster-updates to them go
    /// directly here — unlike the original friend-relationship channel,
    /// this doesn't require `self` to actually be their 1:1 friend.
    #[serde(default)]
    pub group_pubkey: Option<String>,
    /// Where to publish to [group_pubkey] — this member's own relay list,
    /// self-reported alongside it.
    #[serde(default)]
    pub relays: Vec<String>,
    /// This member's forward-secrecy device identity (the same X25519 key
    /// `ratchet.rs` uses for 1:1 — see that module's doc comment), needed
    /// to bootstrap this group's pairwise Double Ratchet session with
    /// them (see `group_ratchet.rs`).
    #[serde(default)]
    pub device_pubkey: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    pub name: String,
    pub members: Vec<GroupMember>,
    pub created_at: i64,
}

#[derive(Clone)]
pub struct GroupChatMessage {
    pub id: String,
    pub group_id: String,
    pub sender_uid: String,
    pub sender_name: String,
    pub content: String,
    pub created_at: i64,
    pub is_mine: bool,
    pub attachment: Option<GroupChatAttachment>,
}

#[derive(Serialize, Deserialize)]
struct GroupInvitePayload {
    group_id: String,
    name: String,
    members: Vec<GroupMember>,
}

#[derive(Serialize, Deserialize)]
struct GroupMessagePayload {
    group_id: String,
    text: String,
}

/// Pointer to an encrypted blob on a Blossom-compatible server, delivered
/// to every member the same way a [GroupMessagePayload] is (see module doc
/// / `deliver_to_member`). Unlike `chat.rs`'s `ChatAttachmentPayload`,
/// `enc_key` carries the raw base64-encoded XChaCha20 key+nonce directly —
/// no separate per-recipient NIP-44 wrapping step is needed here, since
/// `deliver_to_member`'s two channels already end-to-end-encrypt the whole
/// `content` string per recipient (see this module's doc comment for the
/// asymmetry vs. 1:1 attachments).
#[derive(Clone, Serialize, Deserialize)]
pub struct GroupAttachmentPayload {
    pub group_id: String,
    pub url: String,
    pub sha256: String,
    pub size: u32,
    pub mime_type: String,
    pub filename: String,
    pub enc_key: String,
    pub caption: Option<String>,
}

/// An image/file attachment resolved from a [GroupAttachmentPayload],
/// exposed on [GroupChatMessage] — mirrors `chat.rs`'s `ChatAttachment`.
#[derive(Clone, Serialize, Deserialize)]
pub struct GroupChatAttachment {
    pub url: String,
    pub sha256: String,
    pub size: u32,
    pub mime_type: String,
    pub filename: String,
    pub enc_key: String,
    pub caption: Option<String>,
}

/// On-disk counterpart of [GroupChatAttachment] — identical shape today,
/// kept as a separate type (mirroring [StoredGroupMessage] vs
/// [GroupChatMessage]) so the wire/storage representation can diverge from
/// the Dart-facing one later without a breaking rename.
#[derive(Serialize, Deserialize)]
pub(crate) struct StoredGroupAttachment {
    url: String,
    sha256: String,
    size: u32,
    mime_type: String,
    filename: String,
    enc_key: String,
    caption: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct StoredGroupMessage {
    id: String,
    group_id: String,
    sender_uid: String,
    sender_name: String,
    content: String,
    created_at: i64,
    #[serde(default)]
    attachment: Option<StoredGroupAttachment>,
}

fn groups_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("groups.json")
}

pub fn load_groups(storage_dir: String) -> Vec<Group> {
    std::fs::read_to_string(groups_path(&storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_groups(storage_dir: &str, groups: &[Group]) -> Result<(), String> {
    let json = serde_json::to_string(groups).map_err(|e| e.to_string())?;
    std::fs::write(groups_path(storage_dir), json).map_err(|e| e.to_string())
}

fn now() -> i64 {
    nostr::Timestamp::now().as_secs() as i64
}

/// Resolves `pubkeys` (as they appear in this device's own `friends.json`)
/// into [GroupMember]s (routing info left unset — a newly-added member's
/// `group_pubkey` etc. are only known once *they* self-announce, see
/// module doc). Silently drops any pubkey that isn't a friend — group
/// members can only be picked from the friend list in the UI, so this
/// should never actually happen in practice.
fn resolve_members(storage_dir: &str, pubkeys: &[String]) -> Vec<GroupMember> {
    let friends = friends::load_friends(storage_dir.to_string());
    pubkeys
        .iter()
        .filter_map(|pk| {
            friends.iter().find(|f| &f.pubkey == pk).map(|f| GroupMember {
                uid: f.uid.clone(),
                display_name: f.display_name.clone(),
                ..Default::default()
            })
        })
        .collect()
}

/// This device's own [GroupMember] entry for `group_id` — mints/derives
/// its per-group Nostr routing identity (`group_ratchet::own_group_keys`)
/// and includes its forward-secrecy device identity when `ratchet_key` is
/// available (`None` on a fresh install before one exists yet, in which
/// case this member stays reachable only over the 1:1 fallback channel
/// until the account has one).
fn own_member_entry(
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: Option<&str>,
    group_id: &str,
) -> Result<GroupMember, String> {
    let uid = derive_uid(mnemonic)?;
    let display_name = self_display_name(storage_dir);
    let group_pubkey =
        group_ratchet::own_group_keys(mnemonic, storage_dir, group_id).ok().map(|k| k.public_key().to_hex());
    let relays = crate::api::relay::load_relay_list(storage_dir.to_string()).urls;
    let device_pubkey = ratchet_key
        .and_then(|k| ratchet::device_identity_pubkey(storage_dir.to_string(), k.to_string()).ok());
    Ok(GroupMember { uid, display_name, group_pubkey, relays, device_pubkey })
}

/// Creates a group named `name` with `member_pubkeys` (each must already be
/// a friend — see [resolve_members]) plus this account itself, persists it
/// locally, and broadcasts a [GROUP_INVITE_KIND] invite to each member (see
/// module doc for the two delivery channels tried). `ratchet_key` is
/// `None` before this account has one yet (see [own_member_entry]).
pub fn create_group(
    mnemonic: String,
    storage_dir: String,
    name: String,
    member_pubkeys: Vec<String>,
    ratchet_key: Option<String>,
) -> Result<Group, String> {
    // A fresh random id — reusing a throwaway keypair's pubkey is a cheap
    // way to get 32 random bytes without adding a `rand` dependency.
    let group_id = Keys::generate().public_key().to_hex();
    let mut members = resolve_members(&storage_dir, &member_pubkeys);
    members.push(own_member_entry(&mnemonic, &storage_dir, ratchet_key.as_deref(), &group_id)?);

    let group = Group { id: group_id, name, members, created_at: now() };

    let mut groups = load_groups(storage_dir.clone());
    groups.push(group.clone());
    save_groups(&storage_dir, &groups)?;

    broadcast_membership(&mnemonic, &storage_dir, ratchet_key.as_deref(), &group)?;
    Ok(group)
}

fn self_display_name(storage_dir: &str) -> String {
    crate::api::account::load_account(storage_dir.to_string())
        .map(|a| a.display_name)
        .unwrap_or_default()
}

/// Adds `member_pubkey` (must already be a friend) to `group_id`'s member
/// list and re-broadcasts the full updated list to every member (the new
/// one included, so they learn the group's name and existing members in
/// the same message).
pub fn add_group_member(
    mnemonic: String,
    storage_dir: String,
    group_id: String,
    member_pubkey: String,
    ratchet_key: Option<String>,
) -> Result<Group, String> {
    let mut groups = load_groups(storage_dir.clone());
    let group = groups.iter_mut().find(|g| g.id == group_id).ok_or("group not found")?;

    let new_member = resolve_members(&storage_dir, &[member_pubkey])
        .into_iter()
        .next()
        .ok_or("not a friend")?;
    if !group.members.iter().any(|m| m.uid == new_member.uid) {
        group.members.push(new_member);
    }
    let updated = group.clone();
    save_groups(&storage_dir, &groups)?;

    broadcast_membership(&mnemonic, &storage_dir, ratchet_key.as_deref(), &updated)?;
    Ok(updated)
}

/// Sends `group`'s current membership list to every member (see module doc
/// for the two delivery channels tried, in order). Only safe to call from
/// a plain (non-async, not-already-on-`runtime()`) context — e.g.
/// `create_group`/`add_group_member`, which Dart calls directly. Async
/// call sites (like [maybe_self_announce_async], reached from `sync.rs`'s
/// live-subscription task) must use [broadcast_membership_async] instead —
/// see `sync.rs`'s `bump_local_watermark`-adjacent comment for why nesting
/// `block_on` inside an already-running async task silently panics that
/// task rather than erroring visibly.
fn broadcast_membership(
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: Option<&str>,
    group: &Group,
) -> Result<(), String> {
    runtime().block_on(broadcast_membership_async(mnemonic, storage_dir, ratchet_key, group))
}

async fn broadcast_membership_async(
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: Option<&str>,
    group: &Group,
) -> Result<(), String> {
    let self_uid = derive_uid(mnemonic)?;
    let friends = friends::load_friends(storage_dir.to_string());
    let payload = GroupInvitePayload {
        group_id: group.id.clone(),
        name: group.name.clone(),
        members: group.members.clone(),
    };
    let payload_json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    for member in &group.members {
        if member.uid == self_uid {
            continue;
        }
        deliver_to_member(
            mnemonic,
            storage_dir,
            ratchet_key,
            &friends,
            &group.id,
            member,
            GROUP_INVITE_KIND,
            &payload_json,
        )
        .await;
    }
    Ok(())
}

/// Delivers `kind`+`content` (already-serialized JSON) to `member`,
/// preferring the direct forward/backward-secret per-group channel (see
/// module doc) whenever their routing info is known, falling back to their
/// 1:1 friend relationship otherwise. Silently does nothing if `member` is
/// reachable by neither — best-effort, a single unreachable member never
/// fails the whole group send/broadcast.
async fn deliver_to_member(
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: Option<&str>,
    friends: &[friends::Friend],
    group_id: &str,
    member: &GroupMember,
    kind: Kind,
    content: &str,
) {
    if let (Some(local_key), Some(group_pubkey), Some(device_pubkey)) =
        (ratchet_key, member.group_pubkey.as_deref(), member.device_pubkey.as_deref())
    {
        let sent = group_ratchet::send_to_member(
            mnemonic,
            storage_dir,
            local_key,
            group_id,
            group_pubkey,
            device_pubkey,
            &member.relays,
            kind,
            content,
        )
        .await;
        if sent.is_ok() {
            return;
        }
    }
    if let Some(friend) = friends.iter().find(|f| f.uid == member.uid) {
        send_sealed(mnemonic, friend, kind, content.to_string()).await;
    }
}

/// Builds and publishes a Seal+Gift-Wrap of `content` (already-serialized
/// JSON) to `friend`, using the same per-contact key their ordinary 1:1
/// messages use. Not forward/backward secret — see module doc; only used
/// as [deliver_to_member]'s fallback.
async fn send_sealed(mnemonic: &str, friend: &friends::Friend, kind: Kind, content: String) {
    let Ok(keys) = derive_contact_keys(mnemonic, friend.my_account_index) else { return };
    let Ok(friend_pk) = PublicKey::from_hex(&friend.pubkey) else { return };
    let rumor: UnsignedEvent = EventBuilder::new(kind, content).build(keys.public_key());
    let Ok(seal_builder) = EventBuilder::seal(&keys, &friend_pk, rumor).await else { return };
    let Ok(seal) = seal_builder.sign(&keys).await else { return };
    let Ok(wrap) = EventBuilder::gift_wrap_from_seal(&friend_pk, &seal, []) else { return };
    let _ = publish_to_relays(&friend.relays, &wrap).await;
}

fn messages_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("group_messages.enc")
}

fn load_all_messages(mnemonic: &str, storage_dir: &str) -> Vec<StoredGroupMessage> {
    let Ok(keys) = derive_keys(mnemonic) else { return Vec::new() };
    let Ok(raw) = std::fs::read_to_string(messages_path(storage_dir)) else { return Vec::new() };
    let Ok(decrypted) = nip44::decrypt(keys.secret_key(), &keys.public_key(), &raw) else {
        return Vec::new();
    };
    serde_json::from_str(&decrypted).unwrap_or_default()
}

fn append_message(mnemonic: &str, storage_dir: &str, message: StoredGroupMessage) -> Result<(), String> {
    let keys = derive_keys(mnemonic)?;
    let mut all = load_all_messages(mnemonic, storage_dir);
    if !all.iter().any(|m| m.id == message.id) {
        all.push(message);
    }
    let plaintext = serde_json::to_string(&all).map_err(|e| e.to_string())?;
    let encrypted = nip44::encrypt(keys.secret_key(), &keys.public_key(), plaintext, nip44::Version::V2)
        .map_err(|e| e.to_string())?;
    std::fs::write(messages_path(storage_dir), encrypted).map_err(|e| e.to_string())
}

/// This device's message history for `group_id`, oldest first. Like
/// `ratchet.rs`'s history, only ever grows via messages sent/received *by
/// this specific device* — there's no group-wide event log to backfill
/// from, since every member sees a different set of Gift Wraps.
pub fn load_group_messages(
    mnemonic: String,
    storage_dir: String,
    group_id: String,
) -> Result<Vec<GroupChatMessage>, String> {
    let self_uid = derive_uid(&mnemonic)?;
    // Resolved from the *current* member list rather than trusted from
    // whatever was stored at receive time — a message can be processed
    // before its sender's invite (e.g. relay backlog replayed out of
    // order after a fresh install), which would otherwise freeze in a
    // blank sender name forever. Falls back to the stored name (if any)
    // for a sender no longer in the group.
    let member_names: std::collections::HashMap<String, String> = load_groups(storage_dir.clone())
        .into_iter()
        .find(|g| g.id == group_id)
        .map(|g| g.members.into_iter().map(|m| (m.uid, m.display_name)).collect())
        .unwrap_or_default();
    let mut messages: Vec<GroupChatMessage> = load_all_messages(&mnemonic, &storage_dir)
        .into_iter()
        .filter(|m| m.group_id == group_id)
        .map(|m| GroupChatMessage {
            id: m.id,
            group_id: m.group_id,
            is_mine: m.sender_uid == self_uid,
            sender_name: member_names.get(&m.sender_uid).cloned().unwrap_or(m.sender_name),
            sender_uid: m.sender_uid,
            content: m.content,
            created_at: m.created_at,
            attachment: m.attachment.map(|a| GroupChatAttachment {
                url: a.url,
                sha256: a.sha256,
                size: a.size,
                mime_type: a.mime_type,
                filename: a.filename,
                enc_key: a.enc_key,
                caption: a.caption,
            }),
        })
        .collect();
    messages.sort_by_key(|m| m.created_at);
    Ok(messages)
}

/// Sends `content` to every member of `group_id` (see module doc for the
/// two delivery channels tried, in order) and appends it to this device's
/// own local history. `ratchet_key` is `None` on a fresh install before
/// this device's own local storage key exists yet, in which case every
/// member gets the (non-forward-secret) 1:1-fallback copy, same as before
/// forward secrecy existed.
pub fn send_group_message(
    mnemonic: String,
    storage_dir: String,
    group_id: String,
    content: String,
    ratchet_key: Option<String>,
) -> Result<(), String> {
    if content.chars().count() > MAX_MESSAGE_CHARS {
        return Err("message too long".to_string());
    }
    let groups = load_groups(storage_dir.clone());
    let group = groups.into_iter().find(|g| g.id == group_id).ok_or("group not found")?;
    let self_uid = derive_uid(&mnemonic)?;
    let friends = friends::load_friends(storage_dir.clone());
    let payload = GroupMessagePayload { group_id: group_id.clone(), text: content.clone() };
    let payload_json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    runtime().block_on(async {
        for member in &group.members {
            if member.uid == self_uid {
                continue;
            }
            deliver_to_member(
                &mnemonic,
                &storage_dir,
                ratchet_key.as_deref(),
                &friends,
                &group_id,
                member,
                GROUP_MESSAGE_KIND,
                &payload_json,
            )
            .await;
        }
    });

    let id = Keys::generate().public_key().to_hex();
    let created_at = now();
    append_message(
        &mnemonic,
        &storage_dir,
        StoredGroupMessage {
            id,
            group_id,
            sender_uid: self_uid,
            sender_name: self_display_name(&storage_dir),
            content,
            created_at,
            attachment: None,
        },
    )
}

/// Removes the member with `uid` from `group_id`'s roster, saves, and
/// re-broadcasts the updated roster to the remaining members — the removed
/// member naturally stops receiving anything since they're no longer in
/// `group.members`. No key-rotation/PCS-on-removal — out of scope, same
/// best-effort simplicity as the rest of this module. Any existing member
/// can call this (same trust model as [add_group_member]).
pub fn remove_group_member(
    mnemonic: String,
    storage_dir: String,
    group_id: String,
    member_uid: String,
    ratchet_key: Option<String>,
) -> Result<Group, String> {
    let mut groups = load_groups(storage_dir.clone());
    let group = groups.iter_mut().find(|g| g.id == group_id).ok_or("group not found")?;
    group.members.retain(|m| m.uid != member_uid);
    let updated = group.clone();
    save_groups(&storage_dir, &groups)?;

    broadcast_membership(&mnemonic, &storage_dir, ratchet_key.as_deref(), &updated)?;
    Ok(updated)
}

/// Removes this account's own entry from `group_id`'s roster, broadcasts
/// the updated (self-excluded) roster to the remaining members so they see
/// the departure, then deletes the group and its local message history
/// from this device.
pub fn leave_group(
    mnemonic: String,
    storage_dir: String,
    group_id: String,
    ratchet_key: Option<String>,
) -> Result<(), String> {
    let self_uid = derive_uid(&mnemonic)?;
    let mut groups = load_groups(storage_dir.clone());
    let group = groups.iter_mut().find(|g| g.id == group_id).ok_or("group not found")?;

    // Compute the broadcast target (remaining members, self excluded from
    // both the roster *and* the recipient loop — the latter already happens
    // naturally inside `broadcast_membership_async`) before mutating.
    let mut announced = group.clone();
    announced.members.retain(|m| m.uid != self_uid);

    group.members.retain(|m| m.uid != self_uid);
    save_groups(&storage_dir, &groups)?;

    broadcast_membership(&mnemonic, &storage_dir, ratchet_key.as_deref(), &announced)?;

    // Delete the group itself and its local message history from this
    // device.
    let mut groups = load_groups(storage_dir.clone());
    groups.retain(|g| g.id != group_id);
    save_groups(&storage_dir, &groups)?;
    delete_group_messages(&mnemonic, &storage_dir, &group_id);
    Ok(())
}

/// Rewrites `group_messages.enc` with every message for `group_id` removed
/// — follows [append_message]'s encrypt/decrypt pattern. Best-effort: a
/// failure to re-encrypt/write is swallowed, same as the rest of this
/// module's local-storage helpers, since [leave_group]'s roster removal
/// (the important, network-visible part) has already succeeded by the time
/// this runs.
fn delete_group_messages(mnemonic: &str, storage_dir: &str, group_id: &str) {
    let Ok(keys) = derive_keys(mnemonic) else { return };
    let mut all = load_all_messages(mnemonic, storage_dir);
    all.retain(|m| m.group_id != group_id);
    let Ok(plaintext) = serde_json::to_string(&all) else { return };
    let Ok(encrypted) = nip44::encrypt(keys.secret_key(), &keys.public_key(), plaintext, nip44::Version::V2) else {
        return;
    };
    let _ = std::fs::write(messages_path(storage_dir), encrypted);
}

/// Encrypts and uploads `file_path` once (via `attachment.rs`'s shared
/// primitives — see that module's doc comment for the encryption scheme),
/// then delivers a [GroupAttachmentPayload] pointer to every member of
/// `group_id` (see module doc for the two delivery channels tried) and
/// appends the message to this device's own local history. Streams
/// progress/terminal events on `sink`, mirroring
/// `attachment::send_chat_attachment`.
pub fn send_group_attachment(
    mnemonic: String,
    storage_dir: String,
    group_id: String,
    file_path: String,
    mime_type: String,
    caption: Option<String>,
    ratchet_key: Option<String>,
    server_override: Option<String>,
    sink: StreamSink<AttachmentUploadEvent>,
) {
    runtime().spawn(async move {
        let result = upload_and_send_group_attachment(
            &mnemonic,
            &storage_dir,
            &group_id,
            &file_path,
            &mime_type,
            caption,
            ratchet_key,
            server_override,
            &sink,
        )
        .await;
        let _ = sink.add(AttachmentUploadEvent {
            fraction: 1.0,
            done: true,
            error: result.err(),
        });
    });
}

async fn upload_and_send_group_attachment(
    mnemonic: &str,
    storage_dir: &str,
    group_id: &str,
    file_path: &str,
    mime_type: &str,
    caption: Option<String>,
    ratchet_key: Option<String>,
    server_override: Option<String>,
    sink: &StreamSink<AttachmentUploadEvent>,
) -> Result<(), String> {
    let groups = load_groups(storage_dir.to_string());
    let group = groups.into_iter().find(|g| g.id == group_id).ok_or("group not found")?;
    let self_uid = derive_uid(mnemonic)?;
    let self_keys = derive_keys(mnemonic)?;
    let friends = friends::load_friends(storage_dir.to_string());

    let server = server_override.unwrap_or_else(|| attachment::load_upload_servers(storage_dir.to_string()).default_url);
    let plaintext = std::fs::read(file_path).map_err(|e| e.to_string())?;
    let filename = Path::new(file_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());

    let (key_and_nonce, ciphertext_bytes) = attachment::encrypt_attachment_bytes(&plaintext);
    let size = ciphertext_bytes.len() as u32;
    use base64::Engine as _;
    let enc_key = base64::engine::general_purpose::STANDARD.encode(key_and_nonce);

    let mut hasher = Sha256::new();
    hasher.update(&ciphertext_bytes);
    let sha256_hex = hex::encode(hasher.finalize());

    let url = attachment::upload_ciphertext(&server, mime_type, ciphertext_bytes, &sha256_hex, &self_keys, sink).await?;

    let payload = GroupAttachmentPayload {
        group_id: group_id.to_string(),
        url,
        sha256: sha256_hex,
        size,
        mime_type: mime_type.to_string(),
        filename: filename.clone(),
        enc_key,
        caption: caption.clone(),
    };
    let payload_json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    for member in &group.members {
        if member.uid == self_uid {
            continue;
        }
        deliver_to_member(
            mnemonic,
            storage_dir,
            ratchet_key.as_deref(),
            &friends,
            group_id,
            member,
            GROUP_ATTACHMENT_KIND,
            &payload_json,
        )
        .await;
    }

    let id = Keys::generate().public_key().to_hex();
    let created_at = now();
    append_message(
        mnemonic,
        storage_dir,
        StoredGroupMessage {
            id,
            group_id: group_id.to_string(),
            sender_uid: self_uid,
            sender_name: self_display_name(storage_dir),
            content: filename,
            created_at,
            attachment: Some(StoredGroupAttachment {
                url: payload.url,
                sha256: payload.sha256,
                size: payload.size,
                mime_type: payload.mime_type,
                filename: payload.filename,
                enc_key: payload.enc_key,
                caption,
            }),
        },
    )
}

/// Downloads and decrypts a group attachment — mirrors
/// `attachment::download_chat_attachment`, but caches under a
/// group-scoped path (collision-free against the 1:1 cache) and skips the
/// NIP-44 unwrap of `enc_key` (base64-decoded directly instead — see
/// [GroupAttachmentPayload]'s doc comment on the asymmetry).
pub fn download_group_attachment(
    storage_dir: String,
    group_id: String,
    message_id: String,
    url: String,
    enc_key: String,
) -> Result<String, String> {
    let cache_dir = Path::new(&storage_dir).join("group_attachments");
    std::fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;
    let cache_path = cache_dir.join(format!("{group_id}_{message_id}"));
    if cache_path.exists() {
        return Ok(cache_path.to_string_lossy().to_string());
    }

    use base64::Engine as _;
    let key_and_nonce = base64::engine::general_purpose::STANDARD
        .decode(&enc_key)
        .map_err(|e| e.to_string())?;

    let ciphertext_bytes = runtime().block_on(attachment::download_ciphertext(&url))?;
    let plaintext = attachment::decrypt_attachment_bytes(&key_and_nonce, &ciphertext_bytes)?;

    std::fs::write(&cache_path, &plaintext).map_err(|e| e.to_string())?;
    Ok(cache_path.to_string_lossy().to_string())
}

/// What [receive_group_gift_wrap] found, for `sync.rs`'s live subscription
/// to surface as a lighter-weight signal (mirrors `ratchet::RatchetReceived`).
pub(crate) enum GroupReceived {
    /// A new/updated membership list was merged in — carries the group id.
    Invite(String),
    /// A new message was decrypted and saved — carries the group id.
    Message(String),
}

/// Unwraps an incoming Gift Wrap addressed to `my_keys` (one of this
/// account's per-contact keys) from `sender_pk`, and — if it's a
/// [GROUP_INVITE_KIND] or [GROUP_MESSAGE_KIND] rumor — applies it. Returns
/// `None` for any other kind, so `sync.rs` can fall through to its other
/// decoders the same way it already does for `chat.rs`/`ratchet.rs`. This
/// is the 1:1-fallback channel (see module doc) — `sync.rs` also tries
/// [apply_group_ratchet_received] for the direct per-group channel.
pub(crate) async fn receive_group_gift_wrap(
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: Option<&str>,
    my_keys: &Keys,
    sender_pk: &PublicKey,
    gift_wrap: &Event,
) -> Option<GroupReceived> {
    let seal_json = nip44::decrypt(my_keys.secret_key(), &gift_wrap.pubkey, &gift_wrap.content).ok()?;
    let seal = Event::from_json(seal_json).ok()?;
    if seal.kind != Kind::Seal || seal.pubkey != *sender_pk {
        return None;
    }
    seal.verify().ok()?;

    let rumor_json = nip44::decrypt(my_keys.secret_key(), sender_pk, &seal.content).ok()?;
    let rumor = UnsignedEvent::from_json(rumor_json).ok()?;
    if rumor.pubkey != seal.pubkey {
        return None;
    }

    if rumor.kind == GROUP_INVITE_KIND {
        let payload: GroupInvitePayload = serde_json::from_str(&rumor.content).ok()?;
        let group_id = payload.group_id.clone();
        let (merged, _changed) = merge_roster(storage_dir, payload);
        maybe_self_announce_async(mnemonic, storage_dir, ratchet_key, &merged).await;
        Some(GroupReceived::Invite(group_id))
    } else if rumor.kind == GROUP_MESSAGE_KIND {
        let payload: GroupMessagePayload = serde_json::from_str(&rumor.content).ok()?;
        let sender_uid = friends::load_friends(storage_dir.to_string())
            .into_iter()
            .find(|f| f.pubkey == sender_pk.to_hex())
            .map(|f| f.uid)?;
        store_received_group_message(
            mnemonic,
            storage_dir,
            &sender_uid,
            &payload.group_id,
            &payload.text,
            rumor.created_at.as_secs() as i64,
            &seal.id.to_hex(),
            None,
        )?;
        Some(GroupReceived::Message(payload.group_id))
    } else if rumor.kind == GROUP_ATTACHMENT_KIND {
        let payload: GroupAttachmentPayload = serde_json::from_str(&rumor.content).ok()?;
        let sender_uid = friends::load_friends(storage_dir.to_string())
            .into_iter()
            .find(|f| f.pubkey == sender_pk.to_hex())
            .map(|f| f.uid)?;
        let group_id = payload.group_id.clone();
        store_received_group_message(
            mnemonic,
            storage_dir,
            &sender_uid,
            &payload.group_id,
            &payload.filename.clone(),
            rumor.created_at.as_secs() as i64,
            &seal.id.to_hex(),
            Some(StoredGroupAttachment {
                url: payload.url,
                sha256: payload.sha256,
                size: payload.size,
                mime_type: payload.mime_type,
                filename: payload.filename,
                enc_key: payload.enc_key,
                caption: payload.caption,
            }),
        )?;
        Some(GroupReceived::Message(group_id))
    } else {
        None
    }
}

/// Merges `payload` (a just-received/updated roster) into local storage,
/// creating the group if this is the first time hearing about it. Returns
/// the merged [Group] plus whether anything actually changed — used by
/// [maybe_self_announce] to decide whether re-broadcasting is worth doing,
/// so a converged roster doesn't loop forever re-announcing itself.
///
/// `payload.members` is always the *complete* roster as the broadcaster
/// currently knows it (see [broadcast_membership_async] — every call site
/// sends `group.members` in full, never a partial diff), so this replaces
/// `existing.members` wholesale rather than only adding/updating entries.
/// An additive-only merge (the original approach) could never represent a
/// member being removed — [remove_group_member]/[leave_group]'s roster
/// update would arrive here and simply leave the departed member in place
/// forever, since nothing in an add-only merge can delete. Guarded against
/// an empty payload (shouldn't happen — every broadcaster's own roster
/// always includes at least themselves) so a malformed message can't wipe
/// a group's membership locally.
fn merge_roster(storage_dir: &str, payload: GroupInvitePayload) -> (Group, bool) {
    let mut groups = load_groups(storage_dir.to_string());
    let mut changed = false;
    let merged = match groups.iter_mut().find(|g| g.id == payload.group_id) {
        Some(existing) => {
            if existing.name != payload.name {
                existing.name = payload.name;
                changed = true;
            }
            if !payload.members.is_empty() && existing.members != payload.members {
                existing.members = payload.members;
                changed = true;
            }
            existing.clone()
        }
        None => {
            changed = true;
            let group =
                Group { id: payload.group_id.clone(), name: payload.name, members: payload.members, created_at: now() };
            groups.push(group.clone());
            group
        }
    };
    let _ = save_groups(storage_dir, &groups);
    (merged, changed)
}

/// If this device's own entry in `group` is missing or stale (or the
/// roster merge that produced `group` just changed something), ensures its
/// own entry is current and re-broadcasts — the mechanism by which routing
/// info propagates transitively to members `self` isn't directly a 1:1
/// friend of (see module doc). Best-effort; failures are swallowed since
/// this is opportunistic upkeep on top of the primary receive path, not
/// itself required for that receive to succeed. Async, and must stay that
/// way — see [broadcast_membership]'s doc comment for why; this is always
/// reached from `sync.rs`'s already-async live-subscription task.
async fn maybe_self_announce_async(mnemonic: &str, storage_dir: &str, ratchet_key: Option<&str>, group: &Group) {
    let Ok(self_uid) = derive_uid(mnemonic) else { return };
    let Ok(fresh) = own_member_entry(mnemonic, storage_dir, ratchet_key, &group.id) else { return };
    if group.members.iter().find(|m| m.uid == self_uid) == Some(&fresh) {
        return;
    }
    let mut groups = load_groups(storage_dir.to_string());
    let Some(g) = groups.iter_mut().find(|g| g.id == group.id) else { return };
    match g.members.iter_mut().find(|m| m.uid == self_uid) {
        Some(m) => *m = fresh,
        None => g.members.push(fresh),
    }
    let updated = g.clone();
    let _ = save_groups(storage_dir, &groups);
    let _ = broadcast_membership_async(mnemonic, storage_dir, ratchet_key, &updated).await;
}

/// Resolves `group_pubkey` (a sender's per-group routing identity, as seen
/// on an incoming [group_ratchet]-decrypted event) to that member's stable
/// UID, by looking it up in `group_id`'s roster — the direct-channel
/// counterpart of [receive_group_gift_wrap]'s friends.json lookup, since a
/// direct-channel sender isn't necessarily `self`'s 1:1 friend.
fn resolve_member_uid_by_group_pubkey(storage_dir: &str, group_id: &str, group_pubkey: &str) -> Option<String> {
    load_groups(storage_dir.to_string())
        .into_iter()
        .find(|g| g.id == group_id)?
        .members
        .into_iter()
        .find(|m| m.group_pubkey.as_deref() == Some(group_pubkey))
        .map(|m| m.uid)
}

/// Applies whatever [group_ratchet::receive_gift_wrap] decrypted — the
/// direct, forward/backward-secret channel's counterpart of
/// [receive_group_gift_wrap] (see module doc for the two channels).
/// Returns the `FriendEvent` kind string `sync.rs` should surface, if any.
pub(crate) async fn apply_group_ratchet_received(
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: Option<&str>,
    group_id: &str,
    received: &GroupRatchetReceived,
) -> Option<String> {
    if received.kind == GROUP_INVITE_KIND {
        let payload: GroupInvitePayload = serde_json::from_str(&received.plaintext).ok()?;
        let (merged, _changed) = merge_roster(storage_dir, payload);
        maybe_self_announce_async(mnemonic, storage_dir, ratchet_key, &merged).await;
        Some("group_invite".to_string())
    } else if received.kind == GROUP_MESSAGE_KIND {
        let payload: GroupMessagePayload = serde_json::from_str(&received.plaintext).ok()?;
        let sender_uid =
            resolve_member_uid_by_group_pubkey(storage_dir, group_id, &received.sender_group_pubkey)?;
        store_received_group_message(
            mnemonic,
            storage_dir,
            &sender_uid,
            &payload.group_id,
            &payload.text,
            received.created_at,
            &received.id,
            None,
        )?;
        Some("group_message".to_string())
    } else if received.kind == GROUP_ATTACHMENT_KIND {
        let payload: GroupAttachmentPayload = serde_json::from_str(&received.plaintext).ok()?;
        let sender_uid =
            resolve_member_uid_by_group_pubkey(storage_dir, group_id, &received.sender_group_pubkey)?;
        store_received_group_message(
            mnemonic,
            storage_dir,
            &sender_uid,
            &payload.group_id,
            &payload.filename.clone(),
            received.created_at,
            &received.id,
            Some(StoredGroupAttachment {
                url: payload.url,
                sha256: payload.sha256,
                size: payload.size,
                mime_type: payload.mime_type,
                filename: payload.filename,
                enc_key: payload.enc_key,
                caption: payload.caption,
            }),
        )?;
        Some("group_message".to_string())
    } else {
        None
    }
}

/// Applies a group message to this device's local history — shared by
/// both delivery channels (see module doc), since both end up needing the
/// same sender-name resolution and storage call, just arriving via
/// different decrypt paths with `sender_uid` already resolved upstream.
pub(crate) fn store_received_group_message(
    mnemonic: &str,
    storage_dir: &str,
    sender_uid: &str,
    group_id: &str,
    text: &str,
    created_at: i64,
    id: &str,
    attachment: Option<StoredGroupAttachment>,
) -> Option<()> {
    let sender_uid = sender_uid.to_string();
    let sender_name = load_groups(storage_dir.to_string())
        .into_iter()
        .find(|g| g.id == group_id)
        .and_then(|g| g.members.into_iter().find(|m| m.uid == sender_uid))
        .map(|m| m.display_name)
        .unwrap_or_default();
    append_message(
        mnemonic,
        storage_dir,
        StoredGroupMessage {
            id: id.to_string(),
            group_id: group_id.to_string(),
            sender_uid,
            sender_name,
            content: text.to_string(),
            created_at,
            attachment,
        },
    )
    .ok()
}
