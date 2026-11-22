/// Rename, in the app's pop-up (founder, 2026-11-22; decision 2026-11-22
/// "Save as playlist is the app's own pop-up"): the mix's cassette at the top
/// wears the name as it is typed, the name wraps to three lines so a long one
/// reads whole, then the paper "Save" pill and "Cancel". Short enough to
/// keep the full picture above the keyboard.
library;

import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/material.dart';

import '../screens/first_run/step_scaffold.dart' show FirstRunPill;
import 'foundation/haptics.dart';
import 'foundation/mixtape_popup.dart';
import 'foundation/mixtape_sheet.dart';
import 'mix_popup_art.dart';

/// Shows the pop-up; answers the new name, or null on Cancel or a tap
/// outside.
Future<String?> showMixRenamePopup(
  BuildContext context, {
  required String title,
  required String heading,
  required Key fieldKey,
  required Key confirmKey,
  Color? caseColor,
}) => showMixtapePopup<String>(
  context,
  label: heading,
  builder: (_) => MixRenamePopup(
    title: title,
    heading: heading,
    caseColor: caseColor,
    fieldKey: fieldKey,
    confirmKey: confirmKey,
  ),
);

class MixRenamePopup extends StatefulWidget {
  const MixRenamePopup({
    super.key,
    required this.title,
    required this.heading,
    required this.fieldKey,
    required this.confirmKey,
    this.caseColor,
  });

  static const Key cancelKey = Key('mix-rename-cancel');

  /// The notification ask's `.sheet` padding.
  static const double sidePadding = 22;

  final String title;
  final String heading;
  final Key fieldKey;
  final Key confirmKey;
  final Color? caseColor;

  @override
  State<MixRenamePopup> createState() => _MixRenamePopupState();
}

class _MixRenamePopupState extends State<MixRenamePopup> {
  // The current title, selected, so typing replaces it.
  late final TextEditingController _name =
      TextEditingController(text: widget.title)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.title.length,
        );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave => _name.text.trim().isNotEmpty;

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    final shown = _name.text.trim();

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 18),
        ExcludeSemantics(
          child: MixPopupArt(
            caseColor: widget.caseColor,
            label: shown.isEmpty ? null : shown,
          ),
        ),
        const SizedBox(height: 14),
        Semantics(
          header: true,
          child: Text(
            widget.heading,
            textAlign: TextAlign.center,
            style: tokens.body.copyWith(
              fontSize: 17.9,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.18,
              color: tokens.text,
            ),
          ),
        ),
        const SizedBox(height: 16),
        CupertinoTextField(
          key: widget.fieldKey,
          controller: _name,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          placeholder: 'Mix name',
          minLines: 1,
          maxLines: 3,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _save(),
          style: tokens.body.copyWith(
            fontSize: 15,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: tokens.text.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        const SizedBox(height: 18),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: MixRenamePopup.sidePadding,
            ),
            child: body,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MixRenamePopup.sidePadding,
            0,
            MixRenamePopup.sidePadding,
            14,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              FirstRunPill(
                key: widget.confirmKey,
                label: 'Save',
                minHeight: 50,
                fontSize: 15.2,
                onPressed: _canSave
                    ? Haptics.on(HapticKind.primary, _save)
                    : null,
              ),
              const SizedBox(height: 4),
              TextButton(
                key: MixRenamePopup.cancelKey,
                onPressed: Haptics.on(
                  HapticKind.dismiss,
                  () => Navigator.of(context).pop(),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.muted,
                  minimumSize: const Size.fromHeight(44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  'Cancel',
                  style: tokens.body.copyWith(
                    fontSize: 14.08,
                    fontWeight: FontWeight.w600,
                    color: tokens.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
