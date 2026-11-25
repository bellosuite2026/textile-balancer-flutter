import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'features/auth/login_screen.dart';
import 'features/workshops/workshop_select_screen.dart';
import 'state/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

class TextileBalancerApp extends StatelessWidget {
  const TextileBalancerApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider(create: (_) => ShellNav()),
        ],
        child: MaterialApp(
          title: 'Textile Line Balancer',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          locale: const Locale('fr', 'FR'),
          supportedLocales: const [Locale('fr', 'FR')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const RootGate(),
        ),
      );
}

/// Aiguillage : choix du mode → choix de l'atelier → application.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    if (!s.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (s.passwordRecovery) return const PasswordRecoveryScreen();
    if (s.mode == AppMode.none) return const LoginScreen();
    if (s.workshop == null) return const WorkshopSelectScreen();
    return const AppShell();
  }
}
