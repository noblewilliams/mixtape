import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// A bold section word above a flush list — the board's `.k`, a word rather
/// than a header bar.
class SectionWord extends StatelessWidget {
  const SectionWord(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(text, style: context.tokens.section),
  );
}
