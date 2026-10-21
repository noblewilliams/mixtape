/// Making your mix. (first-run spec → The pages, path A step 3).
///
/// A DJ turn takes 20 to 60 seconds. From the moment the first prompt is
/// sent, [startFirstMix] pushes this page over the page it came from and
/// pops it when the turn returns: the welcome background, the cassette with
/// its hubs turning (still under reduced motion), the headline and one line.
/// No counter, no back button, no pills, and the system back is blocked,
/// because leaving abandons the mix.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../widgets/foundation/cassette_tile.dart';
import 'step_scaffold.dart';
import 'welcome_screen.dart';

class MakingScreen extends StatefulWidget {
  const MakingScreen({super.key});

  static const String headline = 'Making your mix.';
  static const String line = 'The DJ is listening. This takes about a minute.';
  static const String routeName = 'first-run/making';

  static const Key cassetteKey = Key('first-run-making-cassette');

  @override
  State<MakingScreen> createState() => _MakingScreenState();
}

class _MakingScreenState extends State<MakingScreen> {
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
    return PopScope(
      // The flow pops this page itself when the turn returns.
      canPop: false,
      child: StepScaffold(
        background: FirstRunBackground.welcome,
        headline: MakingScreen.headline,
        line: MakingScreen.line,
        showBack: false,
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
