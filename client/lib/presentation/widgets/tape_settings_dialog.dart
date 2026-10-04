import 'package:flutter/material.dart';
import '../theme/mixtape_theme.dart';
import 'tape_palette.dart';

class TapeSettingsDialog extends StatefulWidget {
  const TapeSettingsDialog({
    super.key,
    required this.title,
    required this.initialColor,
    required this.onSave,
  });
  final String title, initialColor;
  final Future<bool> Function(String) onSave;
  @override
  State<TapeSettingsDialog> createState() => _TapeSettingsDialogState();
}

class _TapeSettingsDialogState extends State<TapeSettingsDialog> {
  late String _selected = widget.initialColor.toLowerCase();
  bool _saving = false, _failed = false, _attempted = false;
  Future<void> _save() async {
    if (_saving) return;
    if (!_attempted && _selected == widget.initialColor.toLowerCase()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _failed = false;
      _attempted = true;
    });
    var ok = false;
    try {
      ok = await widget.onSave(_selected);
    } catch (_) {
      /* Keep selection for retry. */
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<MixtapeTokens>() ?? MixtapeTokens.light;
    final name =
        tapePalette.where((p) => p.$2 == _selected).firstOrNull?.$1 ?? 'Custom';
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('Tape settings', style: tokens.rowTitle),
                      ),
                      TextButton(
                        onPressed: _saving ? null : _save,
                        child: Text(
                          _saving ? 'Saving…' : 'Done',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    widget.title,
                    style: tokens.meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: Text('Tape colour', style: tokens.meta)),
                      Text(name, style: tokens.meta),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (var row = 0; row < 8; row++)
                    Row(
                      children: [
                        for (final colour in tapePalette.skip(row * 6).take(6))
                          Expanded(
                            child: Semantics(
                              selected: _selected == colour.$2,
                              button: true,
                              label: colour.$1,
                              child: Tooltip(
                                message: colour.$1,
                                child: InkWell(
                                  onTap: _saving
                                      ? null
                                      : () => setState(() {
                                          _selected = colour.$2;
                                          _failed = false;
                                        }),
                                  borderRadius: BorderRadius.circular(7),
                                  child: SizedBox(
                                    height: 44,
                                    child: Center(
                                      child: Container(
                                        width: 28,
                                        height: 28,
                                        padding: const EdgeInsets.all(3),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: _selected == colour.$2
                                              ? Border.all(
                                                  color: tokens.text,
                                                  width: 1.5,
                                                )
                                              : null,
                                        ),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: tapeColor(colour.$2),
                                            border: Border.all(
                                              color: const Color(0x1817161A),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  if (_failed)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        'Couldn’t save tape colour. Try again.',
                        style: tokens.meta.copyWith(color: tokens.errInk),
                      ),
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
