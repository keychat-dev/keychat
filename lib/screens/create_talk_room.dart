import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/friends.dart' as friends_api;

/// Friend picker for "Create talk room" (Talk tab's "+" menu): a searchable,
/// full-screen list rather than a bottom sheet, since a long friends list
/// needs room to scroll and a way to jump to a name quickly. Pops with the
/// selected [friends_api.Friend], or `null` if the user backs out.
class CreateTalkRoomScreen extends StatefulWidget {
  const CreateTalkRoomScreen({super.key, required this.friends});

  final List<friends_api.Friend> friends;

  @override
  State<CreateTalkRoomScreen> createState() => _CreateTalkRoomScreenState();
}

class _CreateTalkRoomScreenState extends State<CreateTalkRoomScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filtered = _query.isEmpty
        ? widget.friends
        : widget.friends
              .where((f) => f.displayName.toLowerCase().contains(_query))
              .toList();

    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.createTalkRoom),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: l10n.searchByNameHint,
                  prefixIcon: const Icon(Icons.search, color: KeychatColors.textSecondary),
                  filled: true,
                  fillColor: KeychatColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
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
                  : filtered.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noSearchResults,
                        style: const TextStyle(color: KeychatColors.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, indent: 72, color: Color(0x14000000)),
                      itemBuilder: (context, index) {
                        final friend = filtered[index];
                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: KeychatColors.surface,
                            child: Icon(Icons.person_outline, color: KeychatColors.textSecondary),
                          ),
                          title: Text(friend.displayName),
                          subtitle: friend.statusMessage.isEmpty
                              ? null
                              : Text(
                                  friend.statusMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => Navigator.of(context).pop(friend),
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
