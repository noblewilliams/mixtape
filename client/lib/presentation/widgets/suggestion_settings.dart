/// The one "Suggest mixes from my routines" control
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → You; frame Y1 in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`; plan task 8.3).
///
/// The board replaced the Suggestions screen with a real toggle in the You
/// list, so this is a row, not a screen: it loads the setting, writes it
/// straight through on change, and refuses the write when the account behind
/// the API has changed underneath it (the guard `routine_suggestions.dart`'s
/// settings screen carried, with its copy).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/suggestions/suggestions_api.dart';
import '../providers/suggestions_provider.dart';
import 'foundation/inset_group.dart';

/// An [InsetRow] with a native switch bound to the routine-suggestions
/// setting. Belongs inside an [InsetGroup].
class SuggestionSettings extends ConsumerStatefulWidget {
  const SuggestionSettings({super.key});

  /// The switch itself, keyed for the You tab's tests.
  static const Key switchKey = Key('you-suggestions-switch');

  static const String title = 'Suggest mixes from my routines';

  /// What the row says once the account behind the API has changed — a toggle
  /// must never be written against another listener's account.
  static const String accountChanged =
      'Your account changed. Return to Home to update suggestions.';

  static const String loadFailed = 'Could not load suggestions. Try again.';
  static const String saveFailed = 'Could not save. Try again.';

  @override
  ConsumerState<SuggestionSettings> createState() => _SuggestionSettingsState();
}

class _SuggestionSettingsState extends ConsumerState<SuggestionSettings> {
  bool? _enabled;
  bool _saving = false;
  String? _error;

  /// The API this row loaded against. A new one means a new account.
  late final SuggestionsApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(suggestionsApiProvider);
    _load();
  }

  Future<void> _load() async {
    try {
      final zone = await ref.read(suggestionTimeZoneProvider)();
      final data = await _api.load(zone);
      if (mounted) setState(() => _enabled = data.enabled);
    } catch (_) {
      if (mounted) setState(() => _error = SuggestionSettings.loadFailed);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_saving || !identical(ref.read(suggestionsApiProvider), _api)) return;
    setState(() {
      _saving = true;
      _error = null;
      _enabled = value;
    });
    try {
      await _api.save(value);
    } catch (_) {
      if (mounted) {
        setState(() {
          // Never leave the switch showing a value the server does not hold.
          _enabled = !value;
          _error = SuggestionSettings.saveFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = !identical(ref.watch(suggestionsApiProvider), _api);
    final subtitle = changed ? SuggestionSettings.accountChanged : _error;
    final live = !changed && _enabled != null && !_saving;

    return InsetRow(
      leading: const Icon(Icons.auto_awesome_outlined),
      title: SuggestionSettings.title,
      subtitle: subtitle,
      trailing: Switch.adaptive(
        key: SuggestionSettings.switchKey,
        value: _enabled ?? false,
        onChanged: live ? _toggle : null,
      ),
    );
  }
}
