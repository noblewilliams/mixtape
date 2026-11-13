// Opens a shared mix a universal link brought in (spec 2026-11-13
// shared-mixes → Recipient in the app). Sits at the root of whatever the app
// shows — the shell, and the first-run flow's Welcome page, which stays
// mounted under the flow's pushed pages — so a link opens both before and
// after first run, on a cold start and while running.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/incoming_link_provider.dart';

class SharedMixLinkListener extends ConsumerStatefulWidget {
  const SharedMixLinkListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SharedMixLinkListener> createState() =>
      _SharedMixLinkListenerState();
}

class _SharedMixLinkListenerState extends ConsumerState<SharedMixLinkListener> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    // Fires at once for a token that arrived before this root was up (a
    // cold start, or a link opened while auth was still loading).
    ref.listenManual<String?>(pendingSharedMixProvider, (_, token) {
      if (token != null) _schedule();
    }, fireImmediately: true);
  }

  /// After the frame: never push while a navigator is building, and the root
  /// navigator is ready by then on a cold start.
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      // Taking the token is what makes it open once.
      final token = ref.read(pendingSharedMixProvider.notifier).consume();
      if (token == null) return;
      ref.read(sharedMixPresenterProvider)(context, token);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
