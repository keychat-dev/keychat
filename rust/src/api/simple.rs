#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();

    // Needed by tokio-tungstenite's rustls TLS backend (used for relay
    // status checks over wss://): without this, the first TLS connection
    // panics because rustls can't auto-select between its ring/aws-lc-rs
    // crypto backends.
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls crypto provider");
}
