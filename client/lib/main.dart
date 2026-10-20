import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/providers/first_run_provider.dart';
import 'presentation/theme/mixtape_theme.dart';
import 'presentation/screens/debug/foundation_gallery_screen.dart';
import 'presentation/screens/first_run/first_run_flow.dart';
import 'presentation/screens/shell/shell_screen.dart';
import 'presentation/widgets/foundation/gradient_background.dart';

/// Run with `flutter run --dart-define=MIXTAPE_GALLERY=true` to open the
/// debug-only foundation gallery instead of the app.
const bool showFoundationGallery = bool.fromEnvironment('MIXTAPE_GALLERY');

void main() {
  runApp(const ProviderScope(child: MixtapeApp()));
}

/// What the root shows. The first-run flow covers no session at all and an
/// anonymous session the flow itself created and has not yet handed off
/// (first-run spec, Account model → Gating); everything else with a session
/// is the shell.
enum _Root { unknown, firstRun, shell }

class MixtapeApp extends ConsumerWidget {
  const MixtapeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final anonymous = ref.watch(isAnonymousProvider);
    final firstRunActive = ref.watch(firstRunActiveProvider);
    final root = switch (auth) {
      AuthStatus.unknown => _Root.unknown,
      AuthStatus.noSession => _Root.firstRun,
      AuthStatus.session =>
        anonymous && firstRunActive ? _Root.firstRun : _Root.shell,
    };
    return MaterialApp(
      // Replacing only `home` leaves pushed account screens and dialogs above
      // sign-in. Give every root its own navigator history — keyed by the
      // root rather than the auth status, so the anonymous session the
      // first-run flow creates mid-flow keeps the flow's pages in place.
      key: ValueKey(root),
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
              _Root.shell => const ShellScreen(),
            },
    );
  }
}
