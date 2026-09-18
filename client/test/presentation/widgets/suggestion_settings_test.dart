// The one shared "Suggest mixes from my routines" row (plan
// `docs/superpowers/plans/2026-09-17-native-design-implementation.md` task
// 8.3): an inset row with a native switch that writes the setting straight
// through, replacing the duplicate settings screen the You tab carried.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/suggestions/suggestions_api.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/suggestion_settings.dart';

/// Records saves and can fail or hold either call.
class FakeSuggestionsApi implements SuggestionsApi {
  FakeSuggestionsApi({this.enabled = true});

  bool enabled;
  bool failLoad = false;
  bool failSave = false;
  final List<bool> saves = [];
  Completer<void>? saveGate;

  @override
  Future<SuggestionsData> load(String zone) async {
    if (failLoad) throw StateError('offline');
    return SuggestionsData(enabled: enabled, dismissed: false);
  }

  @override
  Future<String> select(String id, String zone) => throw UnimplementedError();

  @override
  Future<void> dismiss(String id, String zone) async {}

  @override
  Future<void> save(bool value) async {
    saves.add(value);
    if (saveGate != null) await saveGate!.future;
    if (failSave) throw StateError('offline');
    enabled = value;
  }
}

/// Which API the provider hands out; swapping it is an account change.
class _ApiSlot {
  _ApiSlot(this.api);
  SuggestionsApi api;
}

late _ApiSlot _slot;

ProviderContainer _container(SuggestionsApi api) {
  _slot = _ApiSlot(api);
  final container = ProviderContainer(
    overrides: [
      suggestionsApiProvider.overrideWith((ref) => _slot.api),
      suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Hands out a different API, the way a sign-in as somebody else would.
void _changeAccount(ProviderContainer container, SuggestionsApi api) {
  _slot.api = api;
  container.invalidate(suggestionsApiProvider);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: const Scaffold(
          body: InsetGroup(children: [SuggestionSettings()]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Switch _switch(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(SuggestionSettings.switchKey));

void main() {
  testWidgets('reflects the loaded setting', (tester) async {
    await _pump(tester, _container(FakeSuggestionsApi()));

    expect(find.text(SuggestionSettings.title), findsOneWidget);
    expect(_switch(tester).value, isTrue);
    expect(_switch(tester).onChanged, isNotNull);
  });

  testWidgets('writes the new value straight through', (tester) async {
    final api = FakeSuggestionsApi();
    await _pump(tester, _container(api));

    await tester.tap(find.byKey(SuggestionSettings.switchKey));
    await tester.pumpAndSettle();

    expect(api.saves, [false]);
    expect(_switch(tester).value, isFalse);
  });

  testWidgets('cannot be fired twice while a save is in flight', (
    tester,
  ) async {
    final api = FakeSuggestionsApi()..saveGate = Completer<void>();
    await _pump(tester, _container(api));

    await tester.tap(find.byKey(SuggestionSettings.switchKey));
    await tester.pump();
    expect(_switch(tester).onChanged, isNull);
    await tester.tap(
      find.byKey(SuggestionSettings.switchKey),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(api.saves, [false]);
    api.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(api.saves, [false]);
  });

  testWidgets('refuses to write against another account and says so', (
    tester,
  ) async {
    final mine = FakeSuggestionsApi();
    final container = _container(mine);
    await _pump(tester, container);

    final theirs = FakeSuggestionsApi();
    _changeAccount(container, theirs);
    await tester.pumpAndSettle();

    expect(find.text(SuggestionSettings.accountChanged), findsOneWidget);
    expect(_switch(tester).onChanged, isNull);
    await tester.tap(
      find.byKey(SuggestionSettings.switchKey),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(mine.saves, isEmpty);
    expect(theirs.saves, isEmpty);
  });

  testWidgets('a failed load leaves the switch off and disabled', (
    tester,
  ) async {
    await _pump(tester, _container(FakeSuggestionsApi()..failLoad = true));

    expect(find.text(SuggestionSettings.loadFailed), findsOneWidget);
    expect(_switch(tester).onChanged, isNull);
  });

  testWidgets('a failed save puts the switch back and says so', (tester) async {
    final api = FakeSuggestionsApi()..failSave = true;
    await _pump(tester, _container(api));

    await tester.tap(find.byKey(SuggestionSettings.switchKey));
    await tester.pumpAndSettle();

    expect(api.saves, [false]);
    expect(_switch(tester).value, isTrue, reason: 'the write did not land');
    expect(find.text(SuggestionSettings.saveFailed), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('renders at 200% text on a 320 pt phone in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = _container(FakeSuggestionsApi());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: brightness == Brightness.dark
                ? MixtapeTheme.dark()
                : MixtapeTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: InsetGroup(children: [SuggestionSettings()]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(SuggestionSettings.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
