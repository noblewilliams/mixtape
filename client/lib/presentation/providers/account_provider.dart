import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/google_auth_gateway.dart';
import 'auth_provider.dart';

final accountApiProvider = Provider<AccountApi>((ref) {
  ref.watch(authProvider);
  return AccountApi(ref.watch(apiClientProvider));
});

/// Authentication for linking only obtains a provider token. It must never
/// invoke the sign-in repository or replace the current Mixtape session.
final accountIdentityTokenProvider =
    Provider<Future<String> Function(AccountProvider)>((ref) {
      final apple = ref.watch(appleAuthGatewayProvider);
      final google = ref.watch(googleAuthGatewayProvider);
      return (provider) => switch (provider) {
        AccountProvider.apple => apple.getIdentityToken(),
        AccountProvider.google => google.getIdentityToken(),
      };
    });

class AccountActionException implements Exception {
  const AccountActionException(this.code);
  final String code;

  @override
  String toString() => 'AccountActionException($code)';
}

class AccountState {
  const AccountState({
    this.accounts,
    this.loading = false,
    this.writing = false,
    this.error,
  });

  /// Null is unknown, not an account with no login methods.
  final List<LinkedAccount>? accounts;
  final bool loading;
  final bool writing;
  final Object? error;
  bool get canModify => accounts != null && !loading && !writing;
}

class AccountNotifier extends Notifier<AccountState> {
  int _generation = 0;
  int _operation = 0;

  @override
  AccountState build() {
    final auth = ref.watch(authProvider);
    final api = ref.watch(accountApiProvider);
    final generation = ++_generation;
    final operation = ++_operation;
    ref.onDispose(() => _generation++);
    if (auth != AuthStatus.signedIn) return const AccountState();
    unawaited(
      Future.microtask(() async {
        if (_current(generation, operation)) {
          await _load(api, generation, operation);
        }
      }),
    );
    return const AccountState(loading: true);
  }

  bool _current(int generation, int operation) =>
      ref.mounted &&
      generation == _generation &&
      operation == _operation &&
      ref.read(authProvider) == AuthStatus.signedIn;

  Future<bool> _load(AccountApi api, int generation, int operation) async {
    try {
      final accounts = await api.list();
      if (!_current(generation, operation)) return false;
      state = AccountState(accounts: List.unmodifiable(accounts));
      return true;
    } catch (error) {
      if (!_current(generation, operation)) return false;
      state = AccountState(error: error);
      return false;
    }
  }

  Future<bool> refresh() async {
    if (!ref.mounted ||
        ref.read(authProvider) != AuthStatus.signedIn ||
        state.writing) {
      return false;
    }
    final generation = _generation;
    final operation = ++_operation;
    final api = ref.read(accountApiProvider);
    state = AccountState(accounts: state.accounts, loading: true);
    return _load(api, generation, operation);
  }

  Future<bool> link(AccountProvider provider) async {
    if (!ref.mounted ||
        !state.canModify ||
        ref.read(authProvider) != AuthStatus.signedIn) {
      return false;
    }
    final accounts = state.accounts!;
    if (accounts.any((account) => account.providerId == provider.name)) {
      return false;
    }
    final generation = _generation;
    final operation = ++_operation;
    final api = ref.read(accountApiProvider);
    final identityToken = ref.read(accountIdentityTokenProvider);
    state = AccountState(accounts: accounts, writing: true);
    late String token;
    try {
      token = await identityToken(provider);
      if (!_current(generation, operation)) return false;
      if (token.trim().isEmpty) {
        throw const AccountActionException('missing_identity_token');
      }
    } catch (error) {
      if (!_current(generation, operation)) return false;
      state = AccountState(
        accounts: accounts,
        error: error is AppleSignInCancelled || error is GoogleSignInCancelled
            ? null
            : error,
      );
      return false;
    }
    return _mutate(
      api: api,
      generation: generation,
      operation: operation,
      write: () => api.link(provider: provider, token: token),
      succeeded: (current) =>
          current.any((account) => account.providerId == provider.name),
    );
  }

  Future<bool> unlink(String accountRowId) async {
    if (!ref.mounted ||
        !state.canModify ||
        ref.read(authProvider) != AuthStatus.signedIn) {
      return false;
    }
    final accounts = state.accounts!;
    final targets = accounts.where((account) => account.id == accountRowId);
    if (targets.length != 1) return false;
    if (accounts.length <= 1) {
      state = AccountState(
        accounts: accounts,
        error: const AccountActionException('last_login_method'),
      );
      return false;
    }
    final generation = _generation;
    final operation = ++_operation;
    final api = ref.read(accountApiProvider);
    state = AccountState(accounts: accounts, writing: true);
    return _mutate(
      api: api,
      generation: generation,
      operation: operation,
      write: () => api.unlink(targets.single),
      succeeded: (current) =>
          !current.any((account) => account.id == accountRowId),
    );
  }

  Future<bool> _mutate({
    required AccountApi api,
    required int generation,
    required int operation,
    required Future<void> Function() write,
    required bool Function(List<LinkedAccount>) succeeded,
  }) async {
    Object? mutationError;
    try {
      await write();
    } catch (error) {
      if (!_current(generation, operation)) return false;
      if (error is ApiException && error.statusCode == 401) {
        state = AccountState(error: error);
        return false;
      }
      mutationError = error;
    }
    if (!_current(generation, operation)) return false;
    if (!await _load(api, generation, operation) ||
        !_current(generation, operation)) {
      return false;
    }
    final accounts = state.accounts!;
    if (succeeded(accounts)) return true;
    state = AccountState(
      accounts: accounts,
      error:
          mutationError ?? const AccountActionException('change_not_confirmed'),
    );
    return false;
  }
}

final accountProvider = NotifierProvider<AccountNotifier, AccountState>(
  AccountNotifier.new,
);
