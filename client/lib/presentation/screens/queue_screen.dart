import 'package:flutter/material.dart';

/// Placeholder for Task 5 (drag/swipe queue editing, play-in-Apple-Music,
/// save-as-playlist, reason-on-tap) — see
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`. [ChatScreen] and
/// [QueueCard] already navigate here today, so the constructor shape is
/// binding: Task 5 replaces this body but must keep
/// `QueueScreen({required sessionId})` stable.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('queue')),
      body: const Center(child: Text('queue')),
    );
  }
}
