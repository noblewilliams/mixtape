/// Making your mix. (first-run spec → The pages, path A step 3).
///
/// A DJ turn takes 20 to 60 seconds. From the moment the first prompt is
/// sent, [startFirstMix] pushes this page over the page it came from and
/// pops it when the turn returns: the welcome background, the cassette with
/// its hubs turning (still under reduced motion), the headline and one line.
/// No counter, no back button, no pills, and the system back is blocked,
/// because leaving abandons the mix.
///
/// Under the line, the DJ's working line (turn steps, 2026-11-13): what the
/// first turn is doing as its stream says it, on the conversation's clock
/// until then ([DjWorkingLine]). VoiceOver keeps its one announcement.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mix_activity_provider.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/cassette_tile.dart';
import '../../widgets/lyric_turn.dart' show DjWorkingLine;
import 'step_scaffold.dart';
import 'welcome_screen.dart';

class MakingScreen extends ConsumerStatefulWidget {
  const MakingScreen({super.key});

  static const String headline = 'Making your mix.';

  /// The step line under it starts on "The DJ is listening…", so this one
  /// does not say it too (turn steps spec, First-run Making screens).
  static const String line = 'This takes about a minute.';
  static const String routeName = 'first-run/making';

  static const Key cassetteKey = Key('first-run-making-cassette');
  static const Key stepKey = Key('first-run-making-step');

  @override
  ConsumerState<MakingScreen> createState() => _MakingScreenState();
}

class _MakingScreenState extends ConsumerState<MakingScreen> {
  @override
  void initState() {
    super.initState();
    // The headline names the route on push; the line is read once after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        SemanticsService.announce(
          MakingScreen.line,
          Directionality.maybeOf(context) ?? TextDirection.ltr,
          assertiveness: Assertiveness.polite,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // The new mix's first turn, once its create's stream opens.
    final step = ref.watch(mixActivityProvider.select((a) => a.pendingStep));
    return PopScope(
      // The flow pops this page itself when the turn returns.
      canPop: false,
      child: StepScaffold(
        background: FirstRunBackground.welcome,
        headline: MakingScreen.headline,
        line: MakingScreen.line,
        showBack: false,
        centerTop: true,
        body: [
          const SizedBox(height: 6),
          // The line above is read once; this one changes too often to be.
          ExcludeSemantics(
            child: DjWorkingLine(
              key: MakingScreen.stepKey,
              step: step,
              // The line's type, a step quieter.
              style: FirstRunType.line(
                context.tokens,
              ).copyWith(color: FirstRunColors.cream.withValues(alpha: 0.8)),
            ),
          ),
        ],
        top: Center(
          child: Transform.rotate(
            angle: 0.07,
            child: const ExcludeSemantics(
              child: CassetteTile(
                key: MakingScreen.cassetteKey,
                width: WelcomeScreen.cassetteWidth,
                // The tile holds the hubs still under reduced motion.
                spinning: true,
                shadow: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
