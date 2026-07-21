use futures_util::future::join_all;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// The list of Nostr relay URLs this device publishes to / reads from.
#[derive(Serialize, Deserialize)]
pub struct RelayList {
    pub urls: Vec<String>,
}

fn default_relay_urls() -> Vec<String> {
    vec![
        "wss://relay.damus.io".to_string(),
        "wss://nos.lol".to_string(),
        "wss://relay.primal.net".to_string(),
    ]
}

/// The default set of public relays, used both as the fallback in
/// [load_relay_list] and to let the UI offer a "reset to defaults" action.
pub fn default_relays() -> Vec<String> {
    default_relay_urls()
}

fn relay_list_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("relays.json")
}

/// Saves the relay list as JSON under `storage_dir`.
/// `storage_dir` must already exist (e.g. the app's documents directory,
/// resolved on the Dart side via path_provider).
pub fn save_relay_list(storage_dir: String, urls: Vec<String>) -> Result<(), String> {
    let relay_list = RelayList { urls };
    let content = serde_json::to_string_pretty(&relay_list).map_err(|e| e.to_string())?;
    fs::write(relay_list_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Loads the saved relay list, or a small set of default public relays if
/// none has been saved yet.
pub fn load_relay_list(storage_dir: String) -> RelayList {
    fs::read_to_string(relay_list_path(&storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_else(|| RelayList {
            urls: default_relay_urls(),
        })
}

/// Tries to open a WebSocket connection to each URL to check whether the
/// relay is currently reachable. Returns one bool per input URL, in order.
pub fn check_relay_statuses(urls: Vec<String>) -> Vec<bool> {
    runtime().block_on(async {
        let checks = urls.iter().map(|url| async move {
            let connect = tokio_tungstenite::connect_async(url.as_str());
            matches!(tokio::time::timeout(CONNECT_TIMEOUT, connect).await, Ok(Ok(_)))
        });
        join_all(checks).await
    })
}
