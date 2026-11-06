/// The sheet over a new anonymous listener's first mix (board frame A6;
/// first-run spec → path A step 3, copy amended 2026-11-06) and the cap's
/// hand-off to sign-in ("Cap reached", board C2).
///
/// The sheet is the app's standard [showMixtapeSheet]: it says the mix is
/// ready, its paper pill (Go to my mix) closes it onto the mix, and the
/// quieter Create an account pushes the sign-in page — so nobody mistakes
/// sign-in for the way to their mix. Provider buttons
/// never appear in a sheet or the composer panel (founder, 2026-10-20); they
/// live only on [KeepMixesSignInPage].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart';
import '../providers/auth_provider.dart';
import '../providers/first_run_funnel_provider.dart';
import '../providers/keep_mixes_provider.dart';
import '../screens/first_run/step_scaffold.dart' show FirstRunPill;
import '../screens/sign_in_screen.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/mixtape_sheet.dart';

/// What the listener chose in the sheet. The handle, the scrim and Go to my
/// mix all close it without a choice, onto the mix.
enum _KeepChoice { keep }

abstract final class KeepSheet {
  static const String headline = 'Your mix is ready.';
  static const String line =
      'It\u2019s saved on this device. Create an account to have it on your '
      'other devices too.';
  static const String goToMixLabel = 'Go to my mix';
  static const String createAccountLabel = 'Create an account';

  /// The board's `.fp.paper` inset hairline on the pill.
  static const Color pillHairline = Color.fromRGBO(50, 44, 50, 0.14);

  static const Key headlineKey = Key('keep-sheet-headline');
  static const Key pillHairlineKey = Key('keep-sheet-pill-hairline');
  static const Key goToMixKey = Key('keep-sheet-go-to-mix');
  static const Key createAccountKey = Key('keep-sheet-create-account');
}

/// Shows the sheet over [context] and records what happened. Showing it is
/// the session's one showing ([KeepSheetNotifier.take] already marked it).
Future<void> showKeepSheet(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final funnel = container.read(firstRunFunnelProvider);
  funnel.record(FunnelEventType.keepSheetShown);
  final choice = await showMixtapeSheet<_KeepChoice>(
    context,
    isScrollControlled: true,
    builder: (_) => const _KeepSheetBody(),
  );
  if (choice == _KeepChoice.keep) {
    funnel.record(FunnelEventType.keepSheetSignedIn);
    if (context.mounted) await openKeepMixesSignIn(context, fromMix: true);
  } else {
    funnel.record(FunnelEventType.keepSheetDismissed);
  }
}

/// The cap: a fourth new mix from an anonymous listener. Keeps [kept] for
/// after sign-in, records `cap_reached` once, and pushes the sign-in page
/// with the cap line. Back returns to the composer, which still holds the
/// prompt, so the kept copy is dropped; a sign-in remounts the root as the
/// account and Home sends it ([KeptPromptNotifier.take]).
Future<void> openCapSignIn(BuildContext context, KeptPrompt kept) async {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(keptPromptProvider.notifier).keep(kept);
  container.read(firstRunFunnelProvider).record(FunnelEventType.capReached);
  await openKeepMixesSignIn(context, cap: true);
  if (container.read(isAnonymousProvider)) {
    container.read(keptPromptProvider.notifier).clear();
  }
}

class _KeepSheetBody extends StatelessWidget {
  const _KeepSheetBody();

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: KeepSheet.headline,
      // 200 % text scrolls inside the sheet rather than overflowing it.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // First in reading order, so VoiceOver starts on it.
            Semantics(
              header: true,
              child: Text(
                KeepSheet.headline,
                key: KeepSheet.headlineKey,
                style: tokens.largeTitle.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  letterSpacing: -0.6,
                  color: tokens.text,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              KeepSheet.line,
              style: tokens.body.copyWith(
                fontSize: 16,
                height: 1.4,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 22),
            DecoratedBox(
              key: KeepSheet.pillHairlineKey,
              position: DecorationPosition.foreground,
              decoration: const ShapeDecoration(
                shape: StadiumBorder(
                  side: BorderSide(color: KeepSheet.pillHairline),
                ),
              ),
              child: FirstRunPill(
                key: KeepSheet.goToMixKey,
                label: KeepSheet.goToMixLabel,
                emphasis: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                key: KeepSheet.createAccountKey,
                onPressed: () => Navigator.of(context).pop(_KeepChoice.keep),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.text,
                  minimumSize: const Size(
                    MixtapeMetrics.minTarget,
                    MixtapeMetrics.minTarget,
                  ),
                ),
                child: Text(
                  KeepSheet.createAccountLabel,
                  style: tokens.body.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
