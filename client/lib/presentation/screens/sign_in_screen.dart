import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/auth/google_auth_gateway.dart';
import '../providers/auth_provider.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  AccountProvider? _busy;
  String? _error;

  Future<void> _signIn(AccountProvider provider) async {
    if (_busy != null) return;
    setState(() {
      _busy = provider;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signIn(provider: provider);
    } on AppleSignInCancelled {
      // Dismissing native authentication is not a failure.
    } on GoogleSignInCancelled {
      // The listener remains on this screen and can choose either method.
    } on AuthOperationCancelled {
      // An auth transition or disposal superseded this operation.
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error) {
          AuthSignInException(code: 'ACCOUNT_NOT_LINKED') =>
            'That account is not linked yet. Sign in with your usual method, then link it from Account.',
          GoogleSignInUnavailable() =>
            'Google sign-in is not available in this build.',
          _ => 'Sign-in failed. Try again.',
        },
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final googleAvailable = ref.watch(googleAuthGatewayProvider).isAvailable;
    final lastUsed = ref.watch(lastSignInProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('mixtape'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(0, constraints.maxHeight - 48),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Your music.\nYour moment.',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Sign in to keep your mixes and preferences.',
                        ),
                        const SizedBox(height: 32),
                        for (final provider in AccountProvider.values) ...[
                          OutlinedButton(
                            key: Key('${provider.name}-sign-in'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            onPressed:
                                _busy != null ||
                                    (provider == AccountProvider.google &&
                                        !googleAvailable)
                                ? null
                                : () => _signIn(provider),
                            child: Text(
                              'Continue with ${provider == AccountProvider.apple ? 'Apple' : 'Google'}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          if (lastUsed == provider)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Last used',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          const SizedBox(height: 12),
                        ],
                        if (_busy != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              'Waiting for ${_busy == AccountProvider.apple ? 'Apple' : 'Google'}…',
                            ),
                          ),
                        if (_error != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (!googleAvailable &&
                            _error !=
                                'Google sign-in is not available in this build.')
                          const Text(
                            'Google sign-in is not available in this build.',
                          ),
                        const SizedBox(height: 24),
                        const Text(
                          'Apple Music access is requested separately.',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
