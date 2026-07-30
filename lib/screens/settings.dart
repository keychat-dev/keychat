import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/languages.dart';
import 'package:workspace/screens/logout.dart';
import 'package:workspace/screens/edit_profile.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/relay_settings.dart';
import 'package:workspace/src/rust/api/account.dart' as account_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// Settings menu reachable from the top-right gear icon on Home. Links to
/// the profile edit screen and relay configuration.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.profile,
    required this.onProfileUpdated,
    required this.onSelectLanguage,
    required this.onLogout,
    this.messageEvents,
  });

  final account_api.Account profile;
  final ValueChanged<account_api.Account> onProfileUpdated;
  final ValueChanged<Locale> onSelectLanguage;
  final VoidCallback onLogout;
  final Stream<sync_api.FriendEvent>? messageEvents;

  void _openAccountSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountSettingsScreen(onLogout: onLogout),
      ),
    );
  }

  Future<void> _openEditProfile(BuildContext context) async {
    final updated = await Navigator.of(context).push<account_api.Account>(
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: profile)),
    );
    if (updated == null) return;
    onProfileUpdated(updated);
  }

  void _openRelaySettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelaySettingsScreen(messageEvents: messageEvents),
      ),
    );
  }

  Future<void> _openLanguagePicker(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final currentCode = Localizations.localeOf(context).languageCode;
    final selected = await showDialog<Locale>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: KeychatColors.background,
          title: Text(l10n.settingsLanguage),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final locale in AppLocalizations.supportedLocales)
                ListTile(
                  title: Text(languageNames[locale.languageCode] ?? locale.languageCode.toUpperCase()),
                  trailing: locale.languageCode == currentCode
                      ? const Icon(Icons.check, color: KeychatColors.primaryDark)
                      : null,
                  onTap: () => Navigator.of(dialogContext).pop(locale),
                ),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    onSelectLanguage(selected);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.settingsTitle),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline, color: KeychatColors.textSecondary),
              title: Text(l10n.settingsProfile),
              trailing: const Icon(Icons.chevron_right, color: KeychatColors.textSecondary),
              onTap: () => _openEditProfile(context),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined, color: KeychatColors.textSecondary),
              title: Text(l10n.settingsRelay),
              trailing: const Icon(Icons.chevron_right, color: KeychatColors.textSecondary),
              onTap: () => _openRelaySettings(context),
            ),
            ListTile(
              leading: const Icon(Icons.translate, color: KeychatColors.textSecondary),
              title: Text(l10n.settingsLanguage),
              trailing: const Icon(Icons.chevron_right, color: KeychatColors.textSecondary),
              onTap: () => _openLanguagePicker(context),
            ),
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined, color: KeychatColors.textSecondary),
              title: Text(l10n.settingsAccount),
              trailing: const Icon(Icons.chevron_right, color: KeychatColors.textSecondary),
              onTap: () => _openAccountSettings(context),
            ),
          ],
        ),
      ),
    );
  }
}
