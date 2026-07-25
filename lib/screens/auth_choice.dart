import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/languages.dart';
import 'package:workspace/screens/login.dart';

/// First screen shown on a fresh install: choose between creating a new
/// account (sign up) or restoring an existing one (login via seed phrase).
/// Login is a visual placeholder only — seed generation/restore isn't
/// implemented yet, so it doesn't do anything functional.
class AuthChoiceScreen extends StatelessWidget {
  const AuthChoiceScreen({super.key, this.onSignUp, this.onSelectLanguage});

  final VoidCallback? onSignUp;
  final ValueChanged<Locale>? onSelectLanguage;

  void _openLoginPlaceholder(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _LoginPlaceholderScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: KeychatColors.background,
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
                        color: KeychatColors.surface,
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
                        color: KeychatColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.authChoiceSubtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: KeychatColors.textSecondary),
                    ),
                    const SizedBox(height: 48),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: onSignUp,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: KeychatColors.primaryDark,
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
                        onPressed: () => _openLoginPlaceholder(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: KeychatColors.textPrimary,
                          side: const BorderSide(color: KeychatColors.primary),
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

/// Visual-only seed phrase restore screen. Not wired up to any real
/// account-recovery logic yet.
class _LoginPlaceholderScreen extends StatelessWidget {
  const _LoginPlaceholderScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
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
                style: const TextStyle(color: KeychatColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                enabled: false,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: l10n.seedPhraseLabel,
                  filled: true,
                  fillColor: KeychatColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KeychatColors.primaryDark,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: KeychatColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    l10n.logInButton,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.comingSoon,
                textAlign: TextAlign.center,
                style: const TextStyle(color: KeychatColors.textSecondary, fontSize: 13),
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
            const Icon(Icons.translate, size: 18, color: KeychatColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              languageNames[currentCode] ?? currentCode.toUpperCase(),
              style: const TextStyle(color: KeychatColors.textSecondary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
