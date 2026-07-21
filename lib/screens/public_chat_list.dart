import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';

/// Public chat tab body shown inside the home screen's bottom navigation.
/// Not implemented yet.
class PublicChatListTab extends StatelessWidget {
  const PublicChatListTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Text(
        l10n.comingSoon,
        style: const TextStyle(fontSize: 18, color: KeychatColors.textSecondary),
      ),
    );
  }
}
