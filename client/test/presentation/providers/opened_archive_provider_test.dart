// C5: a ZIP handed to the app from Files or Mail. The notifier is
// user-scoped, so an archive opened for one listener can never surface for
// the next one, and an archive that arrives while nobody is signed in waits
// for the sign-in rather than being dropped.
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/opened_archive_provider.dart';

import '../../helpers/fake_import_service.dart';
import '../../helpers/fake_listening_api.dart';
import '../../helpers/onboarding_harness.dart';

void main() {
  test('a cold start takes the archive the launch left pending, once', () async {
    final opened = FakeOpenedArchiveSource(pending: extendedArchive);
    final container = onboardingContainer(listening: FakeListeningApi(), opened: opened);

    expect(container.read(openedArchiveProvider), isNull);
    await pumpEventQueue();

    expect(container.read(openedArchiveProvider), extendedArchive);
    expect(opened.takes, 1);

    // Home opened the flow with it: it is gone, and nothing re-delivers it.
    container.read(openedArchiveProvider.notifier).consumed(extendedArchive);
    expect(container.read(openedArchiveProvider), isNull);
    await pumpEventQueue();
    expect(container.read(openedArchiveProvider), isNull);
  });

  test('an archive opened while the app is running arrives on the stream', () async {
    final opened = FakeOpenedArchiveSource();
    final container = onboardingContainer(listening: FakeListeningApi(), opened: opened);
    container.read(openedArchiveProvider);
    await pumpEventQueue();

    opened.hand(accountArchive);
    await pumpEventQueue();

    expect(container.read(openedArchiveProvider), accountArchive);
  });

  test('an archive opened before the listener signs in waits for the sign-in', () async {
    final auth = TestAuthNotifier(AuthStatus.signedOut);
    final opened = FakeOpenedArchiveSource();
    final container =
        onboardingContainer(listening: FakeListeningApi(), opened: opened, auth: auth);
    container.read(openedArchiveProvider);
    await pumpEventQueue();

    opened.hand(extendedArchive);
    await pumpEventQueue();
    expect(container.read(openedArchiveProvider), isNull, reason: 'nobody to open it for yet');
    expect(opened.takes, 0);

    auth.set(AuthStatus.signedIn);
    container.read(openedArchiveProvider);
    await pumpEventQueue();

    expect(container.read(openedArchiveProvider), extendedArchive);
  });

  test('an archive opened for one listener never surfaces for the next', () async {
    final auth = TestAuthNotifier(AuthStatus.signedIn);
    final opened = FakeOpenedArchiveSource();
    final container =
        onboardingContainer(listening: FakeListeningApi(), opened: opened, auth: auth);
    container.read(openedArchiveProvider);
    await pumpEventQueue();

    opened.hand(extendedArchive);
    await pumpEventQueue();
    expect(container.read(openedArchiveProvider), extendedArchive);

    auth.set(AuthStatus.signedOut);
    container.read(openedArchiveProvider);
    auth.set(AuthStatus.signedIn);
    container.read(openedArchiveProvider);
    await pumpEventQueue();

    expect(container.read(openedArchiveProvider), isNull);
  });
}
