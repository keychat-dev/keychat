import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/chat_thread.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/chat.dart' as chat_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// A friend's profile and the relays they publish to, with actions to
/// favorite/block/delete them. Shared between the friends list (tapping a
/// row) and a chat thread (tapping the friend's name/avatar in the app
/// bar), so both entry points stay in sync on one implementation.
///
/// Blocking is reversible: a blocked friend stays in the friends list
/// (their messages/profile updates are just silently dropped) and can be
/// unblocked from here. Deleting is only offered while already blocked —
/// blocking first ensures nothing incoming gets applied for the friend
/// mid-deletion, and gives the user a way back (unblock) before they
/// commit to the irreversible delete.
///
/// Pops with `true` only when the friend was deleted (irreversible) —
/// callers still showing that friend (e.g. an open chat thread) should pop
/// themselves too, since the friend no longer exists. Blocking/unblocking
/// update this screen in place instead, since the friend isn't gone.
class FriendProfileScreen extends StatefulWidget {
  const FriendProfileScreen({
    super.key,
    required this.friend,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onUnblockFriend,
    required this.onDeleteFriend,
    required this.onClearChat,
    this.messageEvents,
  });

  final friends_api.Friend friend;
  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;
  final Future<void> Function(friends_api.Friend friend) onClearChat;

  /// Live friend-protocol events, passed through to the chat thread opened
  /// by the "Talk" button — used there to append incoming messages without
  /// polling.
  final Stream<sync_api.FriendEvent>? messageEvents;

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  late bool _isFavorite = widget.friend.isFavorite;
  late bool _isBlocked = widget.friend.isBlocked;

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

  Future<void> _handleStartChat(BuildContext context) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await chat_api.markChatStarted(storageDir: storageDir.path, friendPubkey: friend.pubkey);
    unawaited(publishAccountChatStartedBackup());
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          friend: friend,
          messageEvents: widget.messageEvents,
          onToggleFavorite: widget.onToggleFavorite,
          onBlockFriend: widget.onBlockFriend,
          onUnblockFriend: widget.onUnblockFriend,
          onDeleteFriend: widget.onDeleteFriend,
          onClearChat: widget.onClearChat,
        ),
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
    setState(() => _isBlocked = true);
    await widget.onBlockFriend(friend);
  }

  Future<void> _copyUid(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: friend.uid));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.uidCopiedMessage)));
  }

  Future<void> _handleUnblock() async {
    setState(() => _isBlocked = false);
    await widget.onUnblockFriend(friend);
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
          if (friend.uid.isNotEmpty) ...[
            const SizedBox(height: 8),
            Center(
              child: InkWell(
                onTap: () => _copyUid(context),
                child: Text(
                  '${l10n.uidLabel}: ${friend.uid.substring(0, friend.uid.length > 16 ? 16 : friend.uid.length)}...',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: KeychatColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: () => _handleStartChat(context),
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(l10n.startChat),
            style: ElevatedButton.styleFrom(
              backgroundColor: KeychatColors.primaryDark,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
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
              children: _isBlocked
                  ? [
                      ListTile(
                        leading: const Icon(Icons.lock_open_outlined, color: KeychatColors.primaryDark),
                        title: Text(
                          l10n.unblockFriend,
                          style: const TextStyle(color: KeychatColors.primaryDark),
                        ),
                        onTap: _handleUnblock,
                      ),
                      const Divider(height: 1, color: Color(0x14000000)),
                      ListTile(
                        leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        title: Text(l10n.deleteFriend, style: const TextStyle(color: Colors.redAccent)),
                        onTap: () => _handleDelete(context),
                      ),
                    ]
                  : [
                      ListTile(
                        leading: const Icon(Icons.block, color: Colors.redAccent),
                        title: Text(l10n.blockFriend, style: const TextStyle(color: Colors.redAccent)),
                        onTap: () => _handleBlock(context),
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
