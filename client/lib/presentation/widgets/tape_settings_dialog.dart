/// Tape settings: the mix's name and its tape colour, on an opaque bottom
/// sheet (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Tape settings; `.sheet`, `.namef`, `.fam` and `.tapes` on
/// `docs/mockups/2026-11-03-mix-conversation-redesign.html`, section 3).
///
/// The 48 colours sit in the palette's eight families. A row of family
/// swatches picks one; its six colours appear as real cassettes with their
/// names. Picking a cassette saves at once; Done only closes (and keeps a
/// changed name).
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/mixtape_sheet.dart';
import 'tape_palette.dart';

/// Presents the sheet. [initialColor] is the colour the mix is shown in right
/// now (saved or seeded), so the sheet opens on that family and never
/// appears to change the tape just by opening.
Future<void> showTapeSettingsSheet(
  BuildContext context, {
  required String title,
  required String initialColor,
  required Future<bool> Function(String colour) onSave,
  Future<bool> Function(String name)? onRename,
}) => showMixtapeSheet<void>(
  context,
  isScrollControlled: true,
  builder: (_) => TapeSettingsSheet(
    title: title,
    initialColor: initialColor,
    onSave: onSave,
    onRename: onRename,
  ),
);

class TapeSettingsSheet extends StatefulWidget {
  const TapeSettingsSheet({
    super.key,
    required this.title,
    required this.initialColor,
    required this.onSave,
    this.onRename,
  });

  final String title;
  final String initialColor;
  final Future<bool> Function(String colour) onSave;

  /// Null hides nothing but makes the name read-only in effect: a changed
  /// name is simply not written.
  final Future<bool> Function(String name)? onRename;

  static const Key sheetKey = Key('tape-settings-sheet');
  static const Key nameFieldKey = Key('tape-settings-name');
  static const Key doneKey = Key('tape-settings-done');
  static Key familyKey(int index) => ValueKey('tape-family-$index');
  static Key colourKey(String hex) => ValueKey('tape-colour-$hex');

  /// `.fam i::after { width: 26px }` inside a 44 pt target.
  static const double swatchSize = 26;

  /// `.tapes .cs { width: 92px }`.
  static const double cassetteWidth = 92;

  static const String failedMessage = 'Couldn’t save tape colour. Try again.';

  @override
  State<TapeSettingsSheet> createState() => _TapeSettingsSheetState();
}

class _TapeSettingsSheetState extends State<TapeSettingsSheet> {
  late String _selected = widget.initialColor.toLowerCase();
  late int _family = tapeFamilyOf(_selected) ?? 0;
  late final TextEditingController _name = TextEditingController(
    text: widget.title,
  );
  bool _saving = false;
  bool _failed = false;
  bool _closing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick(String hex) async {
    if (_saving) return;
    // The colour already saved needs no second write; one that failed does.
    if (hex == _selected && !_failed) return;
    setState(() {
      _selected = hex;
      _saving = true;
      _failed = false;
    });
    var ok = false;
    try {
      ok = await widget.onSave(hex);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _failed = !ok;
    });
  }

  Future<void> _done() async {
    if (_closing) return;
    _closing = true;
    final name = _name.text.trim();
    final rename = widget.onRename;
    Navigator.of(context).pop();
    if (rename != null && name.isNotEmpty && name != widget.title.trim()) {
      await rename(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    final colours = tapeFamily(_family);
    return Material(
      key: TapeSettingsSheet.sheetKey,
      color: MixtapeSheet.surfaceColorOf(context),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // `.shd`: the heading and Done.
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: MixtapeMetrics.minTarget,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Tape',
                          style: tokens.rowTitle.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      key: TapeSettingsSheet.doneKey,
                      onPressed: _done,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          MixtapeMetrics.minTarget,
                          MixtapeMetrics.minTarget,
                        ),
                        foregroundColor: tokens.plum,
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              _NameField(controller: _name, onSubmitted: (_) => _done()),
              const SizedBox(height: 14),
              _Families(
                selected: _family,
                onPick: (index) => setState(() => _family = index),
              ),
              const SizedBox(height: 14),
              _Grid(
                colours: colours,
                selected: _selected,
                onPick: _pick,
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      TapeSettingsSheet.failedMessage,
                      style: tokens.meta.copyWith(color: tokens.errInk),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.namef`: the mix's name, with a quiet "Name" label at the end.
class _NameField extends StatelessWidget {
  const _NameField({required this.controller, required this.onSubmitted});

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    return Container(
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.minTarget),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: tokens.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: TapeSettingsSheet.nameFieldKey,
              controller: controller,
              textInputAction: TextInputAction.done,
              onSubmitted: onSubmitted,
              style: tokens.body,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: 'Mix name',
              ),
            ),
          ),
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: Text(
              'Name',
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.fam`: eight swatches, 44 pt targets, the selected one ringed.
class _Families extends StatelessWidget {
  const _Families({required this.selected, required this.onPick});

  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < tapeFamilyNames.length; i++)
          Flexible(
            child: Semantics(
              button: true,
              selected: i == selected,
              label: tapeFamilyNames[i],
              excludeSemantics: true,
              onTap: () => onPick(i),
              child: GestureDetector(
                key: TapeSettingsSheet.familyKey(i),
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(i),
                child: SizedBox.square(
                  dimension: MixtapeMetrics.minTarget,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: i == selected
                          ? Border.all(color: tokens.text, width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Container(
                        width: TapeSettingsSheet.swatchSize,
                        height: TapeSettingsSheet.swatchSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tapeColor(tapeFamilySwatch(i)),
                          border: Border.all(color: const Color(0x1817161A)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// `.tapes`: the family's six cassettes, three to a row, each named.
class _Grid extends StatelessWidget {
  const _Grid({
    required this.colours,
    required this.selected,
    required this.onPick,
  });

  final List<(String, String)> colours;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var row = 0; row < colours.length; row += 3) ...[
          if (row > 0) const SizedBox(height: 14),
          Row(
            children: [
              for (var i = row; i < row + 3 && i < colours.length; i++) ...[
                if (i > row) const SizedBox(width: 12),
                Expanded(
                  child: _TapeChoice(
                    key: TapeSettingsSheet.colourKey(colours[i].$2),
                    name: colours[i].$1,
                    hex: colours[i].$2,
                    selected: colours[i].$2 == selected,
                    onTap: () => onPick(colours[i].$2),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// One cassette in the grid. Selected, it lifts 4 pt, tilts −4° and turns
/// its hubs once; under reduced motion it simply sits lifted.
class _TapeChoice extends StatefulWidget {
  const _TapeChoice({
    super.key,
    required this.name,
    required this.hex,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String hex;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TapeChoice> createState() => _TapeChoiceState();
}

class _TapeChoiceState extends State<_TapeChoice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: CassetteTile.hubPeriod,
  );

  @override
  void didUpdateWidget(_TapeChoice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) {
      if (MediaQuery.disableAnimationsOf(context)) return;
      _turn.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final width = TapeSettingsSheet.cassetteWidth;
    final size = Size(width, width * 128 / 200);
    final cassette = AnimatedBuilder(
      animation: _turn,
      builder: (_, _) => CustomPaint(
        size: size,
        painter: CassettePainter(
          caseColor: tapeColor(widget.hex)!,
          stripes: tokens.prism.take(5).toList(growable: false),
          turn: _turn.value,
          shadow: true,
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.name,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: widget.selected
                ? (Theme.of(context).brightness == Brightness.dark
                      ? const Color.fromRGBO(255, 255, 255, 0.08)
                      : const Color.fromRGBO(84, 68, 81, 0.07))
                : Colors.transparent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                child: AnimatedSlide(
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  offset: widget.selected
                      ? Offset(0, -4 / size.height)
                      : Offset.zero,
                  child: AnimatedRotation(
                    duration: reduced
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    turns: widget.selected ? -4 / 360 : 0,
                    child: cassette,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.meta.copyWith(
                  color: widget.selected ? tokens.text : tokens.smoke,
                  fontWeight: widget.selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
