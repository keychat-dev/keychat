use crate::api::account;
use crate::api::friends;
use crate::api::invites;
use crate::api::keys::{derive_contact_keys, derive_keys};
use crate::api::relay;
use crate::api::requests;
use crate::frb_generated::StreamSink;
use crate::relay_pool;
use base64::Engine;
use futures_util::future::join_all;
use nostr::event::{Event, EventBuilder, Kind, Tag};
use nostr::nips::nip09::EventDeletionRequest;
use nostr::nips::nip44;
use nostr::nips::nip65;
use nostr::types::Timestamp;
use nostr::{Filter, Keys, PublicKey, RelayUrl};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

/// Identifier tag for the account backup's parameterized-replaceable event
/// (NIP-33 / kind 30078), so each account has exactly one such event per
/// relay and newer publishes replace older ones automatically.
const ACCOUNT_BACKUP_D_TAG: &str = "keychat-account";
const ACCOUNT_BACKUP_KIND: Kind = Kind::Custom(30078);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Serialize, Deserialize)]
struct BackupPayload {
    display_name: String,
    status_message: String,
    updated_at: i64,
}

/// Account info decrypted from a relay-hosted backup.
pub struct RemoteAccount {
    pub display_name: String,
    pub status_message: String,
    pub updated_at: i64,
}

/// Encrypts the given account info (NIP-44, to self) and publishes it to
/// `relay_urls` as a kind-30078 parameterized-replaceable event, signed with
/// the Nostr keys derived from `mnemonic` (NIP-06). The seed phrase itself
/// is never transmitted — only the deterministically-derived public
/// identity and the encrypted payload.
pub fn publish_account_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
    display_name: String,
    status_message: String,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let payload = BackupPayload {
        display_name,
        status_message,
        updated_at,
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let encrypted = nip44::encrypt(
        keys.secret_key(),
        &keys.public_key(),
        plaintext,
        nip44::Version::V2,
    )
    .map_err(|e| e.to_string())?;
    let event = EventBuilder::new(ACCOUNT_BACKUP_KIND, encrypted)
        .tag(Tag::identifier(ACCOUNT_BACKUP_D_TAG))
        .custom_created_at(Timestamp::from(updated_at.max(0) as u64))
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    runtime().block_on(publish_to_relays(&relay_urls, &event))
}

/// Fetches and decrypts the newest account backup for `mnemonic`'s derived
/// identity across `relay_urls`. Returns `None` if no relay has one yet.
pub fn fetch_account_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
) -> Result<Option<RemoteAccount>, String> {
    let keys = derive_keys(&mnemonic)?;
    let event = runtime().block_on(fetch_latest_backup_event(&relay_urls, &keys.public_key()))?;
    let Some(event) = event else {
        return Ok(None);
    };
    let decrypted = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content)
        .map_err(|e| e.to_string())?;
    let payload: BackupPayload = serde_json::from_str(&decrypted).map_err(|e| e.to_string())?;
    Ok(Some(RemoteAccount {
        display_name: payload.display_name,
        status_message: payload.status_message,
        updated_at: payload.updated_at,
    }))
}

/// Requests relays to erase this account's backup event (NIP-09 deletion
/// request). A no-op if no backup exists yet.
pub fn delete_account_backup(mnemonic: String, relay_urls: Vec<String>) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    runtime().block_on(async {
        let Some(event) = fetch_latest_backup_event(&relay_urls, &keys.public_key()).await? else {
            return Ok(());
        };
        let deletion = EventBuilder::delete(EventDeletionRequest::new().id(event.id))
            .sign_with_keys(&keys)
            .map_err(|e| e.to_string())?;
        publish_to_relays(&relay_urls, &deletion).await
    })
}

const FRIEND_REQUEST_KIND: Kind = Kind::Custom(30110);
const FRIEND_ACCEPT_KIND: Kind = Kind::Custom(30111);
const FRIEND_PROFILE_UPDATE_KIND: Kind = Kind::Custom(30112);
const FRIEND_D_TAG: &str = "keychat-friend";

#[derive(Serialize, Deserialize)]
struct FriendPayload {
    display_name: String,
    status_message: String,
    relays: Vec<String>,
    /// The sender's avatar image, base64-encoded, if they have one set.
    /// Sent as raw bytes (not a URL) since there's no shared hosting —
    /// each side caches its own local copy on receipt.
    #[serde(default)]
    avatar_base64: Option<String>,
}

/// Reads `avatar_path` (if set) and base64-encodes its bytes for inclusion
/// in a [FriendPayload]. Silently omitted if the file can't be read.
fn read_avatar_base64(avatar_path: &Option<String>) -> Option<String> {
    let path = avatar_path.as_ref()?;
    let bytes = std::fs::read(path).ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// Decodes a base64 avatar payload and caches it to disk under
/// `storage_dir/friend_avatars/<pubkey>`, returning the local path.
/// Silently returns `None` on any failure — avatar sync is best-effort.
fn save_friend_avatar(storage_dir: &str, pubkey: &str, avatar_base64: &Option<String>) -> Option<String> {
    let encoded = avatar_base64.as_ref()?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).ok()?;
    let dir = Path::new(storage_dir).join("friend_avatars");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(pubkey);
    std::fs::write(&path, bytes).ok()?;
    Some(path.to_string_lossy().to_string())
}

/// Publishes a NIP-65 relay-list-metadata event under `keys` — typically
/// one of our per-contact keys — to a fixed, always-known bootstrap relay
/// set (the same 3 defaults every install starts with). This gives anyone
/// who already knows that pubkey a way to resolve our *current* relays
/// even if a direct profile-update notice never reached them — e.g. they
/// moved relays themselves before we could tell them where we are now.
async fn publish_relay_list_nip65(keys: &Keys, relays: &[String]) {
    let entries: Vec<(RelayUrl, Option<nip65::RelayMetadata>)> = relays
        .iter()
        .filter_map(|url| RelayUrl::parse(url).ok())
        .map(|url| (url, None))
        .collect();
    if entries.is_empty() {
        return;
    }
    let Ok(event) = EventBuilder::relay_list(entries).sign_with_keys(keys) else {
        return;
    };
    let _ = publish_to_relays(&relay::default_relays(), &event).await;
}

/// Looks up `pubkey`'s most recent NIP-65 relay list from the bootstrap
/// relay set. Returns an empty list if none is found or reachable.
async fn fetch_relay_list_nip65(pubkey: &PublicKey) -> Vec<String> {
    let filter = Filter::new().author(*pubkey).kind(Kind::RelayList).limit(1);
    let events = fetch_events(&relay::default_relays(), &filter)
        .await
        .unwrap_or_default();
    let Some(event) = events.into_iter().max_by_key(|e| e.created_at) else {
        return Vec::new();
    };
    nip65::extract_relay_list(&event)
        .map(|(url, _)| url.to_string())
        .collect()
}

/// A pending incoming friend request, decrypted and ready to show the user.
pub struct PendingFriendRequest {
    /// Which of our invites this request was sent to.
    pub invite_account_index: u32,
    /// The requester's contact pubkey (hex) — distinct per relationship.
    pub pubkey: String,
    pub display_name: String,
    pub status_message: String,
    pub relays: Vec<String>,
    /// Base64-encoded avatar image, if the requester has one — passed
    /// through unchanged so `accept_friend_request` can cache it.
    pub avatar_base64: Option<String>,
}

/// A friend request we sent that the other side has accepted.
pub struct AcceptedFriend {
    pub pubkey: String,
    pub display_name: String,
    pub status_message: String,
}

/// The data a "my QR" screen encodes: enough for a scanner to send a
/// friend request without any prior relay round-trip. Shown in person, so
/// including the display name/status here isn't a public disclosure the
/// way publishing them to a relay would be.
#[derive(Serialize, Deserialize)]
pub struct InviteQrPayload {
    pub pubkey: String,
    pub relays: Vec<String>,
    pub display_name: String,
    pub status_message: String,
}

/// Builds the QR payload (as JSON) for the given invite's account index.
pub fn build_invite_qr_payload(
    mnemonic: String,
    storage_dir: String,
    account_index: u32,
) -> Result<String, String> {
    let keys = derive_contact_keys(&mnemonic, account_index)?;
    let my_account = account::load_account(storage_dir.clone()).ok_or("no local account")?;
    let relays = relay::load_relay_list(storage_dir).urls;
    let payload = InviteQrPayload {
        pubkey: keys.public_key().to_hex(),
        relays,
        display_name: my_account.display_name,
        status_message: my_account.status_message,
    };
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

/// Parses a scanned QR's JSON payload back into its fields.
pub fn parse_invite_qr_payload(data: String) -> Result<InviteQrPayload, String> {
    serde_json::from_str(&data).map_err(|e| e.to_string())
}

/// Sends a friend request to whichever invite `invite_pubkey`/`invite_relays`
/// (scanned from someone's QR code) describe. Mints a fresh per-relationship
/// key for this contact — distinct from our account identity and every
/// other friend's key — and remembers where to look for their acceptance.
pub fn send_friend_request(
    mnemonic: String,
    storage_dir: String,
    invite_pubkey: String,
    invite_relays: Vec<String>,
) -> Result<(), String> {
    let my_account = account::load_account(storage_dir.clone()).ok_or("no local account")?;
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;

    let index = invites::allocate_account_index(&storage_dir)?;
    let keys = derive_contact_keys(&mnemonic, index)?;
    let target_pubkey = PublicKey::from_hex(&invite_pubkey).map_err(|e| e.to_string())?;

    let payload = FriendPayload {
        display_name: my_account.display_name,
        status_message: my_account.status_message,
        relays: my_relays.clone(),
        avatar_base64: read_avatar_base64(&my_account.avatar_path),
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let encrypted = nip44::encrypt(keys.secret_key(), &target_pubkey, plaintext, nip44::Version::V2)
        .map_err(|e| e.to_string())?;

    let event = EventBuilder::new(FRIEND_REQUEST_KIND, encrypted)
        .tag(Tag::identifier(FRIEND_D_TAG))
        .tag(Tag::public_key(target_pubkey))
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    runtime().block_on(async {
        publish_to_relays(&invite_relays, &event).await?;
        publish_relay_list_nip65(&keys, &my_relays).await;
        Ok::<(), String>(())
    })?;

    requests::add(&storage_dir, index, invite_pubkey, invite_relays)
}

/// Fetches and decrypts pending friend requests addressed to any of our
/// still-active invites, across `relay_urls` (this device's own relays —
/// the same ones advertised in the QR). Already-known friends and blocked
/// pubkeys are filtered out.
pub fn fetch_pending_friend_requests(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
) -> Result<Vec<PendingFriendRequest>, String> {
    let known: std::collections::HashSet<String> = friends::load_friends(storage_dir.clone())
        .into_iter()
        .map(|f| f.pubkey)
        .chain(friends::load_blocked(&storage_dir))
        .collect();

    let mut pending = Vec::new();
    for invite in invites::list_active_invites(storage_dir.clone()) {
        let keys = derive_contact_keys(&mnemonic, invite.account_index)?;
        let filter = Filter::new()
            .kind(FRIEND_REQUEST_KIND)
            .pubkey(keys.public_key())
            .identifier(FRIEND_D_TAG);
        let events = runtime().block_on(fetch_events(&relay_urls, &filter))?;
        for event in events {
            let requester_hex = event.pubkey.to_hex();
            if known.contains(&requester_hex) {
                continue;
            }
            let Ok(decrypted) = nip44::decrypt(keys.secret_key(), &event.pubkey, &event.content)
            else {
                continue;
            };
            let Ok(payload) = serde_json::from_str::<FriendPayload>(&decrypted) else {
                continue;
            };
            pending.push(PendingFriendRequest {
                invite_account_index: invite.account_index,
                pubkey: requester_hex,
                display_name: payload.display_name,
                status_message: payload.status_message,
                relays: payload.relays,
                avatar_base64: payload.avatar_base64,
            });
        }
    }
    Ok(pending)
}

/// Accepts a pending friend request: mints a fresh per-relationship key,
/// tells the requester about it (encrypted to their contact pubkey,
/// published to their relays), and saves them locally as a friend.
pub fn accept_friend_request(
    mnemonic: String,
    storage_dir: String,
    invite_account_index: u32,
    requester_pubkey: String,
    requester_display_name: String,
    requester_status_message: String,
    requester_relays: Vec<String>,
    requester_avatar_base64: Option<String>,
) -> Result<(), String> {
    let my_account = account::load_account(storage_dir.clone()).ok_or("no local account")?;
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;

    let index = invites::allocate_account_index(&storage_dir)?;
    let keys = derive_contact_keys(&mnemonic, index)?;
    let requester = PublicKey::from_hex(&requester_pubkey).map_err(|e| e.to_string())?;

    let payload = FriendPayload {
        display_name: my_account.display_name,
        status_message: my_account.status_message,
        relays: my_relays.clone(),
        avatar_base64: read_avatar_base64(&my_account.avatar_path),
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let encrypted = nip44::encrypt(keys.secret_key(), &requester, plaintext, nip44::Version::V2)
        .map_err(|e| e.to_string())?;

    let event = EventBuilder::new(FRIEND_ACCEPT_KIND, encrypted)
        .tag(Tag::identifier(FRIEND_D_TAG))
        .tag(Tag::public_key(requester))
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    runtime().block_on(async {
        publish_to_relays(&requester_relays, &event).await?;
        publish_relay_list_nip65(&keys, &my_relays).await;
        Ok::<(), String>(())
    })?;

    invites::record_invite_use(storage_dir.clone(), invite_account_index)?;
    let avatar_path = save_friend_avatar(&storage_dir, &requester_pubkey, &requester_avatar_base64);
    friends::add_friend(
        storage_dir,
        requester_pubkey,
        index,
        requester_display_name,
        requester_status_message,
        requester_relays,
        avatar_path,
    )
}

/// Permanently blocks a requester's contact pubkey so their (rejected)
/// friend request stops showing up, even if resent.
pub fn reject_friend_request(storage_dir: String, requester_pubkey: String) -> Result<(), String> {
    friends::block_pubkey(storage_dir, requester_pubkey)
}

/// Publishes the given profile info to every existing friend, each using
/// the per-relationship key already established for them, encrypted to
/// their contact pubkey. Sent to the union of their last-known relays and
/// whatever their NIP-65 relay list (looked up fresh from the bootstrap
/// relays) currently says — so a friend who's since moved relays without
/// us hearing about it yet still gets this. Also republishes our own
/// NIP-65 for that per-relationship key, so *they* can resolve us the same
/// way if our notice doesn't reach them directly.
pub fn publish_profile_update_to_friends(
    mnemonic: String,
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;
    let payload = FriendPayload {
        display_name,
        status_message,
        relays: my_relays.clone(),
        avatar_base64: read_avatar_base64(&avatar_path),
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    runtime().block_on(async {
        for friend in friends::load_friends(storage_dir.clone()) {
            let Ok(keys) = derive_contact_keys(&mnemonic, friend.my_account_index) else {
                continue;
            };
            let Ok(friend_pubkey) = PublicKey::from_hex(&friend.pubkey) else {
                continue;
            };
            let Ok(encrypted) = nip44::encrypt(
                keys.secret_key(),
                &friend_pubkey,
                plaintext.clone(),
                nip44::Version::V2,
            ) else {
                continue;
            };
            let Ok(event) = EventBuilder::new(FRIEND_PROFILE_UPDATE_KIND, encrypted)
                .tag(Tag::identifier(FRIEND_D_TAG))
                .tag(Tag::public_key(friend_pubkey))
                .sign_with_keys(&keys)
            else {
                continue;
            };

            let mut target_relays = friend.relays.clone();
            for url in fetch_relay_list_nip65(&friend_pubkey).await {
                if !target_relays.contains(&url) {
                    target_relays.push(url);
                }
            }
            let _ = publish_to_relays(&target_relays, &event).await;
            publish_relay_list_nip65(&keys, &my_relays).await;
        }
        Ok(())
    })
}

/// Called after the user changes their own relay list in Settings.
/// Republishes NIP-65 (to the fixed bootstrap relays) for every
/// per-relationship key we've ever given out to a friend, so each of them
/// — even ones who miss the direct profile-update notice entirely — can
/// still resolve our current relays by looking up that key there.
pub fn publish_relay_list_update(mnemonic: String, storage_dir: String) -> Result<(), String> {
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;
    runtime().block_on(async {
        for friend in friends::load_friends(storage_dir.clone()) {
            if let Ok(keys) = derive_contact_keys(&mnemonic, friend.my_account_index) {
                publish_relay_list_nip65(&keys, &my_relays).await;
            }
        }
    });
    Ok(())
}

/// Checks every friend request we've sent that hasn't been resolved yet,
/// and turns any that were accepted into saved friends. Returns the newly
/// added friends (e.g. for a "X accepted your request" notification).
pub fn fetch_friend_accepts(
    mnemonic: String,
    storage_dir: String,
) -> Result<Vec<AcceptedFriend>, String> {
    let mut accepted = Vec::new();
    for outgoing in requests::load(&storage_dir) {
        let keys = derive_contact_keys(&mnemonic, outgoing.my_account_index)?;
        let filter = Filter::new()
            .kind(FRIEND_ACCEPT_KIND)
            .pubkey(keys.public_key())
            .identifier(FRIEND_D_TAG);
        let events = runtime().block_on(fetch_events(&outgoing.invite_relays, &filter))?;
        let Some(event) = events.into_iter().max_by_key(|e| e.created_at) else {
            continue;
        };
        let Ok(decrypted) = nip44::decrypt(keys.secret_key(), &event.pubkey, &event.content)
        else {
            continue;
        };
        let Ok(payload) = serde_json::from_str::<FriendPayload>(&decrypted) else {
            continue;
        };
        let pubkey = event.pubkey.to_hex();
        let avatar_path = save_friend_avatar(&storage_dir, &pubkey, &payload.avatar_base64);
        friends::add_friend(
            storage_dir.clone(),
            pubkey.clone(),
            outgoing.my_account_index,
            payload.display_name.clone(),
            payload.status_message.clone(),
            payload.relays.clone(),
            avatar_path,
        )?;
        requests::remove(&storage_dir, outgoing.my_account_index)?;
        accepted.push(AcceptedFriend {
            pubkey,
            display_name: payload.display_name,
            status_message: payload.status_message,
        });
    }
    Ok(accepted)
}

/// A live update about a friend request or acceptance, delivered while
/// this device stays connected to its relays. Cheaper than re-polling: the
/// connection just sits idle (a few bytes of keepalive) until a relay
/// actually has something to send.
#[derive(Clone)]
pub struct FriendEvent {
    /// `"request"` or `"accepted"`.
    pub kind: String,
    pub pubkey: String,
    pub display_name: String,
    pub status_message: String,
    /// Only set for `"request"` — which invite it arrived on, needed to
    /// accept it.
    pub invite_account_index: Option<u32>,
    /// Only set for `"request"` — the requester's relays, needed to accept it.
    pub relays: Vec<String>,
}

#[derive(Clone)]
enum Watch {
    Invite(u32),
    Outgoing(u32),
    /// An existing friend, watched for profile updates. Carries their
    /// pubkey (to know which `friends.json` entry to update).
    Friend(u32, String),
}

/// Opens a connection to this account's relays (plus any outstanding
/// outgoing requests' relays) and streams friend-request / friend-accept
/// events as they arrive, for as long as the returned Dart stream is
/// listened to. Reflects the set of invites/requests that existed at the
/// moment this was called — call again (the Dart side cancels the old
/// subscription first) after creating a new invite or sending a request.
pub fn subscribe_friend_events(
    mnemonic: String,
    storage_dir: String,
    sink: StreamSink<FriendEvent>,
) {
    runtime().spawn(run_friend_event_subscription(mnemonic, storage_dir, sink));
}

async fn run_friend_event_subscription(
    mnemonic: String,
    storage_dir: String,
    sink: StreamSink<FriendEvent>,
) {
    let invite_list = invites::list_active_invites(storage_dir.clone());
    let outgoing_list = requests::load(&storage_dir);
    let friend_list = friends::load_friends(storage_dir.clone());

    let mut watch: Vec<(PublicKey, Watch)> = Vec::new();
    for invite in &invite_list {
        if let Ok(keys) = derive_contact_keys(&mnemonic, invite.account_index) {
            watch.push((keys.public_key(), Watch::Invite(invite.account_index)));
        }
    }
    for outgoing in &outgoing_list {
        if let Ok(keys) = derive_contact_keys(&mnemonic, outgoing.my_account_index) {
            watch.push((keys.public_key(), Watch::Outgoing(outgoing.my_account_index)));
        }
    }
    for friend in &friend_list {
        if let Ok(keys) = derive_contact_keys(&mnemonic, friend.my_account_index) {
            watch.push((
                keys.public_key(),
                Watch::Friend(friend.my_account_index, friend.pubkey.clone()),
            ));
        }
    }
    if watch.is_empty() {
        return;
    }

    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;
    let mut relay_set: std::collections::HashSet<String> = my_relays.into_iter().collect();
    for outgoing in &outgoing_list {
        relay_set.extend(outgoing.invite_relays.iter().cloned());
    }

    let pubkeys: Vec<PublicKey> = watch.iter().map(|(pk, _)| *pk).collect();
    let filter = Filter::new()
        .kinds([FRIEND_REQUEST_KIND, FRIEND_ACCEPT_KIND, FRIEND_PROFILE_UPDATE_KIND])
        .pubkeys(pubkeys);

    let watch_snapshot: Vec<(PublicKey, Watch)> = watch;

    let tasks = relay_set.into_iter().map(|url| {
        let filter = filter.clone();
        let mnemonic = mnemonic.clone();
        let storage_dir = storage_dir.clone();
        let sink = sink.clone();
        let watch_snapshot = watch_snapshot.clone();
        async move {
            listen_for_friend_events(&url, &filter, &watch_snapshot, &mnemonic, &storage_dir, &sink)
                .await
        }
    });
    join_all(tasks).await;
}

/// Subscribes on `url`'s pooled connection (reusing it if already open —
/// e.g. from a recent publish or fetch to the same relay) and pushes
/// decrypted friend events to `sink` as they arrive (persisting accepted
/// friends along the way). Returns once the connection drops.
async fn listen_for_friend_events(
    url: &str,
    filter: &Filter,
    watch: &[(PublicKey, Watch)],
    mnemonic: &str,
    storage_dir: &str,
    sink: &StreamSink<FriendEvent>,
) {
    let Some((sub_id, mut events)) = relay_pool::subscribe(url, filter) else {
        return;
    };

    while let Some(pool_event) = events.recv().await {
        let relay_pool::PoolEvent::Event(event) = pool_event else {
            continue;
        };
        let Some((_, matched)) = watch
            .iter()
            .find(|(pk, _)| event.tags.public_keys().any(|tagged| tagged == pk))
        else {
            continue;
        };
        let account_index = match matched {
            Watch::Invite(idx) | Watch::Outgoing(idx) | Watch::Friend(idx, _) => *idx,
        };
        let Ok(my_keys) = derive_contact_keys(mnemonic, account_index) else {
            continue;
        };
        let Ok(decrypted) = nip44::decrypt(my_keys.secret_key(), &event.pubkey, &event.content)
        else {
            continue;
        };
        let Ok(payload) = serde_json::from_str::<FriendPayload>(&decrypted) else {
            continue;
        };

        let friend_event = match matched {
            Watch::Invite(idx) if event.kind == FRIEND_REQUEST_KIND => FriendEvent {
                kind: "request".to_string(),
                pubkey: event.pubkey.to_hex(),
                display_name: payload.display_name,
                status_message: payload.status_message,
                invite_account_index: Some(*idx),
                relays: payload.relays,
            },
            Watch::Outgoing(idx) if event.kind == FRIEND_ACCEPT_KIND => {
                let pubkey = event.pubkey.to_hex();
                let avatar_path = save_friend_avatar(storage_dir, &pubkey, &payload.avatar_base64);
                let _ = friends::add_friend(
                    storage_dir.to_string(),
                    pubkey.clone(),
                    *idx,
                    payload.display_name.clone(),
                    payload.status_message.clone(),
                    payload.relays.clone(),
                    avatar_path,
                );
                let _ = requests::remove(storage_dir, *idx);
                FriendEvent {
                    kind: "accepted".to_string(),
                    pubkey,
                    display_name: payload.display_name,
                    status_message: payload.status_message,
                    invite_account_index: None,
                    relays: Vec::new(),
                }
            }
            Watch::Friend(_, friend_pubkey) if event.kind == FRIEND_PROFILE_UPDATE_KIND => {
                let avatar_path =
                    save_friend_avatar(storage_dir, friend_pubkey, &payload.avatar_base64);
                let _ = friends::update_friend_profile(
                    storage_dir,
                    friend_pubkey,
                    payload.display_name.clone(),
                    payload.status_message.clone(),
                    payload.relays.clone(),
                    avatar_path,
                );
                FriendEvent {
                    kind: "profile_updated".to_string(),
                    pubkey: friend_pubkey.clone(),
                    display_name: payload.display_name,
                    status_message: payload.status_message,
                    invite_account_index: None,
                    relays: Vec::new(),
                }
            }
            _ => continue,
        };
        let _ = sink.add(friend_event);
    }
    relay_pool::unsubscribe(url, sub_id);
}

/// Publishes `event` to every relay in `urls` over each relay's pooled
/// connection (reused if one's already open, e.g. from the live
/// subscription — never a fresh dial per publish). Fire-and-forget per
/// relay; only fails if every relay's queue is already gone.
async fn publish_to_relays(urls: &[String], event: &Event) -> Result<(), String> {
    let ok = urls.iter().any(|url| relay_pool::publish(url, event).is_ok());
    if ok {
        Ok(())
    } else {
        Err("failed to publish to any relay".to_string())
    }
}

async fn fetch_latest_backup_event(
    urls: &[String],
    pubkey: &PublicKey,
) -> Result<Option<Event>, String> {
    let filter = Filter::new()
        .author(*pubkey)
        .kind(ACCOUNT_BACKUP_KIND)
        .identifier(ACCOUNT_BACKUP_D_TAG)
        .limit(1);
    let tasks = urls
        .iter()
        .map(|url| relay_pool::request(url, &filter, REQUEST_TIMEOUT));
    let results = join_all(tasks).await;
    let mut latest: Option<Event> = None;
    for event in results.into_iter().flatten() {
        if latest.as_ref().is_none_or(|current| event.created_at > current.created_at) {
            latest = Some(event);
        }
    }
    Ok(latest)
}

/// Queries `urls` with `filter` and returns every distinct event found
/// across all of them (deduplicated by event id). Reuses each relay's
/// pooled connection rather than dialing a fresh one.
async fn fetch_events(urls: &[String], filter: &Filter) -> Result<Vec<Event>, String> {
    let tasks = urls
        .iter()
        .map(|url| relay_pool::request(url, filter, REQUEST_TIMEOUT));
    let results = join_all(tasks).await;
    let mut seen = std::collections::HashSet::new();
    let mut events = Vec::new();
    for event in results.into_iter().flatten() {
        if seen.insert(event.id) {
            events.push(event);
        }
    }
    Ok(events)
}
