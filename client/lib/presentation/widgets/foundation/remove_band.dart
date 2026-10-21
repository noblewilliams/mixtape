import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The swipe-to-remove band behind a row: the error ink, white "Remove" and
/// the close glyph. The arrangement screen's, shared with the Listen later
/// shelf (album picks board L2: "unchanged").
class RemoveBand extends StatelessWidget {
  const RemoveBand({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      color: tokens.errInk,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Remove',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(width: 6),
          Icon(Icons.close, size: 18, color: Colors.white),
        ],
      ),
    );
  }
}
