//! A small per-relay WebSocket connection pool.
//!
//! Every place in `api::sync` that talks to a relay used to open (and
//! immediately close) its own connection — a fresh TCP+TLS handshake per
//! publish or fetch, on top of a *separate* long-lived connection already
//! held open for the live friend-events subscription. This module instead
//! keeps at most one connection per relay URL alive for as long as
//! anything is using it, and multiplexes every publish/fetch/subscribe
//! through that single socket — the same approach real Nostr clients
//! (Damus, Amethyst, etc.) use via their relay pools.
//!
//! Not part of the `api` surface — nothing here is `pub` to Dart.

use futures_util::{SinkExt, StreamExt};
use nostr::event::Event;
use nostr::Filter;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// A message delivered to a subscriber of a `REQ`.
pub enum PoolEvent {
    Event(Event),
    Eose,
}

enum Command {
    Req {
        sub_id: String,
        filter_json: serde_json::Value,
        reply: mpsc::UnboundedSender<PoolEvent>,
    },
    Close {
        sub_id: String,
    },
    Publish {
        event_json: String,
    },
}

struct RelayHandle {
    tx: mpsc::UnboundedSender<Command>,
    /// `None` while the handshake is still in flight, then latched to
    /// `Some(true/false)` once it resolves. Callers that arrive while a
    /// connection is still connecting await this instead of racing ahead
    /// with commands that would otherwise be silently dropped if the
    /// handshake ends up failing.
    ready: watch::Receiver<Option<bool>>,
}

fn pool() -> &'static Mutex<HashMap<String, RelayHandle>> {
    static POOL: OnceLock<Mutex<HashMap<String, RelayHandle>>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_sub_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!("origilink-{}", COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// Returns the command channel for `url`'s pooled connection once it's
/// actually connected, spawning a background task to own it if one isn't
/// already running or in flight. Returns `None` if the connection attempt
/// fails — the failed entry is removed from the pool so the next call
/// starts a fresh attempt (a natural, on-demand retry).
async fn handle_for(url: &str) -> Option<mpsc::UnboundedSender<Command>> {
    let (tx, mut ready) = {
        let mut guard = pool().lock().unwrap();
        if let Some(existing) = guard.get(url) {
            (existing.tx.clone(), existing.ready.clone())
        } else {
            let (ready_tx, ready_rx) = watch::channel(None);
            let (tx, rx) = mpsc::unbounded_channel();
            guard.insert(
                url.to_string(),
                RelayHandle { tx: tx.clone(), ready: ready_rx.clone() },
            );
            tokio::spawn(run_connection(url.to_string(), rx, ready_tx));
            (tx, ready_rx)
        }
    };

    loop {
        if let Some(connected) = *ready.borrow() {
            return connected.then_some(tx);
        }
        if ready.changed().await.is_err() {
            return None;
        }
    }
}

/// The one platform-specific step in this module: everything else here
/// (command multiplexing, subscription bookkeeping, the `request`/
/// `publish`/`subscribe` API) only assumes a `Sink`+`Stream` of text/ping/
/// pong/close frames, not that it came from a raw TCP+TLS WebSocket
/// specifically. A non-native target (e.g. wasm32, which can't open its own
/// TCP socket and must go through the browser's WebSocket object instead)
/// would only need to replace this one function with something yielding
/// the same `(write, read)` pair — everything downstream is unaffected.
async fn connect_native(
    url: &str,
) -> Result<
    (
        impl SinkExt<Message, Error = tokio_tungstenite::tungstenite::Error>,
        impl StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>,
    ),
    (),
> {
    let Ok(Ok((ws, _))) = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(url)).await
    else {
        return Err(());
    };
    Ok(ws.split())
}

/// Owns one relay's WebSocket for as long as it stays connected: writes
/// outgoing commands as they arrive and fans incoming EVENT/EOSE messages
/// out to whichever subscription they belong to. Removes itself from the
/// pool on disconnect so the next use reconnects from scratch.
async fn run_connection(url: String, mut rx: mpsc::UnboundedReceiver<Command>, ready: watch::Sender<Option<bool>>) {
    let Ok((mut write, mut read)) = connect_native(&url).await else {
        pool().lock().unwrap().remove(&url);
        let _ = ready.send(Some(false));
        return;
    };
    let _ = ready.send(Some(true));
    let mut subs: HashMap<String, mpsc::UnboundedSender<PoolEvent>> = HashMap::new();

    loop {
        tokio::select! {
            cmd = rx.recv() => {
                let Some(cmd) = cmd else { break };
                match cmd {
                    Command::Req { sub_id, filter_json, reply } => {
                        subs.insert(sub_id.clone(), reply);
                        let msg = serde_json::json!(["REQ", sub_id, filter_json]).to_string();
                        if write.send(Message::Text(msg)).await.is_err() {
                            break;
                        }
                    }
                    Command::Close { sub_id } => {
                        subs.remove(&sub_id);
                        let msg = serde_json::json!(["CLOSE", sub_id]).to_string();
                        let _ = write.send(Message::Text(msg)).await;
                    }
                    Command::Publish { event_json } => {
                        if write.send(Message::Text(event_json)).await.is_err() {
                            break;
                        }
                    }
                }
            }
            msg = read.next() => {
                // The connection is only actually gone on `None`/`Err`/`Close` —
                // relays routinely send Ping/Pong/other frames as keepalive,
                // which used to be mistaken for a dead connection here and
                // torn the whole pooled connection (and every subscription
                // multiplexed on it, including the live one) down on the
                // very first keepalive ping.
                let text = match msg {
                    Some(Ok(Message::Text(text))) => text,
                    Some(Ok(Message::Ping(payload))) => {
                        let _ = write.send(Message::Pong(payload)).await;
                        continue;
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    Some(Ok(_)) => continue,
                };
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
                match value.get(0).and_then(|v| v.as_str()) {
                    Some("EVENT") => {
                        let Some(sub_id) = value.get(1).and_then(|v| v.as_str()) else { continue };
                        let Some(event) = value
                            .get(2)
                            .and_then(|v| serde_json::from_value::<Event>(v.clone()).ok())
                        else {
                            continue;
                        };
                        if let Some(sender) = subs.get(sub_id) {
                            let _ = sender.send(PoolEvent::Event(event));
                        }
                    }
                    Some("EOSE") => {
                        let Some(sub_id) = value.get(1).and_then(|v| v.as_str()) else { continue };
                        if let Some(sender) = subs.get(sub_id) {
                            let _ = sender.send(PoolEvent::Eose);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    pool().lock().unwrap().remove(&url);
}

/// Sends `filter` as a one-shot `REQ` over `url`'s pooled connection,
/// collects events until `EOSE` or `timeout`, then unsubscribes. Reuses
/// (or opens) a single persistent connection per relay rather than
/// dialing a fresh one for every query.
pub async fn request(url: &str, filter: &Filter, timeout: Duration) -> Vec<Event> {
    let Some(tx) = handle_for(url).await else {
        return Vec::new();
    };
    let sub_id = next_sub_id();
    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel();
    let Ok(filter_json) = serde_json::to_value(filter) else {
        return Vec::new();
    };
    if tx
        .send(Command::Req { sub_id: sub_id.clone(), filter_json, reply: reply_tx })
        .is_err()
    {
        return Vec::new();
    }

    let mut events = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, reply_rx.recv()).await {
            Ok(Some(PoolEvent::Event(event))) => events.push(event),
            Ok(Some(PoolEvent::Eose)) => break,
            _ => break,
        }
    }
    let _ = tx.send(Command::Close { sub_id });
    events
}

/// Publishes `event` to `url` over the pooled connection. Fire-and-forget
/// — doesn't wait for the relay's `OK`, since plenty of relays are slow to
/// send one and a missing reply doesn't mean the publish failed.
pub async fn publish(url: &str, event: &Event) -> Result<(), String> {
    let tx = handle_for(url).await.ok_or_else(|| "relay unreachable".to_string())?;
    let event_json =
        serde_json::to_string(&serde_json::json!(["EVENT", event])).map_err(|e| e.to_string())?;
    tx.send(Command::Publish { event_json })
        .map_err(|_| "relay connection closed".to_string())
}

/// Opens a live subscription on `url`'s pooled connection. The returned
/// receiver streams matching events indefinitely — call [unsubscribe] with
/// the returned id once no longer needed.
pub async fn subscribe(url: &str, filter: &Filter) -> Option<(String, mpsc::UnboundedReceiver<PoolEvent>)> {
    let tx = handle_for(url).await?;
    let sub_id = next_sub_id();
    let (reply_tx, reply_rx) = mpsc::unbounded_channel();
    let filter_json = serde_json::to_value(filter).ok()?;
    tx.send(Command::Req { sub_id: sub_id.clone(), filter_json, reply: reply_tx })
        .ok()?;
    Some((sub_id, reply_rx))
}

pub fn unsubscribe(url: &str, sub_id: String) {
    if let Some(tx) = pool().lock().unwrap().get(url).map(|h| h.tx.clone()) {
        let _ = tx.send(Command::Close { sub_id });
    }
}
