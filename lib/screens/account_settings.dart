import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';

/// Account management screen. Currently just offers a destructive "purge
/// account" action that wipes all local data (profile, relays, avatar).
/// KeyChat has no backup/export feature yet, so purging is always
/// irreversible — the confirmation dialog warns about that explicitly.
class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key, required this.onPurgeAccount});

  final VoidCallback onPurgeAccount;

  Future<void> _confirmPurge(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: KeychatColors.background,
          title: Text(l10n.purgeAccountConfirmTitle),
          content: Text(l10n.purgeAccountConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(l10n.purgeButton),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    onPurgeAccount();
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
              leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
              title: Text(
                l10n.purgeAccountButton,
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
              ),
              onTap: () => _confirmPurge(context),
            ),
          ],
        ),
      ),
    );
  }
}
