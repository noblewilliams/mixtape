/// The small frosted toast a swipe action leaves behind ("Quoted", "Removed
/// · Undo"), in the manner of Apple Music's "Added to Queue": a glyph and a
/// few words in a capsule, centred over the bottom of the screen, gone in a
/// moment unless it carries an action.
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

@immutable
class MiniToastData {
  const MiniToastData({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.duration = MiniToast.shortDuration,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
}

/// Holds at most one toast; a new one replaces whatever is showing.
class MiniToastController extends ChangeNotifier {
  MiniToastData? _current;
  Timer? _timer;

  MiniToastData? get current => _current;

  void show(MiniToastData toast) {
    _timer?.cancel();
    _current = toast;
    _timer = Timer(toast.duration, hide);
    notifyListeners();
  }

  void hide() {
    _timer?.cancel();
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Draws [controller]'s toast; place it over the bottom of a screen's body.
class MiniToast extends StatelessWidget {
  const MiniToast({super.key, required this.controller});

  final MiniToastController controller;

  static const Duration shortDuration = Duration(milliseconds: 1600);

  static const Key toastKey = Key('mini-toast');
  static const Key actionKey = Key('mini-toast-action');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final toast = controller.current;
      final reduced = MediaQuery.disableAnimationsOf(context);
      return AnimatedSwitcher(
        duration: reduced ? Duration.zero : const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.85, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        child: toast == null
            ? const SizedBox.shrink()
            : _Capsule(
                key: ValueKey(toast),
                toast: toast,
                onAction: toast.onAction == null
                    ? null
                    : () {
                        controller.hide();
                        toast.onAction!();
                      },
              ),
      );
    },
  );
}

class _Capsule extends StatelessWidget {
  const _Capsule({super.key, required this.toast, this.onAction});

  final MiniToastData toast;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    const ink = Color(0xFFFFFFFF);
    final fill = dark
        ? const Color.fromRGBO(70, 64, 74, 0.78)
        : const Color.fromRGBO(40, 34, 42, 0.78);
    return Semantics(
      liveRegion: true,
      container: true,
      child: ConstrainedBox(
        key: MiniToast.toastKey,
        constraints: const BoxConstraints(maxWidth: 320),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  12,
                  onAction == null ? 18 : 6,
                  12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(toast.icon, size: 18, color: ink),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        toast.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onAction != null)
                      Semantics(
                        button: true,
                        label: toast.actionLabel,
                        excludeSemantics: true,
                        onTap: onAction,
                        child: GestureDetector(
                          key: MiniToast.actionKey,
                          behavior: HitTestBehavior.opaque,
                          onTap: onAction,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                            child: Text(
                              toast.actionLabel ?? '',
                              style: TextStyle(
                                color: context.tokens.tapeInk,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                decoration: TextDecoration.underline,
                                decorationColor: context.tokens.tapeInk
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
