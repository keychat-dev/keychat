use bip39::Mnemonic;
use nostr::nips::nip06::FromMnemonic;
use nostr::Keys;
use sha2::{Digest, Sha256};

/// Reserved NIP-06 account index for deriving the stable UID (see
/// `derive_uid`). Never used for `derive_contact_keys` — friend
/// relationships use small sequential indices starting at 0, so a value
/// this large can never collide with one.
const UID_ACCOUNT_INDEX: u32 = 0x7FFF_FFFE;

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

/// Derives this account's stable UID: a SHA-256 hash of a pubkey minted at
/// a reserved derivation index that's never used for any relationship.
/// Unlike a per-contact pubkey, the UID stays the same across every friend
/// — shown in the profile so a friend can recognize the same account again
/// even after it re-friends them with a brand new relationship key (e.g.
/// to evade a block). Hashing (rather than exposing the reserved pubkey
/// directly) means the UID carries no usable key material — it's purely
/// an identifier, never a way to sign or decrypt anything.
pub(crate) fn derive_uid(mnemonic: &str) -> Result<String, String> {
    let keys = derive_contact_keys(mnemonic, UID_ACCOUNT_INDEX)?;
    let digest = Sha256::digest(keys.public_key().to_hex().as_bytes());
    Ok(digest.iter().map(|b| format!("{:02x}", b)).collect())
}

/// Dart-callable wrapper around [derive_uid] — lets the profile screen show
/// the account's own UID (e.g. for the user to compare against a friend's).
pub fn get_account_uid(mnemonic: String) -> Result<String, String> {
    derive_uid(&mnemonic)
}
