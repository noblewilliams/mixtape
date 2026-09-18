/// The routine suggestion as Home's first idea pill
/// (`docs/mockups/approved/2026-09-17-mobile-home-states.md` → Pills; frames
/// I1/I2 in `docs/mockups/2026-09-17-mobile-home-states.html`; plan task 3.2).
///
/// The September 9 suggestion card is gone: what is left is one pill in the
/// panel's first slot. It fills the composer and never sends, it is a skeleton
/// while the routine loads, and it steps aside for a third starter prompt when
/// nothing is eligible — Home shows no suggestion error at all, the retry
/// lives on You.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/suggestions/suggestions_api.dart';
import '../providers/device_providers.dart';
import '../providers/suggestions_provider.dart';
import 'foundation/idea_pill.dart';
import 'foundation/mixtape_sheet.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/mixtape_menu.dart';

/// Home's first idea pill: the eligible routine suggestion, a skeleton while
/// it loads, or [fallback] when there is nothing to suggest.
class RoutinePillSlot extends ConsumerWidget {
  const RoutinePillSlot({
    super.key,
    required this.onFill,
    required this.builder,
    this.dimmed = false,
    this.enabled = true,
  });

  /// Called with the suggestion's prompt. Filling the field is all a tap ever
  /// does — the mix is not started until Send.
  final ValueChanged<String> onFill;

  /// Builds the row around the pill: the skeleton while the routine loads,
  /// the routine pill once one is eligible, and `null` when none is — which
  /// is the panel's cue to show a third starter prompt instead.
  final Widget Function(BuildContext context, Widget? pill) builder;

  /// The typing state — the field already has text.
  final bool dimmed;

  /// False while a mix is being created: the pill neither fills nor opens.
  final bool enabled;

  static const Key pillKey = Key('routine-pill');
  static const Key skeletonKey = Key('routine-pill-skeleton');
  static const Key notTodayKey = Key('routine-not-today');
  static const Key whyKey = Key('routine-why');
  static const Key turnOffKey = Key('routine-turn-off');
  static const Key whySheetKey = Key('routine-why-sheet');

  static const String notTodayLabel = 'Not today';
  static const String whyLabel = 'Why this?';
  static const String turnOffLabel = 'Turn off routine suggestions';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(suggestionsApiProvider);
    // Keyed on the API so a sign-in or sign-out starts a fresh load instead of
    // leaving another account's suggestion on the pill.
    return _RoutinePillBody(
      key: ObjectKey(api),
      api: api,
      readZone: ref.watch(suggestionTimeZoneProvider),
      onFill: onFill,
      builder: builder,
      dimmed: dimmed,
      enabled: enabled,
    );
  }
}

class _RoutinePillBody extends StatefulWidget {
  const _RoutinePillBody({
    super.key,
    required this.api,
    required this.readZone,
    required this.onFill,
    required this.builder,
    required this.dimmed,
    required this.enabled,
  });

  final SuggestionsApi api;
  final TimeZoneReader readZone;
  final ValueChanged<String> onFill;
  final Widget Function(BuildContext context, Widget? pill) builder;
  final bool dimmed;
  final bool enabled;

  @override
  State<_RoutinePillBody> createState() => _RoutinePillBodyState();
}

enum _RoutineAction { notToday, why, turnOff }

class _RoutinePillBodyState extends State<_RoutinePillBody>
    with WidgetsBindingObserver {
  SuggestionsData? _data;

  /// The first load, which is the only one the skeleton stands in for: a
  /// later refresh must never blank a pill that is already up.
  bool _loading = true;
  bool _working = false;

  /// Answers a load only if it is still the most recent one asked for.
  int _read = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    // A routine is time-of-day eligible, so the pill is re-checked while Home
    // sits open — the same minute tick the September 9 card used.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_working &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_working) unawaited(_refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A failure — a server error, or a device with no time zone to ask about —
  /// leaves the slot empty, which the panel fills with a starter: the board
  /// shows no suggestion error on Home at all.
  Future<void> _refresh() async {
    final request = ++_read;
    try {
      final zone = await widget.readZone();
      if (!mounted) return;
      final data = await widget.api.load(zone);
      if (mounted && request == _read) {
        setState(() {
          _data = data;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && request == _read) {
        setState(() {
          _data = null;
          _loading = false;
        });
      }
    }
  }

  /// One action at a time, and a failure is swallowed: Home has nowhere to say
  /// so, and the pill going quiet is the whole consequence.
  Future<void> _act(Future<void> Function() action) async {
    if (_working || !widget.enabled) return;
    _read++; // a load in flight must not overwrite what this action leaves
    setState(() => _working = true);
    try {
      await action();
    } catch (_) {
      // Deliberately silent; see the doc comment.
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// `select` is what records the choice server-side, and it answers with the
  /// prompt — which goes into the field, never to the DJ.
  Future<void> _fill(RoutineSuggestion suggestion) => _act(() async {
    final zone = await widget.readZone();
    if (!mounted) return;
    final prompt = await widget.api.select(suggestion.id, zone);
    if (!mounted) return;
    widget.onFill(prompt);
  });

  Future<void> _notToday(RoutineSuggestion suggestion) => _act(() async {
    final zone = await widget.readZone();
    if (!mounted) return;
    await widget.api.dismiss(suggestion.id, zone);
    if (!mounted) return;
    setState(
      () => _data = SuggestionsData(
        enabled: _data?.enabled ?? true,
        dismissed: true,
      ),
    );
  });

  Future<void> _turnOff() => _act(() async {
    await widget.api.save(false);
    if (!mounted) return;
    setState(
      () => _data = const SuggestionsData(enabled: false, dismissed: false),
    );
  });

  Future<void> _why(RoutineSuggestion suggestion) async {
    await showMixtapeSheet<void>(
      context,
      builder: (context) => Padding(
        key: RoutinePillSlot.whySheetKey,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(suggestion.title, style: context.tokens.section),
            const SizedBox(height: 8),
            Text(suggestion.reason, style: context.tokens.body),
          ],
        ),
      ),
    );
  }

  /// The board's native context menu on the pill, as an action sheet.
  Future<void> _openMenu(RoutineSuggestion suggestion) async {
    final choice = await showMixtapeMenu<_RoutineAction>(
      context,
      actions: const [
        MixtapeMenuAction(
          key: RoutinePillSlot.notTodayKey,
          value: _RoutineAction.notToday,
          label: RoutinePillSlot.notTodayLabel,
        ),
        MixtapeMenuAction(
          key: RoutinePillSlot.whyKey,
          value: _RoutineAction.why,
          label: RoutinePillSlot.whyLabel,
        ),
        MixtapeMenuAction(
          key: RoutinePillSlot.turnOffKey,
          value: _RoutineAction.turnOff,
          label: RoutinePillSlot.turnOffLabel,
          isDestructive: true,
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _RoutineAction.notToday:
        await _notToday(suggestion);
      case _RoutineAction.why:
        await _why(suggestion);
      case _RoutineAction.turnOff:
        await _turnOff();
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _pill());

  Widget? _pill() {
    if (_loading) {
      return IdeaPill(
        key: RoutinePillSlot.skeletonKey,
        label: IdeaPill.skeletonLabel,
        skeleton: true,
        dimmed: widget.dimmed,
      );
    }
    final suggestion = _data?.suggestion;
    if (suggestion == null) return null;

    final live = widget.enabled && !_working;
    // Merged so the label, the button and the three actions land on one node:
    // VoiceOver reads the pill and offers the same three as rotor actions.
    return MergeSemantics(
      child: Semantics(
        customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
          const CustomSemanticsAction(
            label: RoutinePillSlot.notTodayLabel,
          ): () =>
              unawaited(_notToday(suggestion)),
          const CustomSemanticsAction(label: RoutinePillSlot.whyLabel): () =>
              unawaited(_why(suggestion)),
          const CustomSemanticsAction(
            label: RoutinePillSlot.turnOffLabel,
          ): () =>
              unawaited(_turnOff()),
        },
        child: GestureDetector(
          onLongPress: live ? () => unawaited(_openMenu(suggestion)) : null,
          child: IdeaPill(
            key: RoutinePillSlot.pillKey,
            label: suggestion.title,
            dimmed: widget.dimmed,
            onPressed: live ? () => unawaited(_fill(suggestion)) : null,
          ),
        ),
      ),
    );
  }
}
