import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/services/ratchet_key.dart';
import 'package:workspace/src/rust/api/attachment.dart' as attachment_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;
import 'package:workspace/src/rust/api/groups.dart' as groups_api;
import 'package:workspace/src/rust/api/keys.dart' as keys_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// A group's message thread — a deliberately simpler cousin of
/// [ChatThreadScreen]: no edit/unsend/reply, since group delivery (see
/// `groups.rs`'s module doc) is already its own trade-off on top of the
/// 1:1 transport. Forward secrecy *is* available per-member, automatically,
/// the same way 1:1 chat gets it — see `sendGroupMessage`'s `ratchetKey`
/// argument below. Attachments (images/files) are supported, delivered the
/// same way a text message is — see `groups.rs`'s `send_group_attachment`.
class GroupThreadScreen extends StatefulWidget {
  const GroupThreadScreen({super.key, required this.group, required this.messageEvents});

  final groups_api.Group group;
  final Stream<sync_api.FriendEvent>? messageEvents;

  @override
  State<GroupThreadScreen> createState() => _GroupThreadScreenState();
}

class _GroupThreadScreenState extends State<GroupThreadScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<groups_api.GroupChatMessage> _messages = [];
  groups_api.Group _group;
  bool _sending = false;
  StreamSubscription<sync_api.FriendEvent>? _sub;

  String? _pendingAttachmentPath;
  String? _pendingAttachmentName;
  String? _pendingAttachmentMimeType;
  double? _uploadProgress;

  _GroupThreadScreenState() : _group = groups_api.Group(id: '', name: '', members: const [], createdAt: 0);

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _load();
    _sub = widget.messageEvents?.listen((event) {
      if ((event.kind == 'group_message' || event.kind == 'group_invite') &&
          event.pubkey == widget.group.id) {
        _load();
        _reloadGroup();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final messages = await groups_api.loadGroupMessages(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: widget.group.id,
    );
    if (!mounted) return;
    setState(() => _messages = messages);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// Re-reads this group's roster from local storage — used after a member
  /// list change (own edit, or a roster event received live) so the member
  /// count in the app bar and the member-list sheet stay current.
  Future<void> _reloadGroup() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final groups = await groups_api.loadGroups(storageDir: storageDir.path);
    final updated = groups.where((g) => g.id == widget.group.id).firstOrNull;
    if (updated != null && mounted) {
      setState(() => _group = updated);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final hasAttachment = _pendingAttachmentPath != null;
    if (!hasAttachment && text.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) {
      setState(() => _sending = false);
      return;
    }
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    try {
      if (hasAttachment) {
        await _sendPendingAttachment(mnemonic, storageDir.path, ratchetKey, text);
      } else {
        await groups_api.sendGroupMessage(
          mnemonic: mnemonic,
          storageDir: storageDir.path,
          groupId: widget.group.id,
          content: text,
          ratchetKey: ratchetKey,
        );
      }
      _controller.clear();
      await _load();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendPendingAttachment(
    String mnemonic,
    String storageDir,
    String? ratchetKey,
    String caption,
  ) async {
    final path = _pendingAttachmentPath!;
    final mimeType = _pendingAttachmentMimeType ?? 'application/octet-stream';
    setState(() => _uploadProgress = 0.0);
    final events = groups_api.sendGroupAttachment(
      mnemonic: mnemonic,
      storageDir: storageDir,
      groupId: widget.group.id,
      filePath: path,
      mimeType: mimeType,
      caption: caption.isEmpty ? null : caption,
      ratchetKey: ratchetKey,
    );
    attachment_api.AttachmentUploadEvent? finalEvent;
    await for (final event in events) {
      if (!mounted) break;
      setState(() => _uploadProgress = event.fraction);
      if (event.done) {
        finalEvent = event;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _uploadProgress = null);
    if (finalEvent?.error == null) {
      setState(() {
        _pendingAttachmentPath = null;
        _pendingAttachmentName = null;
        _pendingAttachmentMimeType = null;
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: ${finalEvent!.error}')));
    }
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles();
    final file = result?.files.singleOrNull;
    if (file?.path == null || !mounted) return;
    setState(() {
      _pendingAttachmentPath = file!.path;
      _pendingAttachmentName = file.name;
      _pendingAttachmentMimeType = lookupMimeType(file.path!) ?? 'application/octet-stream';
    });
  }

  void _removePendingAttachment() {
    setState(() {
      _pendingAttachmentPath = null;
      _pendingAttachmentName = null;
      _pendingAttachmentMimeType = null;
    });
  }

  Future<void> _openMemberList() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final selfUid = await keys_api.getAccountUid(mnemonic: mnemonic);
    final friends = await friends_api.loadFriends(storageDir: storageDir.path);
    final friendUids = friends.map((f) => f.uid).toSet();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _MemberListSheet(
        group: _group,
        selfUid: selfUid,
        friendUids: friendUids,
        onRemove: (uid) => _removeMember(uid),
        onLeave: () => _leaveGroup(sheetContext),
      ),
    );
  }

  Future<void> _removeMember(String memberUid) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    final updated = await groups_api.removeGroupMember(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: widget.group.id,
      memberUid: memberUid,
      ratchetKey: ratchetKey,
    );
    if (!mounted) return;
    setState(() => _group = updated);
  }

  Future<void> _leaveGroup(BuildContext sheetContext) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final ratchetKey = await getOrCreateRatchetKey();
    await groups_api.leaveGroup(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      groupId: widget.group.id,
      ratchetKey: ratchetKey,
    );
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
    if (mounted) {
      // Pop the thread itself back to the group list — the group no longer
      // exists locally, same convention `home.dart` follows after any
      // roster-affecting action.
      Navigator.of(context).pop(true);
    }
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_group.name),
            Text(
              l10n.groupMembersCount(_group.members.length),
              style: const TextStyle(fontSize: 12, color: KeychatColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.people_outline),
            onPressed: _openMemberList,
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final m = _messages[index];
                        return Align(
                          alignment: m.isMine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.75,
                            ),
                            decoration: BoxDecoration(
                              color: m.isMine ? KeychatColors.primary : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!m.isMine)
                                  Text(
                                    m.senderName,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: KeychatColors.textSecondary,
                                    ),
                                  ),
                                if (m.attachment != null) ...[
                                  _GroupAttachmentPreview(groupId: widget.group.id, message: m),
                                  if ((m.attachment!.caption ?? '').isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(m.attachment!.caption!),
                                    ),
                                ] else
                                  Text(m.content),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_pendingAttachmentPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, size: 18, color: KeychatColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _pendingAttachmentName ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: KeychatColors.textSecondary),
                      ),
                    ),
                    if (_uploadProgress != null)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, value: _uploadProgress),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _sending ? null : _removePendingAttachment,
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file, color: KeychatColors.textSecondary),
                    onPressed: _sending ? null : _pickAttachment,
                  ),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: l10n.typeMessageHint,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
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
                      onTap: _sending ? null : _send,
                      child: const Padding(
                        padding: EdgeInsets.all(11),
                        child: Icon(Icons.send, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet listing [group]'s members: display name, whether they're a
/// 1:1 friend vs group-only contact, and whether their direct routing
/// (`group_pubkey`/`device_pubkey`) is established yet. Offers a remove
/// action per non-self member and a "leave group" action.
class _MemberListSheet extends StatelessWidget {
  const _MemberListSheet({
    required this.group,
    required this.selfUid,
    required this.friendUids,
    required this.onRemove,
    required this.onLeave,
  });

  final groups_api.Group group;
  final String selfUid;
  final Set<String> friendUids;
  final void Function(String memberUid) onRemove;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Members (${group.members.length})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: group.members.length,
                itemBuilder: (context, index) {
                  final member = group.members[index];
                  final isSelf = member.uid == selfUid;
                  final isFriend = friendUids.contains(member.uid);
                  final routingEstablished = member.groupPubkey != null || member.devicePubkey != null;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: KeychatColors.primary,
                      child: Text(
                        member.displayName.isNotEmpty ? member.displayName[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(member.displayName.isEmpty ? member.uid : member.displayName),
                    subtitle: Text(
                      [
                        isSelf ? 'You' : (isFriend ? 'Friend' : 'Group-only contact'),
                        routingEstablished ? 'Routing established' : 'Routing pending',
                      ].join(' • '),
                      style: const TextStyle(fontSize: 12, color: KeychatColors.textSecondary),
                    ),
                    trailing: isSelf
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.person_remove_outlined, color: Colors.redAccent),
                            onPressed: () => onRemove(member.uid),
                          ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onLeave,
              icon: const Icon(Icons.logout, color: Colors.redAccent),
              label: const Text('Leave group', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a group message's attachment — mirrors `chat_thread.dart`'s
/// `_AttachmentPreview`, but downloads via `downloadGroupAttachment` (no
/// friend pubkey / NIP-44 unwrap needed — see that function's doc comment).
class _GroupAttachmentPreview extends StatefulWidget {
  const _GroupAttachmentPreview({required this.groupId, required this.message});

  final String groupId;
  final groups_api.GroupChatMessage message;

  @override
  State<_GroupAttachmentPreview> createState() => _GroupAttachmentPreviewState();
}

class _GroupAttachmentPreviewState extends State<_GroupAttachmentPreview> {
  bool _loading = false;
  bool _failed = false;
  String? _localPath;

  bool get _isImage => widget.message.attachment?.mimeType.startsWith('image/') ?? false;

  @override
  void initState() {
    super.initState();
    if (_isImage) _download();
  }

  Future<void> _download() async {
    final attachment = widget.message.attachment;
    if (attachment == null || _loading || _localPath != null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final storageDir = await getApplicationDocumentsDirectory();
    try {
      final path = await groups_api.downloadGroupAttachment(
        storageDir: storageDir.path,
        groupId: widget.groupId,
        messageId: widget.message.id,
        url: attachment.url,
        encKey: attachment.encKey,
      );
      if (!mounted) return;
      setState(() {
        _localPath = path;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.message.attachment;
    if (attachment == null) return const SizedBox.shrink();

    if (_isImage) {
      if (_localPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(File(_localPath!), fit: BoxFit.cover, width: 220, height: 220),
        );
      }
      return Container(
        width: 220,
        height: 220,
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: _failed
              ? IconButton(
                  icon: const Icon(Icons.refresh, color: KeychatColors.textSecondary),
                  onPressed: _download,
                )
              : const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    return InkWell(
      onTap: _localPath == null ? _download : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(
              _localPath != null ? Icons.insert_drive_file_outlined : (_failed ? Icons.error_outline : Icons.download),
              color: KeychatColors.textSecondary,
            ),
          const SizedBox(width: 6),
          Flexible(child: Text(attachment.filename, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}
