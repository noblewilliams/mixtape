import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';

class ControlledAuth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.unknown;
  void expire() => state = AuthStatus.noSession;
}

void main() {
  testWidgets('custom routes and overlays inherit normal text defaults', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith(ControlledAuth.new)],
        child: const MixtapeApp(),
      ),
    );
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Center(child: Text('Floating route')),
      ),
    );
    await tester.pumpAndSettle();
    final entry = OverlayEntry(
      builder: (_) =>
          const Positioned(top: 0, left: 0, child: Text('Floating overlay')),
    );
    navigator.overlay!.insert(entry);
    await tester.pump();
    for (final label in ['Floating route', 'Floating overlay']) {
      final rich = tester.widget<RichText>(
        find.descendant(of: find.text(label), matching: find.byType(RichText)),
      );
      expect(
        rich.text.style?.decoration ?? TextDecoration.none,
        TextDecoration.none,
        reason: label,
      );
    }
    entry.remove();
    entry.dispose();
  });

  // Sign-in's cassette turns for as long as the screen is on show, so a
  // settle would never finish; reduced motion holds its hubs still.
  setUp(
    () =>
        TestWidgetsFlutterBinding.ensureInitialized()
            .platformDispatcher
            .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
          disableAnimations: true,
        ),
  );
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );

  testWidgets('auth transition clears pushed protected routes and dialogs', (
    tester,
  ) async {
    final auth = ControlledAuth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith(() => auth)],
        child: const MixtapeApp(),
      ),
    );
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Protected account')),
      ),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: tester.element(find.text('Protected account')),
      builder: (_) => const AlertDialog(title: Text('Protected dialog')),
    );
    await tester.pumpAndSettle();
    auth.expire();
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('Protected account'), findsNothing);
    expect(find.text('Protected dialog'), findsNothing);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isFalse,
    );
  });
}
