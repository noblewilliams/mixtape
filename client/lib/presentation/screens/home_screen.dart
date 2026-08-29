import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/library_sync_provider.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(librarySyncProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('mixtape'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (sync) {
            SyncIdle() => FilledButton(
                key: const Key('sync-library'),
                onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                child: const Text('Sync my library'),
              ),
            SyncRunning(:final progress) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(value: progress == 0 ? null : progress),
                  const SizedBox(height: 16),
                  Text(progress == 0 ? 'Syncing…' : 'Syncing… ${(progress * 100).round()}%'),
                ],
              ),
            SyncDone(:final total) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Synced $total ${total == 1 ? 'song' : 'songs'}. The DJ is listening.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    key: const Key('sync-again'),
                    onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                    child: const Text('Sync again'),
                  ),
                ],
              ),
            SyncFailed(:final message) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    key: const Key('sync-retry'),
                    onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                    child: const Text('Try again'),
                  ),
                ],
              ),
          },
        ),
      ),
    );
  }
}
