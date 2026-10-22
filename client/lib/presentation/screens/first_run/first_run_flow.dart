/// First run: a mix before an account (spec
/// `docs/superpowers/specs/2026-10-20-first-run-flow-design.md`; board
/// `docs/mockups/2026-10-20-first-run-flow-states.html`).
///
/// The flow rides the root navigator: Welcome is the root page, every other
/// page is pushed with [FirstRunPageRoute], and back pops. Path A is Welcome,
/// Who do you love?, then the mix. Path B is three counted steps (Which do
/// you use?, How do you want to add it?, the doing page), then the prompt
/// page and the mix. The flow ends by handing off to the shell, which opens
/// the new mix ([FirstRunActiveNotifier.handOff]).
///
/// Library's Add your music pushes path B's three steps in
/// [AddMusicMode.library], which pops back to Library when the music is in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/api/api_client.dart';
import '../../../data/dj/dj_api.dart';
import '../../../data/listening/listening_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dj_providers.dart';
import '../../providers/first_run_flags_provider.dart';
import '../../providers/first_run_funnel_provider.dart';
import '../../providers/first_run_provider.dart';
import '../../providers/onboarding_provider.dart';
import 'artists_screen.dart';
import 'choose_service_screen.dart';
import 'making_screen.dart';
import 'welcome_screen.dart';

/// The root of the first-run flow: Welcome.
class FirstRunFlow extends StatelessWidget {
  const FirstRunFlow({super.key});

  @override
  Widget build(BuildContext context) => const WelcomeScreen();
}

/// Where path B's pages were opened from.
enum AddMusicMode {
  /// The first-run flow: after the music, the prompt page and the mix.
  firstRun,

  /// Library's Add your music: after the music, back to Library.
  library,
}

/// A first-run push. A [MaterialPageRoute], cross-faded under reduced
/// motion (spec → Accessibility).
class FirstRunPageRoute<T> extends MaterialPageRoute<T> {
  FirstRunPageRoute({required super.builder, super.settings});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// Path B's routes are named under this prefix, so the library mode can pop
/// every one of them at once.
const String addMusicRoutePrefix = 'add-music/';

Future<T?> pushFirstRunPage<T>(
  BuildContext context,
  Widget page, {
  String? name,
}) => Navigator.of(context).push<T>(
  FirstRunPageRoute<T>(
    builder: (_) => page,
    settings: RouteSettings(name: name),
  ),
);

/// Library's Add your music: Step 1 of path B in library mode. Completes
/// when the listener is back on Library.
Future<void> openAddMusic(BuildContext context) => pushFirstRunPage<void>(
  context,
  const ChooseServiceScreen(mode: AddMusicMode.library),
  name: '${addMusicRoutePrefix}1',
);

/// Records a first-run funnel event from a page in [mode]. Library's add
/// flow is not the first run and records nothing.
void recordFirstRun(
  BuildContext context,
  AddMusicMode mode,
  FunnelEventType type,
) {
  if (mode != AddMusicMode.firstRun) return;
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(firstRunFunnelProvider).record(type);
}

/// The music is in ([songs] usable songs, possibly none).
///
/// First run: the prompt page with the count, or Who do you love? first when
/// nothing usable came in. Library: back to Library.
void finishAddMusic(
  BuildContext context,
  AddMusicMode mode, {
  required int songs,
}) {
  switch (mode) {
    case AddMusicMode.library:
      _popAddMusic(context);
    case AddMusicMode.firstRun:
      recordFirstRun(context, mode, FunnelEventType.syncDone);
      if (songs > 0) {
        pushFirstRunPage<void>(context, WelcomeScreen.prompt(songsIn: songs));
      } else {
        pushFirstRunPage<void>(context, const ArtistsScreen());
      }
  }
}

/// "I've requested it" or "Skip for now": nothing usable yet. First run goes
/// on to Who do you love?; Library goes back.
void continueWithoutMusic(BuildContext context, AddMusicMode mode) {
  switch (mode) {
    case AddMusicMode.library:
      _popAddMusic(context);
    case AddMusicMode.firstRun:
      pushFirstRunPage<void>(context, const ArtistsScreen());
  }
}

/// Step 1's "Skip for now". With the server's never-refuse flag on, a
/// listener with no music still gets a mix, so first run goes to the prompt
/// page and its send makes the mix without artists; otherwise as
/// [continueWithoutMusic]. The flag was read when the flow opened
/// ([firstRunFlagsProvider]); a failed read is off.
Future<void> skipAddMusic(BuildContext context, AddMusicMode mode) async {
  if (mode == AddMusicMode.firstRun) {
    final flags = await ProviderScope.containerOf(
      context,
      listen: false,
    ).read(firstRunFlagsProvider.future);
    if (!context.mounted) return;
    if (flags.neverRefuse) {
      unawaited(
        pushFirstRunPage<void>(
          context,
          const WelcomeScreen.prompt(withoutMusic: true),
        ),
      );
      return;
    }
  }
  continueWithoutMusic(context, mode);
}

void _popAddMusic(BuildContext context) {
  Navigator.of(context).popUntil(
    (route) => !(route.settings.name?.startsWith(addMusicRoutePrefix) ?? false),
  );
}

/// Copy for the failures the flow can show. No em dashes on these pages.
abstract final class FirstRunErrors {
  static const String offline =
      "Couldn't reach the DJ. Check your connection and try again.";
  static const String generic = 'Something went wrong on our end. Try again.';
  static const String seeds = "Couldn't save those artists. Try again.";
}

String firstRunErrorFor(Object error) => switch (error) {
  NetworkException() => FirstRunErrors.offline,
  DjApiException(:final message) => message,
  _ => FirstRunErrors.generic,
};

/// The flow's first server action creates the anonymous listener (spec →
/// "When the anonymous user is created": lazily). A session already present,
/// anonymous or not, is used as it is.
Future<void> ensureAnonymousSession(WidgetRef ref) async {
  if (ref.read(authProvider) == AuthStatus.noSession) {
    await ref.read(authProvider.notifier).signInAnonymously();
  }
}

/// Who do you love?'s Continue: the seeds the corpus mix needs, written
/// before the first prompt is sent.
Future<void> saveArtistSeeds(WidgetRef ref, List<String> names) async {
  await ensureAnonymousSession(ref);
  await ref.read(listeningApiProvider).putArtistSeeds(names);
}

/// Sends the first prompt and hands off to the shell, which opens the mix.
///
/// The DJ turn takes 20 to 60 seconds, so [MakingScreen] is pushed over the
/// caller's page the moment the start begins and popped when it returns,
/// whatever the outcome; a failure leaves the listener back on the caller's
/// page with what they typed.
///
/// Returns null once handed off (the caller's page is about to unmount), or
/// the sentence to show when the mix could not start. A session that
/// persisted despite a failed first turn is handed off like Home does, with
/// the failure seeded into the conversation. A capped anonymous listener
/// (possible only if this flow's session already had three mixes) gets
/// [onCap], the sign-in page, and no sentence: nothing about the cap is
/// drawn by the composer.
Future<String?> startFirstMix(
  BuildContext context,
  WidgetRef ref,
  String prompt, {
  void Function()? onCap,
}) async {
  final navigator = Navigator.of(context);
  final making = FirstRunPageRoute<void>(
    builder: (_) => const MakingScreen(),
    settings: const RouteSettings(name: MakingScreen.routeName),
  );
  unawaited(navigator.push(making));
  void leaveMaking() {
    if (making.isCurrent) {
      navigator.pop();
    } else if (making.isActive) {
      navigator.removeRoute(making);
    }
  }

  try {
    await ensureAnonymousSession(ref);
    final sessionId = await ref.read(sessionStarterProvider)(prompt);
    leaveMaking();
    ref
        .read(firstRunActiveProvider.notifier)
        .handOff(PendingConversation(sessionId));
    return null;
  } on AnonymousCapException {
    leaveMaking();
    onCap?.call();
    return null;
  } on DjApiException catch (e) {
    leaveMaking();
    final sessionId = e.sessionId;
    if (sessionId == null) return e.message;
    ref
        .read(firstRunActiveProvider.notifier)
        .handOff(PendingConversation(sessionId, initialError: e.message));
    return null;
  } catch (e) {
    leaveMaking();
    return firstRunErrorFor(e);
  }
}
