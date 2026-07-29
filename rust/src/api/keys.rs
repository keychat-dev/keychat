use bip39::Mnemonic;
use nostr::nips::nip06::FromMnemonic;
use nostr::Keys;

/// Generates a new 12-word BIP-39 seed phrase. The caller is responsible for
/// persisting it (e.g. via platform secure storage) — this function is pure
/// generation with no I/O.
pub fn generate_mnemonic() -> Result<String, String> {
    Mnemonic::generate(12)
        .map(|mnemonic| mnemonic.to_string())
        .map_err(|e| e.to_string())
}

/// Validates that `mnemonic` is both a proper BIP-39 phrase and one that can
/// derive Nostr keys (NIP-06).
pub fn validate_mnemonic(mnemonic: String) -> Result<(), String> {
    let phrase = mnemonic.trim();
    phrase.parse::<Mnemonic>().map_err(|e| e.to_string())?;
    Keys::from_mnemonic(phrase, None).map_err(|e| e.to_string())?;
    Ok(())
}

/// Deterministically derives this account's core identity keys from its
/// seed phrase (NIP-06 account 0). Used for the relay-hosted account
/// backup — same mnemonic always yields the same keys, so nothing needs
/// to be stored beyond the mnemonic itself.
pub(crate) fn derive_keys(mnemonic: &str) -> Result<Keys, String> {
    derive_contact_keys(mnemonic, 0)
}

/// Deterministically derives a per-contact key pair from the seed phrase,
/// using NIP-06's multi-account derivation (`m/44'/1237'/<account>'/0/0`).
/// Each invite/friend gets a distinct `account` index so that if a key
/// shared with one contact ever leaks, it can't be linked to any other
/// contact or to this device's core account identity (account 0).
pub(crate) fn derive_contact_keys(mnemonic: &str, account: u32) -> Result<Keys, String> {
    Keys::from_mnemonic_with_account(mnemonic.trim(), None, Some(account))
        .map_err(|e| e.to_string())
}
