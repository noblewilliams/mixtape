/// Account (`docs/mockups/approved/2026-09-08-mobile-parity.md` → Account
/// methods; linking rules in `docs/mockups/approved/
/// 2026-08-31-web-google-auth-account-linking.md`).
///
/// The identity block, then one row per login method: its mark, its name, its
/// status, whether it was the last one used, and a single trailing action.
/// Signing out belongs to You; the only sign-in action here is the deliberate
/// one a stale session or a failed expiry asks for.
library;

import 'dart:async';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/google_auth_gateway.dart';
import '../providers/account_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_sync_provider.dart' show accountNameProvider;
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/inset_group.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/text_action.dart';
import 'sign_in_screen.dart' show AppleMark, GoogleMark, SignInScreen;

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  /// The identity block's square prism avatar.
  static const Key avatarKey = Key('account-avatar');
  static const double avatarSize = 44;

  /// The provider mark beside each login method.
  static const double markSize = 22;

  /// Shown until `/me` answers with a name; it never blocks the screen.
  static const String unnamedListener = 'Your account';

  /// Why the only remaining method cannot be unlinked.
  static const String lastMethodReason = 'Add another method first';

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
    final tokens = context.tokens;
    final account = ref.watch(accountProvider);
    final lastUsed = ref.watch(lastSignInProvider).value;
    final googleAvailable = ref.watch(googleAuthGatewayProvider).isAvailable;
    final name = ref.watch(accountNameProvider).value;
    ref.listen(accountProvider, (_, next) {
      if (next.error case ApiException(statusCode: 401)) _expireIfCurrent(next);
    });
    // An error may already exist when this route is opened.
    if (account.error case ApiException(statusCode: 401)) {
      _expireIfCurrent(account);
    }

    final busy = account.writing || _signingOut;
    final verifying = account.loading || account.writing;
    final signInAgain =
        _needsFreshSession(account.error) || _localError != null;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'Account',
          leading: GlassCluster(
            children: [
              GlassButton(
                key: const Key('account-back'),
                icon: CupertinoIcons.chevron_left,
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InsetGroup(
                    children: [
                      InsetRow(
                        leading: const _PrismAvatar(),
                        title: (name == null || name.trim().isEmpty)
                            ? AccountScreen.unnamedListener
                            : name.trim(),
                      ),
                    ],
                  ),
                  InsetGroup(
                    header: const SectionWord('Login methods'),
                    children: [
                      for (final provider in AccountProvider.values)
                        _MethodRow(
                          provider: provider,
                          account: account,
                          busy: busy,
                          googleAvailable: googleAvailable,
                          lastUsed: lastUsed == provider,
                        ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextAction(
                      key: const Key('refresh-methods'),
                      label: 'Refresh methods',
                      onPressed: busy || account.loading
                          ? null
                          : () => ref.read(accountProvider.notifier).refresh(),
                    ),
                  ),
                  if (verifying)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          'Verifying your login methods…',
                          style: tokens.meta.copyWith(color: tokens.muted),
                        ),
                      ),
                    ),
                  if (!googleAvailable)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        SignInScreen.googleUnavailable,
                        style: tokens.meta.copyWith(color: tokens.muted),
                      ),
                    ),
                  if (account.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _accountError(account.error!),
                          style: tokens.secondary.copyWith(
                            color: tokens.errInk,
                          ),
                        ),
                      ),
                    ),
                  if (_localError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _localError!,
                        style: tokens.secondary.copyWith(color: tokens.errInk),
                      ),
                    ),
                  if (signInAgain)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextAction(
                        key: const Key('account-sign-out'),
                        label: 'Sign in again',
                        onPressed: _signingOut ? null : _signOut,
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One login method: mark, name, status, and the single action that changes
/// it. The last remaining method carries the reason it cannot be removed
/// beside its disabled action, not as a separate warning.
class _MethodRow extends ConsumerWidget {
  const _MethodRow({
    required this.provider,
    required this.account,
    required this.busy,
    required this.googleAvailable,
    required this.lastUsed,
  });

  final AccountProvider provider;
  final AccountState account;
  final bool busy;
  final bool googleAvailable;
  final bool lastUsed;

  static String nameOf(AccountProvider provider) =>
      provider == AccountProvider.apple ? 'Apple' : 'Google';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final accounts = account.accounts;
    final matching =
        accounts
            ?.where((entry) => entry.providerId == provider.name)
            .toList() ??
        const <LinkedAccount>[];
    final linked = matching.isNotEmpty;
    final onlyMethod = linked && accounts != null && accounts.length == 1;
    final canRemove =
        account.canModify && matching.length == 1 && accounts!.length > 1;
    final canLink =
        account.canModify &&
        !(provider == AccountProvider.google && !googleAvailable);

    final status = account.loading
        ? Text('Checking…', style: tokens.meta.copyWith(color: tokens.muted))
        : accounts == null
        ? Text(
            'Not yet verified',
            style: tokens.meta.copyWith(color: tokens.muted),
          )
        : linked
        ? const StatusWord(label: 'Linked', kind: StatusKind.ok)
        : const StatusWord(label: 'Not linked', kind: StatusKind.muted);

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: InsetGroup.rowInset),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            provider == AccountProvider.apple
                ? AppleMark(size: AccountScreen.markSize, color: tokens.text)
                : const GoogleMark(size: AccountScreen.markSize),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(nameOf(provider), style: tokens.rowTitle),
                  const SizedBox(height: 2),
                  status,
                  if (lastUsed && linked)
                    Text(
                      'Last used',
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                  if (onlyMethod)
                    Text(
                      AccountScreen.lastMethodReason,
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextAction(
              key: Key('${linked ? 'remove' : 'link'}-${provider.name}'),
              label: linked ? 'Unlink' : 'Link',
              onPressed: busy || (linked ? !canRemove : !canLink)
                  ? null
                  : () {
                      final notifier = ref.read(accountProvider.notifier);
                      if (linked) {
                        notifier.unlink(matching.single.id);
                      } else {
                        notifier.link(provider);
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }
}

/// The identity block's square prism avatar, at the board's 3 pt tile radius.
class _PrismAvatar extends StatelessWidget {
  const _PrismAvatar();

  @override
  Widget build(BuildContext context) => Container(
    key: AccountScreen.avatarKey,
    width: AccountScreen.avatarSize,
    height: AccountScreen.avatarSize,
    decoration: BoxDecoration(
      gradient: context.tokens.prismGradient(),
      borderRadius: BorderRadius.circular(MixtapeMetrics.tileRadius),
    ),
  );
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
  GoogleSignInUnavailable() => SignInScreen.googleUnavailable,
  _ => 'Couldn’t verify that change. Refresh your login methods and try again.',
};
