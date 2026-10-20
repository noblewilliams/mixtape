/// Welcome, and the prompt page after the music is in (board frames A1, A2
/// and B8).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/listening/listening_models.dart';
import '../../format/import_format.dart';
import '../../providers/first_run_funnel_provider.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/cassette_tile.dart';
import '../../providers/keep_mixes_provider.dart' show KeptPrompt;
import '../../widgets/keep_sheet.dart';
import '../../widgets/mix_prompt_input.dart';
import '../sign_in_screen.dart';
import 'artists_screen.dart';
import 'choose_service_screen.dart';
import 'first_run_flow.dart';
import 'step_scaffold.dart';

/// "What do you want to hear?": the wordmark, the cassette with its hubs
/// turning (still under reduced motion), the composer with the three
/// rotating examples, and, on Welcome itself, the "or" divider, Add my music
/// first and the sign-in foot link.
///
/// [WelcomeScreen.prompt] is the same page after path B: no add-music pill,
/// a back button, and the library count under the field.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key})
    : songsIn = null,
      isPrompt = false,
      seedsSaved = false;

  /// The prompt page. [songsIn] is the real count from the sync or import;
  /// [seedsSaved] is set when Who do you love? has already run, so a send
  /// goes straight to the mix.
  const WelcomeScreen.prompt({super.key, this.songsIn, this.seedsSaved = false})
    : isPrompt = true;

  final int? songsIn;
  final bool isPrompt;
  final bool seedsSaved;

  static const String headline = 'What do you want to hear?';
  static const List<String> examples = [
    'something for a rainy commute',
    '90s R&B, no ballads',
    'warm up for a long run',
  ];
  static const String addMusicLabel = 'Add my music first';
  static const String footLead = 'Already have an account?';
  static const String footLink = 'Sign in.';

  static String songsInLine(int songs) =>
      '${formatCount(songs)} songs in. Ask for anything.';

  static const Key addMusicKey = Key('first-run-add-music');
  static const Key signInKey = Key('first-run-sign-in');
  static const Key cassetteKey = Key('first-run-cassette');
  static const Key errorKey = Key('first-run-start-error');
  static const Key countLineKey = Key('first-run-songs-in');

  static const double cassetteWidth = 176;

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _controller = TextEditingController();
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.isPrompt) {
      ref.read(firstRunFunnelProvider).record(FunnelEventType.firstRunOpened);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _goesStraightToMix => widget.seedsSaved || (widget.songsIn ?? 0) > 0;

  Future<void> _send() async {
    if (_starting) return;
    final prompt = _controller.text.trim();
    if (prompt.isEmpty) return;
    if (!widget.isPrompt) {
      ref.read(firstRunFunnelProvider).record(FunnelEventType.choseMakeMix);
    }
    if (!_goesStraightToMix) {
      // Nothing synced in this flow: the corpus mix needs seeds first.
      unawaited(pushFirstRunPage<void>(context, ArtistsScreen(prompt: prompt)));
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    final error = await startFirstMix(
      ref,
      prompt,
      onCap: () {
        if (mounted) {
          unawaited(openCapSignIn(context, KeptPrompt(prompt)));
        }
      },
    );
    if (!mounted) return;
    setState(() {
      _starting = false;
      _error = error;
    });
  }

  void _addMusic() {
    ref.read(firstRunFunnelProvider).record(FunnelEventType.choseAddMusic);
    unawaited(
      pushFirstRunPage<void>(
        context,
        const ChooseServiceScreen(mode: AddMusicMode.firstRun),
        name: '${addMusicRoutePrefix}1',
      ),
    );
  }

  void _signIn() =>
      unawaited(pushFirstRunPage<void>(context, const FirstRunSignInPage()));

  @override
  Widget build(BuildContext context) {
    final songs = widget.songsIn ?? 0;
    return StepScaffold(
      background: FirstRunBackground.welcome,
      headline: WelcomeScreen.headline,
      showBack: widget.isPrompt,
      top: const _Hero(),
      body: [
        const SizedBox(height: 24),
        withTokens(
          context,
          paperTokens,
          MixPromptInput(
            controller: _controller,
            busy: _starting,
            onSubmit: () => unawaited(_send()),
            exampleSet: WelcomeScreen.examples,
            showVoiceInput: false,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              key: WelcomeScreen.errorKey,
              style: FirstRunType.line(
                context.tokens,
              ).copyWith(color: FirstRunColors.err),
            ),
          ),
        ],
        if (widget.isPrompt && songs > 0) ...[
          const SizedBox(height: 12),
          Text(
            WelcomeScreen.songsInLine(songs),
            key: WelcomeScreen.countLineKey,
            style: FirstRunType.line(context.tokens),
          ),
        ],
        if (!widget.isPrompt) ...[
          const SizedBox(height: 18),
          const _OrDivider(),
        ],
      ],
      actions: [
        if (!widget.isPrompt)
          FirstRunPill(
            key: WelcomeScreen.addMusicKey,
            label: WelcomeScreen.addMusicLabel,
            onPressed: _starting ? null : _addMusic,
          ),
      ],
      foot: FootLink(
        key: WelcomeScreen.signInKey,
        lead: WelcomeScreen.footLead,
        label: WelcomeScreen.footLink,
        onPressed: _starting ? null : _signIn,
      ),
    );
  }
}

/// The wordmark over the turning cassette.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Transform.rotate(
            angle: -0.035,
            alignment: Alignment.centerLeft,
            child: Text(
              'mixtape',
              style: tokens.wordmark.copyWith(fontSize: 30),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Transform.rotate(
            angle: 0.07,
            child: const ExcludeSemantics(
              child: CassetteTile(
                key: WelcomeScreen.cassetteKey,
                width: WelcomeScreen.cassetteWidth,
                // The tile holds the hubs still under reduced motion.
                spinning: true,
                shadow: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The board's `.fr-or`: a hairline, "or", a hairline.
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final hair = Expanded(
      child: Container(
        height: 1,
        color: FirstRunColors.cream.withValues(alpha: 0.35),
      ),
    );
    return Semantics(
      label: 'or',
      excludeSemantics: true,
      child: Row(
        children: [
          hair,
          const SizedBox(width: 12),
          Text(
            'OR',
            style: context.tokens.meta.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.76,
              color: FirstRunColors.cream.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(width: 12),
          hair,
        ],
      ),
    );
  }
}

/// The existing sign-in page, reached from the welcome foot link, on the
/// plum black graphic like every first-run page (approval → Locked
/// behaviour, "Sign-in page"), with the outlined back button in cream. The
/// headline is unchanged from this link (spec → Sign-in page); the sheet,
/// the cap and the You row use [KeepMixesSignInPage].
class FirstRunSignInPage extends StatelessWidget {
  const FirstRunSignInPage({super.key});

  @override
  Widget build(BuildContext context) => const Stack(
    children: [
      SignInScreen(background: FirstRunBackground.signIn),
      SafeArea(
        child: Padding(
          padding: EdgeInsets.only(left: 8, top: 6),
          child: TapeBackButton(),
        ),
      ),
    ],
  );
}
