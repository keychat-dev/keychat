import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/keys.dart' as keys_api;

const seedStorageKey = 'account_seed_mnemonic';

/// Account management screen. Offers seed phrase backup and a destructive
/// "logout" action that wipes all local data (profile, relays, seed).
/// KeyChat has no server-side account, so logging out is always
/// irreversible — the confirmation dialog warns about that explicitly.
class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key, required this.onLogout});

  final VoidCallback onLogout;

  Future<void> _confirmLogout(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: KeychatColors.background,
          title: Text(l10n.logoutConfirmTitle),
          content: Text(l10n.logoutConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(l10n.logoutButton),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    onLogout();
  }

  Future<void> _openSeedBackup(BuildContext context) async {
    const storage = FlutterSecureStorage();
    var mnemonic = await storage.read(key: seedStorageKey);
    if (mnemonic == null) {
      mnemonic = await keys_api.generateMnemonic();
      await storage.write(key: seedStorageKey, value: mnemonic);
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _SeedBackupScreen(mnemonic: mnemonic!)),
    );
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
        title: Text(l10n.accountSettingsTitle),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.key_outlined, color: KeychatColors.textSecondary),
              title: Text(l10n.seedBackupButton),
              trailing: const Icon(Icons.chevron_right, color: KeychatColors.textSecondary),
              onTap: () => _openSeedBackup(context),
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: Text(
                l10n.logoutButton,
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
              ),
              onTap: () => _confirmLogout(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeedBackupScreen extends StatelessWidget {
  const _SeedBackupScreen({required this.mnemonic});

  final String mnemonic;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = mnemonic.split(' ');
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.seedBackupButton),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.seedBackupWarning,
                style: const TextStyle(color: KeychatColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: KeychatColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < words.length; i++)
                      Chip(
                        backgroundColor: KeychatColors.background,
                        label: Text(
                          '${i + 1}. ${words[i]}',
                          style: const TextStyle(color: KeychatColors.textPrimary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
