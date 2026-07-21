import 'package:flutter/material.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';

/// Brief celebratory screen shown right after onboarding (profile + relay
/// setup) finishes. Animates a checkmark in, then automatically fades into
/// [onDone] (typically a transition to Home).
class SetupCompleteScreen extends StatefulWidget {
  const SetupCompleteScreen({super.key, required this.displayName, required this.onDone});

  final String displayName;
  final VoidCallback onDone;

  @override
  State<SetupCompleteScreen> createState() => _SetupCompleteScreenState();
}

class _SetupCompleteScreenState extends State<SetupCompleteScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _checkScale = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
  );
  late final Animation<double> _textOpacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: KeychatColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _checkScale,
              child: Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  color: KeychatColors.primaryDark,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
              ),
            ),
            const SizedBox(height: 28),
            FadeTransition(
              opacity: _textOpacity,
              child: Column(
                children: [
                  Text(
                    l10n.setupCompleteTitle,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: KeychatColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.setupCompleteSubtitle(widget.displayName),
                    style: const TextStyle(fontSize: 15, color: KeychatColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
