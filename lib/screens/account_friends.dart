import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/account.dart' as account_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;

/// Profile & Friends tab: shows the local display profile at the top and the
/// friends list below.
class AccountFriendsTab extends StatelessWidget {
  const AccountFriendsTab({
    super.key,
    required this.profile,
    required this.friends,
    required this.onEditProfile,
    required this.onAddFriend,
    required this.onRefreshFriends,
  });

  final account_api.Account profile;
  final List<friends_api.Friend> friends;
  final VoidCallback onEditProfile;
  final VoidCallback onAddFriend;

  /// Re-checks whether any outgoing friend requests have been accepted and
  /// reloads the friends list — triggered by pull-to-refresh, so accepted
  /// requests show up without needing to restart the app.
  final Future<void> Function() onRefreshFriends;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProfileCard(profile: profile, onEdit: onEditProfile),
          const SizedBox(height: 24),
          if (friends.isEmpty) ...[
            _AddFriendButton(label: l10n.addFriendByQr, onTap: onAddFriend),
            const SizedBox(height: 24),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.friendsSectionTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: KeychatColors.textSecondary,
                ),
              ),
              if (friends.isNotEmpty)
                IconButton(
                  onPressed: onAddFriend,
                  icon: const Icon(
                    Icons.person_add_alt_outlined,
                    size: 20,
                    color: KeychatColors.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: RefreshIndicator(
              onRefresh: onRefreshFriends,
              child: friends.isEmpty
                  ? const _EmptyFriendsList()
                  : _FriendsList(friends: friends),
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendsList extends StatelessWidget {
  const _FriendsList({required this.friends});

  final List<friends_api.Friend> friends;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView.builder(
      itemCount: friends.length,
      itemBuilder: (context, index) {
        final friend = friends[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: KeychatColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: KeychatColors.background,
              backgroundImage:
                  friend.avatarPath != null &&
                      File(friend.avatarPath!).existsSync()
                  ? FileImage(File(friend.avatarPath!))
                  : null,
              child: friend.avatarPath != null && File(friend.avatarPath!).existsSync()
                  ? null
                  : const Icon(
                      Icons.person_outline,
                      color: KeychatColors.textSecondary,
                    ),
            ),
            title: Text(friend.displayName),
            subtitle: Text(
              friend.statusMessage.isNotEmpty
                  ? friend.statusMessage
                  : l10n.noStatusMessage,
              style: const TextStyle(color: KeychatColors.textSecondary),
            ),
          ),
        );
      },
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.onEdit});

  final account_api.Account profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final avatarPath = profile.avatarPath;
    final statusMessage = profile.statusMessage.isNotEmpty
        ? profile.statusMessage
        : l10n.noStatusMessage;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KeychatColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: KeychatColors.background,
              borderRadius: BorderRadius.circular(18),
            ),
            child: avatarPath != null && File(avatarPath).existsSync()
                ? Image.file(File(avatarPath), fit: BoxFit.cover)
                : const Icon(
                    Icons.person_outline,
                    size: 32,
                    color: KeychatColors.textSecondary,
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.displayName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: KeychatColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  statusMessage,
                  style: TextStyle(
                    fontSize: 13,
                    color: profile.statusMessage.isNotEmpty
                        ? KeychatColors.textSecondary
                        : KeychatColors.textSecondary.withValues(alpha: 0.6),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            tooltip: l10n.editProfile,
            icon: const Icon(
              Icons.edit_outlined,
              size: 20,
              color: KeychatColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddFriendButton extends StatelessWidget {
  const _AddFriendButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.qr_code_2, size: 22),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: KeychatColors.primaryDark,
          side: const BorderSide(color: KeychatColors.primary, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _EmptyFriendsList extends StatelessWidget {
  const _EmptyFriendsList();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: 320,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.group_outlined,
                  size: 48,
                  color: KeychatColors.textSecondary.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.noFriendsYet,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: KeychatColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.noFriendsHint,
                  style: TextStyle(
                    fontSize: 13,
                    color: KeychatColors.textSecondary.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
