import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';

class ControlledAuth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.unknown;
  void expire() => state = AuthStatus.signedOut;
}

void main() {
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

  testWidgets('auth transition clears pushed protected routes and dialogs', (tester) async {
    final auth = ControlledAuth();
    await tester.pumpWidget(ProviderScope(
      overrides: [authProvider.overrideWith(() => auth)],
      child: const MixtapeApp(),
    ));
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Protected account'))));
    await tester.pumpAndSettle();
    showDialog<void>(context: tester.element(find.text('Protected account')), builder: (_) => const AlertDialog(title: Text('Protected dialog')));
    await tester.pumpAndSettle();
    auth.expire();
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.text('Protected account'), findsNothing);
    expect(find.text('Protected dialog'), findsNothing);
    expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
  });
}
