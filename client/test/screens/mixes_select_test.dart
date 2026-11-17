// Select mode on the Mixes tab and its Archived screen
// (`docs/mockups/approved/2026-11-16-select-delete-mixes.md`; board frames
// S1–S10, section 1 of `docs/mockups/2026-11-16-select-delete-mixes.html`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';
import 'package:mixtape/presentation/screens/archived_mixes_screen.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/screens/shell/shell_route_observer.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';
import 'package:mixtape/presentation/widgets/mix_home_row.dart';
import 'package:mixtape/presentation/widgets/mix_select_mode.dart';
import 'package:mixtape/presentation/widgets/shared_mix_row.dart';

class _Api implements DjApi, DjSharedMixes, DjSessionDeleter {
  List<DjSession> sessions = [];
  List<SharedMixRow> shares = [];
  final deleteCalls = <List<String>>[];
  final statusCalls = <(String, String)>[];
  Future<List<String>> Function(List<String> ids)? onDelete;

  @override
  Future<List<DjSession>> listSessions() async => List.of(sessions);

  @override
  Future<List<SharedMixRow>> listSharedMixes() async => shares;

  @override
  Future<List<String>> deleteSessions(List<String> ids) {
    deleteCalls.add(ids);
    final impl = onDelete;
    if (impl != null) return impl(ids);
    sessions = [
      for (final s in sessions)
        if (!ids.contains(s.id)) s,
    ];
    return Future.value(ids);
  }

  @override
  Future<DjSession> setStatus(String id, String status) async {
    statusCalls.add((id, status));
    final index = sessions.indexWhere((s) => s.id == id);
    final next = sessions[index].copyWith(status: status);
    sessions[index] = next;
    return next;
  }

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not wired');
}

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
}

DjSession _session(
  String id,
  String title, {
  String status = 'active',
  bool shared = false,
  int minutesAgo = 0,
}) => DjSession(
  id: id,
  title: title,
  status: status,
  queueVersion: 1,
  updatedAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
  shared: shared,
);

_Api _api() => _Api()
  ..sessions = [
    _session('a', 'Sunday Reset'),
    _session('b', 'Smooth Cruise Through Lagos', minutesAgo: 30),
    _session('c', 'Deep Work, No Words', minutesAgo: 60),
    _session('z', 'Rainy drive home', status: 'archived', minutesAgo: 90),
  ];

ProviderContainer _container(
  _Api api, {
  bool anonymous = false,
  bool albums = true,
}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(_Auth.new),
      isAnonymousProvider.overrideWithValue(anonymous),
      albumPicksEnabledProvider.overrideWithValue(albums),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  double textScale = 1,
  // Wide enough that the toolbar keeps its count in the test font, whose
  // glyphs are a full em wide; S9 checks a phone at the largest text.
  Size size = const Size(700, 900),
  bool settle = true,
  bool inMixesTab = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MixtapeTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            // In the shell every tab root sits under its ShellTabScope.
            child: inMixesTab
                ? ShellTabScope(
                    index: AppTab.mixes.index,
                    child: Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => const MixesScreen(),
                      ),
                    ),
                  )
                : const MixesScreen(),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> _enterSelect(WidgetTester tester) async {
  await tester.tap(find.byKey(MixSelect.moreKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(MixSelect.selectMixesKey));
  await tester.pumpAndSettle();
}

Finder _toolbarText(String text) => find.descendant(
  of: find.byKey(MixSelect.toolbarKey),
  matching: find.text(text),
);

bool _enabled(WidgetTester tester, Key key) =>
    tester
        .getSemantics(find.byKey(key))
        .flagsCollection
        .isEnabled
        .toBoolOrNull() ==
    true;

void main() {
  testWidgets('⋯ opens Select mixes; select mode draws circles on own rows, '
      'none on shared, hides the toggle and takes the dock (S1, S2)', (
    tester,
  ) async {
    final api = _api()
      ..shares = [
        SharedMixRow(
          token: 'AbCdEfGhIjKlMnOpQrStUv',
          title: 'Late drive, windows down',
          caseColor: '#bc5734',
          sharerName: 'Ada',
          savedAt: DateTime.now().subtract(const Duration(minutes: 10)),
          trackCount: 10,
          durationMs: 2460000,
        ),
      ];
    final container = _container(api);
    await _pump(tester, container);

    expect(
      find.byType(SegmentedToggle).evaluate().isNotEmpty ||
          find.byKey(const Key('active-mixes')).evaluate().isNotEmpty,
      isTrue,
    );
    expect(find.byKey(MixSelect.moreKey), findsOneWidget);
    await tester.tap(find.byKey(MixSelect.moreKey));
    await tester.pumpAndSettle();
    expect(find.text(MixSelect.selectMixesLabel), findsOneWidget);
    await tester.tap(find.byKey(MixSelect.selectMixesKey));
    await tester.pumpAndSettle();

    for (final id in ['a', 'b', 'c']) {
      expect(find.byKey(MixSelect.circleKey(id)), findsOneWidget);
    }
    expect(find.byKey(MixSelect.circleKey('z')), findsNothing);
    expect(find.byType(MixSelectOffRow), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MixSelectOffRow),
        matching: find.byType(SharedMixHomeRow),
      ),
      findsOneWidget,
    );
    // Hidden, but its row keeps its room so the list does not jump.
    expect(find.byKey(const Key('active-mixes')).hitTestable(), findsNothing);
    expect(
      tester
          .widget<Visibility>(
            find
                .ancestor(
                  of: find.byKey(const Key('active-mixes')),
                  matching: find.byType(Visibility),
                )
                .first,
          )
          .visible,
      isFalse,
    );
    expect(find.byKey(MixSelect.moreKey), findsNothing);
    expect(find.text(MixSelect.selectAllLabel), findsOneWidget);
    expect(find.byKey(MixSelect.doneKey), findsOneWidget);
    expect(_toolbarText(MixSelect.selectMixesLabel), findsOneWidget);
    expect(_enabled(tester, MixSelect.archiveKey), isFalse);
    expect(_enabled(tester, MixSelect.deleteKey), isFalse);
    expect(container.read(dockTakeoverProvider), isTrue);

    await tester.tap(find.byKey(MixSelect.doneKey));
    await tester.pumpAndSettle();
    expect(find.byKey(MixSelect.toolbarKey), findsNothing);
    expect(find.byKey(MixSelect.circleKey('a')), findsNothing);
    expect(container.read(dockTakeoverProvider), isFalse);
  });

  testWidgets('a tap anywhere on a row ticks it, says so, and the count is '
      'announced (S3)', (tester) async {
    final announced = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (message) async {
        final map = message as Map<Object?, Object?>;
        if (map['type'] == 'announce') {
          announced.add((map['data']! as Map)['message'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          ),
    );
    final semantics = tester.ensureSemantics();
    final container = _container(_api());
    await _pump(tester, container);
    await _enterSelect(tester);

    await tester.tap(find.text('Smooth Cruise Through Lagos'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.circleKey('c')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsNothing, reason: 'a tap ticks');
    expect(_toolbarText(MixSelect.count(2)), findsOneWidget);
    expect(_enabled(tester, MixSelect.deleteKey), isTrue);
    expect(announced, [MixSelect.count(1), MixSelect.count(2)]);
    final row = tester.getSemantics(find.byKey(MixSelect.rowKey('b')));
    expect(row.flagsCollection.isSelected.toBoolOrNull(), isTrue);
    expect(row.label, startsWith('Smooth Cruise Through Lagos, '));
    expect(
      tester
          .getSemantics(find.byKey(MixSelect.rowKey('a')))
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      isFalse,
    );
    semantics.dispose();
  });

  testWidgets('Select all ticks every own mix and turns into Deselect all', (
    tester,
  ) async {
    await _pump(tester, _container(_api()));
    await _enterSelect(tester);

    await tester.tap(find.byKey(MixSelect.selectAllKey));
    await tester.pumpAndSettle();
    expect(_toolbarText(MixSelect.count(3)), findsOneWidget);
    expect(find.text(MixSelect.deselectAllLabel), findsOneWidget);

    await tester.tap(find.byKey(MixSelect.selectAllKey));
    await tester.pumpAndSettle();
    expect(_toolbarText(MixSelect.selectMixesLabel), findsOneWidget);
    expect(find.text(MixSelect.selectAllLabel), findsOneWidget);
  });

  testWidgets('swipe and long-press are off while selecting', (tester) async {
    await _pump(tester, _container(_api()));
    await _enterSelect(tester);

    await tester.drag(find.text('Sunday Reset'), const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(MixHomeRow.archiveActionKey('a')), findsNothing);
    await tester.longPress(find.text('Sunday Reset'));
    await tester.pumpAndSettle();
    expect(find.byKey(mixtapeMenuKey), findsNothing);
  });

  testWidgets('the row menu\'s Select opens select mode with that row ticked', (
    tester,
  ) async {
    await _pump(tester, _container(_api()));

    await tester.longPress(find.text('Deep Work, No Words'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(MixHomeRow.selectLabel));
    await tester.pumpAndSettle();

    expect(_toolbarText(MixSelect.count(1)), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(MixSelect.rowKey('c')))
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      isTrue,
    );
  });

  testWidgets('Delete confirms over Delete; confirming deletes, ends select '
      'mode and says "2 mixes deleted" (S4, S5)', (tester) async {
    final api = _api();
    final container = _container(api);
    await _pump(tester, container);
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.tap(find.text('Deep Work, No Words'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    expect(find.byKey(mixtapeConfirmKey), findsOneWidget);
    expect(find.text(MixSelect.confirmTitle(2)), findsOneWidget);
    expect(find.text('Delete 2 mixes?'), findsOneWidget);
    expect(find.textContaining(MixSelect.goneLine), findsOneWidget);
    expect(find.textContaining(MixSelect.sharedLine), findsNothing);
    expect(find.textContaining(MixSelect.workingLine), findsNothing);
    // Anchored over the toolbar's Delete.
    expect(
      tester.getRect(find.byKey(mixtapeConfirmKey)).bottom,
      lessThan(tester.getRect(find.byKey(MixSelect.deleteKey)).top),
    );

    await tester.tap(find.byKey(MixSelect.cancelKey));
    await tester.pumpAndSettle();
    expect(api.deleteCalls, isEmpty);
    expect(_toolbarText(MixSelect.count(2)), findsOneWidget);

    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 mixes'), findsOneWidget);
    await tester.tap(find.byKey(MixSelect.confirmDeleteKey));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, [
      ['a', 'c'],
    ]);
    expect(find.text('Sunday Reset'), findsNothing);
    expect(find.text('Deep Work, No Words'), findsNothing);
    expect(find.text('Smooth Cruise Through Lagos'), findsOneWidget);
    expect(find.byKey(MixSelect.toolbarKey), findsNothing);
    expect(container.read(dockTakeoverProvider), isFalse);
    expect(find.text('2 mixes deleted'), findsOneWidget);
  });

  testWidgets('one shared mix: "Delete this mix?", the share line, "Delete '
      'mix", and "Mix deleted"', (tester) async {
    final api = _api()
      ..sessions[1] = _session(
        'b',
        'Smooth Cruise Through Lagos',
        shared: true,
        minutesAgo: 30,
      );
    await _pump(tester, _container(api));
    await _enterSelect(tester);
    await tester.tap(find.text('Smooth Cruise Through Lagos'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    expect(find.text('Delete this mix?'), findsOneWidget);
    expect(find.textContaining(MixSelect.sharedLine), findsOneWidget);
    await tester.tap(find.text('Delete mix'));
    await tester.pumpAndSettle();
    expect(find.text('Mix deleted'), findsOneWidget);
  });

  testWidgets('a ticked mix the DJ is still making adds its line', (
    tester,
  ) async {
    final container = _container(_api());
    await _pump(tester, container);
    await _enterSelect(tester);
    container.read(mixActivityProvider.notifier).beginTurn('a');
    await tester.pump();
    await tester.tap(find.byKey(MixSelect.rowKey('a')));
    await tester.pump();

    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(MixSelect.workingLine), findsOneWidget);
  });

  testWidgets('while the delete runs the rows fade; a failure brings them back '
      'still ticked and says so (S6)', (tester) async {
    final answer = Completer<List<String>>();
    final api = _api()..onDelete = (_) => answer.future;
    await _pump(tester, _container(api));
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.confirmDeleteKey));
    await tester.pumpAndSettle();

    double opacityOf(String id) => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(MixSelect.rowKey(id)),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacityOf('a'), MixSelect.fadingOpacity);
    expect(opacityOf('b'), 1);
    expect(find.byKey(MixSelect.toolbarKey), findsOneWidget);

    answer.completeError(ApiException(500, 'boom'));
    await tester.pumpAndSettle();
    expect(find.text('Sunday Reset'), findsOneWidget);
    expect(opacityOf('a'), 1);
    expect(_toolbarText(MixSelect.count(1)), findsOneWidget);
    expect(find.text(MixSelect.deleteFailed), findsOneWidget);
  });

  testWidgets('signed out, Delete asks to sign in and deletes nothing (S7)', (
    tester,
  ) async {
    final api = _api();
    await _pump(tester, _container(api, anonymous: true));
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    expect(find.text(MixSelect.signInTitle), findsOneWidget);
    expect(find.textContaining(MixSelect.signInLine), findsOneWidget);
    expect(find.text(MixSelect.signInLabel), findsOneWidget);
    await tester.tap(find.byKey(MixSelect.notNowKey));
    await tester.pumpAndSettle();
    expect(api.deleteCalls, isEmpty);
    expect(_toolbarText(MixSelect.count(1)), findsOneWidget);
  });

  testWidgets('a 403 sign_in_required also asks to sign in', (tester) async {
    final api = _api()
      ..onDelete = (_) => Future.error(const SignInRequiredException());
    await _pump(tester, _container(api));
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.confirmDeleteKey));
    await tester.pumpAndSettle();

    expect(find.text(MixSelect.signInTitle), findsOneWidget);
    expect(find.text('Sunday Reset'), findsOneWidget);
  });

  testWidgets('Archive asks nothing: the ticked mixes archive, select mode '
      'ends, and one toast offers Undo', (tester) async {
    final api = _api();
    await _pump(tester, _container(api));
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.tap(find.text('Deep Work, No Words'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MixSelect.archiveKey));
    await tester.pumpAndSettle();
    expect(api.statusCalls, [('a', 'archived'), ('c', 'archived')]);
    expect(find.byKey(MixSelect.toolbarKey), findsNothing);
    expect(find.text('2 mixes archived'), findsOneWidget);
    expect(find.text('Sunday Reset'), findsNothing);
  });

  testWidgets('Archived has the same ⋯; select mode puts Select all in Back\'s '
      'place and Unarchive in Archive\'s (S8)', (tester) async {
    final api = _api();
    await _pump(tester, _container(api));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 140));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixesScreen.archivedRowKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ArchivedMixesScreen.backKey), findsOneWidget);

    await _enterSelect(tester);
    expect(find.byKey(ArchivedMixesScreen.backKey), findsNothing);
    expect(find.text(MixSelect.selectAllLabel), findsOneWidget);
    expect(_toolbarText(MixSelect.unarchiveLabel), findsOneWidget);

    await tester.tap(find.text('Rainy drive home'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.archiveKey));
    await tester.pumpAndSettle();
    expect(api.statusCalls, [('z', 'active')]);
    expect(find.text('Mix unarchived'), findsOneWidget);
    expect(find.byKey(ArchivedMixesScreen.backKey), findsOneWidget);
  });

  testWidgets('at the largest text the count drops out first and nothing '
      'overflows (S9)', (tester) async {
    await _pump(
      tester,
      _container(_api()),
      textScale: 3.1,
      size: const Size(390, 844),
    );
    await _enterSelect(tester);
    await tester.tap(find.byKey(MixSelect.rowKey('a')));
    await tester.pumpAndSettle();

    expect(find.byKey(MixSelect.countKey), findsNothing);
    expect(_toolbarText(MixSelect.archiveLabel), findsOneWidget);
    expect(_toolbarText(MixSelect.deleteLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The circle stays level with the title's first line, not the row's
    // middle.
    final circle = tester.getRect(find.byKey(MixSelect.circleKey('a')));
    final row = tester.getRect(find.byKey(MixSelect.rowKey('a')));
    expect(circle.center.dy, lessThan(row.center.dy));
  });

  testWidgets('switching tabs ends select mode, handing the dock back', (
    tester,
  ) async {
    final container = _container(_api());
    container.read(selectedTabProvider.notifier).selectTab(AppTab.mixes);
    await _pump(tester, container, inMixesTab: true);
    await _enterSelect(tester);
    expect(container.read(dockTakeoverProvider), isTrue);

    container.read(selectedTabProvider.notifier).selectTab(AppTab.home);
    await tester.pumpAndSettle();
    expect(container.read(dockTakeoverProvider), isFalse);
    expect(find.byKey(MixSelect.toolbarKey), findsNothing);
  });

  testWidgets('switching tabs ends select mode on Archived too, so the dock '
      'is never left taken', (tester) async {
    final container = _container(_api());
    container.read(selectedTabProvider.notifier).selectTab(AppTab.mixes);
    await _pump(tester, container, inMixesTab: true);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 140));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixesScreen.archivedRowKey));
    await tester.pumpAndSettle();
    await _enterSelect(tester);
    expect(container.read(dockTakeoverProvider), isTrue);

    container.read(selectedTabProvider.notifier).selectTab(AppTab.home);
    await tester.pumpAndSettle();
    expect(container.read(dockTakeoverProvider), isFalse);
    expect(find.byKey(MixSelect.toolbarKey), findsNothing);
  });

  testWidgets('the toast counts what the server deleted; ids it skipped '
      'leave the list too', (tester) async {
    final api = _api()..onDelete = (ids) async => [ids.first];
    await _pump(tester, _container(api));
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.tap(find.text('Deep Work, No Words'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.confirmDeleteKey));
    await tester.pumpAndSettle();

    expect(find.text('Mix deleted'), findsOneWidget);
    expect(find.text('2 mixes deleted'), findsNothing);
    expect(find.text('Sunday Reset'), findsNothing);
    expect(find.text('Deep Work, No Words'), findsNothing);
  });

  testWidgets('nothing deleted, nothing to say', (tester) async {
    final api = _api()..onDelete = (_) async => const [];
    await _pump(tester, _container(api));
    await _enterSelect(tester);
    await tester.tap(find.text('Sunday Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixSelect.confirmDeleteKey));
    await tester.pumpAndSettle();

    expect(find.text('Sunday Reset'), findsNothing);
    expect(find.text('Mix deleted'), findsNothing);
    expect(find.byKey(MixSelect.toolbarKey), findsNothing);
  });

  testWidgets('a new mix still on its first turn, once listed, adds the '
      'working line', (tester) async {
    final container = _container(_api());
    container
        .read(mixActivityProvider.notifier)
        .beginNewMix('a sunday reset', knownIds: {'b', 'c', 'z'});
    await _pump(tester, container, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(MixSelect.moreKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(MixSelect.selectMixesKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(MixSelect.rowKey('a')));
    await tester.pump();

    await tester.tap(find.byKey(MixSelect.deleteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(MixSelect.workingLine), findsOneWidget);
  });
}
