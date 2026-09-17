import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';

void main() {
  testWidgets(
    'rotates only empty unfocused prompts and never changes entered text',
    (tester) async {
      final controller = TextEditingController();
      var submits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () => submits++,
            ),
          ),
        ),
      );
      expect(find.text('A slow Sunday morning'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.text('High-energy songs for my workout'), findsOneWidget);
      await tester.tap(find.byKey(const Key('prompt-field')));
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.text('High-energy songs for my workout'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'My own prompt',
      );
      await tester.pump(const Duration(seconds: 9));
      expect(controller.text, 'My own prompt');
      await tester.tap(find.byKey(const Key('start-session')));
      expect(submits, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('reduced motion freezes examples and blank input cannot submit', (
    tester,
  ) async {
    final controller = TextEditingController();
    var submits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () => submits++,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('A slow Sunday morning'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-session')));
    expect(submits, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('pauses while inactive and behind another route', (tester) async {
    final controller = TextEditingController();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
          ),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 4500));
    expect(find.text('A slow Sunday morning'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other screen')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 4500));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('A slow Sunday morning'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4500));
    expect(find.text('High-energy songs for my workout'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('keyboard send submits only nonblank nonbusy input', (
    tester,
  ) async {
    final controller = TextEditingController();
    var submits = 0;
    Future<void> render(bool busy) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: busy,
            onSubmit: () => submits++,
          ),
        ),
      ),
    );
    await render(false);
    final field = tester.widget<TextField>(
      find.byKey(const Key('prompt-field')),
    );
    expect(field.textInputAction, TextInputAction.send);
    field.onSubmitted!('');
    expect(submits, 0);
    controller.text = '   ';
    field.onSubmitted!('   ');
    expect(submits, 0);
    await tester.enterText(
      find.byKey(const Key('prompt-field')),
      'A road trip',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(submits, 1);
    await render(true);
    tester
        .widget<TextField>(find.byKey(const Key('prompt-field')))
        .onSubmitted!('A road trip');
    expect(submits, 1);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('narrow large text composer has no caption or overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(
      text: 'A long prompt for a slow Sunday morning',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Describe your new mix'), findsNothing);
    expect(tester.takeException(), isNull);
    final submit = tester.getRect(find.byKey(const Key('start-session')));
    expect(submit.right, lessThanOrEqualTo(320));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
