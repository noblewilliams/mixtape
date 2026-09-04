import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import 'fake_import_service.dart';
import 'fake_listening_api.dart';

/// authProvider settled at a stable status (same pattern as
/// dj_providers_test.dart's TestAuthNotifier).
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus status) => state = status;
}

/// A DjApi that answers Home's sessions list with nothing and refuses
/// everything else — the onboarding screens never talk to the DJ.
class BareDjApi implements DjApi {
  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<List<DjSession>> listSessions() async => [];

  @override
  Future<SessionDetail> createSession(String prompt) => throw UnimplementedError();

  @override
  Future<SessionDetail> getSession(String id) => throw UnimplementedError();

  @override
  Future<TurnResult> sendMessage(String id, String text) => throw UnimplementedError();

  @override
  Future<QueueOpsResult> applyQueueOps(String id, List<QueueOp> ops, int? expectedVersion) =>
      throw UnimplementedError();

  @override
  Future<DjSession> setStatus(String id, String status) => throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) => throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) => throw UnimplementedError();

  @override
  Future<List<DjMemory>> listMemories() => throw UnimplementedError();

  @override
  Future<void> deleteMemory(String id) => throw UnimplementedError();

  @override
  void close() {}
}

/// Records the addresses a screen asked to open instead of launching them.
class FakeLinkOpener {
  final List<Uri> opened = [];

  Future<bool> call(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

/// A container for the onboarding screens: signed in, a bare DJ, the given
/// listening API, and fakes for both device integrations so no platform
/// channel is ever touched.
ProviderContainer onboardingContainer({
  required FakeListeningApi listening,
  FakeReminderScheduler? reminders,
  ServicePreferenceStore? prefs,
  FakeLinkOpener? links,
  AuthNotifier? auth,
  FakeImportService? importService,
  FakeArchivePicker? picker,
  FakeOpenedArchiveSource? opened,
  String timeZone = 'Africa/Lagos',
  ExportDiagnoser? diagnoser,
}) {
  final container = ProviderContainer(
    overrides: [
      listeningImportServiceProvider.overrideWithValue(importService ?? FakeImportService()),
      archivePickerProvider.overrideWithValue(picker ?? FakeArchivePicker()),
      openedArchiveSourceProvider.overrideWithValue(opened ?? FakeOpenedArchiveSource()),
      deviceTimeZoneProvider.overrideWithValue(() async => timeZone),
      exportDiagnoserProvider.overrideWithValue(diagnoser ?? (_) async => brokenDiagnostics),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(BareDjApi()),
      listeningApiProvider.overrideWithValue(listening),
      authProvider.overrideWith(() => auth ?? TestAuthNotifier(AuthStatus.signedIn)),
      reminderSchedulerProvider.overrideWithValue(reminders ?? FakeReminderScheduler()),
      servicePreferenceStoreProvider
          .overrideWithValue(prefs ?? InMemoryServicePreferenceStore()),
      funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
      linkOpenerProvider.overrideWithValue((links ?? FakeLinkOpener()).call),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpScreen(WidgetTester tester, ProviderContainer container, Widget home) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: MaterialApp(home: home)),
  );
  await tester.pumpAndSettle();
}

bool _isInteractive(Widget w) =>
    w is ButtonStyleButton ||
    w is TextField ||
    w is IconButton ||
    w is InputChip ||
    w is ListTile ||
    w is SwitchListTile;

/// House rule: every interactive widget carries a Key. Audits the Material
/// controls under [root] that a screen declares itself: a match nested inside
/// another match is the framework's own internal (an IconButton builds an
/// `_IconButtonM3`, a SwitchListTile a ListTile) and is skipped, while a private type the screen declares
/// directly (`FilledButton.icon` is a `_FilledButtonWithIcon`) is checked.
void expectInteractiveWidgetsKeyed(Finder root) {
  final interactive = find.descendant(of: root, matching: find.byWidgetPredicate(_isInteractive));
  expect(interactive, findsWidgets);
  for (final element in interactive.evaluate()) {
    var nested = false;
    element.visitAncestorElements((ancestor) {
      nested = _isInteractive(ancestor.widget);
      return !nested;
    });
    if (nested) continue;
    expect(element.widget.key, isNotNull,
        reason: '${element.widget.runtimeType} without a Key');
  }
}
