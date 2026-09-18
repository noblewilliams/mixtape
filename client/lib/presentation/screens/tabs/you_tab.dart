/// The You tab (`docs/mockups/approved/2026-09-17-mobile-shell.md` → You;
/// frame Y1 in `docs/mockups/2026-09-17-mobile-shell-r3.html`; plan
/// `docs/superpowers/plans/2026-09-17-native-design-implementation.md` task
/// 8.3).
///
/// Native inset-grouped lists: the identity block with the 64 pt square prism
/// avatar, then What the DJ knows and the board's two real toggles ("Learn
/// from my listening", "Suggest mixes from my routines") — which is why
/// Listening and Suggestions no longer have screens of their own — the
/// Together ghost, and finally Account and Sign out.
///
/// Clear learned listening lives under What the DJ knows, as the board says.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the app root.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/auth/account_api.dart';
import '../../../data/playback/playback_controller.dart'
    show PlaybackController;
import '../../../data/listening/listening_models.dart';
import '../../providers/account_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dj_providers.dart' show memoriesProvider;
import '../../providers/library_sync_provider.dart' show accountNameProvider;
import '../../providers/onboarding_provider.dart' show onboardingProvider;
import '../../providers/playback_provider.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../../widgets/foundation/inset_group.dart';
import '../../widgets/foundation/large_title_scaffold.dart';
import '../../widgets/suggestion_settings.dart';
import '../account_screen.dart';
import '../memory_screen.dart';

/// The You tab.
class YouTab extends ConsumerWidget {
  const YouTab({super.key});

  /// A row of breathing room under the last group, on top of the dock's own
  /// height: the shell hands that down as [MediaQuery.padding], which
  /// [LargeTitleScaffold] already emits at the end of the slivers.
  static const double defaultBottomInset = 16;

  /// The square prism avatar.
  static const Key avatarKey = Key('you-avatar');
  static const double avatarSize = 48;

  /// Shown until `/me` answers with a name (it never blocks the tab).
  static const String unnamedListener = 'Your account';

  static const String signOutFailed = 'Couldn’t sign out. Try again.';

  /// The board's note under the preferences group.
  static const String learningFootnote =
      'Learning stays on this account only. Clear learned listening from '
      'What the DJ knows.';

  /// The Together ghost's accessibility label; the row is not tappable.
  static const String togetherLabel = 'Together, planned';

  void _push(BuildContext context, Widget Function() screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final name = ref.watch(accountNameProvider).value;
    final accounts = ref.watch(accountProvider).accounts;
    final onboarding = ref.watch(onboardingProvider).value;
    final memories = ref.watch(memoriesProvider).value;
    final displayName = (name == null || name.trim().isEmpty)
        ? unnamedListener
        : name.trim();

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'You',
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(bottom: defaultBottomInset),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InsetGroup(
                      children: [
                        InsetRow(
                          leading: _PrismAvatar(initial: _initialOf(name)),
                          title: displayName,
                          subtitle: identitySubtitle(accounts, onboarding),
                        ),
                      ],
                    ),
                    InsetGroup(
                      children: [
                        InsetRow(
                          key: const Key('you-memories'),
                          leading: const Icon(Icons.psychology_outlined),
                          title: 'What the DJ knows',
                          subtitle: rememberedLine(memories?.length),
                          onTap: () => _push(context, MemoryScreen.new),
                        ),
                        const _LearningRow(),
                        const SuggestionSettings(),
                      ],
                    ),
                    // A block of its own: the ghost is not one of the live
                    // rows, and no hairline should tie it to them.
                    const InsetGroup(children: [_TogetherRow()]),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        learningFootnote,
                        style: tokens.meta.copyWith(
                          fontSize: 12.5,
                          color: tokens.muted,
                        ),
                      ),
                    ),
                    InsetGroup(
                      children: [
                        InsetRow(
                          key: const Key('you-account'),
                          leading: const Icon(Icons.person_outline),
                          title: 'Account',
                          subtitle: 'Login methods, linked providers',
                          onTap: () => _push(context, AccountScreen.new),
                        ),
                        const _SignOutRow(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The avatar's letter: the name's initial, or the placeholder name's.
  static String _initialOf(String? name) {
    final trimmed = (name ?? unnamedListener).trim();
    if (trimmed.isEmpty) return unnamedListener[0];
    return trimmed[0].toUpperCase();
  }

  /// The board's "7 remembered preferences". Null while the list has not
  /// loaded: a count nobody has read yet is not a fact about this listener.
  @visibleForTesting
  static String? rememberedLine(int? count) => switch (count) {
    null => null,
    0 => 'Nothing remembered yet',
    1 => '1 remembered preference',
    final n => '$n remembered preferences',
  };

  /// The board's "Apple and Google sign-in · Apple Music": the linked sign-in
  /// methods, then the music service, each dropped while it is unknown (null
  /// is unknown, not an account with nothing linked).
  @visibleForTesting
  static String identitySubtitle(
    List<LinkedAccount>? accounts,
    OnboardingState? onboarding,
  ) {
    final parts = <String>[
      if (accounts != null && accounts.isNotEmpty)
        '${_methodsLine(accounts)} sign-in',
      if (_serviceName(onboarding) != null) _serviceName(onboarding)!,
    ];
    return parts.isEmpty ? 'Account' : parts.join(' · ');
  }

  static String _methodsLine(List<LinkedAccount> accounts) {
    final names = accounts.map(_methodName).toList();
    if (names.length == 1) return names.single;
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }

  static String _methodName(LinkedAccount account) =>
      switch (account.providerId) {
        'apple' => 'Apple',
        'google' => 'Google',
        final other => other,
      };

  static String? _serviceName(OnboardingState? onboarding) =>
      switch (onboarding?.chosenService) {
        'apple' => 'Apple Music',
        'spotify' => 'Spotify',
        // Skipped the service gate: an answer, and one worth showing — add a
        // source from Library whenever they are ready.
        'skipped' => 'No service connected',
        _ => null,
      };
}

/// "Learn from my listening", bound to the same controller call the Listening
/// preferences screen writes (`playback_screen.dart` → `setLearning`).
class _LearningRow extends ConsumerStatefulWidget {
  const _LearningRow();

  static const Key switchKey = Key('you-learning-switch');
  static const String title = 'Learn from my listening';

  /// Shown while the setting has not been read (or a read failed): the switch
  /// must never show "off" as though the listener had chosen it.
  static const String unavailable = 'Not available right now';
  static const String saving = 'Saving…';

  /// `playback_screen.dart`'s failure line, kept word for word.
  static const String saveFailed =
      'Could not save. Collection is paused until you try again.';

  @override
  ConsumerState<_LearningRow> createState() => _LearningRowState();
}

class _LearningRowState extends ConsumerState<_LearningRow> {
  bool _saving = false;

  /// The value being written, so the switch holds it while the write is in
  /// flight instead of snapping back to nothing.
  bool? _pending;
  String? _error;

  /// The canonical setting read back after a failed write: the controller
  /// clears its own copy before saving, so a throw would otherwise leave this
  /// row with nothing to show and no way to try again.
  Map<String, dynamic>? _readback;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(playbackProvider).initialize();
    });
  }

  /// What the switch shows: the write in flight, then the controller's own
  /// answer, then the value read back after a failure.
  bool? _value(PlaybackController player) =>
      _pending ??
      player.preferences?['enabled'] as bool? ??
      _readback?['enabled'] as bool?;

  Future<void> _save(bool enabled) async {
    if (_saving) return;
    final player = ref.read(playbackProvider);
    setState(() {
      _saving = true;
      _pending = enabled;
      _error = null;
    });
    try {
      await player.setLearning(enabled);
      if (mounted) setState(() => _readback = null);
    } catch (_) {
      Map<String, dynamic>? current;
      try {
        current = await player.api.preferences();
      } catch (_) {
        // Still unreachable; the row stays on what it last knew.
      }
      if (mounted) {
        setState(() {
          _readback = current ?? _readback;
          _error = _LearningRow.saveFailed;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _pending = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playbackProvider);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final value = _value(player);
        final subtitle = _saving
            ? _LearningRow.saving
            : _error ?? (value == null ? _LearningRow.unavailable : null);

        return InsetRow(
          leading: const Icon(Icons.hearing_outlined),
          title: _LearningRow.title,
          subtitle: subtitle,
          trailing: Switch.adaptive(
            key: _LearningRow.switchKey,
            value: value ?? false,
            // Disabled only while a write is in flight: a failed save must
            // stay retryable.
            onChanged: _saving || value == null ? null : _save,
          ),
        );
      },
    );
  }
}

/// Together, drawn as the board's planned ghost: dashed outline, muted ink, a
/// Planned tag, and no tap of any kind.
class _TogetherRow extends StatelessWidget {
  const _TogetherRow();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Semantics(
      key: const Key('you-together'),
      container: true,
      label: YouTab.togetherLabel,
      excludeSemantics: true,
      child: CustomPaint(
        painter: _DashedOutline(color: tokens.muted),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: InsetGroup.rowInset),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.people_outline, size: 22, color: tokens.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Together',
                        style: tokens.rowTitle.copyWith(color: tokens.muted),
                      ),
                      Text(
                        'Blends and taste twins',
                        style: tokens.meta.copyWith(
                          fontSize: 12.5,
                          color: tokens.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _PlannedTag(color: tokens.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The board's `.tag`: a small dashed box holding one uppercase word.
class _PlannedTag extends StatelessWidget {
  const _PlannedTag({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedOutline(color: color, radius: 4, inset: 0, strokeWidth: 1),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: Text(
        'PLANNED',
        style: TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: color,
        ),
      ),
    ),
  );
}

/// The board's `outline: 1.5px dashed` — Flutter has no dashed border, so the
/// rounded rectangle is walked and stroked in segments.
class _DashedOutline extends CustomPainter {
  const _DashedOutline({
    required this.color,
    this.radius = 14,
    this.inset = 4,
    this.strokeWidth = 1.5,
  });

  final Color color;
  final double radius;
  final double inset;
  final double strokeWidth;

  /// The board's dash rhythm.
  static const double dash = 4;
  static const double gap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    if (rect.isEmpty) return;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color;
    for (final metric in path.computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = (start + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.inset != inset ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// Sign out, disabled while it is in flight so a second tap cannot start a
/// second sign-out or stack another SnackBar.
class _SignOutRow extends ConsumerStatefulWidget {
  const _SignOutRow();

  @override
  ConsumerState<_SignOutRow> createState() => _SignOutRowState();
}

class _SignOutRowState extends ConsumerState<_SignOutRow> {
  bool _signingOut = false;

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(authProvider.notifier).signOut();
    } catch (_) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text(YouTab.signOutFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) => InsetRow(
    key: const Key('you-signout'),
    leading: Icon(Icons.stop_rounded, color: context.tokens.errInk),
    title: 'Sign out',
    destructive: true,
    trailing: const SizedBox.shrink(),
    onTap: _signingOut ? null : _signOut,
  );
}

/// The identity block's round prism avatar: the one prism instance on this
/// screen, clipped to a 48 pt circle (smoke round two, note 7).
class _PrismAvatar extends StatelessWidget {
  const _PrismAvatar({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      key: YouTab.avatarKey,
      width: YouTab.avatarSize,
      height: YouTab.avatarSize,
      decoration: BoxDecoration(
        gradient: tokens.prismGradient(),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initial,
          style: tokens.section.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}
