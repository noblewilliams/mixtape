import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/config.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/providers/first_run_provider.dart';
import 'presentation/providers/name_page_provider.dart';
import 'presentation/theme/mixtape_theme.dart';
import 'presentation/screens/debug/foundation_gallery_screen.dart';
import 'presentation/screens/first_run/first_run_flow.dart';
import 'presentation/screens/first_run/name_screen.dart';
import 'presentation/screens/shell/shell_screen.dart';
import 'presentation/widgets/foundation/glass_occlusion.dart';
import 'presentation/widgets/foundation/gradient_background.dart';

/// Run with `flutter run --dart-define=MIXTAPE_GALLERY=true` to open the
/// debug-only foundation gallery instead of the app.
const bool showFoundationGallery = bool.fromEnvironment('MIXTAPE_GALLERY');

void main() {
  // Fail fast: a store build missing its production define must not ship.
  final problem = releaseConfigProblem(
    AppConfig.apiBaseUrl,
    release: kReleaseMode,
  );
  if (problem != null) throw StateError(problem);
  runApp(const ProviderScope(child: MixtapeApp()));
}

/// What the root shows. The first-run flow covers no session at all and an
/// anonymous session the flow itself created and has not yet handed off
/// (first-run spec, Account model → Gating); everything else with a session
/// is the shell.
enum _Root { unknown, firstRun, shell }

/// One [GlassOcclusionObserver] per root navigator: each root key below
/// builds a fresh navigator, and an observer watches one at a time. Menus
/// and alerts go on the root navigator, over a tab's screen and its glass.
final _rootGlassObservers = <Object, GlassOcclusionObserver>{};

class MixtapeApp extends ConsumerWidget {
  const MixtapeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final anonymous = ref.watch(isAnonymousProvider);
    final firstRunActive = ref.watch(firstRunActiveProvider);
    // The name page's device flag loads from launch, beside the token, so
    // the account root rarely has to wait for it (2026-11-02 profile name).
    ref.listen(namePageSettledProvider, (_, _) {});
    final root = switch (auth) {
      AuthStatus.unknown => _Root.unknown,
      AuthStatus.noSession => _Root.firstRun,
      AuthStatus.session =>
        anonymous && firstRunActive ? _Root.firstRun : _Root.shell,
    };
    final appKey = (root, root == _Root.shell && anonymous);
    final glassObserver = _rootGlassObservers.putIfAbsent(
      appKey,
      GlassOcclusionObserver.new,
    );
    return MaterialApp(
      // Replacing only `home` leaves pushed account screens and dialogs above
      // sign-in. Give every root its own navigator history — keyed by the
      // root rather than the auth status, so the anonymous session the
      // first-run flow creates mid-flow keeps the flow's pages in place. The
      // shell is keyed on anonymity too: a link from an anonymous session
      // always remounts it as the account (dropping the sign-in page pushed
      // over it, and letting Home send a capped prompt), even when the
      // auth provider's pass through `unknown` lands within one frame.
      key: ValueKey(appKey),
      navigatorObservers: [glassObserver],
      title: 'mixtape',
      theme: MixtapeTheme.light(),
      darkTheme: MixtapeTheme.dark(),
      // Scaffolds are transparent by theme; the gradient paints behind every
      // route (sign-in and onboarding included), not only inside the shell.
      builder: (context, child) => GradientBackground(child: child!),
      home: showFoundationGallery && kDebugMode
          ? const FoundationGalleryScreen()
          : switch (root) {
              _Root.unknown => const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
              _Root.firstRun => const FirstRunFlow(),
              // An account's shell waits behind the name page when /me
              // asks for a name; anonymous sessions pass straight through.
              _Root.shell => const NameGateView(child: ShellScreen()),
            },
    );
  }
}
