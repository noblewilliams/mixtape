/// The Phase 1 gate: every foundation component on one screen, so the shell
/// can be reviewed in the simulator in light, dark and 200% text.
///
/// Debug only — `main.dart` reaches it behind `kDebugMode` and
/// `--dart-define=MIXTAPE_GALLERY=true`, so it never ships in a release build.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/cassette_tile.dart';
import '../../widgets/foundation/flush_row.dart';
import '../../widgets/foundation/frosted_surface.dart';
import '../../widgets/foundation/glass_cluster.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../../widgets/foundation/idea_pill.dart';
import '../../widgets/foundation/inset_group.dart';
import '../../widgets/foundation/label_chip.dart';
import '../../widgets/foundation/large_title_scaffold.dart';
import '../../widgets/foundation/prism_stripe.dart';
import '../../widgets/foundation/reason_band.dart';
import '../../widgets/foundation/section_word.dart';
import '../../widgets/foundation/segmented_toggle.dart';
import '../../widgets/foundation/square_art.dart';
import '../../widgets/foundation/status_word.dart';
import '../../widgets/foundation/tape_button.dart';
import '../../widgets/foundation/text_action.dart';
import '../../widgets/mix_prompt_input.dart';

/// A scrolling catalogue of the foundation widgets, with its own light/dark
/// and text-scale switches so the whole matrix can be checked on device
/// without leaving the screen.
class FoundationGalleryScreen extends StatefulWidget {
  const FoundationGalleryScreen({super.key});

  /// The section words, in the order they appear. Also the gate's checklist.
  static const List<String> sectionWords = [
    'Colours',
    'Type',
    'Controls',
    'Composer',
    'Lists',
    'Cassettes',
    'Grouped',
    'Glass',
  ];

  /// The text scales the trailing button cycles through.
  static const List<double> textScaleSteps = [1, 1.5, 2];

  /// The light/dark override button.
  static const Key themeButtonKey = ValueKey('foundationGallery.theme');

  /// The text-scale button.
  static const Key textScaleButtonKey = ValueKey('foundationGallery.textScale');

  /// The `MediaQuery` carrying the overridden text scale.
  static const Key textScaleScopeKey = ValueKey('foundationGallery.scaleScope');

  /// The first widget inside the overridden theme, so a test can read the
  /// brightness the gallery is actually painting.
  static const Key bodyKey = ValueKey('foundationGallery.body');

  /// The room under the last section, so the title always has somewhere to
  /// collapse into.
  static const double bottomPadding = 400;

  @override
  State<FoundationGalleryScreen> createState() =>
      _FoundationGalleryScreenState();
}

class _FoundationGalleryScreenState extends State<FoundationGalleryScreen> {
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _voiceComposer = TextEditingController();

  /// Null follows the platform; a tap pins the gallery to one brightness.
  Brightness? _brightness;
  int _scaleStep = 0;

  @override
  void dispose() {
    _composer.dispose();
    _voiceComposer.dispose();
    super.dispose();
  }

  void _toggleBrightness(Brightness current) => setState(
    () => _brightness = current == Brightness.dark
        ? Brightness.light
        : Brightness.dark,
  );

  void _cycleTextScale() => setState(
    () => _scaleStep =
        (_scaleStep + 1) % FoundationGalleryScreen.textScaleSteps.length,
  );

  @override
  Widget build(BuildContext context) {
    final brightness = _brightness ?? Theme.of(context).brightness;
    final theme = brightness == Brightness.dark
        ? MixtapeTheme.dark()
        : MixtapeTheme.light();
    final scale = FoundationGalleryScreen.textScaleSteps[_scaleStep];

    return Theme(
      data: theme,
      child: Builder(
        builder: (context) => MediaQuery(
          key: FoundationGalleryScreen.textScaleScopeKey,
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          // The gradient reads the overridden tokens, so it follows the switch.
          child: GradientBackground(
            key: FoundationGalleryScreen.bodyKey,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: LargeTitleScaffold(
                title: 'Foundation',
                trailing: GlassCluster(
                  children: [
                    GlassButton(
                      key: FoundationGalleryScreen.themeButtonKey,
                      icon: brightness == Brightness.dark
                          ? CupertinoIcons.sun_max
                          : CupertinoIcons.moon,
                      label: 'Toggle light and dark',
                      onPressed: () => _toggleBrightness(brightness),
                    ),
                    GlassButton(
                      key: FoundationGalleryScreen.textScaleButtonKey,
                      icon: CupertinoIcons.textformat_size,
                      label: 'Text scale ${scale}x',
                      onPressed: _cycleTextScale,
                    ),
                  ],
                ),
                slivers: [
                  SliverList.list(
                    children: [
                      const _Colours(),
                      const _Type(),
                      const _Controls(),
                      _Composers(
                        controller: _composer,
                        voiceController: _voiceComposer,
                      ),
                      const _Lists(),
                      const _Cassettes(),
                      const _Grouped(),
                      const _Glass(),
                      const SizedBox(
                        height: FoundationGalleryScreen.bottomPadding,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 40 pt swatch with its token name underneath.
class _Swatch extends StatelessWidget {
  const _Swatch(this.name, this.color);

  final String name;
  final Color color;

  static const double size = 40;

  /// Wide enough for the swatch, narrow enough that four fit a phone.
  static const double column = 72;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: column,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(MixtapeMetrics.tileRadius),
            border: Border.all(color: context.tokens.hairline),
          ),
        ),
        const SizedBox(height: 4),
        Text(name, style: context.tokens.meta),
      ],
    ),
  );
}

class _Colours extends StatelessWidget {
  const _Colours();

  static const double barHeight = 48;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Colours'),
        Wrap(
          spacing: 8,
          runSpacing: 12,
          children: [
            _Swatch('text', t.text),
            _Swatch('plum', t.plum),
            _Swatch('smoke', t.smoke),
            _Swatch('muted', t.muted),
            _Swatch('tape fill', t.tapeFill),
            for (var i = 0; i < t.prism.length; i++)
              _Swatch('prism ${i + 1}', t.prism[i]),
            _Swatch('ok ink', t.okInk),
            _Swatch('warn ink', t.warnInk),
            _Swatch('err ink', t.errInk),
          ],
        ),
        const SizedBox(height: 12),
        _GradientBar(gradient: t.prismGradient()),
        const SizedBox(height: 8),
        _GradientBar(gradient: t.prismVertical),
      ],
    );
  }
}

class _GradientBar extends StatelessWidget {
  const _GradientBar({required this.gradient});

  final Gradient gradient;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: gradient,
      borderRadius: BorderRadius.circular(MixtapeMetrics.tileRadius),
    ),
    child: const SizedBox(height: _Colours.barHeight, width: double.infinity),
  );
}

class _Type extends StatelessWidget {
  const _Type();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final styles = <String, TextStyle>{
      'largeTitle': t.largeTitle,
      'smallTitle': t.smallTitle,
      'section': t.section,
      'rowTitle': t.rowTitle,
      'body': t.body,
      'secondary': t.secondary,
      'meta': t.meta,
      'label': t.label,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionWord('Type'),
        for (final entry in styles.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(entry.key, style: entry.value),
          ),
      ],
    );
  }
}

class _Controls extends StatefulWidget {
  const _Controls();

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  /// The gallery's live segmented toggle, so the thumb can be watched sliding
  /// on device in both themes and at every text scale.
  bool _archived = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionWord('Controls'),
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedToggle<bool>(
          value: _archived,
          onChanged: (value) => setState(() => _archived = value),
          options: const [
            SegmentedOption(value: false, label: 'Active'),
            SegmentedOption(value: true, label: 'Archived'),
          ],
        ),
      ),
      const SizedBox(height: 10),
      // A scrolling strip, not a Wrap: `TapeButton` and `LabelChip` lay their
      // label out unbounded inside a min-size Row, so on a 320 pt screen at
      // 200% text they run past a bounded parent instead of ellipsising.
      // Giving the strip unbounded width shows them at full size — scroll to
      // read the rest — rather than clipping them. See the report note.
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            TapeButton(label: 'Play now', onPressed: () {}),
            const SizedBox(width: 10),
            TapeButton(label: 'Playing', playing: true, onPressed: () {}),
            const SizedBox(width: 10),
            const TapeButton(label: 'Unavailable'),
            const SizedBox(width: 10),
            LabelChip(label: 'Create playlist', onPressed: () {}),
            const SizedBox(width: 10),
            TextAction(label: 'Rename', onPressed: () {}),
            const SizedBox(width: 10),
            TextAction(label: 'Not today', quiet: true, onPressed: () {}),
          ],
        ),
      ),
      Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IdeaPill(label: 'Your usual Friday wind-down?', onPressed: () {}),
          IdeaPill(label: 'Kitchen, early, coffee on', onPressed: () {}),
          IdeaPill(
            label: 'Running, long, no lyrics',
            dimmed: true,
            onPressed: () {},
          ),
          const IdeaPill(label: '', skeleton: true),
        ],
      ),
      const SizedBox(height: 8),
      const Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          StatusWord(label: 'Connected', kind: StatusKind.ok),
          StatusWord(label: 'Waiting', kind: StatusKind.warn),
          StatusWord(label: "Couldn't reach the DJ", kind: StatusKind.err),
        ],
      ),
      const SizedBox(height: 12),
      const PrismStripe(),
    ],
  );
}

class _Composers extends StatelessWidget {
  const _Composers({required this.controller, required this.voiceController});

  final TextEditingController controller;
  final TextEditingController voiceController;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionWord('Composer'),
      MixPromptInput(
        controller: controller,
        busy: false,
        onSubmit: _noop,
        showVoiceInput: false,
      ),
      const SizedBox(height: 12),
      MixPromptInput(
        controller: voiceController,
        busy: false,
        onSubmit: _noop,
        showVoiceInput: true,
      ),
    ],
  );

  static void _noop() {}
}

class _Lists extends StatelessWidget {
  const _Lists();

  static const List<(String, String, String)> _mixes = [
    ('a', 'A slow way into Sunday', '12 songs · yesterday'),
    ('b', 'Night bus notes', '18 songs · Tuesday'),
    ('c', 'Deadline sprint, no lyrics', '24 songs · last week'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Lists'),
        FlushList(
          children: [
            for (final (seed, title, subtitle) in _mixes)
              FlushRow(
                leading: CassetteTile(width: 60, seedId: seed),
                title: title,
                subtitle: subtitle,
                onTap: _noop,
              ),
          ],
        ),
        FlushRow(
          leading: SquareArt(placeholderGradient: [t.prism[4], t.prism[5]]),
          title: 'Rainy drive home',
          subtitleWidget: const StatusWord(
            label: 'Waiting for Apple Music',
            kind: StatusKind.warn,
          ),
          onTap: _noop,
        ),
        const SizedBox(height: 8),
        const ReasonBand(text: 'Quiet opener, matches "tired but not sad"'),
      ],
    );
  }

  static void _noop() {}
}

class _Cassettes extends StatelessWidget {
  const _Cassettes();

  /// A `Wrap`, not a `Row`: the four sizes sit on one line on a phone and fall
  /// to a second line at 320 pt rather than overflowing.
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionWord('Cassettes'),
      const Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          CassetteTile(width: 22, seedId: 'a'),
          CassetteTile(width: 44, seedId: 'b'),
          CassetteTile(width: 60, seedId: 'c'),
          CassetteTile(width: 150, seedId: 'd'),
        ],
      ),
      const SizedBox(height: 10),
      const CassetteTile(width: 80, seedId: 'e', spinning: true),
    ],
  );
}

class _Grouped extends StatelessWidget {
  const _Grouped();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionWord('Grouped'),
      InsetGroup(
        children: [
          InsetRow(
            leading: const Icon(CupertinoIcons.music_note_list),
            title: 'Your music',
            subtitle: '2,140 songs',
            onTap: _noop,
          ),
          InsetRow(
            leading: const Icon(CupertinoIcons.sparkles),
            title: 'Suggest a mix each morning',
            trailing: Switch.adaptive(value: true, onChanged: (_) {}),
          ),
          InsetRow(title: 'Sign out', destructive: true, onTap: _noop),
        ],
      ),
    ],
  );

  static void _noop() {}
}

class _Glass extends StatelessWidget {
  const _Glass();

  static const double pillHeight = 52;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionWord('Glass'),
      const _GlassPill(),
      const SizedBox(height: 12),
      // The same pill with the blur switched off, as reduced transparency
      // will draw it on device.
      const FrostedSurfaceMode(reduceTransparency: true, child: _GlassPill()),
    ],
  );
}

/// A mini-player-shaped glass pill over a strip of artwork, so the blur has
/// something to blur.
class _GlassPill extends StatelessWidget {
  const _GlassPill();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      height: _Glass.pillHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                SquareArt(
                  size: _Glass.pillHeight,
                  placeholderGradient: [t.prism[i], t.prism[i + 1]],
                ),
              ],
            ],
          ),
          FrostedSurface(
            borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      'Mini-player placeholder',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.secondary.copyWith(color: t.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
