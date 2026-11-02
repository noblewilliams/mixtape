/// The AI-consent prompt (plan
/// `docs/superpowers/plans/2026-11-02-ai-consent-and-privacy.md` → Copy,
/// Where it shows). One body, always in the app's standard sheet: over the
/// first-run page before the first prompt is sent, once over the shell when
/// `/me` says not yet, and again from any send while consent is missing.
///
/// Laid out like the Keep this mix sheet: a heading, the notice, the Privacy
/// policy link, one paper pill and Not now. Nothing boxed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ai_consent_provider.dart';
import '../providers/onboarding_provider.dart' show linkOpenerProvider;
import '../screens/first_run/step_scaffold.dart' show FirstRunPill;
import '../theme/mixtape_theme.dart';
import 'foundation/mixtape_sheet.dart';

/// The plan's exact copy, and the sheet's keys.
abstract final class AiConsentCopy {
  static const String title = 'Before your first mix';
  static const String body =
      'Mixtape’s DJ runs on Anthropic’s Claude. To make your mixes we send it '
      'what you type or say, and the music and listening history you add. '
      'Voice clips are transcribed by Groq. Your data is not sold or used '
      'for ads.';
  static const String privacyLabel = 'Privacy policy';
  static const String agreeLabel = 'Agree and continue';
  static const String notNowLabel = 'Not now';
  static const String saveFailed = 'Couldn’t save that. Try again.';

  static const Key titleKey = Key('ai-consent-title');
  static const Key privacyKey = Key('ai-consent-privacy');
  static const Key agreeKey = Key('ai-consent-agree');
  static const Key notNowKey = Key('ai-consent-not-now');
  static const Key errorKey = Key('ai-consent-error');
}

/// The privacy policy on the landing site, linked from the sheet and You.
final Uri privacyPolicyUri = Uri.parse('https://miixtape.netlify.app/privacy/');

/// Opens [privacyPolicyUri] outside the app.
void openPrivacyPolicy(WidgetRef ref) {
  ref.read(linkOpenerProvider)(privacyPolicyUri);
}

/// Shows the sheet over [context]. True once consent is recorded; false on
/// Not now, the handle or the scrim. [beforeGrant] runs first on Agree (the
/// first run creates its anonymous listener there).
Future<bool> showAiConsentSheet(
  BuildContext context, {
  Future<void> Function()? beforeGrant,
}) async {
  final agreed = await showMixtapeSheet<bool>(
    context,
    isScrollControlled: true,
    builder: (_) => AiConsentPanel(beforeGrant: beforeGrant),
  );
  return agreed == true;
}

/// The gate in front of anything that sends to the DJ: true to go on, either
/// because consent is not needed or because the listener just agreed.
///
/// [beforeSession] is the first run's: with no listener yet it asks, and
/// [beforeGrant] creates one on Agree. Elsewhere no session means nothing
/// to ask about.
Future<bool> confirmAiConsent(
  BuildContext context, {
  bool beforeSession = false,
  Future<void> Function()? beforeGrant,
}) async {
  final ProviderContainer container;
  try {
    container = ProviderScope.containerOf(context, listen: false);
  } on StateError {
    // A widget pumped without a scope in a test: nothing to ask.
    return true;
  }
  final notifier = container.read(aiConsentProvider.notifier);
  if (!await notifier.isRequired(beforeSession: beforeSession)) {
    return true;
  }
  if (!context.mounted) return false;
  return showAiConsentSheet(context, beforeGrant: beforeGrant);
}

/// A send the server refused with `403 ai_consent_required` (enforcement on,
/// and `/me` failed or was out of date): from now on every send asks first,
/// and the sheet shows now. True on Agree, so the caller can send again.
Future<bool> confirmAiConsentAfterRefusal(BuildContext context) async {
  try {
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(aiConsentProvider.notifier).markRequired();
  } on StateError {
    return false;
  }
  return confirmAiConsent(context);
}

/// The sheet's content. Agree records consent and closes with true; a
/// failure stays open with one short line.
class AiConsentPanel extends ConsumerStatefulWidget {
  const AiConsentPanel({super.key, this.beforeGrant});

  final Future<void> Function()? beforeGrant;

  @override
  ConsumerState<AiConsentPanel> createState() => _AiConsentPanelState();
}

class _AiConsentPanelState extends ConsumerState<AiConsentPanel> {
  bool _saving = false;
  bool _failed = false;

  Future<void> _agree() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.beforeGrant?.call();
      // Read after [beforeGrant]: a new session rebuilt the notifier.
      await ref.read(aiConsentProvider.notifier).grant();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: AiConsentCopy.title,
      // 200 % text scrolls inside the sheet rather than overflowing it.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                AiConsentCopy.title,
                key: AiConsentCopy.titleKey,
                style: tokens.largeTitle.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  letterSpacing: -0.6,
                  color: tokens.text,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AiConsentCopy.body,
              style: tokens.body.copyWith(
                fontSize: 16,
                height: 1.4,
                color: tokens.text,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: AiConsentCopy.privacyKey,
                onPressed: () => openPrivacyPolicy(ref),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.plum,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, MixtapeMetrics.minTarget),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  AiConsentCopy.privacyLabel,
                  style: tokens.body.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: tokens.plum,
                    decoration: TextDecoration.underline,
                    decorationColor: tokens.plum,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: const ShapeDecoration(
                shape: StadiumBorder(
                  side: BorderSide(color: Color.fromRGBO(50, 44, 50, 0.14)),
                ),
              ),
              child: FirstRunPill(
                key: AiConsentCopy.agreeKey,
                label: AiConsentCopy.agreeLabel,
                emphasis: true,
                onPressed: _saving ? null : () => _agree(),
              ),
            ),
            if (_failed) ...[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(
                  AiConsentCopy.saveFailed,
                  key: AiConsentCopy.errorKey,
                  textAlign: TextAlign.center,
                  style: tokens.meta.copyWith(
                    fontSize: 13,
                    color: tokens.errInk,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                key: AiConsentCopy.notNowKey,
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.text,
                  minimumSize: const Size(
                    MixtapeMetrics.minTarget,
                    MixtapeMetrics.minTarget,
                  ),
                ),
                child: Text(
                  AiConsentCopy.notNowLabel,
                  style: tokens.body.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one-time sheet over the signed-in app: shown when `/me` says this
/// listener (account or anonymous) has not agreed, once per launch. Not now
/// puts it away until the next auth transition; a send asks again
/// ([confirmAiConsent]).
class AiConsentPrompt extends ConsumerStatefulWidget {
  const AiConsentPrompt({super.key, required this.child, this.sheetContext});

  final Widget child;

  /// Where the sheet is shown. The shell hands in the selected tab's
  /// navigator, so the dock steps aside for it as for any sheet. Defaults to
  /// this widget's own context.
  final BuildContext? Function()? sheetContext;

  @override
  ConsumerState<AiConsentPrompt> createState() => _AiConsentPromptState();
}

class _AiConsentPromptState extends ConsumerState<AiConsentPrompt> {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(aiConsentNeededProvider, (_, needed) {
      if (!needed) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _show());
    }, fireImmediately: true);
  }

  Future<void> _show() async {
    if (_showing || !mounted) return;
    if (!ref.read(aiConsentNeededProvider)) return;
    final consent = ref.read(aiConsentProvider);
    // A refused send shows its own sheet; this one stays out of its way.
    if (consent.dismissed || consent.required) return;
    final target = widget.sheetContext?.call() ?? context;
    if (!target.mounted) return;
    _showing = true;
    final agreed = await showAiConsentSheet(target);
    _showing = false;
    if (!agreed && mounted) ref.read(aiConsentProvider.notifier).dismiss();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
