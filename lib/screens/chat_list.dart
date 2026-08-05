import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/chat_thread.dart';
import 'package:workspace/screens/group_thread.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/services/ratchet_key.dart';
import 'package:workspace/src/rust/api/chat.dart' as chat_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;
import 'package:workspace/src/rust/api/groups.dart' as groups_api;
import 'package:workspace/src/rust/api/ratchet.dart' as ratchet_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// Talk tab body shown inside the home screen's bottom navigation: one row
/// per friend (plus one per group), with a preview of the most recent
/// message. Tapping a row opens the full thread.
class ChatListTab extends StatefulWidget {
  const ChatListTab({
    super.key,
    required this.friends,
    required this.groups,
    required this.messageEvents,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onUnblockFriend,
    required this.onDeleteFriend,
    required this.onClearChat,
    required this.onGroupsChanged,
    required this.unreadCounts,
    required this.onUnreadCountsChanged,
  });

  final List<friends_api.Friend> friends;
  final List<groups_api.Group> groups;

  /// Live friend-protocol events (shared with [HomeScreen]'s subscription)
  /// — used to refresh previews when a new message arrives for a friend
  /// not currently open in a thread.
  final Stream<sync_api.FriendEvent>? messageEvents;

  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;
  final Future<void> Function(friends_api.Friend friend) onClearChat;

  /// Called after returning from a group thread — reloads `home.dart`'s
  /// group list, so a roster change made inside the thread (e.g. leaving
  /// the group, which deletes it locally) is reflected here immediately.
  final Future<void> Function() onGroupsChanged;

  /// Per-friend unread counts, computed and owned by `home.dart` (not here)
  /// so they stay correct even while this tab isn't mounted — see that
  /// field's doc comment for why. Read directly for each row's badge.
  final Map<String, int> unreadCounts;

  /// Triggers `home.dart`'s fetch behind [unreadCounts] — call after
  /// anything here that could change read state (opening or clearing a
  /// thread) instead of computing a local copy.
  final Future<void> Function() onUnreadCountsChanged;

  @override
  State<ChatListTab> createState() => _ChatListTabState();
}

class _ChatListTabState extends State<ChatListTab> {
  final Map<String, chat_api.ChatMessage?> _previews = {};
  final Map<String, groups_api.GroupChatMessage?> _groupPreviews = {};
  StreamSubscription<sync_api.FriendEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _loadPreviews();
    _loadGroupPreviews();
    _subscribe();
  }

  void _subscribe() {
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind == 'message' || event.kind == 'ratchet_message') {
        _loadPreviewFor(event.pubkey);
      } else if (event.kind == 'group_message' || event.kind == 'group_invite') {
        _loadGroupPreviewFor(event.pubkey);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatListTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.friends != widget.friends) {
      _loadPreviews();
    }
    if (oldWidget.groups != widget.groups) {
      _loadGroupPreviews();
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
    // Forward-secret (ratchet) messages live outside `chat.lmdb` (see
    // `ratchet.rs`'s module doc — same reason `chat_thread.dart`'s
    // `_mergeWithRatchetHistory` merges it in), so the newest message for
    // this friend may only exist there, not in `history`.
    final ratchetKey = await getOrCreateRatchetKey();
    if (!mounted) return;
    final ratchetMessages = await ratchet_api.loadRatchetHistory(
      storageDir: storageDir.path,
      localKey: ratchetKey,
      friendPubkey: friendPubkey,
    );
    if (!mounted) return;
    chat_api.ChatMessage? latest = history.isEmpty ? null : history.last;
    if (ratchetMessages.isNotEmpty) {
      final latestRatchet = ratchetMessages.last;
      if (latest == null || latestRatchet.createdAt.toInt() > latest.createdAt.toInt()) {
        latest = chat_api.ChatMessage(
          id: latestRatchet.id,
          senderPubkey: latestRatchet.isMine ? '' : friendPubkey,
          content: latestRatchet.content,
          createdAt: latestRatchet.createdAt,
          isMine: latestRatchet.isMine,
          isEdited: false,
          isDeleted: latestRatchet.isDeleted,
          replyTo: null,
          attachment: null,
        );
      }
    }
    if (!mounted) return;
    setState(() => _previews[friendPubkey] = latest);
  }

  Future<void> _loadGroupPreviews() async {
    for (final group in widget.groups) {
      unawaited(_loadGroupPreviewFor(group.id));
    }
  }

  Future<void> _loadGroupPreviewFor(String groupId) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final history = await groups_api.loadGroupMessages(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: groupId,
    );
    if (!mounted) return;
    setState(() => _groupPreviews[groupId] = history.isEmpty ? null : history.last);
  }

  Future<void> _openGroupThread(groups_api.Group group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupThreadScreen(group: group, messageEvents: widget.messageEvents),
      ),
    );
    await widget.onGroupsChanged();
    _loadGroupPreviewFor(group.id);
  }

  Future<void> _openThread(friends_api.Friend friend) async {
    await Navigator.of(context).push(
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
    unawaited(widget.onUnreadCountsChanged());
  }

  /// Long-press on a row: shows a small menu with "Clear chat", which then
  /// asks for confirmation before actually wiping the local history.
  Future<void> _showChatMenu(friends_api.Friend friend) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(friend.displayName),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('clear'),
            child: Row(
              children: [
                const Icon(Icons.delete_outline, color: Colors.redAccent),
                const SizedBox(width: 12),
                Text(l10n.clearChatButton, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        ],
      ),
    );
    if (action != 'clear' || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.clearChatConfirmTitle),
        content: Text(l10n.clearChatConfirmBody(friend.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(l10n.clearChatButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onClearChat(friend);
    if (!mounted) return;
    setState(() => _previews.remove(friend.pubkey));
    unawaited(widget.onUnreadCountsChanged());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.friends.isEmpty && widget.groups.isEmpty) {
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
      itemCount: widget.groups.length + widget.friends.length,
      separatorBuilder: (context, index) => const Divider(
        height: 1,
        indent: 82,
        color: Color(0x14000000),
      ),
      itemBuilder: (context, index) {
        if (index < widget.groups.length) {
          final group = widget.groups[index];
          final preview = _groupPreviews[group.id];
          return InkWell(
            onTap: () => _openGroupThread(group),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 28,
                    backgroundColor: KeychatColors.surface,
                    child: Icon(Icons.groups_outlined, color: KeychatColors.textSecondary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
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
                          preview == null
                              ? l10n.noMessagesYet
                              : (preview.isMine ? '${l10n.youLabel}: ' : '${preview.senderName}: ') +
                                    preview.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: KeychatColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final friend = widget.friends[index - widget.groups.length];
        final preview = _previews[friend.pubkey];
        final unread = widget.unreadCounts[friend.pubkey] ?? 0;
        final hasAvatar = friend.avatarPath != null && File(friend.avatarPath!).existsSync();
        return InkWell(
          onTap: () => _openThread(friend),
          onLongPress: () => _showChatMenu(friend),
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
                        preview == null
                            ? l10n.noMessagesYet
                            : (preview.isDeleted ? l10n.messageUnsentLabel : preview.content),
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
