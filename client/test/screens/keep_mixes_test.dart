// Task 10 of the first-run plan, end to end through the app root: the Keep
// this mix sheet (board A6), the cap (C2), the link that remounts the root,
// the kept prompt, and the merge notice (C4). First-run spec → path A step 3,
// "Cap reached", "The merge".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/keep_mixes_provider.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';
import 'package:mixtape/presentation/widgets/home_panel.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/keep_sheet.dart';
import 'package:mixtape/presentation/widgets/merge_notice.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';

import '../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../helpers/fake_bridge.dart' show FakeBridge;
import '../helpers/fake_import_service.dart';
import 'first_run/first_run_harness.dart';

/// Auth whose social sign-in behaves like a link from an anonymous session:
/// the flag flips, the provider passes through `unknown` (the root remounts
/// twice) and comes back as an account session.
class _LinkAuth extends AuthNotifier {
  _LinkAuth(this._initial, {bool anonymous = false}) : _anon = anonymous;

  final AuthStatus _initial;
  bool _anon;
  int signIns = 0;

  /// Thrown by the next sign-in instead of linking (a cancelled sheet, a
  /// failed request).
  Object? failWith;

  /// The link flips the flag and stays `session` with no `unknown` frame.
  bool skipUnknown = false;

  @override
  AuthStatus build() => _initial;

  @override
  bool get isAnonymous => _anon;

  @override
  Future<void> signInAnonymously() async {
    if (state == AuthStatus.session) return;
    _anon = true;
    state = AuthStatus.session;
  }

  @override
  Future<void> signIn({
    AccountProvider provider = AccountProvider.apple,
  }) async {
    signIns++;
    final failure = failWith;
    if (failure != null) throw failure;
    _anon = false;
    if (skipUnknown) {
      ref.notifyListeners();
      return;
    }
    state = AuthStatus.unknown;
    await Future<void>.delayed(Duration.zero);
    state = AuthStatus.session;
  }

  @override
  Future<void> signOut() async {
    _anon = false;
    state = AuthStatus.noSession;
  }
}

QueueTrack _track(int position) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: 'apple-$position',
  title: 'Title $position',
  artist: 'Artist',
  durationMs: 180000,
);

/// Creates sessions with [queue] (empty is the DJ's honest refusal) and
/// numbers them, so a second mix is a different conversation.
class _Dj extends FirstRunDjApi {
  List<QueueTrack> queue = [_track(1), _track(2)];
  int created = 0;

  /// Runs as a create succeeds, before it returns.
  void Function()? onCreate;

  /// What a follow-up turn answers with.
  List<QueueTrack> turnQueue = [_track(1), _track(2), _track(3)];
  final List<String> turns = [];

  @override
  Future<TurnResult> sendMessage(String id, String text) async {
    turns.add(text);
    return TurnResult(
      djMessage: DjMessage(
        id: 'dj-${turns.length}',
        role: 'dj',
        content: 'Here you go.',
        queueVersion: 2,
        createdAt: DateTime(2026, 10, 20),
      ),
      queue: turnQueue,
      queueVersion: 2,
    );
  }

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) async {
    prompts.add(prompt);
    final failure = failWith;
    if (failure != null) throw failure;
    onCreate?.call();
    created++;
    return _detail('session-$created');
  }

  @override
  Future<SessionDetail> getSession(String id) async => _detail(id);

  SessionDetail _detail(String id) => SessionDetail(
    session: DjSession(
      id: id,
      title: 'New mix',
      status: 'active',
      queueVersion: 1,
      updatedAt: DateTime(2026, 10, 20),
    ),
    messages: const [],
    queue: queue,
  );
}

class _Rig {
  _Rig({AuthStatus status = AuthStatus.session, bool anonymous = true})
    : auth = _LinkAuth(status, anonymous: anonymous);

  final _LinkAuth auth;
  final FirstRunHarness h = FirstRunHarness();
  final _Dj dj = _Dj();
  MergedMode? merged;
  int mergeReads = 0;

  List<FunnelEventType> get events => h.listening.funnelEvents;

  late final ProviderContainer container = () {
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => auth),
        djApiProvider.overrideWithValue(dj),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        listeningApiProvider.overrideWithValue(h.listening),
        reminderSchedulerProvider.overrideWithValue(h.reminders),
        servicePreferenceStoreProvider.overrideWithValue(h.prefs),
        funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        linkOpenerProvider.overrideWithValue(h.links.call),
        librarySyncProvider.overrideWith(() => h.sync),
        listeningImportServiceProvider.overrideWithValue(FakeImportService()),
        archivePickerProvider.overrideWithValue(h.picker),
        openedArchiveSourceProvider.overrideWithValue(
          FakeOpenedArchiveSource(),
        ),
        mergedModeReaderProvider.overrideWithValue(() async {
          mergeReads++;
          final value = merged;
          merged = null; // the server clears it on read
          return value;
        }),
        musicKitBridgeProvider.overrideWithValue(FakeBridge(const [])),
        authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
        accountNameProvider.overrideWith((ref) async => null),
        mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
        playbackProvider.overrideWithValue(
          PlaybackController(playback.FakeApi(), playback.FakeBridge()),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }();

  Future<void> pump(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MixtapeApp(),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _send(WidgetTester tester, String prompt) async {
  await tester.enterText(find.byKey(const Key('prompt-field')), prompt);
  await tester.pump();
  await tester.tap(find.byKey(const Key('start-session')));
  await tester.pumpAndSettle();
}

Future<void> _backToHome(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('chat-back')));
  await tester.pumpAndSettle();
}

Finder get _sheet => find.text(KeepSheet.headline);

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('prompt-field')))
    .controller!
    .text;

int _count(List<FunnelEventType> events, FunnelEventType type) =>
    events.where((e) => e == type).length;

void main() {
  reduceMotion();

  group('Keep this mix sheet', () {
    testWidgets('shows once, after the first anonymous mix with content, and '
        'Not now holds for the rest of the session', (tester) async {
      final r = _Rig();
      await r.pump(tester);

      await _send(tester, 'rainy commute');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_sheet, findsOneWidget);
      expect(find.text(KeepSheet.line), findsOneWidget);
      expect(find.byKey(KeepSheet.keepKey), findsOneWidget);
      expect(find.byKey(KeepSheet.notNowKey), findsOneWidget);
      expect(
        find.byType(ProviderSignInButton),
        findsNothing,
        reason: 'provider buttons never appear in a sheet',
      );
      expect(r.events, contains(FunnelEventType.firstMixMade));
      expect(r.events, contains(FunnelEventType.keepSheetShown));

      await tester.tap(find.byKey(KeepSheet.notNowKey));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(r.events, contains(FunnelEventType.keepSheetDismissed));
      expect(r.container.read(keepSheetProvider).shown, isTrue);

      await _backToHome(tester);
      await _send(tester, 'second one');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_sheet, findsNothing, reason: 'Not now is final for the session');
      expect(_count(r.events, FunnelEventType.firstMixMade), 1);
      expect(_count(r.events, FunnelEventType.keepSheetShown), 1);
    });

    testWidgets('not after a refusal with an empty queue', (tester) async {
      final r = _Rig();
      r.dj.queue = const [];
      await r.pump(tester);

      await _send(tester, 'artists nobody knows');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_sheet, findsNothing);
      expect(r.events, contains(FunnelEventType.firstMixRefused));
      expect(r.events, isNot(contains(FunnelEventType.firstMixMade)));
      expect(r.events, isNot(contains(FunnelEventType.keepSheetShown)));
    });

    testWidgets('a refused mix that a follow-up turn fills counts as the '
        'first mix: the sheet shows on that turn, first_mix_made once', (
      tester,
    ) async {
      final r = _Rig();
      r.dj.queue = const [];
      await r.pump(tester);
      await _send(tester, 'artists nobody knows');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_sheet, findsNothing);

      final chat = find.byType(ChatScreen);
      await tester.enterText(
        find.descendant(of: chat, matching: find.byType(TextField)),
        'try Sade and Tems',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(r.dj.turns, ['try Sade and Tems']);
      expect(_sheet, findsOneWidget);
      expect(_count(r.events, FunnelEventType.firstMixRefused), 1);
      expect(_count(r.events, FunnelEventType.firstMixMade), 1);
      expect(_count(r.events, FunnelEventType.keepSheetShown), 1);

      await tester.tap(find.byKey(KeepSheet.notNowKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: chat, matching: find.byType(TextField)),
        'more like that',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing, reason: 'the queue was not empty before');
      expect(_count(r.events, FunnelEventType.firstMixMade), 1);
      expect(_count(r.events, FunnelEventType.keepSheetShown), 1);
    });

    testWidgets('the pill carries the board\'s inset hairline', (
      tester,
    ) async {
      final r = _Rig();
      await r.pump(tester);
      await _send(tester, 'rainy commute');
      final box = tester.widget<DecoratedBox>(
        find.byKey(KeepSheet.pillHairlineKey),
      );
      expect(box.position, DecorationPosition.foreground);
      final side =
          ((box.decoration as ShapeDecoration).shape as StadiumBorder).side;
      expect(side.color, const Color.fromRGBO(50, 44, 50, 0.14));
      expect(side.width, 1);
      expect(side.strokeAlign, BorderSide.strokeAlignInside);
    });

    testWidgets('never for an account', (tester) async {
      final r = _Rig(anonymous: false);
      await r.pump(tester);

      await _send(tester, 'rainy commute');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_sheet, findsNothing);
      expect(r.events, isNot(contains(FunnelEventType.firstMixMade)));
      expect(r.events, isNot(contains(FunnelEventType.keepSheetShown)));
    });

    testWidgets('its pill opens the sign-in page: "Keep your mixes." on the '
        'plum background, with the providers there', (tester) async {
      final r = _Rig();
      await r.pump(tester);
      await _send(tester, 'rainy commute');

      await tester.tap(find.byKey(KeepSheet.keepKey));
      await tester.pumpAndSettle();

      expect(_sheet, findsNothing);
      expect(find.byType(KeepMixesSignInPage), findsOneWidget);
      expect(find.text(SignInScreen.keepMixesHeadline), findsOneWidget);
      expect(find.byKey(SignInScreen.lineKey), findsNothing);
      final image = tester.widget<Image>(
        find.byKey(SignInScreen.backgroundKey),
      );
      expect(
        (image.image as AssetImage).assetName,
        'assets/first_run/bg-sign-in.jpg',
      );
      expect(find.byType(ProviderSignInButton), findsNWidgets(2));
      expect(r.events, contains(FunnelEventType.keepSheetSignedIn));
      expect(r.events, isNot(contains(FunnelEventType.keepSheetDismissed)));

      // Back returns to the mix.
      await tester.tap(find.byKey(const Key('first-run-back')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_sheet, findsNothing);
    });

    testWidgets('the scrim dismisses it as Not now', (tester) async {
      final r = _Rig();
      await r.pump(tester);
      await _send(tester, 'rainy commute');
      expect(find.byKey(MixtapeSheet.handleKey), findsOneWidget);

      await tester.tapAt(const Offset(195, 40));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(r.events, contains(FunnelEventType.keepSheetDismissed));
      expect(r.container.read(keepSheetProvider).shown, isTrue);
    });

    testWidgets('a drag on the handle dismisses it as Not now', (tester) async {
      final r = _Rig();
      await r.pump(tester);
      await _send(tester, 'rainy commute');

      await tester.drag(
        find.byKey(MixtapeSheet.handleKey),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(r.events, contains(FunnelEventType.keepSheetDismissed));
    });

    testWidgets('VoiceOver starts on the headline', (tester) async {
      final semantics = tester.ensureSemantics();
      final r = _Rig();
      await r.pump(tester);
      await _send(tester, 'rainy commute');

      final headline = tester.getSemantics(find.byKey(KeepSheet.headlineKey));
      expect(headline.flagsCollection.isHeader, isTrue);
      // The headline is the sheet's first node in reading order: above the
      // line, the pill and Not now.
      final top = tester.getTopLeft(find.byKey(KeepSheet.headlineKey)).dy;
      expect(top, lessThan(tester.getTopLeft(find.text(KeepSheet.line)).dy));
      expect(
        top,
        lessThan(tester.getTopLeft(find.byKey(KeepSheet.keepKey)).dy),
      );
      semantics.dispose();
    });
  });

  group('cap', () {
    testWidgets('keeps the prompt, posts cap_reached once, pushes sign-in '
        'with the cap line; Back restores Home with the prompt', (
      tester,
    ) async {
      final r = _Rig();
      r.dj.failWith = const AnonymousCapException(3);
      await r.pump(tester);

      await _send(tester, 'one more');

      expect(find.byType(KeepMixesSignInPage), findsOneWidget);
      expect(find.text(SignInScreen.keepMixesHeadline), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(SignInScreen.lineKey)).data,
        'That’s three mixes on this device. Sign in to keep going, and '
        'to keep these.',
      );
      expect(find.byKey(SignInScreen.backgroundKey), findsOneWidget);
      expect(find.text('Last used'), findsNothing, reason: 'none on C2');
      expect(_count(r.events, FunnelEventType.capReached), 1);
      expect(
        r.container.read(keptPromptProvider),
        const KeptPrompt('one more'),
      );

      await tester.tap(find.byKey(const Key('first-run-back')));
      await tester.pumpAndSettle();

      expect(find.byType(KeepMixesSignInPage), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(_field(tester), 'one more');
      expect(r.container.read(keptPromptProvider), isNull);
      // Nothing about the cap in the panel.
      expect(
        find.descendant(
          of: find.byType(HomePanel),
          matching: find.byType(ProviderSignInButton),
        ),
        findsNothing,
      );
      expect(find.textContaining('three mixes'), findsNothing);

      // A second try is capped again, and cap_reached stays once.
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      expect(find.byType(KeepMixesSignInPage), findsOneWidget);
      expect(_count(r.events, FunnelEventType.capReached), 1);
    });

    testWidgets('after sign-in and the remount, the kept prompt is sent once', (
      tester,
    ) async {
      final r = _Rig();
      r.dj.failWith = const AnonymousCapException(3);
      await r.pump(tester);
      await _send(tester, 'one more');
      expect(find.byType(KeepMixesSignInPage), findsOneWidget);

      r.dj.failWith = null;
      await tester.tap(find.byKey(const Key('apple-sign-in')));
      await tester.pumpAndSettle();

      expect(r.auth.signIns, 1);
      expect(r.container.read(isAnonymousProvider), isFalse);
      expect(find.byType(KeepMixesSignInPage), findsNothing);
      expect(r.dj.prompts, ['one more', 'one more']);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(r.container.read(keptPromptProvider), isNull);
      expect(_sheet, findsNothing, reason: 'an account never sees the sheet');

      await _backToHome(tester);
      await tester.pumpAndSettle();
      expect(r.dj.prompts, hasLength(2), reason: 'consumed once');
    });

    testWidgets('the shape is kept apart from the draft: only the draft goes '
        'back in the field, and the brief is composed at send', (
      tester,
    ) async {
      final r = _Rig();
      r.dj.failWith = const AnonymousCapException(3);
      await r.pump(tester);
      await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
      await tester.pump();
      await tester.tap(find.byKey(EnergyControl.chipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.confirmKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(
        r.container.read(keptPromptProvider),
        const KeptPrompt('late', arc: EnergyArc.fall),
      );
      final brief = 'late\nEnergy journey: ${EnergyArc.fall.label}.';
      expect(r.dj.prompts, [brief]);

      r.dj.failWith = null;
      final field = <String>[];
      r.dj.onCreate = () => field.add(_field(tester));
      await tester.tap(find.byKey(const Key('apple-sign-in')));
      await tester.pumpAndSettle();

      expect(field, ['late'], reason: 'the draft only, never the brief');
      expect(r.dj.prompts, [brief, brief]);
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    for (final (name, failure) in [
      ('cancelled', AppleSignInCancelled()),
      ('failed', StateError('offline')),
    ]) {
      testWidgets('a $name sign-in from the cap page stays there; Back '
          'returns to Home with the prompt', (tester) async {
        final r = _Rig();
        r.dj.failWith = const AnonymousCapException(3);
        await r.pump(tester);
        await _send(tester, 'one more');
        r.auth.failWith = failure;

        await tester.tap(find.byKey(const Key('apple-sign-in')));
        await tester.pumpAndSettle();
        expect(r.auth.signIns, 1);
        expect(find.byType(KeepMixesSignInPage), findsOneWidget);
        expect(r.container.read(isAnonymousProvider), isTrue);

        await tester.tap(find.byKey(const Key('first-run-back')));
        await tester.pumpAndSettle();
        expect(find.byType(KeepMixesSignInPage), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(_field(tester), 'one more');
        expect(r.container.read(keptPromptProvider), isNull);
        expect(r.dj.prompts, ['one more'], reason: 'nothing sent later');
      });
    }

    testWidgets('a link with no unknown frame still remounts: the sign-in '
        'page goes, the kept prompt is sent once, /me is read once', (
      tester,
    ) async {
      final r = _Rig()..auth.skipUnknown = true;
      r.dj.failWith = const AnonymousCapException(3);
      await r.pump(tester);
      await _send(tester, 'one more');
      expect(find.byType(KeepMixesSignInPage), findsOneWidget);

      r.dj.failWith = null;
      r.merged = MergedMode.mixesOnly;
      await tester.tap(find.byKey(const Key('apple-sign-in')));
      await tester.pumpAndSettle();

      expect(r.container.read(authProvider), AuthStatus.session);
      expect(r.container.read(isAnonymousProvider), isFalse);
      expect(find.byType(KeepMixesSignInPage), findsNothing);
      expect(r.dj.prompts, ['one more', 'one more']);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(r.mergeReads, 1);
    });

    testWidgets('the composer panel never renders provider buttons', (
      tester,
    ) async {
      final r = _Rig();
      await r.pump(tester);
      expect(find.byType(HomePanel), findsOneWidget);
      expect(find.byType(ProviderSignInButton), findsNothing);
    });
  });

  group('merge notice', () {
    for (final (merged, message) in [
      (MergedMode.mixesOnly, MergeNotice.mixesOnly),
      (MergedMode.libraryKept, MergeNotice.libraryKept),
    ]) {
      testWidgets('${merged.name}: "$message"', (tester) async {
        final r = _Rig(anonymous: false)..merged = merged;
        await r.pump(tester);

        expect(find.text(message), findsOneWidget);
        expect(find.byType(MixtapeFeedback), findsOneWidget);
        expect(r.mergeReads, 1);
        // Polite: a live region, not an alert.
        final semantics = tester.ensureSemantics();
        expect(
          tester.getSemantics(find.text(message)).flagsCollection.isLiveRegion,
          isTrue,
        );
        semantics.dispose();
        // Above the panel and the dock (C4).
        expect(
          tester.getBottomLeft(find.byType(MixtapeFeedback)).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.byType(HomePanel)).dy),
        );
      });
    }

    for (final merged in [MergedMode.all, null]) {
      testWidgets('${merged?.name ?? 'null'}: nothing', (tester) async {
        final r = _Rig(anonymous: false)..merged = merged;
        await r.pump(tester);
        expect(find.byType(MixtapeFeedback), findsNothing);
        expect(r.mergeReads, 1);
      });
    }

    testWidgets('not read for an anonymous listener', (tester) async {
      final r = _Rig()..merged = MergedMode.mixesOnly;
      await r.pump(tester);
      expect(r.mergeReads, 0);
      expect(find.byType(MixtapeFeedback), findsNothing);
    });

    testWidgets('after a capped link, shown only once Home is the top '
        'route again', (tester) async {
      final r = _Rig();
      r.dj.failWith = const AnonymousCapException(3);
      await r.pump(tester);
      await _send(tester, 'one more');
      r.dj.failWith = null;
      r.merged = MergedMode.mixesOnly;

      await tester.tap(find.byKey(const Key('apple-sign-in')));
      await tester.pumpAndSettle();

      // The kept prompt's mix is on top: the notice waits for Home.
      expect(r.mergeReads, 1);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text(MergeNotice.mixesOnly), findsNothing);

      await _backToHome(tester);
      expect(find.text(MergeNotice.mixesOnly), findsOneWidget);
      expect(r.mergeReads, 1);
    });
  });
}
