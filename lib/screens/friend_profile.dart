import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/friends.dart' as friends_api;

/// A friend's profile and the relays they publish to, with actions to
/// favorite/block/delete them. Shared between the friends list (tapping a
/// row) and a chat thread (tapping the friend's name/avatar in the app
/// bar), so both entry points stay in sync on one implementation.
///
/// Pops with `true` if the friend was blocked or deleted — callers still
/// showing that friend (e.g. an open chat thread) should pop themselves
/// too, since the friend no longer exists.
class FriendProfileScreen extends StatefulWidget {
  const FriendProfileScreen({
    super.key,
    required this.friend,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onDeleteFriend,
  });

  final friends_api.Friend friend;
  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  late bool _isFavorite = widget.friend.isFavorite;

  friends_api.Friend get friend => widget.friend;

  Future<void> _toggleFavorite() async {
    setState(() => _isFavorite = !_isFavorite);
    await widget.onToggleFavorite(friend);
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.rejectButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleBlock(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      context,
      title: l10n.blockFriendConfirmTitle(friend.displayName),
      body: l10n.blockFriendConfirmBody,
      confirmLabel: l10n.blockFriend,
    );
    if (confirmed != true) return;
    await widget.onBlockFriend(friend);
    if (context.mounted) Navigator.of(context).pop(true);
  }

  Future<void> _handleDelete(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      context,
      title: l10n.deleteFriendConfirmTitle(friend.displayName),
      body: l10n.deleteFriendConfirmBody,
      confirmLabel: l10n.deleteFriend,
    );
    if (confirmed != true) return;
    await widget.onDeleteFriend(friend);
    if (context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasAvatar = friend.avatarPath != null && File(friend.avatarPath!).existsSync();
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        actions: [
          IconButton(
            tooltip: _isFavorite ? l10n.removeFromFavorites : l10n.addToFavorites,
            onPressed: _toggleFavorite,
            icon: Icon(
              _isFavorite ? Icons.star : Icons.star_border,
              color: KeychatColors.primaryDark,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          Center(
            child: CircleAvatar(
              radius: 48,
              backgroundColor: KeychatColors.surface,
              backgroundImage: hasAvatar ? FileImage(File(friend.avatarPath!)) : null,
              child: hasAvatar
                  ? null
                  : const Icon(Icons.person_outline, size: 44, color: KeychatColors.textSecondary),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              friend.displayName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: KeychatColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              friend.statusMessage.isEmpty ? l10n.noStatusMessage : friend.statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: KeychatColors.textSecondary),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            l10n.relaySettingsTitle,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: KeychatColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          if (friend.relays.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.noRelaysYet,
                style: const TextStyle(color: KeychatColors.textSecondary),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: KeychatColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < friend.relays.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: Color(0x14000000)),
                    ListTile(
                      leading: const Icon(Icons.dns_outlined, color: KeychatColors.textSecondary),
                      title: Text(
                        friend.relays[i],
                        style: const TextStyle(color: KeychatColors.textPrimary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 28),
          Container(
            decoration: BoxDecoration(
              color: KeychatColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.block, color: Colors.redAccent),
                  title: Text(l10n.blockFriend, style: const TextStyle(color: Colors.redAccent)),
                  onTap: () => _handleBlock(context),
                ),
                const Divider(height: 1, color: Color(0x14000000)),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: Text(l10n.deleteFriend, style: const TextStyle(color: Colors.redAccent)),
                  onTap: () => _handleDelete(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
