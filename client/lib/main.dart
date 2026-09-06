import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/screens/choose_service_screen.dart';
import 'presentation/screens/sign_in_screen.dart';

void main() {
  runApp(const ProviderScope(child: MixtapeApp()));
}

class MixtapeApp extends ConsumerWidget {
  const MixtapeApp({super.key});

  static const _brandPlum = Color(0xFF544451);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return MaterialApp(
      title: 'mixtape',
      theme: ThemeData(colorSchemeSeed: _brandPlum, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _brandPlum,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: switch (auth) {
        AuthStatus.unknown => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        AuthStatus.signedOut => const SignInScreen(),
        // ServiceGate resolves to Home once the listener has a service (or
        // onboarding cannot be read); Home stays the only screen that pushes
        // routes and hosts sign-out.
        AuthStatus.signedIn => const ServiceGate(),
      },
    );
  }
}
