import 'package:flutter/material.dart';
import 'package:workspace/nav_bar.dart';
import 'package:workspace/screens/chat_list.dart';
import 'package:workspace/screens/edit_profile.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/profile_friends.dart';
import 'package:workspace/screens/public_chat_list.dart';
import 'package:workspace/screens/settings.dart';
import 'package:workspace/src/rust/api/profile.dart' as profile_api;

/// Home screen shown after profile setup. Hosts the three main sections of
/// the app behind a bottom navigation bar: Profile & Friends, Talk, and
/// Public Chat.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.profile,
    required this.onSelectLanguage,
    required this.onPurgeAccount,
  });

  final profile_api.Profile profile;
  final ValueChanged<Locale> onSelectLanguage;
  final VoidCallback onPurgeAccount;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 1;
  late profile_api.Profile _profile = widget.profile;

  // TODO: replace with the real friends list once friend persistence exists.
  final List<String> _friends = [];

  Future<void> _editProfile() async {
    final updated = await Navigator.of(context).push<profile_api.Profile>(
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: _profile)),
    );
    if (updated == null) return;
    setState(() => _profile = updated);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          profile: _profile,
          onProfileUpdated: (updated) => setState(() => _profile = updated),
          onSelectLanguage: widget.onSelectLanguage,
          onPurgeAccount: widget.onPurgeAccount,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      ProfileFriendsTab(
        profile: _profile,
        hasFriends: _friends.isNotEmpty,
        onEditProfile: _editProfile,
      ),
      ChatListTab(displayName: _profile.displayName),
      const PublicChatListTab(),
    ];

    return Scaffold(
      backgroundColor: KeychatColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _HomeTopBar(onSettingsTap: _openSettings),
            Expanded(child: tabs[_selectedIndex]),
          ],
        ),
      ),
      bottomNavigationBar: KeychatNavBar(
        selectedIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
      ),
    );
  }
}

/// Right-aligned bar of icon actions shown above the tab content, regardless
/// of which tab is selected: announcements, add friend, settings.
class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({required this.onSettingsTap});

  final VoidCallback onSettingsTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _topBarIcon(Icons.notifications_outlined, () {}),
          const SizedBox(width: 12),
          _topBarIcon(Icons.person_add_alt_outlined, () {}),
          const SizedBox(width: 12),
          _topBarIcon(Icons.settings_outlined, onSettingsTap),
        ],
      ),
    );
  }

  Widget _topBarIcon(IconData icon, VoidCallback onPressed) {
    return InkResponse(
      // TODO: wire up announcements / add-friend / settings actions.
      onTap: onPressed,
      radius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Icon(icon, color: KeychatColors.textSecondary),
      ),
    );
  }
}
