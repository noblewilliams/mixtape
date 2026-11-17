/// Archived mixes, behind the "Archived" row at the top of the Mixes tab —
/// WhatsApp's Archived chats (founder, 2026-11-09). Pushed inside the Mixes
/// tab's navigator, so the dock steps aside for it as it does for a
/// conversation.
///
/// The rows are the Mixes tab's: tap to open, long-press for the menu, swipe
/// left for More and Unarchive. Select mode works here as on Mixes, with
/// Unarchive in Archive's place and Select all in Back's while selecting
/// (select and delete mixes board, S8).
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../providers/dj_providers.dart';
import '../widgets/foundation/empty_state.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/swipe_actions.dart';
import '../widgets/mix_home_row.dart';
import 'chat_screen.dart';
import 'mix_archive_feedback.dart';
import 'mix_select_flow.dart';
import '../providers/mix_activity_provider.dart';

class ArchivedMixesScreen extends ConsumerStatefulWidget {
  const ArchivedMixesScreen({super.key});

  static const Key backKey = Key('archived-mixes-back');
  static const Key listKey = Key('archived-mixes-list');
  static const Key emptyKey = Key('archived-mixes-empty');

  @override
  ConsumerState<ArchivedMixesScreen> createState() =>
      _ArchivedMixesScreenState();
}

class _ArchivedMixesScreenState extends ConsumerState<ArchivedMixesScreen>
    with MixSelectFlow<ArchivedMixesScreen> {
  @override
  List<DjSession> get selectableSessions =>
      archivedSessions(ref.read(sessionsProvider).value ?? const []);

  @override
  Set<String> get workingIds =>
      ref.read(mixActivityProvider).working.keys.toSet();

  @override
  bool get archivedList => true;

  void _open(BuildContext context, WidgetRef ref, String sessionId) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (_) => ChatScreen(sessionId: sessionId)),
        )
        .then((_) {
          if (!context.mounted) return;
          ref.read(sessionsProvider.notifier).refresh();
        });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider).value ?? const <DjSession>[];
    final archived = archivedSessions(sessions);
    pruneSelection();
    exitSelectOnTabChange(context);

    // Back while selecting ends select mode rather than leaving.
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) exitSelect();
      },
      child: GradientBackground(
        // As on the tab: a transparent Scaffold only to host this screen's own
        // SnackBars, floating so Undo stays clear of the home indicator.
        child: Theme(
          data: Theme.of(context).copyWith(
            snackBarTheme: Theme.of(
              context,
            ).snackBarTheme.copyWith(behavior: SnackBarBehavior.floating),
          ),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SwipeActionsGroup(
                  child: LargeTitleScaffold(
                    title: 'Archived',
                    leading: selecting
                        ? selectAllButton()
                        : GlassCluster(
                            children: [
                              GlassButton(
                                key: ArchivedMixesScreen.backKey,
                                icon: CupertinoIcons.chevron_left,
                                label: 'Back',
                                onPressed: () =>
                                    Navigator.of(context).maybePop(),
                              ),
                            ],
                          ),
                    trailing: selecting
                        ? doneButton()
                        : archived.isEmpty
                        ? null
                        : moreButton(),
                    onRefresh: () =>
                        ref.read(sessionsProvider.notifier).refresh(),
                    slivers: [
                      if (archived.isEmpty)
                        const EmptyStateSliver(
                          key: ArchivedMixesScreen.emptyKey,
                          child: EmptyState(
                            title: 'Nothing archived',
                            body:
                                'Swipe a mix left and tap Archive to keep it here.',
                          ),
                        )
                      else
                        SliverList.builder(
                          key: ArchivedMixesScreen.listKey,
                          itemCount: archived.length,
                          // By key, so a row keeps its state as others leave.
                          findChildIndexCallback: (key) {
                            final index = archived.indexWhere(
                              (s) => Key('session-${s.id}') == key,
                            );
                            return index < 0 ? null : index;
                          },
                          itemBuilder: (context, index) {
                            final session = archived[index];
                            return MixHomeRow(
                              key: Key('session-${session.id}'),
                              session: session,
                              isFirst: index == 0,
                              onOpen: () => _open(context, ref, session.id),
                              onRename: (title) => ref
                                  .read(sessionsProvider.notifier)
                                  .rename(session.id, title),
                              onCaseColor: (color) => ref
                                  .read(sessionsProvider.notifier)
                                  .setCaseColor(session.id, color),
                              onArchive: () => setMixArchived(
                                context,
                                ref,
                                session.id,
                                archived: true,
                              ),
                              onRestore: () => setMixArchived(
                                context,
                                ref,
                                session.id,
                                archived: false,
                              ),
                              onSelect: () => enterSelect(session.id),
                              selecting: selecting,
                              selected: isSelected(session.id),
                              fading: isDeleting(session.id),
                              onToggleSelected: () =>
                                  toggleSelected(session.id),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                if (selecting) selectToolbar(context),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
