/// "What should we call you?" (2026-11-02 profile name; board
/// `docs/mockups/2026-11-02-profile-name-states.html` frames N1 to N8;
/// approval `docs/mockups/approved/2026-11-02-profile-name.md`).
///
/// One optional first-run page on the plum sign-in image, shown once per
/// account after a sign-in that leaves no usable name, and once at launch
/// for an existing account in that state. No back (the listener is signed
/// in; Skip is the way past) and no autofocus (one tap raises the keyboard,
/// drawn dark on the graphic). [NameGateView] decides between it and the
/// shell from GET /me's askName ([nameGateProvider]).
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/auth/account_api.dart';
import '../../../data/auth/profile_name.dart';
import '../../providers/capabilities_provider.dart';
import '../../providers/name_page_provider.dart';
import '../../theme/mixtape_theme.dart';
import 'step_scaffold.dart';

/// The account root: the name page, the sign-in image while `/me` decides,
/// or [child] (the shell). The shell is not built until the question is
/// settled, so Home (and a prompt kept from the cap) starts after the page.
class NameGateView extends ConsumerStatefulWidget {
  const NameGateView({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NameGateView> createState() => _NameGateViewState();
}

class _NameGateViewState extends ConsumerState<NameGateView> {
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    // /me said no: this device need not wait for it on the next launch.
    // Only a settled answer counts; a value carried while /me reloads for
    // a new session belongs to the previous one.
    ref.listenManual<AsyncValue<Me?>>(meProvider, (_, next) {
      if (next.isLoading) return;
      final me = next.value;
      if (me == null || me.isAnonymous || me.askName) return;
      ref.read(namePageSettledProvider.notifier).markSettled();
    }, fireImmediately: true);
    // The image waits for /me at most [nameHoldTimeout], then the shell.
    ref.listenManual<NameGate>(nameGateProvider, (_, gate) {
      if (gate != NameGate.hold) {
        _holdTimer?.cancel();
        _holdTimer = null;
        return;
      }
      _holdTimer ??= Timer(nameHoldTimeout, () {
        _holdTimer = null;
        if (mounted) ref.read(nameHoldExpiredProvider.notifier).expire();
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gate = ref.watch(nameGateProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(
        key: ValueKey(gate),
        child: switch (gate) {
          // The launch placeholder continues for the moment the flag loads.
          NameGate.wait => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          NameGate.hold => const NamePageHold(),
          NameGate.ask => const NameScreen(),
          NameGate.off => widget.child,
        },
      ),
    );
  }
}

/// The sign-in image alone, while GET /me decides whether to ask.
class NamePageHold extends StatelessWidget {
  const NamePageHold({super.key});

  static const Key holdKey = Key('name-page-hold');

  @override
  Widget build(BuildContext context) => Scaffold(
    key: holdKey,
    backgroundColor: FirstRunColors.base,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          FirstRunBackground.signIn.asset,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(gradient: FirstRunColors.scrim),
        ),
      ],
    ),
  );
}

class NameScreen extends ConsumerStatefulWidget {
  const NameScreen({super.key, this.forShare = false});

  /// Pushed by a mix's Share when the server needs a name first (spec
  /// 2026-11-13 shared-mixes, board S4/S5): Back in place of Skip, the line
  /// says who sees the name, and a saved name pops the page with true so
  /// the share goes on. Back pops with nothing and nothing is shared.
  final bool forShare;

  /// The route Share pushes; it completes with true once a name is saved.
  static Route<bool> shareRoute() =>
      MaterialPageRoute<bool>(builder: (_) => const NameScreen(forShare: true));

  static const String headline = 'What should we call you?';
  static const String line =
      'It shows in Account, and the DJ may use it now and then.';
  static const String shareLine =
      'Whoever opens your link will see your first name.';
  static const String placeholder = 'Your name';
  static const String typeName = 'Type a name.';
  static const String saving = 'Saving';
  static const String failed = 'Couldn’t save your name.';
  static const String cut = 'Names stop at 40 characters.';

  /// The count appears from this many characters.
  static const int countFrom = 30;

  static const Key fieldKey = Key('name-page-field');
  static const Key continueKey = Key('name-page-continue');
  static const Key statusKey = Key('name-page-status');

  @override
  ConsumerState<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends ConsumerState<NameScreen> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  late final _formatter = ProfileNameFormatter(onCut: _onCut);
  bool _saving = false;
  bool _failed = false;
  bool _cut = false;
  String _text = '';

  @override
  void initState() {
    super.initState();
    _field.addListener(_changed);
  }

  @override
  void dispose() {
    _field.removeListener(_changed);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted || _field.text == _text) return;
    _text = _field.text;
    // Typing after a failure clears the error; Retry is Continue again.
    setState(() => _failed = false);
  }

  void _onCut(bool cut) {
    if (cut && !_cut) _announce(NameScreen.cut);
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

  String get _name => normalizeProfileName(_field.text);

  Future<void> _continue() async {
    final name = _name;
    if (_saving || name.isEmpty) return;
    _focus.unfocus();
    setState(() {
      _saving = true;
      _failed = false;
    });
    _announce(NameScreen.saving);
    try {
      final page = ref.read(namePageProvider.notifier);
      await (widget.forShare ? page.saveForShare(name) : page.save(name));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      _announce(NameScreen.failed);
      return;
    }
    // Success closes the page; the next screen announces itself.
    if (widget.forShare && mounted) Navigator.of(context).pop(true);
  }

  /// Moves on at once; the asked flag is written behind it.
  void _skip() => ref.read(namePageProvider.notifier).skip();

  @override
  Widget build(BuildContext context) {
    final ready = _name.isNotEmpty;
    final Widget pill;
    if (_saving) {
      pill = FirstRunPill(
        key: NameScreen.continueKey,
        label: NameScreen.saving,
        // Full paper while it saves: the pill is busy, not unavailable.
        onPressed: () {},
        trailing: const _StillDots(),
      );
    } else if (_failed) {
      pill = FirstRunPill(
        key: NameScreen.continueKey,
        label: 'Retry',
        emphasis: true,
        onPressed: () => unawaited(_continue()),
      );
    } else {
      pill = FirstRunPill(
        key: NameScreen.continueKey,
        label: 'Continue',
        forward: true,
        disabledHint: NameScreen.typeName,
        onPressed: ready ? () => unawaited(_continue()) : null,
      );
    }
    return StepScaffold(
      background: FirstRunBackground.signIn,
      headline: NameScreen.headline,
      line: widget.forShare ? NameScreen.shareLine : NameScreen.line,
      // From Share, Back returns to the mix and nothing is shared; Skip is
      // not offered, since the share needs the name.
      showBack: widget.forShare,
      body: [const SizedBox(height: 24), _input(context), _status(context)],
      actions: [pill],
      // Off while a save is in flight, so its failure is never hidden.
      foot: widget.forShare
          ? null
          : FootLink(label: 'Skip', onPressed: _saving ? null : _skip),
    );
  }

  Widget _input(BuildContext context) {
    final tokens = paperTokens(context.tokens);
    final length = nameLength(_field.text);
    final counted = length >= NameScreen.countFrom;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: FirstRunColors.paper,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: NameScreen.fieldKey,
                  controller: _field,
                  focusNode: _focus,
                  readOnly: _saving,
                  inputFormatters: [_formatter],
                  keyboardAppearance: Brightness.dark,
                  keyboardType: TextInputType.name,
                  autofillHints: const [AutofillHints.name],
                  textCapitalization: TextCapitalization.words,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => unawaited(_continue()),
                  cursorColor: FirstRunColors.ink,
                  style: tokens.body.copyWith(
                    color: _saving
                        ? FirstRunColors.paperMuted
                        : FirstRunColors.ink,
                  ),
                  decoration: InputDecoration(
                    hintText: NameScreen.placeholder,
                    hintStyle: tokens.body.copyWith(
                      color: FirstRunColors.paperMuted,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    semanticCounterText: counted
                        ? '$length of $profileNameMax'
                        : null,
                  ),
                ),
              ),
              if (counted) ...[
                const SizedBox(width: 8),
                // Read with the field (its counter), not twice.
                ExcludeSemantics(
                  child: Text(
                    '$length of $profileNameMax',
                    style: tokens.meta.copyWith(
                      color: FirstRunColors.paperMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The reserved line under the field, so nothing moves when it fills.
  Widget _status(BuildContext context) {
    final style = context.tokens.meta.copyWith(
      fontSize: 15,
      height: 1.3,
      color: FirstRunColors.cream.withValues(alpha: 0.8),
    );
    final Widget content;
    if (_failed) {
      content = Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                CupertinoIcons.exclamationmark_circle,
                size: 15,
                color: FirstRunColors.err,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                NameScreen.failed,
                style: style.copyWith(color: FirstRunColors.err),
              ),
            ),
          ],
        ),
      );
    } else {
      final atCap = _cut || nameLength(_field.text) >= profileNameMax;
      // A space keeps the line's height while it is empty.
      content = Text(atCap ? NameScreen.cut : ' ', style: style);
    }
    return Padding(
      key: NameScreen.statusKey,
      padding: const EdgeInsets.only(top: 10, left: 4, right: 4),
      child: content,
    );
  }
}

/// Three still dots after "Saving": they never animate, in any mode.
class _StillDots extends StatelessWidget {
  const _StillDots();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: FirstRunColors.ink.withValues(alpha: 0.4 + 0.2 * i),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    ),
  );
}
