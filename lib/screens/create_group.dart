import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/friends.dart' as friends_api;

/// "Create group" from the Talk tab's "+" menu: a group name field plus a
/// multi-select friend list. Pops with `(name, selectedPubkeys)`, or `null`
/// if the user backs out. Group members can only be picked from the local
/// friends list — see `groups.rs`'s module doc for why a group member has
/// to already be a friend for delivery to work at all.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key, required this.friends});

  final List<friends_api.Friend> friends;

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;
    Navigator.of(context).pop((name, _selected.toList()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canSubmit = _nameController.text.trim().isNotEmpty && _selected.isNotEmpty;
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.createGroup),
        actions: [
          TextButton(
            onPressed: canSubmit ? _submit : null,
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _nameController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l10n.groupNameLabel,
                  filled: true,
                  fillColor: KeychatColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.selectMembersLabel,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: KeychatColors.textSecondary,
                  ),
                ),
              ),
            ),
            Expanded(
              child: widget.friends.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noFriendsYet,
                        style: const TextStyle(color: KeychatColors.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: widget.friends.length,
                      itemBuilder: (context, index) {
                        final friend = widget.friends[index];
                        final checked = _selected.contains(friend.pubkey);
                        return CheckboxListTile(
                          value: checked,
                          onChanged: (value) => setState(() {
                            if (value ?? false) {
                              _selected.add(friend.pubkey);
                            } else {
                              _selected.remove(friend.pubkey);
                            }
                          }),
                          controlAffinity: ListTileControlAffinity.leading,
                          secondary: const CircleAvatar(
                            backgroundColor: KeychatColors.surface,
                            child: Icon(Icons.person_outline, color: KeychatColors.textSecondary),
                          ),
                          title: Text(friend.displayName),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
