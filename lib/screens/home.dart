import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/nav_bar.dart';
import 'package:workspace/screens/add_friend.dart';
import 'package:workspace/screens/chat_list.dart';
import 'package:workspace/screens/chat_thread.dart';
import 'package:workspace/screens/create_talk_room.dart';
import 'package:workspace/screens/edit_profile.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/screens/logout.dart' show seedStorageKey;
import 'package:workspace/screens/account_friends.dart';
import 'package:workspace/screens/public_chat_list.dart';
import 'package:workspace/screens/settings.dart';
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/account.dart' as account_api;
import 'package:workspace/src/rust/api/chat.dart' as chat_api;
import 'package:workspace/src/rust/api/config.dart' as config_api;
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
    required this.onLocaleSynced,
  });

  final account_api.Account profile;
  final ValueChanged<Locale> onSelectLanguage;
  final VoidCallback onLogout;

  /// Called when a config backup with a different language arrives from
  /// another device — updates the displayed locale immediately, without
  /// re-persisting or re-publishing (that already happened on the device
  /// that made the change; this is purely a display refresh).
  final ValueChanged<Locale> onLocaleSynced;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _selectedIndex = 1;
  late account_api.Account _profile = widget.profile;

  List<friends_api.Friend> _friends = [];
  Set<String> _activeChatPubkeys = {};
  int _pendingRequestCount = 0;
  StreamSubscription<sync_api.FriendEvent>? _friendEventsSub;
  Stream<sync_api.FriendEvent>? _friendEventsStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFriends();
    _loadActiveChatPubkeys();
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
      _loadActiveChatPubkeys();
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
      if (event.kind == 'accepted' || event.kind == 'already_friend') {
        _loadFriends();
        unawaited(publishAccountFriendsBackup());
        // The live subscription's watch list was built from the friends
        // list as it stood when this subscription started — a friend
        // gained just now via acceptance isn't in it yet, so their gift
        // wraps would silently fail to match until we rebuild it.
        _subscribeFriendEvents();
        if (event.kind == 'already_friend' && mounted) {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.friendAlreadyAddedMessage)));
        }
      } else if (event.kind == 'profile_updated') {
        _loadFriends();
      } else if (event.kind == 'request') {
        _refreshPendingRequestCount();
      } else if (event.kind == 'message') {
        // A friend messaging us first means their thread should show up
        // in the Talk tab even though nobody tapped "Talk" yet.
        _loadActiveChatPubkeys();
      } else if (event.kind == 'account_synced') {
        // Another device published a newer text/avatar/relays/friends/
        // config/chat-started backup and this device applied it locally —
        // refresh everything shown from that local state.
        _reloadProfile();
        _loadFriends();
        _loadActiveChatPubkeys();
        _applySyncedLocale();
      }
    });
  }

  Future<void> _loadActiveChatPubkeys() async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    final pubkeys = await chat_api.listActiveChatPubkeys(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
    );
    if (!mounted) return;
    setState(() => _activeChatPubkeys = pubkeys.toSet());
  }

  Future<void> _refreshPendingRequestCount() async {
    final count = await pendingFriendRequestCount();
    if (!mounted) return;
    setState(() => _pendingRequestCount = count);
  }

  Future<void> _reloadProfile() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final profile = await account_api.loadAccount(storageDir: storageDir.path);
    if (!mounted || profile == null) return;
    setState(() => _profile = profile);
  }

  Future<void> _applySyncedLocale() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final config = await config_api.loadConfig(storageDir: storageDir.path);
    final language = config.language;
    if (language == null || !mounted) return;
    widget.onLocaleSynced(Locale(language));
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
    unawaited(publishAccountFriendsBackup());
  }

  Future<void> _blockFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    // Blocking silences a friend (their messages/profile updates stop
    // being applied — see the live subscription's blocked check) but
    // deliberately doesn't remove them from friends.json, so it stays
    // reversible via unblock.
    await friends_api.blockPubkey(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
    unawaited(publishAccountBlockedBackup());
  }

  Future<void> _unblockFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.unblockPubkey(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
    unawaited(publishAccountBlockedBackup());
  }

  Future<void> _deleteFriend(friends_api.Friend friend) async {
    final storageDir = await getApplicationDocumentsDirectory();
    await friends_api.removeFriend(storageDir: storageDir.path, pubkey: friend.pubkey);
    await _loadFriends();
    unawaited(publishAccountFriendsBackup());
  }

  /// Wipes local message history with a friend and drops the thread out of
  /// the Talk tab (until either side messages again) — purely local, so it
  /// doesn't affect the friendship or notify them.
  Future<void> _clearChat(friends_api.Friend friend) async {
    const secureStorage = FlutterSecureStorage();
    final mnemonic = await secureStorage.read(key: seedStorageKey);
    if (mnemonic == null) return;
    final storageDir = await getApplicationDocumentsDirectory();
    await chat_api.clearChatHistory(
      mnemonic: mnemonic,
      storageDir: storageDir.path,
      friendPubkey: friend.pubkey,
    );
    await _loadActiveChatPubkeys();
  }

  /// "Create talk room" from the Talk tab's "+" menu: pick a friend and
  /// open their thread, marking it started if it wasn't already. If a
  /// thread already exists (with this friend or otherwise), this just
  /// opens it — [chat_api.markChatStarted] is idempotent and
  /// [ChatThreadScreen] always loads whatever history is already there,
  /// so there's no separate "room" entity being created underneath.
  Future<void> _createTalkRoom(BuildContext context) async {
    final friend = await Navigator.of(context).push<friends_api.Friend>(
      MaterialPageRoute(builder: (_) => CreateTalkRoomScreen(friends: _friends)),
    );
    if (friend == null || !context.mounted) return;

    final storageDir = await getApplicationDocumentsDirectory();
    await chat_api.markChatStarted(storageDir: storageDir.path, friendPubkey: friend.pubkey);
    unawaited(publishAccountChatStartedBackup());
    await _loadActiveChatPubkeys();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          friend: friend,
          messageEvents: _friendEventsStream,
          onToggleFavorite: _toggleFavorite,
          onBlockFriend: _blockFriend,
          onUnblockFriend: _unblockFriend,
          onDeleteFriend: _deleteFriend,
          onClearChat: _clearChat,
        ),
      ),
    );
    _loadActiveChatPubkeys();
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
    unawaited(publishAccountFriendsBackup());
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
          messageEvents: _friendEventsStream,
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
        onUnblockFriend: _unblockFriend,
        onDeleteFriend: _deleteFriend,
        onClearChat: _clearChat,
        onFriendProfileClosed: () {
          _loadFriends();
          _loadActiveChatPubkeys();
        },
        messageEvents: _friendEventsStream,
      ),
      ChatListTab(
        // Only friends with a started (or already-in-progress) chat show
        // up here — tapping "Talk" on a friend's profile is what starts
        // one, rather than every friend appearing by default.
        friends: _friends.where((f) => _activeChatPubkeys.contains(f.pubkey)).toList(),
        messageEvents: _friendEventsStream,
        onToggleFavorite: _toggleFavorite,
        onBlockFriend: _blockFriend,
        onUnblockFriend: _unblockFriend,
        onDeleteFriend: _deleteFriend,
        onClearChat: _clearChat,
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
              onCreateTalkRoom: _createTalkRoom,
              pendingRequestCount: _pendingRequestCount,
              isTalkTab: _selectedIndex == 1,
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
    required this.onCreateTalkRoom,
    required this.pendingRequestCount,
    required this.isTalkTab,
  });

  final VoidCallback onSettingsTap;
  final VoidCallback onAddFriendTap;
  final Future<void> Function(BuildContext context) onCreateTalkRoom;
  final int pendingRequestCount;

  /// On the Talk tab, the usual "add friend" icon becomes a plain "+" that
  /// opens a menu with talk room / group / friend creation instead of
  /// jumping straight to add-friend — the other two aren't implemented
  /// yet (see [_showTalkAddMenu]'s "coming soon" entries), but the menu
  /// shape is there so friend-adding stays reachable from the Talk tab too.
  final bool isTalkTab;

  Future<void> _showTalkAddMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: KeychatColors.background,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(l10n.createTalkRoom),
              onTap: () => Navigator.of(sheetContext).pop('room'),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(l10n.createGroup),
              onTap: () => Navigator.of(sheetContext).pop('group'),
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_outlined),
              title: Text(l10n.addFriendTitle),
              onTap: () => Navigator.of(sheetContext).pop('friend'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'friend') {
      onAddFriendTap();
    } else if (choice == 'room' && context.mounted) {
      onCreateTalkRoom(context);
    } else if (choice == 'group' && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.comingSoon)));
    }
  }

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
          if (isTalkTab)
            _topBarIcon(Icons.add, () => _showTalkAddMenu(context))
          else
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
