import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';

/// Talk tab body shown inside the home screen's bottom navigation.
/// Chat creation via QR/deep-link key exchange is not implemented yet.
class ChatListTab extends StatelessWidget {
  const ChatListTab({super.key, required this.displayName});

  final String displayName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Text(
        l10n.chatListWelcome(displayName),
        style: const TextStyle(fontSize: 20, color: KeychatColors.textPrimary),
      ),
    );
  }
}
