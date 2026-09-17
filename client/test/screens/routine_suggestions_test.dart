import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/suggestions/suggestions_api.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/widgets/routine_suggestions.dart';
import '../helpers/auth_ui_snapshot.dart';

class FakeSuggestions implements SuggestionsApi {
  bool enabled = true, hidden = false, expired = false;
  int selections = 0;
  Completer<String>? pending;
  @override
  Future<SuggestionsData> load(String zone) async => SuggestionsData(
    enabled: enabled,
    dismissed: hidden,
    suggestion: enabled && !hidden
        ? const RoutineSuggestion(
            id: '5-3-fall',
            title: 'Ease into a slower pace.',
            reason: 'You have made winding-down mixes on 3 Friday evenings.',
          )
        : null,
  );
  @override
  Future<String> select(String id, String zone) async {
    selections++;
    if (expired) throw Exception('expired');
    if (pending != null) return pending!.future;
    return 'Make a mix that gradually winds down.';
  }

  @override
  Future<void> dismiss(String id, String zone) async {
    hidden = true;
  }

  @override
  Future<void> save(bool value) async {
    enabled = value;
  }
}

void main() {
  testWidgets('expired and late account responses cannot create a mix', (
    tester,
  ) async {
    final api = FakeSuggestions()..expired = true;
    final prompts = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(api),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RoutineSuggestions(
                onCreate: (p) async {
                  prompts.add(p);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make this mix'));
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);
    expect(find.textContaining('Could not complete'), findsOneWidget);
    api.expired = false;
    api.pending = Completer<String>();
    await tester.tap(find.text('Make this mix'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    api.pending!.complete('A brief');
    await tester.pump();
    expect(prompts, isEmpty);
  });

  testWidgets('renders the native suggestion card', (tester) async {
    await loadAuthSnapshotFonts(tester);
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(FakeSuggestions()),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: RepaintBoundary(
          key: authSnapshotKey,
          child: MaterialApp(
            theme: authSnapshotTheme(Brightness.dark),
            home: Scaffold(
              appBar: AppBar(title: const Text('Your tapes')),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: RoutineSuggestions(onCreate: (_) async {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await captureAuthSnapshot(tester, 'routine-native-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'requires an explicit tap, dismisses, and saves settings on a short phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeSuggestions();
      final prompts = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            suggestionsApiProvider.overrideWithValue(api),
            suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: RoutineSuggestions(
                  onCreate: (p) async {
                    prompts.add(p);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(prompts, isEmpty);
      await tester.scrollUntilVisible(find.text('Make this mix'), 100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make this mix'));
      await tester.pumpAndSettle();
      expect(prompts, ['Make a mix that gradually winds down.']);
      await tester.scrollUntilVisible(find.text('Not today'), 100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not today'));
      await tester.pumpAndSettle();
      expect(find.text('That suggestion is hidden for today.'), findsOneWidget);
      await tester.ensureVisible(find.text('Suggestion settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suggestion settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Save'), 100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(api.enabled, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
