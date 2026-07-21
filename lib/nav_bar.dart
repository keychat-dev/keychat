import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';

/// Bottom navigation bar for the home screen: Profile & Friends, Talk, and
/// Public Chat.
class KeychatNavBar extends StatelessWidget {
  const KeychatNavBar({super.key, required this.selectedIndex, required this.onTap});

  final int selectedIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Theme(
      // BottomNavigationBar always shows a Material splash/ripple on tap.
      // Suppress it so tapping only changes the icon/label color.
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
      ),
      child: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: onTap,
        backgroundColor: KeychatColors.surface,
        selectedItemColor: KeychatColors.primaryDark,
        unselectedItemColor: KeychatColors.textSecondary,
        items: [
          _navItem(Icons.person_outline, Icons.person, l10n.navProfileFriends, 0),
          _navItem(Icons.chat_bubble_outline, Icons.chat_bubble, l10n.navTalk, 1),
          _navItem(Icons.forum_outlined, Icons.forum, l10n.navPublicChat, 2),
        ],
      ),
    );
  }

  BottomNavigationBarItem _navItem(
    IconData outlinedIcon,
    IconData filledIcon,
    String label,
    int index,
  ) {
    final selected = selectedIndex == index;
    final color = selected ? KeychatColors.primaryDark : KeychatColors.textSecondary;
    return BottomNavigationBarItem(
      icon: Icon(selected ? filledIcon : outlinedIcon, color: color),
      label: label,
    );
  }
}
