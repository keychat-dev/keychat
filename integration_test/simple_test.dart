// Boots the real app (including RustLib.init() against the real native
// library) on-device and verifies a fresh install reaches AuthChoiceScreen —
// the actual first screen a user sees, not a synthetic widget.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:origilink/main.dart';
import 'package:origilink/screens/auth_choice.dart';
import 'package:origilink/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Fresh install boots to AuthChoiceScreen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OrigilinkApp());
    await tester.pumpAndSettle();

    expect(find.byType(AuthChoiceScreen), findsOneWidget);
  });
}
