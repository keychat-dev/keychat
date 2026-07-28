// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'KeyChat';

  @override
  String get authChoiceSubtitle => '新規アカウントを作成するか、既存のアカウントを復元してください';

  @override
  String get signUpButton => '新規登録';

  @override
  String get logInButton => 'ログイン';

  @override
  String get seedPhraseLabel => 'シードフレーズ';

  @override
  String get seedPhraseHint => 'シードフレーズを入力してアカウントを復元してください';

  @override
  String get restoreInvalidSeed => '正しいシードフレーズではないようです。';

  @override
  String get restoreNoBackupFound =>
      'このシードフレーズのバックアップが見つかりませんでした。別の端末でリレー同期まで設定を完了しているか確認してください。';

  @override
  String get restoreNetworkError => 'リレーに接続できませんでした。通信状況を確認してもう一度お試しください。';

  @override
  String get profileSetupSubtitle => 'プロフィールを設定してください';

  @override
  String get displayNameLabel => '表示名';

  @override
  String get displayNameRequired => '表示名を入力してください';

  @override
  String get statusMessageLabel => 'ステータスメッセージ (任意)';

  @override
  String get continueButton => '次へ';

  @override
  String get confirmButton => '決定';

  @override
  String get setupCompleteTitle => '準備完了!';

  @override
  String setupCompleteSubtitle(String displayName) {
    return 'ようこそ、$displayName さん';
  }

  @override
  String chatListWelcome(String displayName) {
    return 'ようこそ、$displayName さん';
  }

  @override
  String get navProfileFriends => 'ホーム';

  @override
  String get editProfile => 'プロフィールを編集';

  @override
  String get addFriendByQr => 'QRコードで友達追加';

  @override
  String get friendsSectionTitle => '友達';

  @override
  String get noFriendsYet => 'まだ友達がいません';

  @override
  String get noFriendsHint => '友達を追加してチャットを始めましょう';

  @override
  String get noStatusMessage => 'ステータスメッセージ未設定';

  @override
  String get navTalk => 'トーク';

  @override
  String get navPublicChat => 'パブリックチャット';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsProfile => 'プロフィール';

  @override
  String get settingsRelay => 'リレー';

  @override
  String get settingsLanguage => '言語';

  @override
  String get settingsAccount => 'アカウント';

  @override
  String get accountSettingsTitle => 'アカウント';

  @override
  String get seedBackupButton => 'シードフレーズをバックアップ';

  @override
  String get seedBackupWarning =>
      'この単語を順番通りに書き留め、安全な場所に保管してください。このフレーズを知っている人は誰でもアカウントを復元できます。';

  @override
  String get seedBackupOnboardingNote => 'このフレーズは、いつでも設定 > アカウントから確認できます。';

  @override
  String get seedBackupNoDefaultRelayTitle => 'リレーのURLも保存してください';

  @override
  String get seedBackupNoDefaultRelayBody =>
      '現在のリレーはデフォルトのものを一つも含んでいません。別の端末で復元する際はこのアカウントが公開しているリレーと同じものを選ぶ必要があるため、このフレーズだけでなくリレーのURLも書き留めておいてください。';

  @override
  String get logoutButton => 'ログアウト';

  @override
  String get logoutConfirmTitle => 'ログアウトしますか?';

  @override
  String get logoutConfirmBody =>
      'アカウントはこの端末から削除され、シードフレーズを保存していない場合、二度と復元できなくなります。';

  @override
  String get deleteAccountButton => 'アカウントを削除';

  @override
  String get deleteAccountConfirmTitle => 'アカウントを削除しますか?';

  @override
  String get deleteAccountConfirmBody =>
      'シードフレーズを含め、アカウントがこの端末とリレーの両方から完全に削除され、二度と復元できなくなります。';

  @override
  String get relaySettingsTitle => 'リレー設定';

  @override
  String get relayUrlLabel => 'リレーURL';

  @override
  String get addRelay => 'リレーを追加';

  @override
  String get removeRelay => '削除';

  @override
  String get editRelay => '編集';

  @override
  String get resetRelays => '初期値に戻す';

  @override
  String get resetRelaysConfirmTitle => 'リレーをリセットしますか?';

  @override
  String get resetRelaysConfirmBody => '現在のリレー一覧が初期値に置き換わります。';

  @override
  String get resetButton => 'リセット';

  @override
  String get removeRelayConfirmTitle => 'リレーを削除しますか?';

  @override
  String removeRelayConfirmBody(String url) {
    return '$url をリレー一覧から削除しますか?';
  }

  @override
  String get noRelaysYet => 'リレーが設定されていません';

  @override
  String get invalidRelayUrl => 'リレーURLはwss://またはws://で始まる必要があります';

  @override
  String get relayCountHint => '推奨: 3〜5個程度';
}
