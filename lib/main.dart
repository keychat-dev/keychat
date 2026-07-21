import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/home.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/relay_settings.dart';
import 'package:workspace/screens/setup_complete.dart';
import 'package:workspace/src/rust/api/profile.dart' as profile_api;
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

  late final Future<profile_api.Profile?> _profileFuture = _loadProfile();

  Future<profile_api.Profile?> _loadProfile() async {
    final storageDir = await getApplicationDocumentsDirectory();
    return profile_api.loadProfile(storageDir: storageDir.path);
  }

  void _selectLocale(Locale locale) {
    setState(() => _locale = locale);
  }

  Future<void> _purgeAccount(BuildContext context) async {
    final storageDir = await getApplicationDocumentsDirectory();
    for (final entity in storageDir.listSync()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (name == 'profile.json' || name == 'relays.json' || name.startsWith('avatar.')) {
          await entity.delete();
        }
      }
    }
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => Builder(
          builder: (context) => ProfileSetupScreen(
            onSelectLanguage: _selectLocale,
            onContinue: (displayName, statusMessage, avatarPath) =>
                _handleContinue(context, displayName, statusMessage, avatarPath),
          ),
        ),
      ),
      (route) => false,
    );
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
    final profile = profile_api.Profile(
      displayName: displayName,
      statusMessage: statusMessage,
      avatarPath: persistedAvatarPath,
    );
    await profile_api.saveProfile(
      storageDir: storageDir.path,
      displayName: profile.displayName,
      statusMessage: profile.statusMessage,
      avatarPath: profile.avatarPath,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelaySettingsScreen(
          onContinue: () {
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (_, _, _) => SetupCompleteScreen(
                  displayName: profile.displayName,
                  onDone: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => HomeScreen(
                          profile: profile,
                          onSelectLanguage: _selectLocale,
                          onPurgeAccount: () => _purgeAccount(context),
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
      home: FutureBuilder<profile_api.Profile?>(
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
                onPurgeAccount: () => _purgeAccount(context),
              ),
            );
          }
          return Builder(
            builder: (context) => ProfileSetupScreen(
              onSelectLanguage: _selectLocale,
              onContinue: (displayName, statusMessage, avatarPath) =>
                  _handleContinue(context, displayName, statusMessage, avatarPath),
            ),
          );
        },
      ),
    );
  }
}
