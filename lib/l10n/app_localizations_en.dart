// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'KeyChat';

  @override
  String get authChoiceSubtitle =>
      'Create a new account or restore an existing one';

  @override
  String get signUpButton => 'Sign up';

  @override
  String get logInButton => 'Log in';

  @override
  String get seedPhraseLabel => 'Seed phrase';

  @override
  String get seedPhraseHint => 'Enter your seed phrase to restore your account';

  @override
  String get profileSetupSubtitle => 'Set up your profile';

  @override
  String get displayNameLabel => 'Display name';

  @override
  String get displayNameRequired => 'Please enter a display name';

  @override
  String get statusMessageLabel => 'Status message (optional)';

  @override
  String get continueButton => 'Continue';

  @override
  String get confirmButton => 'Confirm';

  @override
  String get setupCompleteTitle => 'All set!';

  @override
  String setupCompleteSubtitle(String displayName) {
    return 'Welcome to KeyChat, $displayName';
  }

  @override
  String chatListWelcome(String displayName) {
    return 'Welcome, $displayName';
  }

  @override
  String get navProfileFriends => 'Home';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get addFriendByQr => 'Add friend with QR code';

  @override
  String get friendsSectionTitle => 'Friends';

  @override
  String get noFriendsYet => 'No friends yet';

  @override
  String get noFriendsHint => 'Add a friend to start chatting';

  @override
  String get noStatusMessage => 'No status message';

  @override
  String get navTalk => 'Talk';

  @override
  String get navPublicChat => 'Public Chat';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsProfile => 'Profile';

  @override
  String get settingsRelay => 'Relay';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsAccount => 'Account';

  @override
  String get accountSettingsTitle => 'Account';

  @override
  String get logoutButton => 'Logout';

  @override
  String get logoutConfirmTitle => 'Logout?';

  @override
  String get logoutConfirmBody =>
      'If you haven\'t saved a backup file, your account will be deleted permanently.';

  @override
  String get relaySettingsTitle => 'Relay settings';

  @override
  String get relayUrlLabel => 'Relay URL';

  @override
  String get addRelay => 'Add relay';

  @override
  String get removeRelay => 'Remove';

  @override
  String get editRelay => 'Edit';

  @override
  String get resetRelays => 'Reset to defaults';

  @override
  String get resetRelaysConfirmTitle => 'Reset relays?';

  @override
  String get resetRelaysConfirmBody =>
      'This replaces your relay list with the default relays.';

  @override
  String get resetButton => 'Reset';

  @override
  String get removeRelayConfirmTitle => 'Remove relay?';

  @override
  String removeRelayConfirmBody(String url) {
    return 'Remove $url from your relay list?';
  }

  @override
  String get noRelaysYet => 'No relays configured';

  @override
  String get invalidRelayUrl => 'Relay URL must start with wss:// or ws://';

  @override
  String get relayCountHint => 'Recommended: 3-5 relays';
}
