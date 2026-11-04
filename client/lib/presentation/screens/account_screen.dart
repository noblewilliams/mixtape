/// Account (`docs/mockups/approved/2026-09-08-mobile-parity.md` → Account
/// methods; linking rules in `docs/mockups/approved/
/// 2026-08-31-web-google-auth-account-linking.md`).
///
/// The identity block, then one row per login method: its mark, its name, its
/// status, whether it was the last one used, and a single trailing action.
/// Signing out belongs to You; the only sign-in action here is the deliberate
/// one a stale session or a failed expiry asks for.
///
/// Delete account closes the screen (`docs/superpowers/plans/
/// 2026-11-02-account-deletion.md`): one destructive alert, then, for an
/// account with an Apple login, a fresh Apple sheet whose code lets the
/// server revoke Apple's tokens. Success moves auth to noSession and the
/// root gate takes the listener to the welcome.
library;

import 'dart:async';
import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoIcons,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/google_auth_gateway.dart';
import '../../data/auth/profile_name.dart';
import '../providers/account_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/capabilities_provider.dart' show meProvider;
import '../providers/library_sync_provider.dart' show accountNameProvider;
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/inset_group.dart';
import '../widgets/foundation/large_title_scaffold.dart';
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

  /// The name edit (`docs/mockups/approved/2026-11-02-profile-name.md`).
  static const Key nameRowKey = Key('account-name-row');
  static const Key nameFieldKey = Key('account-name-field');
  static const Key nameClearKey = Key('account-name-clear');
  static const ValueKey<String> nameSaveKey = ValueKey('account-name-save');
  static const ValueKey<String> nameCancelKey = ValueKey('account-name-cancel');
  static const String addName = 'Add name';
  static const String editName = 'Edit';
  static const String nameLabel = 'Your name';
  static const String nameHint =
      'Up to 40 characters. Leave it blank to remove your name.';
  static const String nameCut = 'Names stop at 40 characters.';
  static const String nameSaving = 'Saving…';
  static const String nameFailed = 'Couldn’t save your name.';
  static const String nameExpired = 'Your session expired. Sign in again.';
  static const String nameSaved = 'Name saved';
  static const String nameRemoved = 'Name removed';

  /// The count appears from this many characters.
  static const int nameCountFrom = 30;

  /// Why the only remaining method cannot be unlinked.
  static const String lastMethodReason = 'Add another method before unlinking';

  /// Account deletion copy, fixed by the plan for both clients.
  static const String deleteLabel = 'Delete account';
  static const String deleteTitle = 'Delete your account?';
  static const String deleteBody =
      'This permanently deletes your mixes, library, memories and listening '
      'history from Mixtape. Your Apple Music and Spotify libraries are not '
      'touched.';
  static const String deleteFailed = 'Couldn’t delete your account. Try again.';

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  bool _signingOut = false;
  bool _deleting = false;
  String? _localError;
  String? _deleteError;
  AccountState? _expiryAttempted;

  void _expireIfCurrent(AccountState observed) {
    scheduleMicrotask(() async {
      if (!mounted ||
          identical(_expiryAttempted, observed) ||
          !identical(ref.read(accountProvider), observed) ||
          ref.read(authProvider) != AuthStatus.session) {
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

  /// A name save answered 401: the same expiry as the methods' 401, so the
  /// listener signs in again rather than retrying a dead session. If signing
  /// out fails, "Sign in again" stays offered.
  void _nameSessionExpired() {
    if (ref.read(authProvider) != AuthStatus.session) return;
    unawaited(_signOut());
  }

  Future<void> _deleteAccount() async {
    if (_deleting) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text(AccountScreen.deleteTitle),
        content: const Text(AccountScreen.deleteBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(AccountScreen.deleteLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _deleting) return;
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    try {
      // The row is disabled until the methods are verified, so this list is
      // known: a native Apple sign-in leaves no token on the server, and the
      // fresh code from this sheet is the only way to revoke Apple's grant.
      final apple =
          ref
              .read(accountProvider)
              .accounts
              ?.any((a) => a.providerId == AccountProvider.apple.name) ??
          false;
      String? code;
      if (apple) {
        try {
          code = await ref
              .read(appleAuthGatewayProvider)
              .getAuthorizationCode();
        } on AppleSignInCancelled {
          // Dismissing the Apple sheet is changing one's mind, not an error.
          return;
        } catch (_) {
          // `unknown` is common without iCloud and on the simulator: the
          // listener still asked for their data to go, so delete without it.
          code = null;
        }
      }
      await ref
          .read(authProvider.notifier)
          .deleteAccount(appleAuthorizationCode: code);
    } catch (_) {
      if (mounted) setState(() => _deleteError = AccountScreen.deleteFailed);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final account = ref.watch(accountProvider);
    final lastUsed = ref.watch(lastSignInProvider).value;
    final googleAvailable = ref.watch(googleAuthGatewayProvider).isAvailable;
    final name = ref.watch(accountNameProvider).value;
    // Offered to accounts only; anonymous data expires on its own.
    final canDelete =
        ref.watch(authProvider) == AuthStatus.session &&
        !ref.watch(isAnonymousProvider);
    ref.listen(accountProvider, (_, next) {
      if (next.error case ApiException(statusCode: 401)) _expireIfCurrent(next);
    });
    // An error may already exist when this route is opened.
    if (account.error case ApiException(statusCode: 401)) {
      _expireIfCurrent(account);
    }

    final busy = account.writing || _signingOut || _deleting;
    final verifying = account.loading || account.writing;
    // Unverified methods (loading or failed) keep deletion off: whether an
    // Apple login needs revoking is unknown. Refresh methods is the retry.
    final deleteEnabled = !busy && account.canModify;
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
                  _Identity(
                    name: name,
                    editable: canDelete,
                    onSessionExpired: _nameSessionExpired,
                  ),
                  InsetGroup(
                    header: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Login methods',
                            style: tokens.meta.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextAction(
                          key: const Key('refresh-methods'),
                          label: 'Refresh',
                          quiet: true,
                          onPressed: busy || account.loading
                              ? null
                              : () => ref
                                    .read(accountProvider.notifier)
                                    .refresh(),
                        ),
                      ],
                    ),
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
                  if (!verifying && account.accounts?.length == 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      child: Text(
                        '${AccountScreen.lastMethodReason} ${account.accounts!.single.providerId == 'apple' ? 'Apple' : 'Google'}.',
                        style: tokens.meta.copyWith(color: tokens.muted),
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
                  if (canDelete) ...[
                    InsetGroup(
                      children: [
                        Opacity(
                          opacity: deleteEnabled ? 1 : 0.5,
                          child: InsetRow(
                            key: const Key('account-delete'),
                            leading: Icon(
                              CupertinoIcons.trash,
                              color: tokens.errInk,
                            ),
                            title: AccountScreen.deleteLabel,
                            destructive: true,
                            trailing: const SizedBox.shrink(),
                            onTap: deleteEnabled ? _deleteAccount : null,
                          ),
                        ),
                      ],
                    ),
                    if (_deleteError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _deleteError!,
                            style: tokens.secondary.copyWith(
                              color: tokens.errInk,
                            ),
                          ),
                        ),
                      ),
                  ],
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
/// in a shared footnote below the group.
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
        ? const StatusWord(label: 'Linked', kind: StatusKind.muted, icon: false)
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      status,
                      if (lastUsed && linked && !account.loading)
                        Text(
                          'Last used',
                          style: tokens.meta.copyWith(color: tokens.muted),
                        ),
                    ],
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

/// The identity block: the square prism avatar and the name, or "Your
/// account". For an account the whole row is the button, with a trailing
/// "Edit" or "Add name"; editing happens in place, the title turning into the
/// field and Save and Cancel sitting under the group
/// (`docs/mockups/2026-11-02-profile-name-states.html` → A1–A7). Done on the
/// keyboard saves; leaving the field does not (no silent saves).
class _Identity extends ConsumerStatefulWidget {
  const _Identity({
    required this.name,
    required this.editable,
    required this.onSessionExpired,
  });

  /// A save answered 401.
  final VoidCallback onSessionExpired;

  /// The saved name from `/me`, or null.
  final String? name;

  /// Accounts only: anonymous listeners have nothing to name.
  final bool editable;

  @override
  ConsumerState<_Identity> createState() => _IdentityState();
}

class _IdentityState extends ConsumerState<_Identity> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  late final _formatter = ProfileNameFormatter(onCut: _onCut);
  bool _editing = false;
  bool _saving = false;
  bool _failed = false;
  bool _cut = false;
  bool _expired = false;

  String? get _saved {
    final name = widget.name?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  @override
  void initState() {
    super.initState();
    _field.addListener(_changed);
    _focus.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _Identity oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Signed out or became anonymous mid-edit: nothing left to name.
    if (!widget.editable && _editing && !_saving) _editing = false;
  }

  @override
  void dispose() {
    _field.removeListener(_changed);
    _focus.removeListener(_changed);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _text = '';

  void _changed() {
    if (!mounted) return;
    final typed = _field.text != _text;
    _text = _field.text;
    // Typing after a failure clears the error; Save is Save again.
    setState(() {
      if (typed && _failed) _failed = false;
    });
  }

  void _onCut(bool cut) {
    if (cut && !_cut) _announce(AccountScreen.nameCut);
    if (cut != _cut) setState(() => _cut = cut);
  }

  void _announce(String message) {
    unawaited(
      SemanticsService.announce(
        message,
        Directionality.maybeOf(context) ?? TextDirection.ltr,
        assertiveness: Assertiveness.polite,
      ),
    );
  }

  void _edit() {
    final current = _saved ?? '';
    _text = current;
    _field.value = TextEditingValue(
      text: current,
      selection: TextSelection.collapsed(offset: current.length),
    );
    setState(() {
      _editing = true;
      _failed = false;
      _expired = false;
      _cut = false;
    });
    _focus.requestFocus();
  }

  void _cancel() {
    if (_saving) return;
    _focus.unfocus();
    setState(() {
      _editing = false;
      _failed = false;
      _expired = false;
      _cut = false;
    });
  }

  Future<void> _save() async {
    if (_saving || !_editing) return;
    final next = normalizeProfileName(_field.text);
    if (next == (_saved ?? '')) {
      _cancel();
      return;
    }
    _focus.unfocus();
    setState(() {
      _saving = true;
      _failed = false;
    });
    _announce('Saving');
    // Held across the awaits: if the listener leaves mid-save, /me is still
    // refreshed so You, chat and the save dialog's author default update.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(accountApiProvider).updateUser(name: next);
    } catch (error) {
      if (!mounted) return;
      final expired = error is ApiException && error.statusCode == 401;
      setState(() {
        _saving = false;
        _failed = !expired;
        _expired = expired;
      });
      if (expired) {
        _announce(AccountScreen.nameExpired);
        widget.onSessionExpired();
      } else {
        _announce(AccountScreen.nameFailed);
      }
      return;
    }
    // `/me` is the one reader: Account, You and the save dialog's author
    // default all derive from it. Wait for the stored (normalised) name so
    // the row never flashes the old one.
    container.invalidate(meProvider);
    if (!mounted) return;
    try {
      await container.read(accountNameProvider.future);
    } catch (_) {
      // The write landed; a failed reread only leaves the row stale.
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = false;
      _cut = false;
    });
    _announce(
      next.isEmpty ? AccountScreen.nameRemoved : AccountScreen.nameSaved,
    );
  }

  /// The row's frame, as [InsetRow]'s: the avatar, then [middle] taking the
  /// width it is given, then [trailing].
  Widget _row(Widget middle, {Widget? trailing}) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: InsetGroup.rowInset),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        vertical: InsetRow.verticalPadding,
        horizontal: 16,
      ),
      child: Row(
        children: [
          const _PrismAvatar(),
          const SizedBox(width: 12),
          Expanded(child: middle),
          if (trailing != null) ...[const SizedBox(width: 12), trailing],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final saved = _saved;
    if (!widget.editable) {
      return InsetGroup(
        children: [
          InsetRow(
            leading: const _PrismAvatar(),
            title: saved ?? AccountScreen.unnamedListener,
          ),
        ],
      );
    }
    if (!_editing) {
      final action = saved == null
          ? AccountScreen.addName
          : AccountScreen.editName;
      return InsetGroup(
        children: [
          // The whole row is one button: "Your account. Add name, button."
          Semantics(
            container: true,
            button: true,
            label: saved == null
                ? '${AccountScreen.unnamedListener}. $action'
                : '$saved, your name. $action',
            onTap: _edit,
            excludeSemantics: true,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: AccountScreen.nameRowKey,
                onTap: _edit,
                child: _row(
                  // A long name wraps; never an ellipsis.
                  Text(
                    saved ?? AccountScreen.unnamedListener,
                    style: tokens.rowTitle,
                  ),
                  // Reserve only the action's width; cap it for large text.
                  trailing: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.3,
                    ),
                    child: TextAction(label: action, onPressed: _edit),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Marked text an IME is still composing is neither counted nor capped.
    final length = nameLength(committedText(_field.value));
    final atCap = _cut || length >= profileNameMax;
    final Widget line;
    if (_saving) {
      // Keeps the line's height so nothing shifts.
      line = Text(' ', style: tokens.meta);
    } else if (_failed || _expired) {
      line = Row(
        children: [
          Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 15,
            color: tokens.errInk,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _expired ? AccountScreen.nameExpired : AccountScreen.nameFailed,
              style: tokens.meta.copyWith(color: tokens.errInk),
            ),
          ),
        ],
      );
    } else {
      line = Text(
        atCap ? AccountScreen.nameCut : AccountScreen.nameHint,
        style: tokens.meta.copyWith(color: tokens.muted),
      );
    }
    final showClear = _focus.hasFocus && !_saving && _field.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InsetGroup(
          children: [
            _row(
              TextField(
                key: AccountScreen.nameFieldKey,
                controller: _field,
                focusNode: _focus,
                readOnly: _saving,
                inputFormatters: [_formatter],
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.words,
                autocorrect: false,
                keyboardType: TextInputType.name,
                autofillHints: const [AutofillHints.name],
                onSubmitted: (_) => _save(),
                // Done saves; leaving the field does nothing (no silent
                // saves), so a tap outside must not close the keyboard.
                onTapOutside: (_) {},
                maxLines: null,
                style: tokens.rowTitle.copyWith(
                  fontWeight: FontWeight.w400,
                  color: _saving ? tokens.muted : tokens.text,
                ),
                cursorColor: tokens.plum,
                decoration: InputDecoration.collapsed(
                  hintText: AccountScreen.nameLabel,
                  hintStyle: tokens.rowTitle.copyWith(
                    fontWeight: FontWeight.w400,
                    color: tokens.muted,
                  ),
                ),
              ),
              trailing: showClear
                  ? Semantics(
                      button: true,
                      label: 'Clear text',
                      excludeSemantics: true,
                      onTap: _field.clear,
                      child: GestureDetector(
                        key: AccountScreen.nameClearKey,
                        behavior: HitTestBehavior.opaque,
                        onTap: _field.clear,
                        child: SizedBox.square(
                          dimension: MixtapeMetrics.minTarget,
                          child: Icon(
                            CupertinoIcons.clear_circled_solid,
                            size: 17,
                            color: tokens.muted,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 16),
          child: Row(
            children: [
              // Save and Cancel wrap onto two lines before shrinking.
              Expanded(
                child: Wrap(
                  spacing: 4,
                  children: [
                    TextAction(
                      key: AccountScreen.nameSaveKey,
                      label: _saving
                          ? AccountScreen.nameSaving
                          : _failed
                          ? 'Retry'
                          : 'Save',
                      onPressed: _saving || _expired ? null : _save,
                    ),
                    TextAction(
                      key: AccountScreen.nameCancelKey,
                      label: 'Cancel',
                      quiet: true,
                      onPressed: _saving ? null : _cancel,
                    ),
                  ],
                ),
              ),
              // Its own stop for VoiceOver, after Save and Cancel.
              if (length >= AccountScreen.nameCountFrom)
                Text(
                  '$length of $profileNameMax',
                  style: tokens.meta.copyWith(color: tokens.muted),
                ),
            ],
          ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: line),
      ],
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
