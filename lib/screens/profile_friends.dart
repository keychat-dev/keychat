import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/profile.dart' as profile_api;

/// Profile & Friends tab: shows the local display profile at the top and the
/// friends list below. Layout mock — edit / add-friend actions are not wired
/// up yet, and the friends list is always the empty state for now.
class ProfileFriendsTab extends StatelessWidget {
  const ProfileFriendsTab({
    super.key,
    required this.profile,
    required this.hasFriends,
    required this.onEditProfile,
  });

  final profile_api.Profile profile;

  // The QR add-friend button is only useful before the user has any
  // friends yet; once at least one friend exists it's hidden here.
  final bool hasFriends;

  final VoidCallback onEditProfile;

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
          if (!hasFriends) ...[
            _AddFriendButton(label: l10n.addFriendByQr),
            const SizedBox(height: 24),
          ],
          Text(
            l10n.friendsSectionTitle,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: KeychatColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          const Expanded(child: _EmptyFriendsList()),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.onEdit});

  final profile_api.Profile profile;
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
  const _AddFriendButton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        // TODO: wire up QR-based key exchange for adding a friend.
        onPressed: () {},
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
    return Center(
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
    );
  }
}
