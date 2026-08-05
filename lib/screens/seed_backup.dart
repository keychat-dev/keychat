import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/src/rust/api/relay.dart' as relay_api;

/// Shows a generated seed phrase for the user to write down.
///
/// In onboarding mode (`onContinue` provided) this also shows a note that
/// the phrase can be reviewed again later from Settings, and a primary
/// "Continue" button instead of just a back arrow.
///
/// On open, if none of the configured relays are on the built-in default
/// list, shows a one-time dialog warning that restoring on another device
/// needs those relay URLs saved too — since restore only searches relays
/// the user selects, not whichever ones this account happens to publish to.
class SeedBackupScreen extends StatefulWidget {
  const SeedBackupScreen({super.key, required this.mnemonic, this.onContinue});

  final String mnemonic;
  final VoidCallback? onContinue;

  @override
  State<SeedBackupScreen> createState() => _SeedBackupScreenState();
}

class _SeedBackupScreenState extends State<SeedBackupScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWarnNoDefaultRelay());
  }

  Future<void> _maybeWarnNoDefaultRelay() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final current = (await relay_api.loadRelayList(storageDir: storageDir.path)).urls;
    final defaults = await relay_api.defaultRelays();
    final hasNoDefaultRelay = current.toSet().intersection(defaults.toSet()).isEmpty;
    if (!hasNoDefaultRelay || !mounted) return;

    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: OrigilinkColors.background,
        title: Text(l10n.seedBackupNoDefaultRelayTitle),
        content: Text(l10n.seedBackupNoDefaultRelayBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = widget.mnemonic.split(' ');
    return Scaffold(
      backgroundColor: OrigilinkColors.background,
      appBar: AppBar(
        backgroundColor: OrigilinkColors.background,
        elevation: 0,
        foregroundColor: OrigilinkColors.textPrimary,
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
                style: const TextStyle(color: OrigilinkColors.textSecondary, fontSize: 14),
              ),
              if (widget.onContinue != null) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.seedBackupOnboardingNote,
                  style: const TextStyle(color: OrigilinkColors.textSecondary, fontSize: 13),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: OrigilinkColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < words.length; i++)
                      Chip(
                        backgroundColor: OrigilinkColors.background,
                        label: Text(
                          '${i + 1}. ${words[i]}',
                          style: const TextStyle(color: OrigilinkColors.textPrimary),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.onContinue != null) ...[
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: widget.onContinue,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: OrigilinkColors.primaryDark,
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
