import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/src/rust/api/ratchet.dart' as ratchet_api;

/// OS Keystore/Keychain storage key for this device's forward-secrecy local
/// storage key — see `ratchet.rs`'s module doc. Deliberately separate from
/// [seedStorageKey]: unlike the seed phrase, this key must be unique per
/// device (sharing it across devices is exactly what breaks the ratchet),
/// so it's never derived from the mnemonic and never included in any
/// backup/restore flow.
const ratchetKeyStorageKey = 'ratchet_local_storage_key';

/// The device's forward-secrecy local storage key, generating and
/// persisting one on first use.
Future<String> getOrCreateRatchetKey() async {
  const secureStorage = FlutterSecureStorage();
  final existing = await secureStorage.read(key: ratchetKeyStorageKey);
  if (existing != null) return existing;
  final generated = await ratchet_api.generateLocalStorageKey();
  await secureStorage.write(key: ratchetKeyStorageKey, value: generated);
  return generated;
}

/// Announces this device's forward-secrecy identity to a friend right away
/// — call as soon as a friendship is established (both the accepting side
/// and the side that gets notified their request was accepted), instead of
/// waiting for either side to open the chat thread. Best-effort and
/// silently swallows failures (e.g. offline): [ChatThreadScreen] retries
/// this on every thread open, so a missed announce here just means the
/// forward-secrecy handshake completes a little later instead of
/// immediately after friending.
Future<void> announceRatchetDeviceTo(String friendPubkey) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;
  final storageDir = await getApplicationDocumentsDirectory();
  final ratchetKey = await getOrCreateRatchetKey();
  try {
    await ratchet_api.announceDevice(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: friendPubkey,
      localKey: ratchetKey,
    );
  } catch (_) {
    // Offline — picked up later when the thread is opened.
  }
}
