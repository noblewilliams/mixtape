// The routine suggestion as Home's first idea pill (plan
// `docs/superpowers/plans/2026-09-17-native-design-implementation.md` task
// 3.2; frames I1/I2 in `docs/mockups/2026-09-17-mobile-home-states.html`).
//
// The September 9 card is gone: the suggestion is one pill that fills the
// composer and never sends, with the board's native context menu on
// long-press and the same three actions as VoiceOver rotor actions.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/suggestions/suggestions_api.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/routine_suggestions.dart';

/// The suggestions API, with gates so a test can hold the load or the
/// selection open and look at the pill while it is in flight.
class FakeSuggestions implements SuggestionsApi {
  bool enabled = true, hidden = false, expired = false;
  int selections = 0, loads = 0, saves = 0;
  Completer<void>? loadGate;
  Completer<String>? pending;

  static const RoutineSuggestion eligible = RoutineSuggestion(
    id: '5-3-fall',
    title: 'Your usual Friday wind-down?',
    reason: 'You have made winding-down mixes on 3 Friday evenings.',
  );

  static const String prompt = 'Make a mix that gradually winds down.';

  @override
  Future<SuggestionsData> load(String zone) async {
    loads++;
    if (loadGate != null) await loadGate!.future;
    return SuggestionsData(
      enabled: enabled,
      dismissed: hidden,
      suggestion: enabled && !hidden ? eligible : null,
    );
  }

  @override
  Future<String> select(String id, String zone) async {
    selections++;
    if (expired) throw Exception('expired');
    if (pending != null) return pending!.future;
    return prompt;
  }

  @override
  Future<void> dismiss(String id, String zone) async {
    hidden = true;
  }

  @override
  Future<void> save(bool value) async {
    saves++;
    enabled = value;
  }
}

/// The slot on its own, with a starter pill as the fallback the board asks
/// for when nothing is eligible.
Future<void> _pumpSlot(
  WidgetTester tester, {
  required FakeSuggestions api,
  TimeZoneReader? readZone,
  List<String>? filled,
  bool enabled = true,
  bool dimmed = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        suggestionsApiProvider.overrideWithValue(api),
        suggestionTimeZoneProvider.overrideWithValue(
          readZone ?? () async => 'UTC',
        ),
      ],
      child: MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: RoutinePillSlot(
              onFill: (prompt) => filled?.add(prompt),
              enabled: enabled,
              dimmed: dimmed,
              // Home's panel shows a third starter where the routine would
              // have been; the slot hands it `null` to say so.
              builder: (context, pill) =>
                  pill ??
                  const IdeaPill(
                    key: Key('fallback-starter'),
                    label: 'A rainy drive home',
                  ),
            ),
          ),
        ),
      ),
    ),
  );
}

List<String?> _customActions(WidgetTester tester, Finder finder) {
  final data = tester.getSemantics(finder).getSemanticsData();
  return [
    for (final id in data.customSemanticsActionIds ?? const <int>[])
      CustomSemanticsAction.getAction(id)?.label,
  ];
}

void main() {
  testWidgets('the slot is a skeleton pill while the routine loads', (
    tester,
  ) async {
    final api = FakeSuggestions()..loadGate = Completer<void>();
    await _pumpSlot(tester, api: api);
    await tester.pump();

    final skeleton = tester.widget<IdeaPill>(find.byType(IdeaPill));
    expect(skeleton.skeleton, isTrue);
    expect(find.byKey(const Key('fallback-starter')), findsNothing);

    api.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<IdeaPill>(find.byType(IdeaPill)).label,
      FakeSuggestions.eligible.title,
    );
  });

  testWidgets('tapping the routine pill fills the field and never sends', (
    tester,
  ) async {
    final api = FakeSuggestions();
    final filled = <String>[];
    await _pumpSlot(tester, api: api, filled: filled);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();

    expect(api.selections, 1);
    expect(filled, [FakeSuggestions.prompt]);
  });

  testWidgets('nothing eligible falls back to the starter pill', (
    tester,
  ) async {
    await _pumpSlot(tester, api: FakeSuggestions()..hidden = true);
    await tester.pumpAndSettle();

    expect(find.byKey(RoutinePillSlot.pillKey), findsNothing);
    expect(find.byKey(const Key('fallback-starter')), findsOneWidget);
  });

  testWidgets('an unknown time zone falls back with no error on Home', (
    tester,
  ) async {
    await _pumpSlot(
      tester,
      api: FakeSuggestions(),
      readZone: () async => throw StateError('Time zone unavailable'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fallback-starter')), findsOneWidget);
    expect(find.textContaining('Could not'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long press offers Not today, which hides the pill for today', (
    tester,
  ) async {
    final api = FakeSuggestions();
    await _pumpSlot(tester, api: api);
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();
    expect(find.text(RoutinePillSlot.notTodayLabel), findsOneWidget);
    expect(find.text(RoutinePillSlot.whyLabel), findsOneWidget);
    expect(find.text(RoutinePillSlot.turnOffLabel), findsOneWidget);

    await tester.tap(find.byKey(RoutinePillSlot.notTodayKey));
    await tester.pumpAndSettle();
    expect(api.hidden, isTrue);
    expect(find.byKey(const Key('fallback-starter')), findsOneWidget);
  });

  testWidgets('"Why this?" shows the reason in a sheet', (tester) async {
    await _pumpSlot(tester, api: FakeSuggestions());
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RoutinePillSlot.whyKey));
    await tester.pumpAndSettle();

    expect(find.byKey(RoutinePillSlot.whySheetKey), findsOneWidget);
    expect(find.text(FakeSuggestions.eligible.reason), findsOneWidget);
  });

  testWidgets('"Turn off routine suggestions" writes the settings toggle', (
    tester,
  ) async {
    final api = FakeSuggestions();
    await _pumpSlot(tester, api: api);
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RoutinePillSlot.turnOffKey));
    await tester.pumpAndSettle();

    expect(api.saves, 1);
    expect(api.enabled, isFalse);
    expect(find.byKey(const Key('fallback-starter')), findsOneWidget);
  });

  testWidgets('the pill carries the three actions as rotor actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpSlot(tester, api: FakeSuggestions());
    await tester.pumpAndSettle();

    expect(
      _customActions(tester, find.byKey(RoutinePillSlot.pillKey)),
      containsAll(<String?>[
        RoutinePillSlot.notTodayLabel,
        RoutinePillSlot.whyLabel,
        RoutinePillSlot.turnOffLabel,
      ]),
    );
    handle.dispose();
  });

  testWidgets('a disabled slot neither fills nor opens its menu', (
    tester,
  ) async {
    final api = FakeSuggestions();
    final filled = <String>[];
    await _pumpSlot(tester, api: api, filled: filled, enabled: false);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();

    expect(filled, isEmpty);
    expect(api.selections, 0);
    expect(find.text(RoutinePillSlot.notTodayLabel), findsNothing);
  });

  testWidgets('a late selection cannot fill a field that is gone', (
    tester,
  ) async {
    final api = FakeSuggestions()..pending = Completer<String>();
    final filled = <String>[];
    await _pumpSlot(tester, api: api, filled: filled);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(RoutinePillSlot.pillKey));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    api.pending!.complete('A brief');
    await tester.pump();

    expect(filled, isEmpty);
  });
}
