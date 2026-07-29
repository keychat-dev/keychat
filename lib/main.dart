import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/auth_choice.dart';
import 'package:workspace/screens/home.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/screens/relay_settings.dart';
import 'package:workspace/screens/seed_backup.dart';
import 'package:workspace/screens/setup_complete.dart';
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/account.dart' as account_api;
import 'package:workspace/src/rust/api/keys.dart' as keys_api;
import 'package:workspace/src/rust/api/relay.dart' as relay_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;
import 'package:workspace/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const KeyChatApp());
}

class KeyChatApp extends StatefulWidget {
  const KeyChatApp({super.key});

  @override
  State<KeyChatApp> createState() => _KeyChatAppState();
}

class _KeyChatAppState extends State<KeyChatApp> {
  // Null means "follow the device locale". Set explicitly when the user
  // picks a language from the language selector on the login screen.
  Locale? _locale;

  late final Future<account_api.Account?> _profileFuture = _loadProfile();

  Future<account_api.Account?> _loadProfile() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final profile = await account_api.loadAccount(storageDir: storageDir.path);
    if (profile == null) return null;
    unawaited(_pollFriendAccepts(storageDir.path));
    return reconcileAccountBackup(profile);
  }

  /// Best-effort: turns any of our outgoing friend requests that have since
  /// been accepted into saved friends. Never blocks startup or surfaces
  /// errors — the next app open (or a manual refresh) will retry.
  Future<void> _pollFriendAccepts(String storageDir) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    try {
      await sync_api.fetchFriendAccepts(mnemonic: mnemonic, storageDir: storageDir);
    } catch (_) {
      // Offline or relays unreachable — try again next launch.
    }
  }

  void _selectLocale(Locale locale) {
    setState(() => _locale = locale);
  }

  Future<void> _logout(BuildContext context) async {
    final storageDir = await getApplicationDocumentsDirectory();
    for (final entity in storageDir.listSync()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (name == 'account.json' || name == 'relays.json' || name.startsWith('avatar.')) {
          await entity.delete();
        }
      }
    }
    const secureStorage = FlutterSecureStorage();
    await secureStorage.delete(key: seedStorageKey);
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => Builder(builder: _buildAuthChoice)),
      (route) => false,
    );
  }

  Widget _buildAuthChoice(BuildContext context) {
    return AuthChoiceScreen(
      onSelectLanguage: _selectLocale,
      onSignUp: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ProfileSetupScreen(
              onContinue: (displayName, statusMessage, avatarPath) =>
                  _handleContinue(context, displayName, statusMessage, avatarPath),
            ),
          ),
        );
      },
      onRestore: (mnemonic) => _handleRestore(context, mnemonic),
    );
  }

  /// Validates the given seed phrase, looks up its relay-hosted account
  /// backup (NIP-06 derived identity), and if found recreates the local
  /// account from it and navigates to Home. Returns a user-facing error
  /// message on failure, or `null` on success.
  Future<String?> _handleRestore(BuildContext context, String mnemonic) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await keys_api.validateMnemonic(mnemonic: mnemonic);
    } catch (_) {
      return l10n.restoreInvalidSeed;
    }

    // The relay-selection step (shown right before this screen) already
    // persisted the user's chosen search relays to relays.json.
    final storageDir = await getApplicationDocumentsDirectory();
    final relayUrls = (await relay_api.loadRelayList(storageDir: storageDir.path)).urls;
    sync_api.RemoteAccount? remote;
    try {
      remote = await sync_api.fetchAccountBackup(mnemonic: mnemonic, relayUrls: relayUrls);
    } catch (_) {
      return l10n.restoreNetworkError;
    }
    if (remote == null) return l10n.restoreNoBackupFound;

    await account_api.saveAccountWithTimestamp(
      storageDir: storageDir.path,
      displayName: remote.displayName,
      statusMessage: remote.statusMessage,
      updatedAt: remote.updatedAt,
    );
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(key: seedStorageKey, value: mnemonic);

    final profile = (await account_api.loadAccount(storageDir: storageDir.path))!;
    if (!context.mounted) return null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => Builder(
          builder: (context) => HomeScreen(
            profile: profile,
            onSelectLanguage: _selectLocale,
            onLogout: () => _logout(context),
          ),
        ),
      ),
      (route) => false,
    );
    return null;
  }

  Future<void> _handleContinue(
    BuildContext context,
    String displayName,
    String statusMessage,
    String? avatarPath,
  ) async {
    final storageDir = await getApplicationDocumentsDirectory();
    String? persistedAvatarPath;
    if (avatarPath != null) {
      final extension = avatarPath.split('.').last;
      final destination = '${storageDir.path}/avatar.$extension';
      await File(avatarPath).copy(destination);
      persistedAvatarPath = destination;
    }
    await account_api.saveAccount(
      storageDir: storageDir.path,
      displayName: displayName,
      statusMessage: statusMessage,
      avatarPath: persistedAvatarPath,
    );
    final profile = (await account_api.loadAccount(storageDir: storageDir.path))!;
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelaySettingsScreen(
          onContinue: () async {
            const secureStorage = FlutterSecureStorage();
            final mnemonic = await keys_api.generateMnemonic();
            await secureStorage.write(key: seedStorageKey, value: mnemonic);
            unawaited(publishAccountBackup(profile));
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SeedBackupScreen(
                  mnemonic: mnemonic,
                  onContinue: () {
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (_, _, _) => SetupCompleteScreen(
                          displayName: profile.displayName,
                          onDone: () {
                            Navigator.of(context).pushAndRemoveUntil(
                              MaterialPageRoute(
                                builder: (_) => Builder(
                                  builder: (context) => HomeScreen(
                                    profile: profile,
                                    onSelectLanguage: _selectLocale,
                                    onLogout: () => _logout(context),
                                  ),
                                ),
                              ),
                              (route) => false,
                            );
                          },
                        ),
                        transitionsBuilder: (_, animation, _, child) =>
                            FadeTransition(opacity: animation, child: child),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KeyChat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: KeychatColors.primary),
        scaffoldBackgroundColor: KeychatColors.background,
        useMaterial3: true,
      ),
      locale: _locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: FutureBuilder<account_api.Account?>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              backgroundColor: KeychatColors.background,
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final existingProfile = snapshot.data;
          if (existingProfile != null) {
            return Builder(
              builder: (context) => HomeScreen(
                profile: existingProfile,
                onSelectLanguage: _selectLocale,
                onLogout: () => _logout(context),
              ),
            );
          }
          return Builder(builder: _buildAuthChoice);
        },
      ),
    );
  }
}
