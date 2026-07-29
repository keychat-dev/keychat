import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/chat_thread.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/src/rust/api/chat.dart' as chat_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// Talk tab body shown inside the home screen's bottom navigation: one row
/// per friend, with a preview of the most recent message. Tapping a row
/// opens the full thread.
class ChatListTab extends StatefulWidget {
  const ChatListTab({
    super.key,
    required this.friends,
    required this.messageEvents,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onDeleteFriend,
  });

  final List<friends_api.Friend> friends;

  /// Live friend-protocol events (shared with [HomeScreen]'s subscription)
  /// — used to refresh previews when a new message arrives for a friend
  /// not currently open in a thread.
  final Stream<sync_api.FriendEvent>? messageEvents;

  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;

  @override
  State<ChatListTab> createState() => _ChatListTabState();
}

class _ChatListTabState extends State<ChatListTab> {
  final Map<String, chat_api.ChatMessage?> _previews = {};
  final Map<String, int> _unreadCounts = {};
  StreamSubscription<sync_api.FriendEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _loadPreviews();
    _loadUnreadCounts();
    _subscribe();
  }

  void _subscribe() {
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind == 'message') {
        _loadPreviewFor(event.pubkey);
        _loadUnreadCounts();
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatListTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.friends != widget.friends) {
      _loadPreviews();
      _loadUnreadCounts();
    }
    if (oldWidget.messageEvents != widget.messageEvents) {
      _sub?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadPreviews() async {
    for (final friend in widget.friends) {
      unawaited(_loadPreviewFor(friend.pubkey));
    }
  }

  Future<void> _loadPreviewFor(String friendPubkey) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final history = await chat_api.loadChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: friendPubkey,
    );
    if (!mounted) return;
    setState(() => _previews[friendPubkey] = history.isEmpty ? null : history.last);
  }

  Future<void> _loadUnreadCounts() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || widget.friends.isEmpty) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final counts = await chat_api.loadUnreadCounts(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkeys: widget.friends.map((f) => f.pubkey).toList(),
    );
    if (!mounted) return;
    setState(() {
      for (final c in counts) {
        _unreadCounts[c.friendPubkey] = c.count.toInt();
      }
    });
  }

  Future<void> _openThread(friends_api.Friend friend) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          friend: friend,
          messageEvents: widget.messageEvents,
          onToggleFavorite: widget.onToggleFavorite,
          onBlockFriend: widget.onBlockFriend,
          onDeleteFriend: widget.onDeleteFriend,
        ),
      ),
    );
    _loadUnreadCounts();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: KeychatColors.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.noChatsYet,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: KeychatColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.noChatsHint,
              style: TextStyle(
                fontSize: 13,
                color: KeychatColors.textSecondary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: widget.friends.length,
      separatorBuilder: (context, index) => const Divider(
        height: 1,
        indent: 82,
        color: Color(0x14000000),
      ),
      itemBuilder: (context, index) {
        final friend = widget.friends[index];
        final preview = _previews[friend.pubkey];
        final unread = _unreadCounts[friend.pubkey] ?? 0;
        final hasAvatar = friend.avatarPath != null && File(friend.avatarPath!).existsSync();
        return InkWell(
          onTap: () => _openThread(friend),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: KeychatColors.surface,
                  backgroundImage: hasAvatar ? FileImage(File(friend.avatarPath!)) : null,
                  child: hasAvatar
                      ? null
                      : const Icon(Icons.person_outline, color: KeychatColors.textSecondary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        friend.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: KeychatColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        preview?.content ?? l10n.noMessagesYet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: unread > 0 ? KeychatColors.textPrimary : KeychatColors.textSecondary,
                          fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (preview != null)
                      Text(
                        _formatPreviewTime(preview.createdAt.toInt()),
                        style: TextStyle(
                          fontSize: 12,
                          color: unread > 0
                              ? KeychatColors.primaryDark
                              : KeychatColors.textSecondary.withValues(alpha: 0.8),
                          fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    const SizedBox(height: 6),
                    if (unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        constraints: const BoxConstraints(minWidth: 20),
                        decoration: BoxDecoration(
                          color: KeychatColors.primaryDark,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          unread >= 99 ? '99+' : '$unread',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatPreviewTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }
}
