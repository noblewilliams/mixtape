import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/google_auth_gateway.dart';
import '../providers/account_provider.dart';
import '../providers/auth_provider.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});
  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  bool _signingOut = false;
  String? _localError;
  AccountState? _expiryAttempted;

  void _expireIfCurrent(AccountState observed) {
    scheduleMicrotask(() async {
      if (!mounted ||
          identical(_expiryAttempted, observed) ||
          !identical(ref.read(accountProvider), observed) ||
          ref.read(authProvider) != AuthStatus.signedIn) {
        return;
      }
      _expiryAttempted = observed;
      await _signOut();
    });
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() {
      _signingOut = true;
      _localError = null;
    });
    try {
      await ref.read(authProvider.notifier).signOut();
    } catch (_) {
      if (mounted) {
        setState(() => _localError = 'Couldn’t sign out. Try again.');
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final lastUsed = ref.watch(lastSignInProvider).value;
    final googleAvailable = ref.watch(googleAuthGatewayProvider).isAvailable;
    ref.listen(accountProvider, (_, next) {
      if (next.error case ApiException(statusCode: 401)) _expireIfCurrent(next);
    });
    // An error may already exist when this route is opened.
    if (account.error case ApiException(statusCode: 401)) {
      _expireIfCurrent(account);
    }
    final busy = account.writing || _signingOut;
    final accounts = account.accounts;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Login methods',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Use either linked method to sign in to this account.',
                  ),
                  const SizedBox(height: 24),
                  for (final provider in AccountProvider.values) ...[
                    Builder(
                      builder: (context) {
                        final matching =
                            accounts
                                ?.where(
                                  (entry) => entry.providerId == provider.name,
                                )
                                .toList() ??
                            <LinkedAccount>[];
                        final linked = matching.isNotEmpty;
                        final label = provider == AccountProvider.apple
                            ? 'Apple'
                            : 'Google';
                        final canRemove =
                            account.canModify &&
                            matching.length == 1 &&
                            accounts!.length > 1;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                account.loading
                                    ? 'Checking…'
                                    : accounts == null
                                    ? 'Not yet verified'
                                    : linked
                                    ? 'Connected'
                                    : 'Not connected',
                              ),
                              if (lastUsed == provider) const Text('Last used'),
                              const SizedBox(height: 4),
                              TextButton(
                                key: Key(
                                  '${linked ? 'remove' : 'link'}-${provider.name}',
                                ),
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                ),
                                onPressed:
                                    busy ||
                                        (linked
                                            ? !canRemove
                                            : !account.canModify ||
                                                  (provider ==
                                                          AccountProvider
                                                              .google &&
                                                      !googleAvailable))
                                    ? null
                                    : () {
                                        final notifier = ref.read(
                                          accountProvider.notifier,
                                        );
                                        if (linked) {
                                          notifier.unlink(matching.single.id);
                                        } else {
                                          notifier.link(provider);
                                        }
                                      },
                                child: Text(linked ? 'Remove' : 'Link $label'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                  if (accounts != null && accounts.length == 1)
                    const Text(
                      'Keep at least one login method. Link another before removing this one.',
                    ),
                  if (!googleAvailable)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Google sign-in is not available in this build.',
                      ),
                    ),
                  if (account.writing)
                    Semantics(
                      liveRegion: true,
                      child: const Text('Verifying your login methods…'),
                    ),
                  if (account.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _accountError(account.error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  if (_localError != null)
                    Text(
                      _localError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  TextButton(
                    key: const Key('refresh-methods'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: busy || account.loading
                        ? null
                        : () => ref.read(accountProvider.notifier).refresh(),
                    child: const Text('Refresh methods'),
                  ),
                  const SizedBox(height: 24),
                  TextButton(
                    key: const Key('account-sign-out'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _signingOut ? null : _signOut,
                    child: Text(
                      _needsFreshSession(account.error)
                          ? 'Sign in again'
                          : 'Sign out',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _needsFreshSession(Object? error) =>
    error is AccountApiException && error.code == 'SESSION_NOT_FRESH';

String _accountError(Object error) => switch (error) {
  AccountApiException(code: 'SOCIAL_ACCOUNT_ALREADY_LINKED') =>
    'That login method belongs to another account. Your current account is unchanged.',
  AccountApiException(code: 'SESSION_NOT_FRESH') =>
    'Sign in again before removing a login method.',
  AccountApiException(code: 'FAILED_TO_UNLINK_LAST_ACCOUNT') ||
  AccountActionException(
    code: 'last_login_method',
  ) => 'Keep at least one login method. Link another first.',
  ApiException(statusCode: 401) => 'Your session expired. Sign in again.',
  GoogleSignInUnavailable() => 'Google sign-in is not available in this build.',
  _ => 'Couldn’t verify that change. Refresh your login methods and try again.',
};
