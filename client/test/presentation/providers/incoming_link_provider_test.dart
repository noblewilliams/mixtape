// C2: universal links. A share link (`<share base>/m/<token>`) that opens the
// app, on a cold start or while it runs, becomes a pending token the root
// opens SharedMixScreen for. Any other link is ignored.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/share/share_link.dart';
import 'package:mixtape/presentation/providers/incoming_link_provider.dart';

import '../../helpers/fake_incoming_links.dart';

const token = 'AbCdEfGhIjKlMnOpQrStUv';
const other = 'ZyXwVuTsRqPoNmLkJiHgFe';

Uri shareLink(String t) => Uri.parse(shareUrlFor(t));

ProviderContainer containerWith(FakeIncomingLinkSource source) {
  final container = ProviderContainer(
    overrides: [incomingLinkSourceProvider.overrideWithValue(source)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('cold start: the launch link becomes the pending token', () async {
    final source = FakeIncomingLinkSource(initial: shareLink(token));
    final container = containerWith(source);

    expect(container.read(pendingSharedMixProvider), isNull);
    await pumpEventQueue();

    expect(container.read(pendingSharedMixProvider), token);
  });

  test('a link tapped while running becomes the pending token', () async {
    final source = FakeIncomingLinkSource();
    final container = containerWith(source);
    container.read(pendingSharedMixProvider);
    await pumpEventQueue();
    expect(container.read(pendingSharedMixProvider), isNull);

    source.tap(shareLink(other));
    await pumpEventQueue();

    expect(container.read(pendingSharedMixProvider), other);
  });

  test('links that are not shares are ignored', () async {
    final source = FakeIncomingLinkSource(
      initial: Uri.parse('https://miixtape.netlify.app/app/'),
    );
    final container = containerWith(source);
    container.read(pendingSharedMixProvider);
    await pumpEventQueue();

    source.tap(Uri.parse('https://example.com/m/$token'));
    source.tap(Uri.parse('https://miixtape.netlify.app/m/short'));
    await pumpEventQueue();

    expect(container.read(pendingSharedMixProvider), isNull);
  });

  test('consume hands the token over once and clears it', () async {
    final source = FakeIncomingLinkSource(initial: shareLink(token));
    final container = containerWith(source);
    container.read(pendingSharedMixProvider);
    await pumpEventQueue();

    final notifier = container.read(pendingSharedMixProvider.notifier);
    expect(notifier.consume(), token);
    expect(container.read(pendingSharedMixProvider), isNull);
    expect(notifier.consume(), isNull);
  });

  test(
    'the same link tapped again after it was opened is pending again',
    () async {
      final source = FakeIncomingLinkSource();
      final container = containerWith(source);
      container.read(pendingSharedMixProvider);
      await pumpEventQueue();

      source.tap(shareLink(token));
      await pumpEventQueue();
      container.read(pendingSharedMixProvider.notifier).consume();

      source.tap(shareLink(token));
      await pumpEventQueue();
      expect(container.read(pendingSharedMixProvider), token);
    },
  );

  test(
    'the launch link is delivered once even when the stream repeats it',
    () async {
      // app_links on iOS hands the launch link to getInitialLink and also to
      // the stream's first listener.
      final source = FakeIncomingLinkSource(initial: shareLink(token));
      final container = containerWith(source);
      container.read(pendingSharedMixProvider);
      await pumpEventQueue();
      expect(
        container.read(pendingSharedMixProvider.notifier).consume(),
        token,
      );

      source.tap(shareLink(token));
      await pumpEventQueue();
      expect(container.read(pendingSharedMixProvider), isNull);

      // A real second tap of the same link opens it again.
      source.tap(shareLink(token));
      await pumpEventQueue();
      expect(container.read(pendingSharedMixProvider), token);
    },
  );

  test('the stream delivering the launch link first is not repeated by the '
      'initial link', () async {
    final source = FakeIncomingLinkSource(initial: shareLink(token));
    final container = containerWith(source);
    container.read(pendingSharedMixProvider);
    // The stream's copy lands before getInitialLink answers.
    source.tap(shareLink(token));
    await pumpEventQueue();
    container.read(pendingSharedMixProvider.notifier).consume();
    await pumpEventQueue();

    expect(container.read(pendingSharedMixProvider), isNull);
  });

  test('dispose cancels the subscription', () async {
    final source = FakeIncomingLinkSource();
    final container = ProviderContainer(
      overrides: [incomingLinkSourceProvider.overrideWithValue(source)],
    );
    container.read(pendingSharedMixProvider);
    await pumpEventQueue();
    expect(source.listening, isTrue);

    container.dispose();

    expect(source.listening, isFalse);
    expect(source.cancels, 1);
  });

  test('the presenter defaults to a no-op', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(sharedMixPresenterProvider), isNotNull);
  });
}
