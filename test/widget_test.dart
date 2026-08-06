// Smoke test: the first screen shown on a fresh install (no persisted
// Account) renders without crashing and shows the app title plus both
// entry points into the sign-up/restore flows.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/auth_choice.dart';

void main() {
  testWidgets('AuthChoiceScreen shows the app title and both entry points', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AuthChoiceScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(AuthChoiceScreen)),
    )!;

    expect(find.text(l10n.appTitle), findsOneWidget);
    expect(find.text(l10n.signUpButton), findsOneWidget);
    expect(find.text(l10n.logInButton), findsOneWidget);
  });
}
