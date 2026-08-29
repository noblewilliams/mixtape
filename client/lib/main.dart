import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/screens/home_screen.dart';
import 'presentation/screens/sign_in_screen.dart';

void main() {
  runApp(const ProviderScope(child: MixtapeApp()));
}

class MixtapeApp extends ConsumerWidget {
  const MixtapeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return MaterialApp(
      title: 'mixtape',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: switch (auth) {
        AuthStatus.unknown => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.signedOut => const SignInScreen(),
        AuthStatus.signedIn => const HomeScreen(),
      },
    );
  }
}
