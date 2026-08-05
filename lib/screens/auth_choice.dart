import 'package:flutter/material.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/languages.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/relay_settings.dart';

/// First screen shown on a fresh install: choose between creating a new
/// account (sign up) or restoring an existing one (login via seed phrase).
class AuthChoiceScreen extends StatelessWidget {
  const AuthChoiceScreen({
    super.key,
    this.onSignUp,
    this.onSelectLanguage,
    this.onRestore,
  });

  final VoidCallback? onSignUp;
  final ValueChanged<Locale>? onSelectLanguage;

  /// Called with a validated seed phrase when the user submits the restore
  /// form. Returns a user-facing error message on failure, or `null` on
  /// success (in which case the caller is expected to have already
  /// navigated away, e.g. to the home screen).
  final Future<String?> Function(String mnemonic)? onRestore;

  /// Login starts with relay selection, not the seed phrase itself: restore
  /// only searches whichever relays are chosen here, so the user needs a
  /// chance to point at non-default relays before entering their phrase.
  void _openLogin(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelaySettingsScreen(
          onContinue: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => _LoginScreen(onRestore: onRestore)),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: OrigilinkColors.surface,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Image.asset('assets/branding/app_icon.png', fit: BoxFit.cover),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.appTitle,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: OrigilinkColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.authChoiceSubtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: OrigilinkColors.textSecondary),
                    ),
                    const SizedBox(height: 48),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: onSignUp,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: OrigilinkColors.primaryDark,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          l10n.signUpButton,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton(
                        onPressed: () => _openLogin(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: OrigilinkColors.textPrimary,
                          side: const BorderSide(color: OrigilinkColors.primary),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          l10n.logInButton,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (onSelectLanguage != null)
              Positioned(
                top: 8,
                right: 16,
                child: _AuthLanguageSelector(onSelected: onSelectLanguage!),
              ),
          ],
        ),
      ),
    );
  }
}

/// Seed phrase restore screen: lets the user paste their 12-word seed
/// phrase and, if [onRestore] is given, submits it for account recovery.
class _LoginScreen extends StatefulWidget {
  const _LoginScreen({this.onRestore});

  final Future<String?> Function(String mnemonic)? onRestore;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  static const _wordCount = 12;
  final _controllers = List.generate(_wordCount, (_) => TextEditingController());
  late final _focusNodes = List.generate(
    _wordCount,
    (_) => FocusNode()..addListener(() => setState(() {})),
  );
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final onRestore = widget.onRestore;
    if (onRestore == null) return;
    final words = _controllers.map((c) => c.text.trim()).where((w) => w.isNotEmpty);
    final mnemonic = words.join(' ');
    if (mnemonic.isEmpty) return;

    setState(() {
      _submitting = true;
      _errorText = null;
    });
    final error = await onRestore(mnemonic);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _errorText = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
        title: Text(l10n.logInButton),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.seedPhraseHint,
                style: const TextStyle(color: OrigilinkColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: OrigilinkColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _wordCount,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.4,
                  ),
                  itemBuilder: (context, index) => TextField(
                    controller: _controllers[index],
                    focusNode: _focusNodes[index],
                    enabled: !_submitting,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: _focusNodes[index].hasFocus ? null : '${index + 1}',
                      hintStyle: TextStyle(color: OrigilinkColors.textSecondary.withValues(alpha: 0.5)),
                      filled: true,
                      fillColor: OrigilinkColors.background,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                  ),
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: OrigilinkColors.primaryDark,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: OrigilinkColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          l10n.logInButton,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthLanguageSelector extends StatelessWidget {
  const _AuthLanguageSelector({required this.onSelected});

  final ValueChanged<Locale> onSelected;

  @override
  Widget build(BuildContext context) {
    final currentCode = Localizations.localeOf(context).languageCode;
    return PopupMenuButton<Locale>(
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final locale in AppLocalizations.supportedLocales)
          PopupMenuItem(
            value: locale,
            child: Text(languageNames[locale.languageCode] ?? locale.languageCode.toUpperCase()),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 18, color: OrigilinkColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              languageNames[currentCode] ?? currentCode.toUpperCase(),
              style: const TextStyle(color: OrigilinkColors.textSecondary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
