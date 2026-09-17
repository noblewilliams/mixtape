/// The You tab (`docs/mockups/approved/2026-09-17-mobile-shell.md` → You;
/// plan `docs/superpowers/plans/2026-09-17-native-design-implementation.md`
/// task 2.4).
///
/// A skeleton on purpose: the identity block with the square prism avatar and
/// native inset-grouped rows that reach the shipped screens, so the shell is
/// navigable end to end. The board's toggles ("Learn from my listening",
/// "Suggest mixes from my routines") and the Together ghost arrive in Phase 8;
/// rows are enough now.
///
/// Everything Home's overflow menu offered about the listener lands here: what
/// the DJ knows, listening, suggestions, account and sign out.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the app root.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/auth/account_api.dart';
import '../../../data/suggestions/suggestions_api.dart';
import '../../providers/account_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_sync_provider.dart' show accountNameProvider;
import '../../providers/suggestions_provider.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../../widgets/foundation/inset_group.dart';
import '../../widgets/foundation/large_title_scaffold.dart';
import '../account_screen.dart';
import '../memory_screen.dart';
import '../playback_screen.dart' show ListeningPreferencesScreen;

/// The You tab.
class YouTab extends ConsumerWidget {
  const YouTab({super.key});

  /// A row of breathing room under the last group, on top of the dock's own
  /// height: the shell hands that down as [MediaQuery.padding], which
  /// [LargeTitleScaffold] already emits at the end of the slivers.
  static const double defaultBottomInset = 16;

  /// The square prism avatar.
  static const Key avatarKey = Key('you-avatar');
  static const double avatarSize = 64;

  /// Shown until `/me` answers with a name (it never blocks the tab).
  static const String unnamedListener = 'Your account';

  static const String signOutFailed = 'Couldn’t sign out. Try again.';

  void _push(BuildContext context, Widget Function() screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(accountNameProvider).value;
    final accounts = ref.watch(accountProvider).accounts;
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
                          subtitle: _methodsLine(accounts),
                        ),
                      ],
                    ),
                    InsetGroup(
                      children: [
                        InsetRow(
                          key: const Key('you-memories'),
                          title: 'What the DJ knows',
                          onTap: () => _push(context, MemoryScreen.new),
                        ),
                        InsetRow(
                          key: const Key('you-listening'),
                          title: 'Listening',
                          onTap: () =>
                              _push(context, ListeningPreferencesScreen.new),
                        ),
                        InsetRow(
                          key: const Key('you-suggestions'),
                          title: 'Suggestions',
                          onTap: () =>
                              _push(context, SuggestionSettingsScreen.new),
                        ),
                      ],
                    ),
                    InsetGroup(
                      children: [
                        InsetRow(
                          key: const Key('you-account'),
                          title: 'Account',
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

  /// "Apple", "Apple and Google" — the sign-in methods when the account
  /// provider knows them, and a plain word while it does not (null is
  /// unknown, not an account with no methods).
  static String _methodsLine(List<LinkedAccount>? accounts) {
    if (accounts == null || accounts.isEmpty) return 'Account';
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
    title: 'Sign out',
    destructive: true,
    trailing: const SizedBox.shrink(),
    onTap: _signingOut ? null : _signOut,
  );
}

/// The identity block's square prism avatar: the one prism instance on this
/// screen, at the board's 3 pt tile radius.
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
        borderRadius: BorderRadius.circular(MixtapeMetrics.tileRadius),
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

/// Suggestion settings, reachable from the You tab.
///
/// Gap (task 2.4): the shipped settings screen is private to
/// `routine_suggestions.dart` (`_SuggestionSettings`, pushed by the Home
/// card), which this task may not edit, so this reproduces its toggle, its
/// copy, its save and its account-change guard.
// TODO(Phase 8): extract one shared suggestion toggle and delete the private
// copy in routine_suggestions.dart.
class SuggestionSettingsScreen extends ConsumerStatefulWidget {
  const SuggestionSettingsScreen({super.key});

  static const Key toggleKey = Key('you-suggestions-toggle');
  static const Key saveKey = Key('you-suggestions-save');

  /// What the screen says once the account behind the API has changed — an
  /// in-flight toggle must never be written against another listener's
  /// account (`routine_suggestions.dart`'s guard, verbatim).
  static const String accountChanged =
      'Your account changed. Return to Home to update suggestions.';

  @override
  ConsumerState<SuggestionSettingsScreen> createState() =>
      _SuggestionSettingsScreenState();
}

class _SuggestionSettingsScreenState
    extends ConsumerState<SuggestionSettingsScreen> {
  bool? _enabled;
  bool _saving = false;
  String? _error;

  /// The API this screen loaded against. A new one means a new account.
  late final SuggestionsApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(suggestionsApiProvider);
    _load();
  }

  Future<void> _load() async {
    final api = _api;
    final readZone = ref.read(suggestionTimeZoneProvider);
    try {
      final zone = await readZone();
      final data = await api.load(zone);
      if (mounted) setState(() => _enabled = data.enabled);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load suggestions. Try again.');
      }
    }
  }

  Future<void> _save() async {
    final api = _api;
    if (!identical(ref.read(suggestionsApiProvider), api)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await api.save(_enabled!);
      if (mounted) Navigator.of(context).pop(_enabled);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    if (!identical(ref.watch(suggestionsApiProvider), _api)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Suggestion settings')),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(SuggestionSettingsScreen.accountChanged),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Suggestion settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Suggestions, on your terms.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          SwitchListTile(
            key: SuggestionSettingsScreen.toggleKey,
            contentPadding: EdgeInsets.zero,
            title: const Text('Suggest mixes from my routines'),
            value: enabled ?? false,
            onChanged: enabled == null || _saving
                ? null
                : (value) => setState(() => _enabled = value),
          ),
          const Text(
            'Suggestions appear in Mixtape. They never start playing by '
            'themselves.',
          ),
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: SuggestionSettingsScreen.saveKey,
              onPressed: enabled == null || _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ],
      ),
    );
  }
}
