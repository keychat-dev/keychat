import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/friend_profile.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/chat.dart' as chat_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// WhatsApp-style chat wallpaper and bubble colors, layered on top of the
/// app's greige palette rather than replacing it elsewhere.
class _WaColors {
  static const wallpaper = Color(0xFFE9DFCF);
  static const bubbleMine = Color(0xFFD9C9AC);
  static const bubbleTheirs = Color(0xFFFFFFFF);
}

/// One-to-one chat thread with [friend]: message history plus an input bar.
/// Sending re-reads the full history from local storage afterward (it's a
/// small per-friend dataset) rather than optimistically patching state, so
/// what's shown always matches what [chat_api.sendChatMessage] persisted.
class ChatThreadScreen extends StatefulWidget {
  const ChatThreadScreen({
    super.key,
    required this.friend,
    required this.messageEvents,
    required this.onToggleFavorite,
    required this.onBlockFriend,
    required this.onUnblockFriend,
    required this.onDeleteFriend,
    required this.onClearChat,
  });

  final friends_api.Friend friend;

  /// Live friend-protocol events shared with [HomeScreen]'s subscription —
  /// used to append incoming messages for this friend without polling.
  final Stream<sync_api.FriendEvent>? messageEvents;

  final Future<void> Function(friends_api.Friend friend) onToggleFavorite;
  final Future<void> Function(friends_api.Friend friend) onBlockFriend;
  final Future<void> Function(friends_api.Friend friend) onUnblockFriend;
  final Future<void> Function(friends_api.Friend friend) onDeleteFriend;
  final Future<void> Function(friends_api.Friend friend) onClearChat;

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  List<chat_api.ChatMessage> _messages = [];
  bool _sending = false;
  late bool _isBlocked = widget.friend.isBlocked;
  int _maxMessageChars = 4000;
  StreamSubscription<sync_api.FriendEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _subscribe();
    chat_api.maxMessageChars().then((max) {
      if (mounted) setState(() => _maxMessageChars = max);
    });
  }

  Future<void> _handleBlock(friends_api.Friend friend) async {
    setState(() => _isBlocked = true);
    await widget.onBlockFriend(friend);
  }

  Future<void> _handleUnblock(friends_api.Friend friend) async {
    setState(() => _isBlocked = false);
    await widget.onUnblockFriend(friend);
  }

  void _subscribe() {
    _sub = widget.messageEvents?.listen((event) {
      if (event.kind == 'message' && event.pubkey == widget.friend.pubkey) {
        _loadHistory();
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageEvents != widget.messageEvents) {
      _sub?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final history = await chat_api.loadChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: widget.friend.pubkey,
    );
    if (!mounted) return;
    setState(() => _messages = history);
    _scrollToBottom();
    await chat_api.markThreadRead(storageDir: storageDir.path, friendPubkey: widget.friend.pubkey);
    unawaited(publishAccountReadStateBackup());
  }

  Future<void> _openProfile(BuildContext context) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(
          friend: widget.friend,
          onToggleFavorite: widget.onToggleFavorite,
          onBlockFriend: _handleBlock,
          onUnblockFriend: _handleUnblock,
          onDeleteFriend: widget.onDeleteFriend,
          onClearChat: widget.onClearChat,
          messageEvents: widget.messageEvents,
        ),
      ),
    );
    if (removed == true && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _clearChat(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.clearChatConfirmTitle),
        content: Text(l10n.clearChatConfirmBody(widget.friend.displayName)),
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
    await widget.onClearChat(widget.friend);
    if (!context.mounted) return;
    setState(() => _messages = []);
    Navigator.of(context).pop();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  /// Asks whether to unblock so the pending message can go out — shown
  /// when the user tries to send while [_isBlocked] is true, rather than
  /// silently failing (the Rust side also rejects the send either way).
  Future<bool> _confirmUnblockToSend() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.blockedSendConfirmTitle),
        content: Text(l10n.blockedSendConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.unblockFriend),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await _handleUnblock(widget.friend);
    return true;
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending || text.runes.length > _maxMessageChars) return;
    if (_isBlocked) {
      final unblocked = await _confirmUnblockToSend();
      if (!unblocked || !mounted) return;
    }
    setState(() => _sending = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic != null) {
      final storageDir = await getApplicationDocumentsDirectory();
      try {
        await chat_api.sendChatMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          friendPubkey: widget.friend.pubkey,
          message: text,
        );
        _messageController.clear();
        await _loadHistory();
      } catch (_) {
        // Offline or every relay unreachable — leave the draft in the
        // field so the user can retry.
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasAvatar =
        widget.friend.avatarPath != null && File(widget.friend.avatarPath!).existsSync();
    return Scaffold(
      backgroundColor: _WaColors.wallpaper,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        titleSpacing: 0,
        title: InkWell(
          onTap: () => _openProfile(context),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: KeychatColors.surface,
                backgroundImage: hasAvatar ? FileImage(File(widget.friend.avatarPath!)) : null,
                child: hasAvatar
                    ? null
                    : const Icon(Icons.person_outline, size: 18, color: KeychatColors.textSecondary),
              ),
              const SizedBox(width: 10),
              Text(widget.friend.displayName),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: l10n.clearChatButton,
            onPressed: () => _clearChat(context),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noMessagesYet,
                        style: const TextStyle(color: KeychatColors.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        final previous = index > 0 ? _messages[index - 1] : null;
                        final startOfGroup = previous == null || previous.isMine != message.isMine;
                        return _MessageBubble(
                          message: message,
                          showTail: startOfGroup,
                          friendAvatarPath: widget.friend.avatarPath,
                          onAvatarTap: () => _openProfile(context),
                        );
                      },
                    ),
            ),
            _Composer(
              controller: _messageController,
              sending: _sending,
              onSend: _send,
              hint: l10n.typeMessageHint,
              maxLength: _maxMessageChars,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showTail,
    required this.friendAvatarPath,
    required this.onAvatarTap,
  });

  final chat_api.ChatMessage message;
  final bool showTail;
  final String? friendAvatarPath;
  final VoidCallback onAvatarTap;

  String _formatTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final isMine = message.isMine;
    final bubbleColor = isMine ? _WaColors.bubbleMine : _WaColors.bubbleTheirs;
    final radius = const Radius.circular(12);
    final tailRadius = const Radius.circular(2);

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: radius,
          topRight: radius,
          bottomLeft: !isMine && showTail ? tailRadius : radius,
          bottomRight: isMine && showTail ? tailRadius : radius,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x14000000), blurRadius: 1, offset: Offset(0, 1)),
        ],
      ),
      child: Text(
        message.content,
        style: const TextStyle(color: KeychatColors.textPrimary, fontSize: 15.5, height: 1.3),
      ),
    );

    final time = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        _formatTime(message.createdAt.toInt()),
        style: TextStyle(
          fontSize: 11,
          color: KeychatColors.textSecondary.withValues(alpha: 0.8),
        ),
      ),
    );

    final hasAvatar = friendAvatarPath != null && File(friendAvatarPath!).existsSync();
    final avatar = SizedBox(
      width: 28,
      height: 28,
      child: showTail
          ? GestureDetector(
              onTap: onAvatarTap,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: KeychatColors.surface,
                backgroundImage: hasAvatar ? FileImage(File(friendAvatarPath!)) : null,
                child: hasAvatar
                    ? null
                    : const Icon(Icons.person_outline, size: 14, color: KeychatColors.textSecondary),
              ),
            )
          : null,
    );

    return Container(
      margin: EdgeInsets.only(
        top: showTail ? 6 : 2,
        bottom: 2,
        left: isMine ? 40 : 4,
        right: isMine ? 4 : 40,
      ),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.max,
        children: isMine
            ? [time, bubble]
            : [avatar, const SizedBox(width: 4), bubble, time],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.hint,
    required this.maxLength,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final String hint;
  final int maxLength;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final length = controller.text.runes.length;
        final overLimit = length > maxLength;
        final nearLimit = !overLimit && length > maxLength * 0.9;
        final warnColor = overLimit ? Colors.redAccent : Colors.orange;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: (overLimit || nearLimit) ? Border.all(color: warnColor, width: 1.5) : null,
                    boxShadow: const [
                      BoxShadow(color: Color(0x11000000), blurRadius: 2, offset: Offset(0, 1)),
                    ],
                  ),
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: maxLength,
                    maxLengthEnforcement: MaxLengthEnforcement.none,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: InputDecoration(
                      hintText: hint,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                      counterText: (overLimit || nearLimit) ? '$length/$maxLength' : '',
                      counterStyle: TextStyle(color: warnColor, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: KeychatColors.primaryDark,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: (sending || overLimit) ? null : onSend,
                  child: const Padding(
                    padding: EdgeInsets.all(11),
                    child: Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
