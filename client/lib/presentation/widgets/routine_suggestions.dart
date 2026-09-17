import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/suggestions/suggestions_api.dart';
import '../providers/suggestions_provider.dart';
import '../providers/device_providers.dart';

class RoutineSuggestions extends ConsumerWidget {
  const RoutineSuggestions({
    super.key,
    required this.onCreate,
    this.busy = false,
  });
  final Future<void> Function(String) onCreate;
  final bool busy;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(suggestionsApiProvider);
    return _RoutineBody(
      key: ObjectKey(api),
      api: api,
      readZone: ref.watch(suggestionTimeZoneProvider),
      onCreate: onCreate,
      busy: busy,
    );
  }
}

class _RoutineBody extends StatefulWidget {
  const _RoutineBody({
    super.key,
    required this.api,
    required this.readZone,
    required this.onCreate,
    required this.busy,
  });
  final SuggestionsApi api;
  final TimeZoneReader readZone;
  final Future<void> Function(String) onCreate;
  final bool busy;
  @override
  State<_RoutineBody> createState() => _RoutineBodyState();
}

class _RoutineBodyState extends State<_RoutineBody>
    with WidgetsBindingObserver {
  SuggestionsData? _data;
  String? _error;
  bool _working = false;
  int _read = 0;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
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

  Future<void> _refresh() async {
    final request = ++_read;
    try {
      final zone = await widget.readZone();
      if (!mounted) return;
      final data = await widget.api.load(zone);
      if (mounted && request == _read) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && request == _read) {
        setState(() => _error = 'Could not load suggestions. Try again.');
      }
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_working || widget.busy) return;
    _read++;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not complete that action. Refresh suggestions and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _settings() async {
    final enabled = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            _SuggestionSettings(api: widget.api, enabled: _data!.enabled),
      ),
    );
    if (!mounted || enabled == null) return;
    setState(() => _data = SuggestionsData(enabled: enabled, dismissed: false));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final suggestion = _data?.suggestion;
    final disabled = _working || widget.busy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (suggestion != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A familiar moment',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    suggestion.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(suggestion.reason),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: disabled
                            ? null
                            : () => _act(() async {
                                final zone = await widget.readZone();
                                if (!mounted) return;
                                final prompt = await widget.api.select(
                                  suggestion.id,
                                  zone,
                                );
                                if (mounted) await widget.onCreate(prompt);
                              }),
                        child: Text(
                          widget.busy ? 'Making your mix…' : 'Make this mix',
                        ),
                      ),
                      TextButton(
                        onPressed: disabled
                            ? null
                            : () => _act(() async {
                                final zone = await widget.readZone();
                                if (!mounted) return;
                                await widget.api.dismiss(suggestion.id, zone);
                                if (mounted) {
                                  setState(
                                    () => _data = SuggestionsData(
                                      enabled: _data!.enabled,
                                      dismissed: true,
                                    ),
                                  );
                                }
                              }),
                        child: const Text('Not today'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (suggestion == null && _data?.enabled == true)
            Text(
              _data!.dismissed
                  ? 'That suggestion is hidden for today.'
                  : 'Your usual moments will appear here as Mixtape gets to know your routines.',
            ),
          if (_data == null && _error == null)
            const Text('Checking your usual moments…'),
          if (_error != null) ...[
            Semantics(liveRegion: true, child: Text(_error!)),
            TextButton(
              onPressed: disabled ? null : _refresh,
              child: const Text('Refresh suggestions'),
            ),
          ],
          TextButton(
            onPressed: _data == null || disabled ? null : _settings,
            child: const Text('Suggestion settings'),
          ),
        ],
      ),
    );
  }
}

class _SuggestionSettings extends ConsumerStatefulWidget {
  const _SuggestionSettings({required this.api, required this.enabled});
  final SuggestionsApi api;
  final bool enabled;
  @override
  ConsumerState<_SuggestionSettings> createState() =>
      _SuggestionSettingsState();
}

class _SuggestionSettingsState extends ConsumerState<_SuggestionSettings> {
  late bool _enabled = widget.enabled;
  bool _saving = false;
  String? _error;
  @override
  Widget build(BuildContext context) {
    final currentApi = ref.watch(suggestionsApiProvider);
    if (!identical(currentApi, widget.api)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Suggestion settings')),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Your account changed. Return to Home to update suggestions.',
          ),
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
            contentPadding: EdgeInsets.zero,
            title: const Text('Suggest mixes from my routines'),
            value: _enabled,
            onChanged: _saving
                ? null
                : (value) => setState(() => _enabled = value),
          ),
          const Text(
            'Suggestions appear in Mixtape. They never start playing by themselves.',
          ),
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() {
                        _saving = true;
                        _error = null;
                      });
                      try {
                        await widget.api.save(_enabled);
                        if (context.mounted) Navigator.pop(context, _enabled);
                      } catch (_) {
                        if (mounted) {
                          setState(() {
                            _saving = false;
                            _error = 'Could not save. Try again.';
                          });
                        }
                      }
                    },
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ],
      ),
    );
  }
}
