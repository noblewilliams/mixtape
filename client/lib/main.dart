import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/theme/mixtape_theme.dart';
import 'presentation/screens/choose_service_screen.dart';
import 'presentation/screens/debug/foundation_gallery_screen.dart';
import 'presentation/screens/sign_in_screen.dart';

/// Run with `flutter run --dart-define=MIXTAPE_GALLERY=true` to open the
/// debug-only foundation gallery instead of the app.
const bool showFoundationGallery = bool.fromEnvironment('MIXTAPE_GALLERY');

void main() {
  runApp(const ProviderScope(child: MixtapeApp()));
}

class MixtapeApp extends ConsumerWidget {
  const MixtapeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return MaterialApp(
      // Replacing only `home` leaves pushed account screens and dialogs above
      // sign-in. Give every auth state its own navigator history.
      key: ValueKey(auth),
      title: 'mixtape',
      theme: MixtapeTheme.light(),
      darkTheme: MixtapeTheme.dark(),
      home: showFoundationGallery && kDebugMode
          ? const FoundationGalleryScreen()
          : switch (auth) {
              AuthStatus.unknown => const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
              AuthStatus.signedOut => const SignInScreen(),
              // ServiceGate resolves to Home once the listener has a service (or
              // onboarding cannot be read).
              AuthStatus.signedIn => const ServiceGate(),
            },
    );
  }
}
