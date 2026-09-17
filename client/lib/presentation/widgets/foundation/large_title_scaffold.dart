/// Apple Music's large title and its collapsing bar
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Titles; `.large-title`,
/// `.smallbar` and `.smalltitle` in `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'frosted_surface.dart';

/// A [CustomScrollView] under a large title that collapses into a small centred
/// title over a progressive blur with no bottom edge.
///
/// The bar is built only once the title row's bottom has passed the top safe
/// area, so the large title is never hidden behind it, and it is entirely
/// non-interactive: touches reach the content underneath everywhere, including
/// through the small title. The collapsed title stays in the semantics tree as
/// a header.
class LargeTitleScaffold extends StatefulWidget {
  const LargeTitleScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.trailing,
    this.titleAccessory,
    this.controller,
    this.onRefresh,
    this.contentPadding,
  });

  final String title;

  /// The body. Each sliver is wrapped in [contentPadding].
  final List<Widget> slivers;

  /// Bottom-aligned beside the title — normally a `GlassCluster`.
  final Widget? trailing;

  /// Bottom-aligned beside the title — normally a segmented control.
  final Widget? titleAccessory;

  final ScrollController? controller;

  /// When given, a `CupertinoSliverRefreshControl` rides above the title.
  final Future<void> Function()? onRefresh;

  /// Defaults to [MixtapeMetrics.screenSidePadding] on each side.
  final EdgeInsets? contentPadding;

  /// The collapsed bar, for tests.
  static const Key smallBarKey = ValueKey('largeTitleScaffold.smallBar');

  /// The title row's resting height — the board's 46 pt glass cluster.
  static const double titleRowHeight = 46;

  /// The collapsed bar's own height, below the top safe area. On a device with
  /// a 54 pt status bar this makes the board's 100 pt `.smallbar`.
  static const double barHeight = 46;

  /// The gap under the title row before the body.
  static const double titleBottomGap = 8;

  /// The gap between the title and the trailing cluster or accessory.
  static const double titleGap = 10;

  static const Duration fadeDuration = Duration(milliseconds: 180);

  /// The blur bands down the bar, top to bottom. A `BackdropFilter` inside a
  /// `ShaderMask` samples the mask's own empty layer, so the board's
  /// `mask-image` becomes a stack of clipped bands of falling sigma.
  static const List<double> blurSigmas = [16, 10, 6, 3];

  /// Where the scrim turns from its full alpha to fading.
  static const double blurFadeStart = 0.58;

  /// The scrim's alpha at the top of the bar.
  static const double scrimAlpha = 0.6;

  /// The scroll offset at which the title collapses at the default text scale.
  ///
  /// The live threshold is the measured title row's bottom, so a wrapped title
  /// at large text sizes collapses later than this; tests and callers that
  /// assume the default scale can use the constant.
  static const double collapseThreshold =
      MixtapeMetrics.largeTitleTopPadding + titleRowHeight;

  @override
  State<LargeTitleScaffold> createState() => _LargeTitleScaffoldState();
}

class _LargeTitleScaffoldState extends State<LargeTitleScaffold>
    with SingleTickerProviderStateMixin {
  final GlobalKey _titleRowKey = GlobalKey();

  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: LargeTitleScaffold.fadeDuration,
  );

  ScrollController? _ownedController;
  late ScrollController _scrollController;

  /// The title row's bottom in scroll offsets, measured once per layout. The
  /// top safe area sits inside both the row's padding and the bar, so it
  /// cancels out and the threshold is the same on every device.
  double _titleRowBottom = LargeTitleScaffold.collapseThreshold;
  bool _measureScheduled = false;
  bool _collapsed = false;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(LargeTitleScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _scrollController.removeListener(_handleScroll);
      _ownedController?.dispose();
      _ownedController = null;
      _attach(widget.controller);
      // The new controller carries its own offset; the old collapse state may
      // no longer match it.
      _scheduleMeasure();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    // Depend on the metrics that change the row's height, so a text-scale or
    // window-size change re-measures it.
    MediaQuery.textScalerOf(context);
    MediaQuery.sizeOf(context);
    _scheduleMeasure();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _ownedController?.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _attach(ScrollController? controller) {
    _ownedController = controller == null ? ScrollController() : null;
    _scrollController = controller ?? _ownedController!;
    _scrollController.addListener(_handleScroll);
  }

  /// Measures the title row after the frame it was laid out in, so the scroll
  /// handler never walks the render tree on a tick.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final box = _titleRowKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        _titleRowBottom = MixtapeMetrics.largeTitleTopPadding + box.size.height;
      }
      _handleScroll();
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final collapsed = _scrollController.offset >= _titleRowBottom;
    if (collapsed == _collapsed) return;
    _collapsed = collapsed;
    if (_disableAnimations) {
      _fade.value = collapsed ? 1 : 0;
    } else if (collapsed) {
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    final padding = MediaQuery.paddingOf(context);
    final content =
        widget.contentPadding ??
        const EdgeInsets.symmetric(
          horizontal: MixtapeMetrics.screenSidePadding,
        );

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            if (widget.onRefresh != null)
              CupertinoSliverRefreshControl(onRefresh: widget.onRefresh),
            SliverToBoxAdapter(
              child: _titleBlock(context, padding.top, content),
            ),
            for (final sliver in widget.slivers)
              SliverPadding(padding: content, sliver: sliver),
            SliverToBoxAdapter(child: SizedBox(height: padding.bottom)),
          ],
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedBuilder(
            animation: _fade,
            builder: (context, _) => _fade.value == 0
                ? const SizedBox.shrink()
                : _collapsedBar(context, padding.top),
          ),
        ),
      ],
    );
  }

  Widget _titleBlock(BuildContext context, double topInset, EdgeInsets side) {
    final tokens = context.tokens;
    final accessory = widget.titleAccessory;
    final trailing = widget.trailing;

    return Padding(
      // The title keeps the body's side padding, so both stay on one margin.
      padding: EdgeInsets.fromLTRB(
        side.left,
        topInset + MixtapeMetrics.largeTitleTopPadding,
        side.right,
        LargeTitleScaffold.titleBottomGap,
      ),
      child: ConstrainedBox(
        key: _titleRowKey,
        constraints: const BoxConstraints(
          minHeight: LargeTitleScaffold.titleRowHeight,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(widget.title, style: tokens.largeTitle),
              ),
            ),
            if (accessory != null) ...[
              const SizedBox(width: LargeTitleScaffold.titleGap),
              accessory,
            ],
            if (trailing != null) ...[
              const SizedBox(width: LargeTitleScaffold.titleGap),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _collapsedBar(BuildContext context, double topInset) {
    final tokens = context.tokens;
    final solid = FrostedSurfaceMode.of(context).reduceTransparency;

    return FadeTransition(
      key: LargeTitleScaffold.smallBarKey,
      opacity: _fade,
      // The blur is expensive; keep it off the scroll view's repaint list.
      child: RepaintBoundary(
        child: SizedBox(
          height: topInset + LargeTitleScaffold.barHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: solid
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _scrim(tokens, topAlpha: 1),
                        ),
                      )
                    : _progressiveBlur(tokens),
              ),
              Positioned(
                top: topInset,
                left: 0,
                right: 0,
                height: LargeTitleScaffold.barHeight,
                child: Semantics(
                  header: true,
                  label: widget.title,
                  container: true,
                  child: IgnorePointer(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 56),
                        child: Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.smallTitle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Blur masked away towards the bottom, under a scrim that fades with it —
  /// so the bar has no bottom edge at all.
  Widget _progressiveBlur(MixtapeTokens tokens) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            for (final sigma in LargeTitleScaffold.blurSigmas)
              Expanded(
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: _scrim(tokens, topAlpha: LargeTitleScaffold.scrimAlpha),
          ),
        ),
      ],
    );
  }

  /// The board's `rgba(bg,.6)` fall to nothing, so the bar dissolves into the
  /// content instead of ending on an edge.
  LinearGradient _scrim(MixtapeTokens tokens, {required double topAlpha}) =>
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          tokens.scrimBase.withValues(alpha: topAlpha),
          tokens.scrimBase.withValues(alpha: topAlpha),
          tokens.scrimBase.withValues(alpha: 0),
        ],
        stops: const [0, LargeTitleScaffold.blurFadeStart, 1],
      );
}
