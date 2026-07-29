import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/nav_bar.dart';
import 'package:workspace/screens/add_friend.dart';
import 'package:workspace/screens/chat_list.dart';
import 'package:workspace/screens/edit_profile.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/screens/account_friends.dart';
import 'package:workspace/screens/public_chat_list.dart';
import 'package:workspace/screens/settings.dart';
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/account.dart' as account_api;
import 'package:workspace/src/rust/api/friends.dart' as friends_api;
import 'package:workspace/src/rust/api/sync.dart' as sync_api;

/// Home screen shown after profile setup. Hosts the three main sections of
/// the app behind a bottom navigation bar: Profile & Friends, Talk, and
/// Public Chat.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.profile,
    required this.onSelectLanguage,
    required this.onLogout,
  });

  final account_api.Account profile;
  final ValueChanged<Locale> onSelectLanguage;
  final VoidCallback onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _selectedIndex = 1;
  late account_api.Account _profile = widget.profile;

  List<friends_api.Friend> _friends = [];
  int _pendingRequestCount = 0;
  StreamSubscription<sync_api.FriendEvent>? _friendEventsSub;
  Stream<sync_api.FriendEvent>? _friendEventsStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFriends();
    _refreshPendingRequestCount();
    _subscribeFriendEvents();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _friendEventsSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS suspends the relay connection while backgrounded, so pick it
    // back up (and catch anything missed) when the app is foregrounded again.
    if (state == AppLifecycleState.resumed) {
      _refreshPendingRequestCount();
      _refreshFriends();
      _subscribeFriendEvents();
    }
  }

  /// Opens a live connection to this account's relays so incoming friend
  /// requests and acceptances show up immediately, without polling.
  /// Cancels and reopens any existing subscription — call again after the
  /// set of invites/outgoing requests may have changed.
  Future<void> _subscribeFriendEvents() async {
    await _friendEventsSub?.cancel();
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null || !mounted) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final stream = sync_api
        .subscribeFriendEvents(mnemonic: mnemonic, storageDir: storageDir.path)
        .asBroadcastStream();
    setState(() => _friendEventsStream = stream);
    _friendEventsSub = stream.listen((event) {
      if (event.kind == 'accepted' || event.kind == 'profile_updated') {
        _loadFriends();
      } else if (event.kind == 'request') {
        _refreshPendingRequestCount();
      }
    });
  }

  Future<void> _refreshPendingRequestCount() async {
    final count = await pendingFriendRequestCount();
    if (!mounted) return;
    setState(() => _pendingRequestCount = count);
  }

  Future<void> _loadFriends() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final friends = await friends_api.loadFriends(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() => _friends = friends);
  }

  /// Pull-to-refresh: just re-reads the local friends list. The live
  /// subscription (started in [_subscribeFriendEvents]) keeps it current —
  /// on reconnect, relays replay any events missed while the app was
  /// closed, so no separate relay round-trip is needed here.
  Future<void> _refreshFriends() async {
    await _loadFriends();
  }

  Future<void> _toggleFavorite(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.setFavoriteFriend(
      storageDir: storageDir.path,
      pubkey: friend.pubkey,
      isFavorite: !friend.isFavorite,
    );
    await _loadFriends();
  }

  Future<void> _blockFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.removeFriend(storageDir: storageDir.path, pubkey: friend.pubkey);
    await friends_api.blockPubkey(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
  }

  Future<void> _deleteFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.removeFriend(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
  }

  Future<void> _editProfile() async {
    final updated = await Navigator.of(context).push<account_api.Account>(
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: _profile)),
    );
    if (updated == null) return;
    setState(() => _profile = updated);
  }

  Future<void> _openAddFriend() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AddFriendScreen()));
    _refreshFriends();
    _refreshPendingRequestCount();
    // A new invite or outgoing request may have been created — resubscribe
    // so the live connection watches for it too.
    _subscribeFriendEvents();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          profile: _profile,
          onProfileUpdated: (updated) => setState(() => _profile = updated),
          onSelectLanguage: widget.onSelectLanguage,
          onLogout: widget.onLogout,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      AccountFriendsTab(
        profile: _profile,
        friends: _friends,
        onEditProfile: _editProfile,
        onAddFriend: _openAddFriend,
        onRefreshFriends: _refreshFriends,
        onToggleFavorite: _toggleFavorite,
        onBlockFriend: _blockFriend,
        onDeleteFriend: _deleteFriend,
      ),
      ChatListTab(
        friends: _friends,
        messageEvents: _friendEventsStream,
        onToggleFavorite: _toggleFavorite,
        onBlockFriend: _blockFriend,
        onDeleteFriend: _deleteFriend,
      ),
      const PublicChatListTab(),
    ];

    return Scaffold(
      backgroundColor: KeychatColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _HomeTopBar(
              onSettingsTap: _openSettings,
              onAddFriendTap: _openAddFriend,
              pendingRequestCount: _pendingRequestCount,
            ),
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
/// of which tab is selected: announcements (not wired up yet), add friend,
/// settings.
class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({
    required this.onSettingsTap,
    required this.onAddFriendTap,
    required this.pendingRequestCount,
  });

  final VoidCallback onSettingsTap;
  final VoidCallback onAddFriendTap;
  final int pendingRequestCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // TODO: wire up announcements.
          _topBarIcon(Icons.notifications_outlined, () {}),
          const SizedBox(width: 12),
          _topBarIcon(
            Icons.person_add_alt_outlined,
            onAddFriendTap,
            badgeCount: pendingRequestCount,
          ),
          const SizedBox(width: 12),
          _topBarIcon(Icons.settings_outlined, onSettingsTap),
        ],
      ),
    );
  }

  Widget _topBarIcon(
    IconData icon,
    VoidCallback onPressed, {
    int badgeCount = 0,
  }) {
    return InkResponse(
      onTap: onPressed,
      radius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Badge(
          isLabelVisible: badgeCount > 0,
          label: Text('$badgeCount'),
          child: Icon(icon, color: KeychatColors.textSecondary),
        ),
      ),
    );
  }
}
