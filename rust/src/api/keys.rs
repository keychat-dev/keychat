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
