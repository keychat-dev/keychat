use crate::api::keys::derive_keys;
use futures_util::{future::join_all, SinkExt, StreamExt};
use nostr::event::{Event, EventBuilder, Kind, Tag};
use nostr::nips::nip09::EventDeletionRequest;
use nostr::nips::nip44;
use nostr::types::Timestamp;
use nostr::{Filter, PublicKey};
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio_tungstenite::tungstenite::Message;

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

/// Identifier tag for the account backup's parameterized-replaceable event
/// (NIP-33 / kind 30078), so each account has exactly one such event per
/// relay and newer publishes replace older ones automatically.
const ACCOUNT_BACKUP_D_TAG: &str = "keychat-account";
const ACCOUNT_BACKUP_KIND: Kind = Kind::Custom(30078);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
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

async fn publish_to_relays(urls: &[String], event: &Event) -> Result<(), String> {
    let msg = serde_json::to_string(&serde_json::json!(["EVENT", event])).map_err(|e| e.to_string())?;
    let tasks = urls.iter().map(|url| {
        let msg = msg.clone();
        let url = url.clone();
        async move { publish_one(&url, &msg).await.is_ok() }
    });
    let results = join_all(tasks).await;
    if results.into_iter().any(|ok| ok) {
        Ok(())
    } else {
        Err("failed to publish to any relay".to_string())
    }
}

async fn publish_one(url: &str, msg: &str) -> Result<(), String> {
    let (mut ws, _) = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(url))
        .await
        .map_err(|_| "connect timeout".to_string())?
        .map_err(|e| e.to_string())?;
    ws.send(Message::Text(msg.to_string()))
        .await
        .map_err(|e| e.to_string())?;
    // Best-effort: give the relay a moment to send back an OK, but a missing
    // reply doesn't mean the publish failed — plenty of relays are slow here.
    let _ = tokio::time::timeout(Duration::from_secs(3), ws.next()).await;
    let _ = ws.close(None).await;
    Ok(())
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
    let req_msg = serde_json::to_string(&serde_json::json!(["REQ", "keychat-account", filter]))
        .map_err(|e| e.to_string())?;
    let tasks = urls.iter().map(|url| {
        let req_msg = req_msg.clone();
        let url = url.clone();
        async move { fetch_one(&url, &req_msg).await.unwrap_or_default() }
    });
    let results = join_all(tasks).await;
    let mut latest: Option<Event> = None;
    for event in results.into_iter().flatten() {
        if latest.as_ref().is_none_or(|current| event.created_at > current.created_at) {
            latest = Some(event);
        }
    }
    Ok(latest)
}

async fn fetch_one(url: &str, req_msg: &str) -> Result<Vec<Event>, String> {
    let (mut ws, _) = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(url))
        .await
        .map_err(|_| "connect timeout".to_string())?
        .map_err(|e| e.to_string())?;
    ws.send(Message::Text(req_msg.to_string()))
        .await
        .map_err(|e| e.to_string())?;

    let mut events = Vec::new();
    let deadline = tokio::time::Instant::now() + REQUEST_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        let Ok(Some(Ok(Message::Text(text)))) = tokio::time::timeout(remaining, ws.next()).await
        else {
            break;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        match value.get(0).and_then(|v| v.as_str()) {
            Some("EVENT") => {
                if let Some(event) = value
                    .get(2)
                    .and_then(|v| serde_json::from_value::<Event>(v.clone()).ok())
                {
                    events.push(event);
                }
            }
            Some("EOSE") => break,
            _ => {}
        }
    }
    let _ = ws.close(None).await;
    Ok(events)
}
