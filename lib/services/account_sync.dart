import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/src/rust/api/account.dart' as account_api;
import 'package:workspace/src/rust/api/relay.dart' as relay_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// Publishes the given account to the relay-hosted encrypted backup, if a
/// seed phrase has been generated yet. Silently does nothing (no seed) or
/// fails silently (relays unreachable) — publishing is best-effort and
/// shouldn't block or fail the caller's own flow.
Future<void> publishAccountBackup(account_api.Account profile) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
  try {
    await sync_api.publishAccountBackup(
      mnemonic: mnemonic,
      relayUrls: relayList.urls,
      displayName: profile.displayName,
      statusMessage: profile.statusMessage,
      updatedAt: profile.updatedAt,
    );
  } catch (_) {
    // Offline or every relay unreachable — the next publish attempt
    // (next edit, or next app startup) will retry.
  }
}

/// Reconciles the local account with its relay-hosted backup: whichever
/// side has the newer `updatedAt` wins. If the relay copy is newer, the
/// local `account.json` is overwritten and the updated [account_api.Account]
/// is returned; otherwise (local is newer, or there's no backup yet) the
/// local copy is pushed to relays and `localProfile` is returned unchanged.
///
/// Returns `localProfile` unchanged if there's no seed yet or relays are
/// unreachable — sync is best-effort, never blocks being able to use the app.
Future<account_api.Account> reconcileAccountBackup(
  account_api.Account localProfile,
) async {
  const secureStorage = FlutterSecureStorage();
  final mnemonic = await secureStorage.read(key: seedStorageKey);
  if (mnemonic == null) return localProfile;

  final storageDir = await getApplicationDocumentsDirectory();
  final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);

  try {
    final remote = await sync_api.fetchAccountBackup(mnemonic: mnemonic, relayUrls: relayList.urls);
    if (remote != null && remote.updatedAt > localProfile.updatedAt) {
      await account_api.saveAccountWithTimestamp(
        storageDir: storageDir.path,
        displayName: remote.displayName,
        statusMessage: remote.statusMessage,
        avatarPath: localProfile.avatarPath,
        updatedAt: remote.updatedAt,
      );
      return account_api.Account(
        displayName: remote.displayName,
        statusMessage: remote.statusMessage,
        avatarPath: localProfile.avatarPath,
        updatedAt: remote.updatedAt,
      );
    }
    if (remote == null || localProfile.updatedAt > remote.updatedAt) {
      await sync_api.publishAccountBackup(
        mnemonic: mnemonic,
        relayUrls: relayList.urls,
        displayName: localProfile.displayName,
        statusMessage: localProfile.statusMessage,
        updatedAt: localProfile.updatedAt,
      );
    }
  } catch (_) {
    // Offline or every relay unreachable — proceed with the local copy.
  }
  return localProfile;
}
