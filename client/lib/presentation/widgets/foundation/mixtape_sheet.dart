/// The one presentation every modal sheet in the app goes through
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Sheets; smoke round
/// two, note 4).
///
/// Sheets used to set their own chrome — some floated on a 12 pt margin, some
/// sat on Material's near-black scrim, some let the screen behind bleed
/// through a frosted surface. They all come through [showMixtapeSheet] now:
/// full width, flush to the bottom edge, 20 pt top corners, one grab handle,
/// an opaque panel and the board's lighter scrim.
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The shared sheet's own metrics, colours and keys.
abstract final class MixtapeSheet {
  /// The board's sheet corner. Only the top two are rounded: the sheet reaches
  /// the bottom edge of the screen, so the bottom two would cut into it.
  static const double topRadius = 20;

  static const BorderRadius radius = BorderRadius.vertical(
    top: Radius.circular(topRadius),
  );

  /// The chrome wrapper, and so the sheet's own rect, for tests.
  static const Key surfaceKey = Key('mixtape-sheet-surface');

  /// The one grab handle. Sheets that carried their own point their key here
  /// rather than drawing a second.
  static const Key handleKey = Key('mixtape-sheet-handle');

  static const double handleWidth = 36;
  static const double handleHeight = 5;
  static const Color handleColor = Color.fromRGBO(127, 120, 130, 0.45);

  /// The gap above and below the handle.
  static const double handleTopGap = 8;
  static const double handleBottomGap = 6;

  /// The scrim: light enough to keep the room behind the sheet readable.
  static const Color lightBarrier = Color.fromRGBO(0, 0, 0, 0.25);
  static const Color darkBarrier = Color.fromRGBO(0, 0, 0, 0.5);

  /// The tokens, or the theme's own when a caller pumped a bare `ThemeData`
  /// — a sheet must not throw just because its host skipped the extension.
  static MixtapeTokens tokensOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<MixtapeTokens>() ??
        (theme.brightness == Brightness.dark
            ? MixtapeTokens.dark
            : MixtapeTokens.light);
  }

  static Color barrierColorOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? darkBarrier
      : lightBarrier;

  /// The panel tint laid over the app's own base, so the surface is opaque:
  /// nothing behind the sheet shows through to muddy its text.
  static Color surfaceColorOf(BuildContext context) {
    final tokens = tokensOf(context);
    return Color.alphaBlend(tokens.panel, tokens.scrimBase);
  }
}

/// Presents [builder] as the app's standard sheet.
///
/// [isScrollControlled] is passed straight through for sheets that grow past
/// Material's half-screen default; [isDismissible] and [enableDrag] for the
/// import sheet, which locks itself while an upload is in flight.
Future<T?> showMixtapeSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  isDismissible: isDismissible,
  enableDrag: enableDrag,
  // The sheet absorbs the bottom inset in its own padding instead, so the
  // surface reaches the edge and only the content clears the home indicator.
  useSafeArea: false,
  backgroundColor: MixtapeSheet.surfaceColorOf(context),
  barrierColor: MixtapeSheet.barrierColorOf(context),
  elevation: 0,
  shape: const RoundedRectangleBorder(borderRadius: MixtapeSheet.radius),
  clipBehavior: Clip.antiAlias,
  builder: (sheetContext) => MixtapeSheetChrome(child: builder(sheetContext)),
);

/// The grab handle and the bottom inset every sheet shares.
class MixtapeSheetChrome extends StatelessWidget {
  const MixtapeSheetChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    key: MixtapeSheet.surfaceKey,
    padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: MixtapeSheet.handleTopGap,
            bottom: MixtapeSheet.handleBottomGap,
          ),
          child: Center(
            child: Container(
              key: MixtapeSheet.handleKey,
              width: MixtapeSheet.handleWidth,
              height: MixtapeSheet.handleHeight,
              decoration: const BoxDecoration(
                color: MixtapeSheet.handleColor,
                borderRadius: BorderRadius.all(Radius.circular(3)),
              ),
            ),
          ),
        ),
        Flexible(child: child),
      ],
    ),
  );
}
