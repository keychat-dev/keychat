import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';

/// Shows a generated seed phrase for the user to write down.
///
/// In onboarding mode (`onContinue` provided) this also shows a note that
/// the phrase can be reviewed again later from Settings, and a primary
/// "Continue" button instead of just a back arrow.
class SeedBackupScreen extends StatelessWidget {
  const SeedBackupScreen({super.key, required this.mnemonic, this.onContinue});

  final String mnemonic;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = mnemonic.split(' ');
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.seedBackupButton),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.seedBackupWarning,
                style: const TextStyle(color: KeychatColors.textSecondary, fontSize: 14),
              ),
              if (onContinue != null) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.seedBackupOnboardingNote,
                  style: const TextStyle(color: KeychatColors.textSecondary, fontSize: 13),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: KeychatColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < words.length; i++)
                      Chip(
                        backgroundColor: KeychatColors.background,
                        label: Text(
                          '${i + 1}. ${words[i]}',
                          style: const TextStyle(color: KeychatColors.textPrimary),
                        ),
                      ),
                  ],
                ),
              ),
              if (onContinue != null) ...[
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: onContinue,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KeychatColors.primaryDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      l10n.continueButton,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
