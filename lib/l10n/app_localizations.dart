import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'KeyChat'**
  String get appTitle;

  /// No description provided for @authChoiceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a new account or restore an existing one'**
  String get authChoiceSubtitle;

  /// No description provided for @signUpButton.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get signUpButton;

  /// No description provided for @logInButton.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get logInButton;

  /// No description provided for @seedPhraseLabel.
  ///
  /// In en, this message translates to:
  /// **'Seed phrase'**
  String get seedPhraseLabel;

  /// No description provided for @seedPhraseHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your seed phrase to restore your account'**
  String get seedPhraseHint;

  /// No description provided for @profileSetupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set up your profile'**
  String get profileSetupSubtitle;

  /// No description provided for @displayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get displayNameLabel;

  /// No description provided for @displayNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a display name'**
  String get displayNameRequired;

  /// No description provided for @statusMessageLabel.
  ///
  /// In en, this message translates to:
  /// **'Status message (optional)'**
  String get statusMessageLabel;

  /// No description provided for @continueButton.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueButton;

  /// No description provided for @confirmButton.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirmButton;

  /// No description provided for @setupCompleteTitle.
  ///
  /// In en, this message translates to:
  /// **'All set!'**
  String get setupCompleteTitle;

  /// No description provided for @setupCompleteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to KeyChat, {displayName}'**
  String setupCompleteSubtitle(String displayName);

  /// No description provided for @chatListWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome, {displayName}'**
  String chatListWelcome(String displayName);

  /// No description provided for @navProfileFriends.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navProfileFriends;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// No description provided for @addFriendByQr.
  ///
  /// In en, this message translates to:
  /// **'Add friend with QR code'**
  String get addFriendByQr;

  /// No description provided for @friendsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Friends'**
  String get friendsSectionTitle;

  /// No description provided for @noFriendsYet.
  ///
  /// In en, this message translates to:
  /// **'No friends yet'**
  String get noFriendsYet;

  /// No description provided for @noFriendsHint.
  ///
  /// In en, this message translates to:
  /// **'Add a friend to start chatting'**
  String get noFriendsHint;

  /// No description provided for @noStatusMessage.
  ///
  /// In en, this message translates to:
  /// **'No status message'**
  String get noStatusMessage;

  /// No description provided for @navTalk.
  ///
  /// In en, this message translates to:
  /// **'Talk'**
  String get navTalk;

  /// No description provided for @navPublicChat.
  ///
  /// In en, this message translates to:
  /// **'Public Chat'**
  String get navPublicChat;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsProfile;

  /// No description provided for @settingsRelay.
  ///
  /// In en, this message translates to:
  /// **'Relay'**
  String get settingsRelay;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAccount;

  /// No description provided for @accountSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountSettingsTitle;

  /// No description provided for @logoutButton.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logoutButton;

  /// No description provided for @logoutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Logout?'**
  String get logoutConfirmTitle;

  /// No description provided for @logoutConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'If you haven\'t saved a backup file, your account will be deleted permanently.'**
  String get logoutConfirmBody;

  /// No description provided for @relaySettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Relay settings'**
  String get relaySettingsTitle;

  /// No description provided for @relayUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Relay URL'**
  String get relayUrlLabel;

  /// No description provided for @addRelay.
  ///
  /// In en, this message translates to:
  /// **'Add relay'**
  String get addRelay;

  /// No description provided for @removeRelay.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeRelay;

  /// No description provided for @editRelay.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editRelay;

  /// No description provided for @resetRelays.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetRelays;

  /// No description provided for @resetRelaysConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset relays?'**
  String get resetRelaysConfirmTitle;

  /// No description provided for @resetRelaysConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This replaces your relay list with the default relays.'**
  String get resetRelaysConfirmBody;

  /// No description provided for @resetButton.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get resetButton;

  /// No description provided for @removeRelayConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove relay?'**
  String get removeRelayConfirmTitle;

  /// No description provided for @removeRelayConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Remove {url} from your relay list?'**
  String removeRelayConfirmBody(String url);

  /// No description provided for @noRelaysYet.
  ///
  /// In en, this message translates to:
  /// **'No relays configured'**
  String get noRelaysYet;

  /// No description provided for @invalidRelayUrl.
  ///
  /// In en, this message translates to:
  /// **'Relay URL must start with wss:// or ws://'**
  String get invalidRelayUrl;

  /// No description provided for @relayCountHint.
  ///
  /// In en, this message translates to:
  /// **'Recommended: 3-5 relays'**
  String get relayCountHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
