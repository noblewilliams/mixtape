import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../providers/auth_provider.dart';

class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('mixtape', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('your personal DJ'),
            const SizedBox(height: 48),
            FilledButton.icon(
              key: const Key('apple-sign-in'),
              onPressed: () async {
                try {
                  await ref.read(authProvider.notifier).signIn();
                } on AppleSignInCancelled {
                  // User dismissed the Apple sheet — not an error.
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
                  }
                }
              },
              icon: const Icon(Icons.apple),
              label: const Text('Sign in with Apple'),
            ),
          ],
        ),
      ),
    );
  }
}
